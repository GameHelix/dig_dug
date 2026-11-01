import Foundation
import JQ
import Testing
@testable import GopherwoodKit

/// Answers requests from a table and remembers them.
actor RecordingHTTP: HTTPSending {
    var requests: [CheckRequest] = []
    let responses: [String: CheckResponse]

    init(_ responses: [String: CheckResponse]) { self.responses = responses }

    func send(_ request: CheckRequest) async throws -> CheckResponse {
        requests.append(request)
        guard let r = responses["\(request.method) \(request.url.absoluteString)"] else {
            throw URLError(.cannotConnectToHost)
        }
        return r
    }
}

func response(_ status: Int, _ body: String, headers: [NameValue] = [], trailers: [NameValue] = []) -> CheckResponse {
    CheckResponse(statusCode: status, headers: headers, trailers: trailers, body: Data(body.utf8), url: URL(string: "http://localhost")!)
}

@Suite struct CheckerTests {
    let env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]

    @Test func commandsTheirTestsAndCaptures() async throws {
        let dir = try Fixtures.tempDir("cli")
        defer { try? FileManager.default.removeItem(at: dir) }
        try "module example.com/hello\n".write(to: dir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        let lesson = CLILesson(steps: [
            CLIStep(description: "read go.mod", action: .command(CLICommand(command: "cat go.mod", tests: [
                .exitCode(0), .stdoutContainsAll(["example.com/hello"]), .stdoutContainsNone(["github.com"]), .stdoutLinesGT(0),
            ]))),
            CLIStep(description: "capture", action: .command(CLICommand(command: "echo 'token=abc123'", variables: [NameValue("token", "token=(\\w+)")], tests: [.exitCode(0)]))),
            CLIStep(description: "use it", action: .command(CLICommand(command: "echo got ${token}", tests: [.stdoutContainsAll(["got abc123"])]))),
            CLIStep(description: "json", action: .command(CLICommand(command: "printf '{\"ok\": true, \"n\": 3}'", tests: [
                .stdoutJq(query: ".ok", jsonl: false, expected: [JqExpectation("==", .bool(true))]),
                .stdoutJq(query: ".n", jsonl: false, expected: [JqExpectation(">=", .int(3))]),
            ]))),
            CLIStep(description: "fails", action: .command(CLICommand(command: "exit 3", tests: [.exitCode(0)]))),
            CLIStep(description: "zsh", action: .command(CLICommand(command: "print -r -- ${ZSH_VERSION:+zsh}", tests: [.stdoutContainsAll(["zsh"])]))),
        ])
        let checker = CLIChecker(environment: env, makeHTTP: { RecordingHTTP([:]) })
        let run = await checker.run(lesson, directory: dir.path, baseURL: nil)
        #expect(run.status == .failed && run.steps.count == 6)
        #expect(run.duration > .zero && run.steps.allSatisfy { $0.duration > .zero })
        #expect(run.steps[0].passed && run.steps[0].checks.count == 4)
        #expect(run.steps[1].passed && run.steps[2].passed && run.steps[2].action == "echo got abc123")
        #expect(run.steps[3].passed, "\(run.steps[3].checks)")
        #expect(!run.steps[4].passed && run.steps[4].checks[0].text.contains("got 3"))
        #expect(run.steps[5].passed) // command lines run under zsh
        #expect(run.report.contains("✗ 5. fails"))

        let missing = await checker.run(lesson, directory: dir.appendingPathComponent("missing").path, baseURL: nil)
        #expect(missing.status == .error && missing.error?.contains("does not exist") == true)
    }

    @Test func httpStepsVariablesHeadersAndTrailers() async throws {
        let http = RecordingHTTP([
            "POST http://localhost:9999/api/login": response(200, #"{"token": "tok-ada", "user": {"id": 7}}"#,
                                                             headers: [NameValue("Set-Cookie", "session_id=s3cr3t; Path=/; HttpOnly"), NameValue("Content-Type", "application/json")]),
            "GET http://localhost:9999/api/me": response(200, #"{"email": "ada@example.com", "items": [{"n": 1}, {"n": 2}], "admin": false}"#,
                                                         headers: [NameValue("Content-Type", "application/json")]),
            "GET http://localhost:9999/file": response(200, "0123", trailers: [NameValue("X-Content-Sha256", "abc"), NameValue("X-Content-Length", "4")]),
        ])
        let lesson = CLILesson(baseURLDefault: "http://localhost:8080", steps: [
            CLIStep(description: "log in", action: .http(HTTPStep(method: "POST", fullURL: "${baseURL}/api/login", followRedirects: false,
                                                                  body: .json(#"{"email": "ada@example.com", "note": "${baseURL}"}"#),
                                                                  bodyVariables: [.init(name: "token", jsonPath: ".token")],
                                                                  headerVariables: [.init(name: "cookie", header: "set-cookie", regex: "^(session_id=[^;]+)")],
                                                                  tests: [.statusCode(200), .jsonValue(path: ".user.id", op: "gte", value: .int(7))]))),
            CLIStep(description: "me", action: .http(HTTPStep(fullURL: "${baseURL}/api/me", basicAuth: NameValue("ada", "pw"),
                                                              headers: [NameValue("Authorization2", "Bearer ${token}"), NameValue("Cookie", "${cookie}")],
                                                              tests: [.jsonValue(path: ".email", op: "eq", value: .string("ada@example.com")),
                                                                      .jsonValue(path: ".items[1].n", op: "gt", value: .int(1)),
                                                                      .jsonValue(path: ".admin", op: "eq", value: .bool(false)),
                                                                      .headersEqual("content-type", "application/json"),
                                                                      .bodyContainsNone("password")]))),
            CLIStep(description: "trailers", action: .http(HTTPStep(fullURL: "${baseURL}/file", tests: [
                .trailersEqual("X-Content-Sha256", "abc"), .trailersContain("X-Content-Length", "4"),
            ]))),
            CLIStep(description: "down", action: .http(HTTPStep(fullURL: "${baseURL}/nope", tests: [.statusCode(200)]))),
            CLIStep(description: "needs a value", action: .command(CLICommand(command: "echo ${neverCaptured}"))),
            CLIStep(description: "captures it too late", action: .command(CLICommand(command: "echo x", variables: [NameValue("neverCaptured", "(y)")]))),
        ])
        let checker = CLIChecker(environment: env, makeHTTP: { http })
        let run = await checker.run(lesson, directory: "/tmp", baseURL: "http://localhost:9999/")
        #expect(run.baseURL == "http://localhost:9999")
        #expect(run.steps[0].passed, "\(run.steps[0].checks) \(run.steps[0].error ?? "")")
        #expect(run.steps[1].passed, "\(run.steps[1].checks) \(run.steps[1].error ?? "")")
        #expect(run.steps[2].passed, "\(run.steps[2].checks)")
        #expect(!run.steps[3].passed && run.steps[3].error?.contains("Is your server running") == true)
        #expect(run.steps[4].error?.contains("${neverCaptured}") == true) // skipped: no step captured it before
        #expect(run.status == .failed)

        // Requests go out exactly as the steps define them.
        let sent = await http.requests
        #expect(sent[0].headers == [NameValue("Content-Type", "application/json")] && !sent[0].followRedirects)
        // The JSON body goes out as stored, with ${names} filled in.
        #expect(sent[0].body.map { String(decoding: $0, as: UTF8.self) } == #"{"email": "ada@example.com", "note": "http://localhost:9999"}"#)
        #expect(sent[1].headers == [NameValue("Authorization2", "Bearer tok-ada"), NameValue("Cookie", "session_id=s3cr3t")])
        #expect(sent[1].basicAuth == NameValue("ada", "pw") && sent[1].followRedirects)
    }

    @Test func aServerAddressIsNeeded() async {
        let lesson = CLILesson(asksForBaseURL: true, steps: [CLIStep(description: "x", action: .http(HTTPStep(fullURL: "${baseURL}/")))])
        let run = await CLIChecker(environment: env, makeHTTP: { RecordingHTTP([:]) }).run(lesson, directory: "/tmp", baseURL: nil)
        #expect(run.status == .error && run.error?.contains("address") == true)
    }

    /// The jq queries real lessons use, on jq compiled into the app.
    @Test func realJQ() throws {
        let jq = CompiledJQ()
        let goEnv = try JQValue(json: #"{"GOVERSION": "go1.27.3"}"#)
        #expect(try jq.run(#".GOVERSION | [scan("[0-9]+") | tonumber] | .[1] > 27 or (.[1] == 27 and .[2] >= 2)"#, on: goEnv) == [true])
        let logs = try JQValue(json: """
        {"msg": "Served page", "path": "/", "trace_id": "abc", "duration": 3}
        {"msg": "error checking token", "user": "grace", "error": {"stack_trace": "x"}}
        {"msg": "Served page", "path": "/api/login", "response_status": 401}
        """, mode: .jsonl)
        #expect(try jq.run(#"any(.[]; .msg == "Served page" and .path == "/" and .trace_id != null)"#, on: logs) == [true])
        #expect(try jq.run(#"[.[] | select(.msg == "error checking token")] | any(.user == "grace")"#, on: logs) == [true])
        #expect(try jq.run(#"[.[] | select(.msg == "Served page")] | length"#, on: logs) == [2])
        #expect(try jq.run(#".[0:2] | map(.msg) | sort | join(", ")"#, on: logs) == ["Served page, error checking token"])
        #expect(try jq.run(#"all(.[]; (.msg | type) == "string") and (.[1].user | contains("rac")) and (.[2] | keys | length) == 3 and (.[0].missing | not)"#, on: logs) == [true])
        #expect(throws: JQError.self) { try jq.run("this is not jq", on: goEnv) }
        #expect(throws: JQError.self) { try JQValue(json: "{not json") }
    }

    @Test func helpers() throws {
        #expect(CLIChecker.interpolate("${a}-${b}-${a}", ["a": "1"]) == "1-${b}-1")
        #expect(CLIChecker.interpolateJSON(#"{"q": "${v}"}"#, ["v": "say \"hi\"\n"]) == #"{"q": "say \"hi\"\n"}"#)
        #expect(CLIChecker.formEncode([NameValue("returnTo", "/files/1 x"), NameValue("email", "a+b@x.io")]) == "email=a%2Bb%40x.io&returnTo=%2Ffiles%2F1+x")
        #expect(CLIChecker.jqMatches(3, JqExpectation(">", .int(2))))
        #expect(CLIChecker.jqMatches("true", JqExpectation("==", .bool(true))))
        #expect(!CLIChecker.jqMatches(1.5, JqExpectation("==", .int(1))))
        #expect(CLIChecker.coerceInt(try JQValue(json: "12345678901234567")) == 12_345_678_901_234_567) // exact, past 2^53
        #expect(extractTmdlBlock("a\n{\"settingsLoaded\": true,\n  more\nb", "{\"settingsLoaded\":") == "{\"settingsLoaded\": true,\n  more")
        #expect(extractTmdlBlock("nothing here", "x") == "")
    }
}
