import Foundation
import Testing
@testable import GopherwoodKit

/// The checker on the real HTTP client (LessonHTTP), against a small Go server built here.
@Suite(.serialized) struct LiveHTTPTests {
    static let server = """
    package main

    import (
    \t"fmt"
    \t"net"
    \t"net/http"
    \t"os"
    )

    func main() {
    \tln, err := net.Listen("tcp", "127.0.0.1:0")
    \tif err != nil {
    \t\tpanic(err)
    \t}
    \tfmt.Println(ln.Addr().(*net.TCPAddr).Port)
    \tos.Stdout.Sync()
    \thttp.HandleFunc("/api/login", func(w http.ResponseWriter, r *http.Request) {
    \t\thttp.SetCookie(w, &http.Cookie{Name: "session_id", Value: "s3cr3t", Path: "/"})
    \t\tw.Header().Set("Content-Type", "application/json")
    \t\tfmt.Fprint(w, `{"token": "tok-1", "user": {"id": 7}}`)
    \t})
    \thttp.HandleFunc("/me", func(w http.ResponseWriter, r *http.Request) {
    \t\tif c, err := r.Cookie("session_id"); err != nil || c.Value != "s3cr3t" {
    \t\t\thttp.Error(w, "who are you", http.StatusUnauthorized)
    \t\t\treturn
    \t\t}
    \t\tfmt.Fprint(w, "hello ada")
    \t})
    \thttp.HandleFunc("/range", func(w http.ResponseWriter, r *http.Request) {
    \t\tw.Header().Set("Trailer", "X-Content-Sha256")
    \t\tw.Write([]byte("0123456789"))
    \t\tw.(http.Flusher).Flush()
    \t\tw.Header().Set("X-Content-Sha256", "abc123")
    \t})
    \thttp.HandleFunc("/old", func(w http.ResponseWriter, r *http.Request) {
    \t\thttp.Redirect(w, r, "/me", http.StatusFound)
    \t})
    \thttp.Serve(ln, nil)
    }
    """

    @Test func stepsAgainstARealServer() async throws {
        guard let toolchain = await Fixtures.toolchain(), let go = toolchain.go else { return }
        let dir = try Fixtures.tempDir("server")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.server.write(to: dir.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)
        try "module server\n\ngo \(toolchain.languageVersion)\n".write(to: dir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        let build = await ProcessRunner.run(ProcessRequest(executable: go, arguments: ["build", "-o", "server", "."], directory: dir.path,
                                                           environment: toolchain.goEnvironment(submit: false), timeout: .seconds(120)))
        try #require(build.succeeded, "\(build.combined)")

        let process = Process()
        process.executableURL = dir.appendingPathComponent("server")
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        defer { process.terminate() }
        let line = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let port = try #require(Int(line))

        let lesson = CLILesson(baseURLDefault: "http://localhost:8080", steps: [
            CLIStep(description: "log in", action: .http(HTTPStep(method: "POST", fullURL: "${baseURL}/api/login", body: .json(#"{"email": "ada@example.com"}"#),
                                                                  headerVariables: [.init(name: "cookie", header: "Set-Cookie", regex: "^(session_id=[^;]+)")],
                                                                  tests: [.statusCode(200), .headersContain("Content-Type", "json")]))),
            CLIStep(description: "use the session", action: .http(HTTPStep(fullURL: "${baseURL}/me", headers: [NameValue("Cookie", "${cookie}")],
                                                                          tests: [.statusCode(200), .bodyContains("hello ada")]))),
            CLIStep(description: "trailers", action: .http(HTTPStep(fullURL: "${baseURL}/range", tests: [
                .statusCode(200), .trailersEqual("X-Content-Sha256", "abc123"), .bodyContains("0123456789"),
            ]))),
            CLIStep(description: "redirect not followed", action: .http(HTTPStep(fullURL: "${baseURL}/old", followRedirects: false,
                                                                                tests: [.statusCode(302), .headersEqual("Location", "/me")]))),
            CLIStep(description: "redirect followed", action: .http(HTTPStep(fullURL: "${baseURL}/old", tests: [.statusCode(401)]))),
        ])
        let checker = CLIChecker(environment: toolchain.environment)
        let run = await checker.run(lesson, directory: dir.path, baseURL: "http://127.0.0.1:\(port)")
        for step in run.steps {
            #expect(step.passed, "\(step.description): \(step.error ?? "") \(step.checks.filter { $0.state == .failed }.map(\.text))")
        }
        #expect(run.status == .passed)

        // Nobody listening: the step fails and says so.
        let down = await checker.run(CLILesson(steps: [CLIStep(description: "down", action: .http(HTTPStep(fullURL: "${baseURL}/", tests: [.statusCode(200)])))]),
                                     directory: dir.path, baseURL: "http://127.0.0.1:1")
        #expect(down.status == .failed && down.steps[0].error?.contains("Is your server running") == true)
    }
}
