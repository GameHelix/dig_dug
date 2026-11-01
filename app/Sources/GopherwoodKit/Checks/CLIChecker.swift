import Foundation
import JQ

// MARK: - What the checker needs from HTTP

public struct CheckRequest: Sendable {
    public var method: String
    public var url: URL
    /// In order, as the step lists them, plus the content type of a body.
    public var headers: [NameValue]
    public var body: Data?
    public var basicAuth: NameValue?
    public var followRedirects: Bool
    public var timeout: Duration
}

public struct CheckResponse: Sendable {
    public var statusCode: Int
    public var headers: [NameValue]
    public var trailers: [NameValue]
    public var body: Data
    public var url: URL

    public init(statusCode: Int, headers: [NameValue], trailers: [NameValue], body: Data, url: URL) {
        self.statusCode = statusCode
        self.headers = headers
        self.trailers = trailers
        self.body = body
        self.url = url
    }

    /// All values of a field, joined with commas as Go does; nil if absent.
    public func header(_ name: String) -> String? { CheckResponse.lookup(headers, name) }
    public func trailer(_ name: String) -> String? { CheckResponse.lookup(trailers, name) }

    static func lookup(_ fields: [NameValue], _ name: String) -> String? {
        let values = fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
        return values.isEmpty ? nil : values.joined(separator: ",")
    }
}

/// Sends a step's HTTP request exactly as the step defines it. The app's implementation is
/// LessonHTTPTransport, its own HTTP/1.1 client on SwiftNIO, which reads trailers too.
public protocol HTTPSending: Sendable {
    func send(_ request: CheckRequest) async throws -> CheckResponse
    /// Releases connections and threads once a check run ends.
    func shutdown() async
}

extension HTTPSending {
    public func shutdown() async {}
}

// MARK: - Results

/// One check of a step, as shown under it.
public struct CheckLine: Hashable, Sendable {
    public enum State: Sendable { case passed, failed }
    public var text: String
    public var state: State

    public init(_ text: String, _ state: State) {
        self.text = text
        self.state = state
    }
}

public struct StepResult: Sendable {
    public var index: Int
    public var description: String
    /// The command or request as run, with ${variables} filled in.
    public var action: String
    /// What the command printed.
    public var output: String
    /// For an HTTP step: the response's status line, headers and body.
    public var response: CheckResponse?
    public var checks: [CheckLine]
    /// Why the step could not run or capture its values.
    public var error: String?
    public var duration: Duration = .zero
    /// What the step shows under it, made once when it finishes, off the main actor: the
    /// response (status, headers, the body as pretty JSON when it is JSON, trailers) or the
    /// command's output.
    public private(set) var shown = ""

    public var passed: Bool { error == nil && !checks.contains { $0.state == .failed } }

    mutating func finish() {
        shown = response.map(CLIChecker.describe) ?? output
    }
}

/// The result of running a lesson's checks.
public struct CheckRun: Sendable {
    public enum Status: Sendable { case passed, failed, error, cancelled }
    public var status: Status
    public var steps: [StepResult]
    public var error: String?
    public var baseURL: String
    public var duration: Duration = .zero
    /// A plain-text account of the run, for the attempt history; made when the run ends.
    public private(set) var report = ""

    mutating func finish() {
        var lines: [String] = []
        if let error { lines.append(error) }
        for s in steps {
            lines.append("\(s.passed ? "✓" : "✗") \(s.index + 1). \(s.description)")
            lines.append("  " + s.action)
            if let e = s.error { lines.append("  ! " + e) }
            for c in s.checks {
                let mark = c.state == .passed ? "✓" : "✗"
                lines.append("  \(mark) \(c.text)")
            }
            if !s.shown.isEmpty && !s.passed {
                let clipped = s.shown.count > 4000 ? String(s.shown.prefix(4000)) + "\n…" : s.shown
                lines.append(contentsOf: clipped.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 })
            }
        }
        report = lines.joined(separator: "\n")
    }
}

// MARK: - The checker

/// Runs a command-line lesson's steps: shell commands in
/// your project folder (under /bin/zsh -c) and HTTP requests to your server, each followed by
/// its tests. Values a step captures fill ${name} in later steps; a step that needs a value no
/// earlier step captured is skipped.
public struct CLIChecker: Sendable {
    public let environment: [String: String]
    public let jq: CompiledJQ
    /// Makes the HTTP client for one check run; it is shut down when the run ends.
    public let makeHTTP: @Sendable () -> any HTTPSending
    public var commandTimeout: Duration = .seconds(120)
    public var requestTimeout: Duration = .seconds(30)

    public init(environment: [String: String], jq: CompiledJQ = CompiledJQ(),
                makeHTTP: @escaping @Sendable () -> any HTTPSending = { LessonHTTPTransport() }) {
        self.environment = environment
        self.jq = jq
        self.makeHTTP = makeHTTP
    }

    /// Runs every step in order. `baseURL` fills ${baseURL}: your course's address, or the
    /// lesson's own. `onStep` hears about each step as it starts and as it finishes.
    @concurrent
    public func run(_ lesson: CLILesson, directory: String, baseURL: String?,
                    onStep: (@Sendable (Int, StepResult?) async -> Void)? = nil) async -> CheckRun {
        let http = makeHTTP()
        let clock = ContinuousClock()
        let started = clock.now
        var run = await run(lesson, directory: directory, baseURL: baseURL, http: http, onStep: onStep)
        run.duration = clock.now - started
        run.finish()
        await http.shutdown()
        return run
    }

    private func run(_ lesson: CLILesson, directory: String, baseURL: String?, http: any HTTPSending,
                     onStep: (@Sendable (Int, StepResult?) async -> Void)?) async -> CheckRun {
        let clock = ContinuousClock()
        var run = CheckRun(status: .passed, steps: [], error: nil, baseURL: "")

        var namespace: Set<String> = ["baseURL"]
        for (i, step) in lesson.steps.enumerated() {
            var seen = Set<String>()
            for name in step.captureNames {
                if name.isEmpty || name == "baseURL" || seen.contains(name) {
                    run.status = .error
                    run.error = "Step \(i + 1) captures “\(name)” twice or under a reserved name; this lesson cannot run."
                    return run
                }
                seen.insert(name)
                namespace.insert(name)
            }
        }

        var base = (baseURL ?? "").trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        run.baseURL = base
        if lesson.usesBaseURL && base.isEmpty {
            run.status = .error
            run.error = "This lesson calls your server: enter its address first, for example http://localhost:8080."
            return run
        }
        if lesson.hasCommands {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue else {
                run.status = .error
                run.error = "The project folder does not exist: \(directory)"
                return run
            }
        }

        var vars: [String: String] = [:]
        if !base.isEmpty { vars["baseURL"] = base }
        for (i, step) in lesson.steps.enumerated() {
            if Task.isCancelled {
                run.status = .cancelled
                return run
            }
            await onStep?(i, nil)
            let stepStarted = clock.now
            var result: StepResult
            let missing = CLIChecker.missingNames(step, namespace: namespace, values: vars)
            if !missing.isEmpty {
                for name in step.captureNames { vars.removeValue(forKey: name) }
                result = StepResult(index: i, description: step.description, action: step.actionText, output: "", checks: [],
                                    error: "Skipped: no earlier step captured \(missing.map { "${\($0)}" }.joined(separator: ", ")).")
            } else {
                switch step.action {
                case .command(let c): result = await command(c, directory: directory, vars: &vars)
                case .http(let h): result = await request(h, vars: &vars, http: http)
                }
                result.index = i
                result.description = step.description
                if let ms = step.sleepAfterMs, ms > 0 { try? await Task.sleep(for: .milliseconds(min(ms, 30_000))) }
            }
            result.duration = clock.now - stepStarted
            result.finish()
            if !result.passed { run.status = .failed }
            run.steps.append(result)
            await onStep?(i, result)
        }
        if Task.isCancelled { run.status = .cancelled }
        return run
    }

    // MARK: Variables

    /// Fills ${name} from captured values; unknown names stay as written.
    public static func interpolate(_ text: String, _ vars: [String: String]) -> String {
        text.replacing(/\$\{([^}]+)\}/) { m in vars[String(m.1)] ?? String(m.0) }
    }

    /// Fills ${name} inside JSON text with each value escaped as a JSON string's contents.
    public static func interpolateJSON(_ text: String, _ vars: [String: String]) -> String {
        text.replacing(/\$\{([^}]+)\}/) { m in
            guard let value = vars[String(m.1)] else { return String(m.0) }
            let quoted = JQValue.string(value).jsonString()
            return String(quoted.dropFirst().dropLast())
        }
    }

    static func names(_ text: String) -> [String] {
        text.matches(of: /\$\{([^}]+)\}/).map { String($0.1) }
    }

    /// Names the step uses that some step captures but none has captured (yet).
    static func missingNames(_ step: CLIStep, namespace: Set<String>, values: [String: String]) -> [String] {
        var texts: [String] = []
        switch step.action {
        case .command(let c):
            texts.append(c.command)
        case .http(let h):
            texts.append(h.fullURL)
            texts += h.headers.map(\.value)
            switch h.body {
            case .json(let body)?: texts += (try? JQValue(json: body)).map(strings) ?? [body]
            case .form(let fields)?: texts += fields.map(\.value)
            case nil: break
            }
        }
        return Array(Set(texts.flatMap(names).filter { namespace.contains($0) && values[$0] == nil })).sorted()
    }

    static func strings(_ v: JQValue) -> [String] {
        switch v {
        case .string(let s): [s]
        case .array(let a): a.flatMap(strings)
        case .object(let o): o.flatMap { strings($0.value) }
        default: []
        }
    }

    /// The first group of `pattern` in `input`; the pattern must have exactly one group.
    static func capture(_ pattern: String, _ input: String) -> (value: String?, error: String?) {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return (nil, "the pattern “\(pattern)” is not valid") }
        guard re.numberOfCaptureGroups == 1 else { return (nil, "the pattern “\(pattern)” needs exactly one group") }
        let ns = input as NSString
        guard let m = re.firstMatch(in: input, range: NSRange(location: 0, length: ns.length)), m.range(at: 1).location != NSNotFound else {
            return (nil, nil)
        }
        return (ns.substring(with: m.range(at: 1)), nil)
    }

    /// Publishes a step's captures: all of them, or none if one is missing.
    static func publish(_ names: [String], _ captured: [String: String], into vars: inout [String: String]) -> String? {
        for name in names { vars.removeValue(forKey: name) }
        if let missing = names.first(where: { captured[$0] == nil }) { return "missing value for “\(missing)”" }
        for name in names { vars[name] = captured[name] }
        return nil
    }

    // MARK: Commands

    func command(_ c: CLICommand, directory: String, vars: inout [String: String]) async -> StepResult {
        let final = CLIChecker.interpolate(c.command, vars)
        var r = StepResult(index: 0, description: "", action: final, output: "", checks: [], error: nil)
        var env = environment
        env["LANG"] = "en_US.UTF-8"
        let out = await ProcessRunner.run(ProcessRequest(executable: SystemTools.zsh, arguments: ["-c", final], directory: directory,
                                                         environment: env, timeout: commandTimeout, outputLimit: 1 << 20))
        r.output = out.truncated ? out.combined + "\n… output cut off" : out.combined
        if let launch = out.launchError {
            r.error = "The command could not start: \(launch)"
            return r
        }
        if out.cancelled {
            r.error = "Stopped."
        } else if out.timedOut {
            r.error = "Stopped: the command ran longer than \(commandTimeout.components.seconds) seconds."
        } else if out.exitCode < 0 {
            r.error = "The command was stopped by signal \(out.signal)."
        }
        var stdout = out.stdout
        while let last = stdout.last, " \n\t\r".contains(last) { stdout.removeLast() }
        if let filter = c.stdoutFilterTmdl { stdout = extractTmdlBlock(stdout, filter) }

        var captured: [String: String] = [:]
        for v in c.variables {
            let (value, problem) = CLIChecker.capture(v.value, stdout)
            if let problem { r.error = r.error ?? problem }
            if let value { captured[v.name] = value }
        }
        if let problem = CLIChecker.publish(c.variables.map(\.name), captured, into: &vars) { r.error = r.error ?? problem }

        for t in c.tests {
            switch t {
            case .exitCode(let want):
                r.checks.append(CheckLine("exits with code \(want) (got \(out.exitCode))", out.exitCode == Int32(want) ? .passed : .failed))
            case .stdoutContainsAll(let texts):
                for text in texts {
                    let want = CLIChecker.interpolate(text, vars)
                    r.checks.append(CheckLine("output contains “\(want)”", stdout.contains(want) ? .passed : .failed))
                }
            case .stdoutContainsNone(let texts):
                for text in texts {
                    let bad = CLIChecker.interpolate(text, vars)
                    r.checks.append(CheckLine("output does not contain “\(bad)”", stdout.contains(bad) ? .failed : .passed))
                }
            case .stdoutLinesGT(let n):
                let count = stdout.isEmpty ? 0 : stdout.filter { $0 == "\n" }.count + 1
                r.checks.append(CheckLine("output has more than \(n) lines (got \(count))", count > n ? .passed : .failed))
            case .stdoutJq(let query, let jsonl, let expected):
                r.checks.append(jqCheck(query, input: Data(stdout.utf8), jsonl: jsonl, expected: expected))
            }
        }
        return r
    }

    func jqCheck(_ query: String, input: Data, jsonl: Bool, expected: [JqExpectation]) -> CheckLine {
        let label = "jq “\(query.count > 90 ? String(query.prefix(90)) + "…" : query)”"
        let results: [JQValue]
        do {
            results = try jq.run(query, on: try JQValue(json: input, mode: jsonl ? .jsonl : .json))
        } catch {
            return CheckLine("\(label) fails: \(error.localizedDescription)", .failed)
        }
        guard !results.isEmpty else { return CheckLine("\(label) gives no result", .failed) }
        let got = results.map { $0.jsonString() }.joined(separator: ", ")
        let ok = expected.allSatisfy { e in results.contains { CLIChecker.jqMatches($0, e) } }
        let want = expected.map { "\($0.op) \(CLIChecker.describe($0.value))" }.joined(separator: " and ")
        return CheckLine("\(label) gives a value \(want) (got \(got))", ok ? .passed : .failed)
    }

    /// Compares one jq result with one expectation: bools and strings by == and !=, whole
    /// numbers by all six operators.
    static func jqMatches(_ actual: JQValue, _ e: JqExpectation) -> Bool {
        switch e.value {
        case .bool(let want):
            guard let got = coerceBool(actual) else { return false }
            return e.op == "!=" ? got != want : (e.op == "==" && got == want)
        case .string(let want):
            guard case .string(let got) = actual else { return false }
            return e.op == "!=" ? got != want : (e.op == "==" && got == want)
        case .int(let want):
            guard let got = coerceInt(actual) else { return false }
            return compare(got, e.op, want)
        }
    }

    static func coerceBool(_ v: JQValue) -> Bool? {
        switch v {
        case .bool(let b): b
        case .string(let s): ["1", "t", "T", "TRUE", "true", "True"].contains(s) ? true : (["0", "f", "F", "FALSE", "false", "False"].contains(s) ? false : nil)
        default: nil
        }
    }

    static func coerceInt(_ v: JQValue) -> Int? {
        switch v {
        case .number(let n): n.intValue
        case .string(let s): Int(s)
        default: nil
        }
    }

    static func compare(_ got: Int, _ op: String, _ want: Int) -> Bool {
        switch op {
        case "==", "eq": got == want
        case "!=", "ne": got != want
        case ">", "gt": got > want
        case ">=", "gte": got >= want
        case "<", "lt": got < want
        case "<=", "lte": got <= want
        default: false
        }
    }

    static func describe(_ v: TypedValue) -> String {
        switch v {
        case .bool(let b): b ? "true" : "false"
        case .int(let i): String(i)
        case .string(let s): "“\(s)”"
        }
    }

    /// A response as text: status, headers, trailers and body (pretty JSON when it is JSON).
    public static func describe(_ r: CheckResponse) -> String {
        var lines = ["HTTP \(r.statusCode)"]
        lines += r.headers.map { "\($0.name): \($0.value)" }
        let text = String(decoding: r.body, as: UTF8.self)
        if !r.body.isEmpty {
            lines.append("")
            lines.append((try? JQValue(json: r.body)).map { $0.jsonString(pretty: true) } ?? text)
        }
        if !r.trailers.isEmpty {
            lines.append("")
            lines += r.trailers.map { "\($0.name): \($0.value)  (trailer)" }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: HTTP

    func request(_ h: HTTPStep, vars: inout [String: String], http: any HTTPSending) async -> StepResult {
        let target = CLIChecker.interpolate(h.fullURL, vars)
        let method = h.method.uppercased()
        var r = StepResult(index: 0, description: "", action: "\(method) \(target)", output: "", checks: [], error: nil)
        let captureNames = h.bodyVariables.map(\.name) + h.headerVariables.map(\.name)
        guard target.hasPrefix("http://") || target.hasPrefix("https://"), let url = URL(string: target) else {
            _ = CLIChecker.publish(captureNames, [:], into: &vars)
            r.error = "\(target) is not a web address. Set your server's address first, for example http://localhost:8080."
            return r
        }

        var headers: [NameValue] = []
        var body: Data?
        switch h.body {
        case .json(let raw)?:
            // The body as stored, verbatim; ${names} sit inside JSON strings, so their values
            // go in JSON-escaped.
            body = Data(CLIChecker.interpolateJSON(raw, vars).utf8)
            headers.append(NameValue("Content-Type", "application/json"))
        case .form(let fields)?:
            body = Data(CLIChecker.formEncode(fields.map { NameValue($0.name, CLIChecker.interpolate($0.value, vars)) }).utf8)
            headers.append(NameValue("Content-Type", "application/x-www-form-urlencoded"))
        case nil:
            break
        }
        for field in h.headers { headers.append(NameValue(field.name, CLIChecker.interpolate(field.value, vars))) }

        let response: CheckResponse
        do {
            response = try await http.send(CheckRequest(method: method, url: url, headers: headers, body: body, basicAuth: h.basicAuth,
                                                        followRedirects: h.followRedirects, timeout: requestTimeout))
        } catch is CancellationError {
            _ = CLIChecker.publish(captureNames, [:], into: &vars)
            r.error = "Stopped."
            return r
        } catch {
            _ = CLIChecker.publish(captureNames, [:], into: &vars)
            let server = vars["baseURL"].map { " Is your server running at \($0)?" } ?? ""
            r.error = "Could not reach the server: \(error.localizedDescription).\(server)"
            return r
        }
        r.response = response
        let text = String(decoding: response.body, as: UTF8.self)
        let json: Result<JQValue, JQError> = Result { () throws(JQError) in try JQValue(json: response.body) }

        var captured: [String: String] = [:]
        for v in h.bodyVariables {
            if let path = v.jsonPath {
                // The path runs on the body as one JSON value; the first output is captured, a
                // string as it is, anything else as its JSON text.
                do {
                    if let first = try jq.run(path, on: json.get()).first, first != .null {
                        if case .string(let s) = first { captured[v.name] = s } else { captured[v.name] = first.jsonString() }
                    }
                } catch {
                    r.error = r.error ?? "Could not capture \(v.name): \(error.localizedDescription)"
                }
            } else if let pattern = v.regex {
                let (value, problem) = CLIChecker.capture(pattern, text)
                if let problem { r.error = r.error ?? problem }
                if let value { captured[v.name] = value }
            }
        }
        for v in h.headerVariables {
            guard let value = response.header(v.header) else { continue }
            if let pattern = v.regex {
                let (match, problem) = CLIChecker.capture(pattern, value)
                if let problem { r.error = r.error ?? problem }
                if let match { captured[v.name] = match }
            } else {
                captured[v.name] = value
            }
        }
        if let problem = CLIChecker.publish(captureNames, captured, into: &vars) { r.error = r.error ?? problem }

        for t in h.tests {
            switch t {
            case .statusCode(let want):
                r.checks.append(CheckLine("status code is \(want) (got \(response.statusCode))", response.statusCode == want ? .passed : .failed))
            case .bodyContains(let want):
                r.checks.append(CheckLine("body contains “\(want)”", text.contains(want) ? .passed : .failed))
            case .bodyContainsNone(let bad):
                r.checks.append(CheckLine("body does not contain “\(bad)”", text.contains(bad) ? .failed : .passed))
            case .headersEqual(let k, let want):
                let got = response.header(k)
                r.checks.append(CheckLine("header \(k) is “\(want)” (got \(got.map { "“\($0)”" } ?? "none"))", got == want ? .passed : .failed))
            case .headersContain(let k, let want):
                let got = response.header(k)
                r.checks.append(CheckLine("header \(k) contains “\(want)” (got \(got.map { "“\($0)”" } ?? "none"))", got?.contains(want) == true ? .passed : .failed))
            case .trailersEqual(let k, let want):
                let got = response.trailer(k)
                r.checks.append(CheckLine("trailer \(k) is “\(want)” (got \(got.map { "“\($0)”" } ?? "none"))", got == want ? .passed : .failed))
            case .trailersContain(let k, let want):
                let got = response.trailer(k)
                r.checks.append(CheckLine("trailer \(k) contains “\(want)” (got \(got.map { "“\($0)”" } ?? "none"))", got?.contains(want) == true ? .passed : .failed))
            case .jsonValue(let path, let op, let value):
                r.checks.append(jsonValueCheck(path, op, value, body: try? json.get(), vars: vars))
            }
        }
        return r
    }

    func jsonValueCheck(_ path: String, _ op: String, _ want: TypedValue, body: JQValue?, vars: [String: String]) -> CheckLine {
        var expected = want
        if case .string(let s) = want { expected = .string(CLIChecker.interpolate(s, vars)) }
        let words = ["eq": "is", "ne": "is not", "gt": ">", "gte": "≥", "lt": "<", "lte": "≤", "contains": "contains", "not_contains": "does not contain"]
        let label = "JSON \(path.count > 90 ? String(path.prefix(90)) + "…" : path) \(words[op] ?? op) \(CLIChecker.describe(expected))"
        guard let body else { return CheckLine("\(label) (the body is not JSON)", .failed) }
        let values: [JQValue]
        do {
            values = try jq.run(path, on: body)
        } catch {
            return CheckLine("\(label) (\(error.localizedDescription))", .failed)
        }
        guard let got = values.first, got != .null else {
            return CheckLine("\(label) (got \(values.isEmpty ? "nothing" : "null"))", .failed)
        }
        let ok: Bool
        switch (expected, got) {
        case (.bool(let w), .bool(let g)):
            ok = op == "eq" ? g == w : (op == "ne" ? g != w : false)
        case (.int(let w), .number):
            ok = CLIChecker.coerceInt(got).map { CLIChecker.compare($0, op, w) } ?? false
        case (.string(let w), .string(let g)):
            switch op {
            case "eq": ok = g == w
            case "ne": ok = g != w
            case "contains": ok = g.contains(w)
            case "not_contains": ok = !g.contains(w)
            case "gt": ok = g > w
            case "gte": ok = g >= w
            case "lt": ok = g < w
            case "lte": ok = g <= w
            default: ok = false
            }
        default:
            ok = false
        }
        return CheckLine("\(label) (got \(got.jsonString()))", ok ? .passed : .failed)
    }

    /// Form encoding as Go's url.Values.Encode writes it: keys sorted, spaces as +.
    static func formEncode(_ fields: [NameValue]) -> String {
        func escape(_ s: String) -> String {
            s.unicodeScalars.map { u -> String in
                if u == " " { return "+" }
                if u.isASCII && (u.properties.isAlphabetic || ("0"..."9").contains(u) || "-_.~".unicodeScalars.contains(u)) { return String(u) }
                return String(u).utf8.map { String(format: "%%%02X", $0) }.joined()
            }.joined()
        }
        return fields.sorted { $0.name < $1.name }.map { "\(escape($0.name))=\(escape($0.value))" }.joined(separator: "&")
    }
}

/// stdout_filter_tmdl: the first line whose text (after its indentation) starts with
/// `query`, and the lines after it until the next non-blank line indented no deeper.
public func extractTmdlBlock(_ input: String, _ query: String) -> String {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return input }
    func indent(_ line: Substring) -> Int {
        var w = 0
        for c in line {
            if c == " " { w += 1 } else if c == "\t" { w += 4 } else { break }
        }
        return w
    }
    var out: [Substring] = []
    var base = -1
    for line in input.split(separator: "\n", omittingEmptySubsequences: false) {
        if base < 0 {
            if line.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix(q) {
                base = indent(line)
                out.append(line)
            }
            continue
        }
        if !line.trimmingCharacters(in: .whitespaces).isEmpty && indent(line) <= base { break }
        out.append(line)
    }
    guard base >= 0 else { return "" }
    var text = out.joined(separator: "\n")
    while let last = text.last, " \n\t\r".contains(last) { text.removeLast() }
    return text
}
