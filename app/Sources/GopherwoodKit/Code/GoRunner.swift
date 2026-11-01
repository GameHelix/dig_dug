import Darwin
import Foundation

public enum RunStatus: String, Sendable {
    case passed, failed, ran, buildError = "build-error", timeout, cancelled, error

    public var label: String {
        switch self {
        case .passed: "Passed"
        case .failed: "Failed"
        case .ran: "Finished"
        case .buildError: "Does not compile"
        case .timeout: "Timed out"
        case .cancelled: "Stopped"
        case .error: "Could not run"
        }
    }

    public var isSuccess: Bool { self == .passed || self == .ran }
}

/// What a Run or Submit reports back.
public struct RunResult: Sendable {
    public var status: RunStatus
    public var output: String
    /// The expected output, when a Submit's printed output does not match it.
    public var expected: String?
    public var duration: Duration = .zero
    /// For a tests lesson, the cases found in the output, parsed once off the main actor.
    public var tests: TestOutput?
    /// For a Submit whose output differs: expected and actual output, line by line.
    public var comparison: OutputComparison?

    public init(status: RunStatus, output: String, expected: String? = nil, duration: Duration = .zero) {
        self.status = status
        self.output = output
        self.expected = expected
        self.duration = duration
    }

    public var durationMs: Int { Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000) }
}

/// Expected output beside yours, line by line, ignoring line endings and trailing spaces.
public struct OutputComparison: Sendable, Equatable {
    public struct Row: Sendable, Equatable {
        public let expected: String?
        public let actual: String?
        public var matches: Bool { expected == actual }
    }

    public let rows: [Row]

    public init(expected: String, actual: String) {
        let e = GoRunner.normalizeOutput(expected).components(separatedBy: "\n")
        let a = GoRunner.normalizeOutput(actual).components(separatedBy: "\n")
        rows = (0..<max(e.count, a.count)).map { Row(expected: $0 < e.count ? e[$0] : nil, actual: $0 < a.count ? a[$0] : nil) }
    }
}

/// Checks code lessons with your own Go toolchain. A Run shows what the code does; a Submit
/// decides whether the lesson passes. For test lessons a Run uses the smaller set of test
/// cases (the tests' withSubmit switch is off) and a Submit all of them.
///
/// The program is built, then run, so a compile error and a failing program are told apart
/// and an endless loop stops after ten seconds rather than after the build's timeout. The
/// tests that run are always the lesson's own, even if the copy in the folder was edited, and
/// the hidden helper files are added at build time with `-overlay`, so nothing extra appears
/// in the folder.
public struct GoRunner: Sendable {
    public static let buildTimeout: Duration = .seconds(120) // a cold build cache makes the first compile slow
    public static let runTimeout: Duration = .seconds(10)
    public static let maxOutput = 256 << 10

    public let toolchain: Toolchain
    /// Where each run's overlay files and binary go (Workspace.runsFolder), removed after it.
    public let scratch: URL

    public init(toolchain: Toolchain, scratch: URL) {
        self.toolchain = toolchain
        self.scratch = scratch
    }

    @concurrent
    public func run(_ code: CodeExercise, tests: Bool, folder: URL, submit: Bool) async -> RunResult {
        let clock = ContinuousClock()
        let started = clock.now
        var result = await check(code, tests: tests, folder: folder, submit: submit)
        result.output = GoRunner.readablePaths(result.output, folder: folder)
        if tests { result.tests = TestOutput(result.output) }
        if let expected = result.expected { result.comparison = OutputComparison(expected: expected, actual: result.output) }
        result.duration = clock.now - started
        if Task.isCancelled && result.status != .passed { result.status = .cancelled }
        return result
    }

    private func check(_ code: CodeExercise, tests: Bool, folder: URL, submit: Bool) async -> RunResult {
        guard code.runsHere else { return RunResult(status: .error, output: code.otherLanguageNote) }
        guard let go = toolchain.go else {
            return RunResult(status: .error, output: "Go was not found. Install it from https://go.dev/dl/ or with Homebrew (brew install go), or set its path in Settings.")
        }
        // The go command matches overlay paths against the real directory, so resolve
        // symlinks (such as /var -> /private/var) first.
        let dir = GoRunner.realPath(folder.path)
        let tmp: String
        do {
            tmp = try GoRunner.makeTempDir(in: scratch)
        } catch {
            return RunResult(status: .error, output: error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let overlay: String
        do {
            overlay = try GoRunner.writeOverlay(code, dir: dir, tmp: tmp)
        } catch {
            return RunResult(status: .error, output: error.localizedDescription)
        }
        let env = toolchain.goEnvironment(submit: submit)
        if let failure = await addRequirements(go: go, dir: dir, env: env) {
            return RunResult(status: .buildError, output: failure)
        }

        if tests {
            let out = await ProcessRunner.run(ProcessRequest(
                executable: go, arguments: ["test", "-overlay", overlay, "-count=1", "-timeout", "\(GoRunner.runTimeout.components.seconds)s"],
                directory: dir, environment: env, timeout: GoRunner.buildTimeout + GoRunner.runTimeout,
                outputLimit: GoRunner.maxOutput, killGroupOnExit: true))
            let text = GoRunner.shown(out)
            if let launch = out.launchError { return RunResult(status: .error, output: launch) }
            if out.cancelled { return RunResult(status: .cancelled, output: text) }
            if text.contains("[build failed]") || text.contains("[setup failed]") {
                return RunResult(status: .buildError, output: text)
            }
            if text.contains("panic: test timed out") || out.timedOut {
                return RunResult(status: .timeout, output: text + "\nStopped: the tests ran longer than \(GoRunner.runTimeout.components.seconds) seconds. Is there an endless loop?")
            }
            // Exit status 0 is not enough: some lesson tests print Fail and a summary such
            // as "0 passed, 5 failed" without calling t.Error, and go test still says PASS.
            let passed = out.exitCode == 0 && !TestOutput(text).reportsFailure
            return RunResult(status: passed ? .passed : .failed, output: text)
        }

        let bin = tmp + "/lesson"
        let build = await ProcessRunner.run(ProcessRequest(
            executable: go, arguments: ["build", "-overlay", overlay, "-o", bin, "."], directory: dir, environment: env,
            timeout: GoRunner.buildTimeout, outputLimit: GoRunner.maxOutput, killGroupOnExit: true))
        if let launch = build.launchError { return RunResult(status: .error, output: launch) }
        if build.cancelled { return RunResult(status: .cancelled, output: GoRunner.shown(build)) }
        if build.timedOut { return RunResult(status: .timeout, output: GoRunner.shown(build) + "\nStopped: the build took longer than two minutes.") }
        if build.exitCode != 0 { return RunResult(status: .buildError, output: GoRunner.shown(build)) }

        let out = await ProcessRunner.run(ProcessRequest(
            executable: bin, arguments: [], directory: dir, environment: env, timeout: GoRunner.runTimeout,
            outputLimit: GoRunner.maxOutput, killGroupOnExit: true))
        let text = GoRunner.shown(out)
        if out.cancelled { return RunResult(status: .cancelled, output: text) }
        if out.timedOut {
            return RunResult(status: .timeout, output: text + "\nStopped: the program ran longer than \(GoRunner.runTimeout.components.seconds) seconds. Is there an endless loop?")
        }
        if let launch = out.launchError { return RunResult(status: .error, output: launch) }
        if out.exitCode != 0 {
            let why = out.signal != 0 ? "signal: \(String(cString: strsignal(out.signal)))" : "exit status \(out.exitCode)"
            return RunResult(status: .failed, output: text + (text.hasSuffix("\n") || text.isEmpty ? "" : "\n") + why)
        }
        if !submit { return RunResult(status: .ran, output: text) }
        if GoRunner.normalizeOutput(out.stdout) == GoRunner.normalizeOutput(code.expectedOutput ?? "") {
            return RunResult(status: .passed, output: text)
        }
        return RunResult(status: .failed, output: text, expected: code.expectedOutput ?? "")
    }

    /// Compiler messages name the lesson's files, not the overlay's temporary copies or the
    /// work folder's full path: "main_test.go:37:7", as in a terminal opened there.
    static func readablePaths(_ output: String, folder: URL) -> String {
        var text = output.replacing(/(?:\/private)?\/[^\s:]*\/run-[A-Za-z0-9]+\/overlay-\d+-/) { _ in "" }
        let dir = folder.path
        for prefix in Set([dir, realPath(dir), "/private" + dir]) where !prefix.isEmpty {
            text = text.replacingOccurrences(of: prefix + "/", with: "")
        }
        return text
    }

    /// Output as shown, with a note when it was cut off.
    static func shown(_ out: ProcessOutput) -> String {
        out.truncated ? out.combined + "\n… output cut off after \(maxOutput >> 10) KB" : out.combined
    }

    /// Ignores line endings and trailing whitespace.
    public static func normalizeOutput(_ s: String) -> String {
        var lines = s.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for i in lines.indices {
            while let last = lines[i].last, last == " " || last == "\t" { lines[i].removeLast() }
        }
        var joined = lines.joined(separator: "\n")
        while joined.hasSuffix("\n") { joined.removeLast() }
        return joined
    }

    /// Writes a `go build -overlay` file that adds the lesson's hidden files, pins read-only
    /// files to their original content, and lets GOPHERWOOD_SUBMIT choose between the run and
    /// submit test cases. Nothing is written into the lesson folder.
    static func writeOverlay(_ code: CodeExercise, dir: String, tmp: String) throws -> String {
        var replace: [String: String] = [:]
        func add(_ name: String, _ content: String) throws {
            let path = try Workspace.lessonPath(URL(fileURLWithPath: dir), name).path
            let backing = tmp + "/overlay-\(replace.count)-" + (path as NSString).lastPathComponent
            try Data(content.utf8).write(to: URL(fileURLWithPath: backing))
            replace[path] = backing
        }
        for f in code.starterFiles where f.isHidden || f.isReadonly {
            try add(f.name, f.content)
            if f.name.hasSuffix("_test.go"), let pkg = declaresWithSubmit(f.content) {
                let harness = "package \(pkg)\n\nimport \"os\"\n\nfunc init() {\n\tif os.Getenv(\"GOPHERWOOD_SUBMIT\") != \"1\" {\n\t\twithSubmit = false\n\t}\n}\n"
                let sub = (f.name as NSString).deletingLastPathComponent
                try add(sub.isEmpty ? "zz_gopherwood_submit_test.go" : sub + "/zz_gopherwood_submit_test.go", harness)
            }
        }
        let data = try JSONSerialization.data(withJSONObject: ["Replace": replace], options: [.sortedKeys])
        let path = tmp + "/overlay.json"
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    /// The package name, if the file declares the package-level withSubmit switch the
    /// original tests use.
    static func declaresWithSubmit(_ source: String) -> String? {
        guard source.firstMatch(of: /(?m)^var\s+withSubmit\b|^var\s*\([^)]*\bwithSubmit\b/) != nil,
              let pkg = source.firstMatch(of: /(?m)^\s*package\s+([A-Za-z_][A-Za-z0-9_]*)/) else { return nil }
        return String(pkg.1)
    }

    /// Runs `go mod tidy` when the lesson imports packages from outside the standard library
    /// that go.mod does not list yet. Downloading a module needs the network once; after that
    /// it comes from the module cache. Returns the failure to show, if any.
    func addRequirements(go: String, dir: String, env: [String: String]) async -> String? {
        guard let mod = try? String(contentsOfFile: dir + "/go.mod", encoding: .utf8) else { return nil }
        let have = mod.matches(of: /(?m)^\s*(?:require\s+)?([A-Za-z0-9][-A-Za-z0-9._~\/]*\.[-A-Za-z0-9._~\/]+)\s+v\d/).map { String($0.1) }
        var imports: [String] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".go") {
            guard let src = try? String(contentsOfFile: dir + "/" + name, encoding: .utf8) else { continue }
            for m in src.matches(of: /\bimport\s*\(([^)]*)\)/) {
                imports += m.1.matches(of: /"([^"]+)"/).map { String($0.1) }
            }
            imports += src.matches(of: /\bimport\s+(?:[A-Za-z_.][A-Za-z0-9_]*\s+)?"([^"]+)"/).map { String($0.1) }
        }
        let missing = imports.contains { path in
            guard path.split(separator: "/").first?.contains(".") == true else { return false } // standard library
            return !have.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        guard missing else { return nil }
        let out = await ProcessRunner.run(ProcessRequest(executable: go, arguments: ["mod", "tidy"], directory: dir, environment: env,
                                                         timeout: GoRunner.buildTimeout, outputLimit: GoRunner.maxOutput, killGroupOnExit: true))
        return out.succeeded ? nil : "go mod tidy could not add the modules this lesson imports (it needs the network the first time):\n\n" + out.combined
    }

    public static func realPath(_ path: String) -> String {
        guard let p = realpath(path, nil) else { return path }
        defer { free(p) }
        return String(cString: p)
    }

    static func makeTempDir(in scratch: URL) throws -> String {
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            throw WorkspaceError.io(scratch.path, error.localizedDescription)
        }
        var template = Array(scratch.appendingPathComponent("run-XXXXXX").path.utf8CString)
        let made: String? = template.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress, let p = mkdtemp(base) else { return nil }
            return String(cString: p)
        }
        guard let made else { throw WorkspaceError.io(scratch.path, String(cString: strerror(errno))) }
        return realPath(made)
    }
}
