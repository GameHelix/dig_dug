import Foundation
import GRDB
import os
import Testing
@testable import GopherwoodKit

/// GitHub's API for these tests: a URLProtocol that answers from a table and records every
/// request. Nothing reaches the network.
final class GitHubStub: URLProtocol, @unchecked Sendable {
    struct Answer: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = ""
        var failure: URLError.Code?

        static func json(_ body: String, status: Int = 200, headers: [String: String] = [:]) -> Answer {
            Answer(status: status, headers: headers.merging(["Content-Type": "application/json"]) { a, _ in a }, body: body)
        }
        static func redirect(_ location: String, status: Int = 302) -> Answer { Answer(status: status, headers: ["Location": location]) }
        static func text(_ body: String) -> Answer { Answer(status: 200, headers: ["Content-Type": "text/plain"], body: body) }
        static func offline() -> Answer { Answer(failure: .notConnectedToInternet) }
    }

    struct Seen: Sendable {
        let key: String
        let method: String
        let headers: [String: String]
        let body: Data?
    }

    private static let table = OSAllocatedUnfairLock<(answers: [String: Answer], seen: [Seen])>(initialState: ([:], []))

    static func answer(_ answers: [String: Answer]) { table.withLock { $0 = (answers, []) } }
    static var seen: [Seen] { table.withLock { $0.seen } }

    /// "GET /repos/a/b/pulls?base=main&state=all", query keys sorted, for api.github.com;
    /// "GET https://host/path" for any other host.
    static func key(_ request: URLRequest) -> String {
        let method = request.httpMethod ?? "GET"
        guard let url = request.url, let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return method }
        guard c.host == "api.github.com" else { return "\(method) \(c.scheme ?? "")://\(c.host ?? "")\(c.percentEncodedPath)" }
        let query = (c.queryItems ?? []).map { "\($0.name)=\($0.value ?? "")" }.sorted().joined(separator: "&")
        return "\(method) \(c.percentEncodedPath)" + (query.isEmpty ? "" : "?" + query)
    }

    static func client() -> GitHubClient {
        let c = GitHubClient.configuration()
        c.protocolClasses = [GitHubStub.self]
        return GitHubClient(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = GitHubStub.key(request)
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            body = data
        }
        let seen = Seen(key: key, method: request.httpMethod ?? "GET", headers: request.allHTTPHeaderFields ?? [:], body: body)
        let answer = GitHubStub.table.withLock { state -> Answer? in
            state.seen.append(seen)
            return state.answers[key]
        } ?? .json(#"{"message":"Not Found"}"#, status: 404)
        guard let url = request.url else { return }
        if let failure = answer.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)
        if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite struct GitHubRepoTests {
    @Test func whatALearnerPastesBecomesOwnerSlashName() throws {
        for text in ["ada/notely", "  ada/notely\n", "ada/notely/", "ada/notely.git", "https://github.com/ada/notely", "https://github.com/ada/notely/",
                     "https://github.com/ada/notely.git", "https://github.com/ada/notely.git/", "http://github.com/ada/notely", "https://www.github.com/ada/notely",
                     "HTTPS://GitHub.com/ada/notely", "github.com/ada/notely", "git@github.com:ada/notely.git", "git@github.com:ada/notely",
                     "ssh://git@github.com/ada/notely.git", "https://github.com/ada/notely/tree/main/docs", "https://github.com/ada/notely?tab=readme"] {
            #expect(GitHubRepo(parsing: text)?.fullName == "ada/notely", "\(text)")
        }
        #expect(GitHubRepo(parsing: "octo-org/.github")?.fullName == "octo-org/.github")
        #expect(GitHubRepo(parsing: "Ada-L/my_repo.v2")?.fullName == "Ada-L/my_repo.v2")
        for text in ["", "ada", "ada/", "/notely", "ada/notely/extra", "https://gitlab.com/ada/notely", "https://github.com/ada", "ftp://github.com/ada/notely",
                     "-ada/notely", "ada-/notely", "a--b/c", "a.b/c", "a_b/c", "x/.", "x/..", "x/a b", "x/é", String(repeating: "a", count: 40) + "/b",
                     "a/" + String(repeating: "b", count: 101), "git@gitlab.com:ada/notely.git"] {
            #expect(GitHubRepo(parsing: text) == nil, "\(text)")
        }
        let repo = try #require(GitHubRepo(owner: "ada", name: "notely"))
        #expect(repo.webURL.absoluteString == "https://github.com/ada/notely" && "\(repo)" == "ada/notely")
    }
}

/// project.github_repo: saved and read with the course's project, and refused by the schema's
/// CHECK unless it is owner/name exactly as the parser makes it.
@Suite struct GitHubRepoStorageTests {
    @Test func theCourseKeepsItsRepository() async throws {
        let (db, dir) = try Fixtures.database()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await db.saveProject(Fixtures.courseID, Project(dir: nil, baseURL: nil, githubRepo: "ada/notely")) // a repository alone
        #expect(try await db.project(for: Fixtures.courseID) == Project(dir: nil, baseURL: nil, githubRepo: "ada/notely"))
        try await db.saveProject(Fixtures.courseID, Project(dir: "/tmp/lantern", baseURL: "https://lantern.example.com", githubRepo: "ada/notely"))
        #expect(try await db.project(for: Fixtures.courseID) == Project(dir: "/tmp/lantern", baseURL: "https://lantern.example.com", githubRepo: "ada/notely"))
        try await db.saveProject(Fixtures.courseID, Project(dir: nil, baseURL: nil, githubRepo: "ada/notely-2")) // changed
        #expect(try await db.project(for: Fixtures.courseID)?.githubRepo == "ada/notely-2")
        try await db.saveProject(Fixtures.courseID, Project(dir: nil, baseURL: nil, githubRepo: " ")) // all missing: the row goes
        #expect(try await db.project(for: Fixtures.courseID) == nil)
        #expect(try await db.project(for: Fixtures.projectCourseID) == nil) // another course has its own
        await #expect(throws: DatabaseError.self) { try await db.saveProject(Fixtures.courseID, Project(dir: nil, baseURL: nil, githubRepo: "https://github.com/ada/notely")) }
    }

    @Test func theParserAndTheSchemaAgree() async throws {
        let (db, dir) = try Fixtures.database()
        defer { try? FileManager.default.removeItem(at: dir) }
        let candidates = ["ismatsamadov/learn-cicd-starter", "a/b", "octo-org/.github", "x/...", "https://github.com/a/b", "github.com/a/b", "a/b/c",
                          "-a/b", "a-/b", "a--b/c", "a.b/c", "a_b/c", "x/.", "x/..", "x/a b", " x/y", "x/é", String(repeating: "o", count: 39) + "/b",
                          String(repeating: "o", count: 40) + "/b", "a/" + String(repeating: "n", count: 100), "a/" + String(repeating: "n", count: 101)]
        for text in candidates {
            let stored: Bool
            do {
                try await db.saveProject(Fixtures.courseID, Project(dir: "/tmp/x", baseURL: nil, githubRepo: text))
                stored = try await db.project(for: Fixtures.courseID)?.githubRepo == text
            } catch {
                stored = false
            }
            #expect(stored == (GitHubRepo(parsing: text)?.fullName == text), "\(text)")
        }
    }

    @Test func lessonStepsReadAsChecks() async throws {
        let (db, dir) = try Fixtures.database()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard case .githubChecks(let gh)? = try await db.lesson(Fixtures.githubLesson)?.content else { Issue.record("github"); return }
        #expect(gh.steps.map(\.check) == [.workflowStatus(workflow: "ci.yml", conclusion: "success"),
                                          .workflowLogsContains(workflow: "ci.yml", jobs: [.init(job: "Style", texts: ["staticcheck"])])])
        #expect(gh.readsLogs)
        #expect(gh.steps[0].summary == "The latest run of ci.yml succeeded")
        #expect(gh.steps[1].summary == "In the latest run of ci.yml, the Style job's log shows “staticcheck”")
    }
}

/// gh, played by scripts: the app runs `gh auth token` and keeps what it prints hidden.
@Suite struct GitHubCLITests {
    func script(_ dir: URL, _ body: String) throws -> String {
        let url = dir.appendingPathComponent("gh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    @Test func aSignInIsATokenNobodySees() async throws {
        let dir = try Fixtures.tempDir("gh")
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = ["PATH": dir.path + ":/usr/bin:/bin", "HOME": dir.path]
        let gh = try script(dir, #"[ "$*" = "auth token --hostname github.com" ] && [ "$GH_PROMPT_DISABLED" = 1 ] && echo fake-token-for-tests && exit 0; exit 3"#)
        #expect(GitHubCLI.locate(environment: env) == gh) // the login shell's PATH comes first
        let signIn = await GitHubCLI.signIn(gh: gh, environment: env)
        let token = try #require(signIn.token)
        #expect(token.value == "fake-token-for-tests")
        var dumped = ""
        dump(token, to: &dumped)
        for shown in ["\(token)", String(reflecting: token), dumped, "\(signIn)"] { #expect(!shown.contains("fake-token"), "\(shown)") }

        let out = try script(dir, "echo 'no oauth token found for github.com' >&2; exit 1")
        guard case .notSignedIn = await GitHubCLI.signIn(gh: out, environment: env) else { Issue.record("signed out"); return }
        guard case .noCLI = await GitHubCLI.signIn(gh: nil, environment: env) else { Issue.record("no gh"); return }
    }
}

/// The checks against the stub: every kind passing and failing, a run in progress, the
/// limits, a refused sign-in, no network, and the token on redirects.
@Suite(.serialized) struct GitHubAPITests {
    static let token = GitHubToken("test-token-0000")
    static let repo = GitHubRepo(owner: "ada", name: "notely")!
    static let allKinds = GitHubChecks(steps: [
        .init(kind: "repo_exists", check: .repoExists),
        .init(kind: "submit_repo_for_course", check: .submitRepoForCourse),
        .init(kind: "branch_exists", check: .branchExists("addtests")),
        .init(kind: "file_contains", check: .fileContains(path: "README.md", texts: ["/badge.svg"])),
        .init(kind: "pr_exists", check: .prExists(baseOwner: nil, baseRepo: nil, baseBranch: "main", compareBranch: "addtests")),
        .init(kind: "workflow_status", check: .workflowStatus(workflow: "ci.yml", conclusion: "success")),
        .init(kind: "workflow_logs_contains", check: .workflowLogsContains(workflow: "ci.yml", jobs: [.init(job: "Tests", texts: ["go test", "-cover"])])),
    ])

    static func contents(_ text: String) -> String {
        // GitHub breaks its base64 into lines.
        let encoded = Data(text.utf8).base64EncodedString(options: .lineLength64Characters)
        let object: [String: Any] = ["type": "file", "encoding": "base64", "content": encoded, "html_url": "https://github.com/ada/notely/blob/main/README.md"]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
    }

    static func runs(_ status: String, _ conclusion: String?) -> GitHubStub.Answer {
        .json(#"{"total_count":3,"workflow_runs":[{"id":101,"name":"ci","status":"\#(status)","conclusion":\#(conclusion.map { "\"\($0)\"" } ?? "null"),"html_url":"https://github.com/ada/notely/actions/runs/101"}]}"#)
    }

    static let runsKey = "GET /repos/ada/notely/actions/workflows/ci.yml/runs?exclude_pull_requests=true&per_page=1"

    /// A repository that has everything the lesson asks for.
    static var everything: [String: GitHubStub.Answer] {
        [
            "GET /repos/ada/notely": .json(#"{"full_name":"ada/notely","default_branch":"main"}"#),
            "GET /repos/ada/notely/branches/addtests": .json(#"{"name":"addtests"}"#),
            "GET /repos/ada/notely/contents/README.md": .json(contents("# Notely\n\n![ci](https://github.com/ada/notely/actions/workflows/ci.yml/badge.svg)\n")),
            "GET /repos/ada/notely/pulls?base=main&head=ada:addtests&per_page=1&state=all":
                .json(#"[{"number":3,"state":"open","merged_at":null,"html_url":"https://github.com/ada/notely/pull/3"}]"#),
            runsKey: runs("completed", "success"),
            "GET /repos/ada/notely/actions/runs/101/jobs?per_page=100":
                .json(#"{"total_count":1,"jobs":[{"id":201,"name":"Tests","html_url":"https://github.com/ada/notely/actions/runs/101/job/201"}]}"#),
            "GET /repos/ada/notely/actions/jobs/201/logs": .redirect("https://results.blob.example.net/logs/201.txt?sig=abc"),
            "GET https://results.blob.example.net/logs/201.txt": .text("2026-10-01T10:00:00.0Z ##[group]Run go test -cover ./...\n2026-10-01T10:00:09.0Z ok"),
        ]
    }

    func run(_ answers: [String: GitHubStub.Answer], checks: GitHubChecks = GitHubAPITests.allKinds,
             signIn: GitHubSignIn = .signedIn(GitHubAPITests.token)) async -> GitHubCheckRun {
        GitHubStub.answer(answers)
        let run = await GitHubChecker(client: GitHubStub.client(), signIn: { signIn }).run(checks, repo: GitHubAPITests.repo)
        // Read-only: nothing but GET, and the token goes to api.github.com only.
        for seen in GitHubStub.seen {
            #expect(seen.method == "GET", "\(seen.key)")
            let api = !seen.key.contains("://")
            #expect((seen.headers["Authorization"] != nil) == (api && signIn.token != nil), "\(seen.key)")
            #expect((seen.headers["X-GitHub-Api-Version"] == "2022-11-28") == api, "\(seen.key)")
        }
        return run
    }

    @Test func everyKindPasses() async {
        let run = await self.run(GitHubAPITests.everything)
        #expect(run.status == .passed && run.signedIn && run.error == nil)
        #expect(run.steps.map { $0?.reason } == [
            "ada/notely is on GitHub", "ada/notely is on GitHub", "Branch addtests is in ada/notely", "README.md on main contains “/badge.svg”",
            "Pull request #3 from addtests into main is open", "The latest 'ci' run succeeded",
            "In the latest 'ci' run, the Tests job's log shows “go test” and “-cover”",
        ])
        #expect(run.steps.allSatisfy { $0?.passed == true })
        #expect(run.steps[4]?.link?.absoluteString == "https://github.com/ada/notely/pull/3")
        // Each answer is asked for once: the repository and the latest run serve every step.
        let keys = GitHubStub.seen.map(\.key)
        #expect(keys.filter { $0 == "GET /repos/ada/notely" }.count == 1 && keys.filter { $0 == GitHubAPITests.runsKey }.count == 1)
        #expect(keys.last == "GET https://results.blob.example.net/logs/201.txt")
        #expect(GitHubStub.seen.last?.headers["Authorization"] == nil) // the log's blob storage never gets the token
        #expect(run.report.contains("✓ 7. ") && run.report.contains("signed in through the GitHub CLI") && !run.report.contains("test-token"))
    }

    @Test func everyKindFailsWithItsReason() async {
        var answers = GitHubAPITests.everything
        answers["GET /repos/ada/notely/branches/addtests"] = .json(#"{"message":"Branch not found"}"#, status: 404)
        answers["GET /repos/ada/notely/contents/README.md"] = .json(GitHubAPITests.contents("# Notely\n"))
        answers["GET /repos/ada/notely/pulls?base=main&head=ada:addtests&per_page=1&state=all"] = .json("[]")
        answers[GitHubAPITests.runsKey] = GitHubAPITests.runs("completed", "failure")
        answers["GET https://results.blob.example.net/logs/201.txt"] = .text("Run go test ./...\nFAIL")
        let run = await self.run(answers)
        #expect(run.status == .failed)
        #expect(run.steps.map { $0?.passed } == [true, true, false, false, false, false, false])
        #expect(run.steps.dropFirst(2).map { $0?.reason } == [
            "No branch addtests in ada/notely", "README.md on main doesn't contain “/badge.svg”", "No pull request from addtests into main in ada/notely",
            "The latest 'ci' run failed; this step wants it to succeed", "In the latest 'ci' run, the Tests job's log doesn't show “-cover”",
        ])
        #expect(run.report.contains("✗ 3. Branch addtests exists\n  No branch addtests in ada/notely"))

        // The workflow that should fail, and succeeded; a file that's missing; a pull request
        // into another repository.
        let more = GitHubChecks(steps: [
            .init(kind: "workflow_status", check: .workflowStatus(workflow: "ci.yml", conclusion: "failure")),
            .init(kind: "file_contains", check: .fileContains(path: "docs/USAGE.md", texts: ["gator"])),
            .init(kind: "pr_exists", check: .prExists(baseOwner: "bootdotdev", baseRepo: "learn-cicd-starter", baseBranch: "main", compareBranch: "addtests")),
        ])
        answers[GitHubAPITests.runsKey] = GitHubAPITests.runs("completed", "success")
        answers["GET /repos/bootdotdev/learn-cicd-starter/pulls?base=main&head=ada:addtests&per_page=1&state=all"] = .json("[]")
        let other = await self.run(answers, checks: more)
        #expect(other.steps.map { $0?.reason } == [
            "The latest 'ci' run succeeded; this step wants it to fail", "No docs/USAGE.md on main in ada/notely",
            "No pull request from ada:addtests into main in bootdotdev/learn-cicd-starter",
        ])
        #expect(GitHubStub.seen.contains { $0.key == "GET /repos/ada/notely/contents/docs/USAGE.md" })
    }

    @Test func aMissingRepositoryFailsEveryStep() async {
        let signedIn = await self.run([:])
        #expect(signedIn.status == .failed && signedIn.steps.allSatisfy { $0?.reason == "No repository ada/notely on GitHub" })
        #expect(GitHubStub.seen.count == 1) // asked once
        let anonymous = await self.run([:], signIn: .notSignedIn)
        #expect(anonymous.steps[0]?.reason == "No repository ada/notely on GitHub. If it's private, sign in with `gh auth login` in Terminal.")
        #expect(anonymous.report.contains("not signed in"))
    }

    @Test func aRunStillInProgress() async {
        var answers = GitHubAPITests.everything
        answers[GitHubAPITests.runsKey] = GitHubAPITests.runs("in_progress", nil)
        let run = await self.run(answers, checks: GitHubChecks(steps: Array(GitHubAPITests.allKinds.steps.suffix(2))))
        #expect(run.status == .failed)
        #expect(run.steps.map { $0?.reason } == Array(repeating: "The latest 'ci' run is still running, check again in a moment", count: 2))
        #expect(run.steps[0]?.link?.absoluteString == "https://github.com/ada/notely/actions/runs/101")
        #expect(!GitHubStub.seen.contains { $0.key.contains("/jobs") }) // no logs of a run that hasn't finished
    }

    @Test func logsNeedASignIn() async {
        let logs = GitHubChecks(steps: Array(GitHubAPITests.allKinds.steps.suffix(1)))
        let signedOut = await self.run(GitHubAPITests.everything, checks: logs, signIn: .notSignedIn)
        #expect(signedOut.steps[0]?.reason == "Sign in with `gh auth login` in Terminal to check workflow logs.")
        #expect(!GitHubStub.seen.contains { $0.key.contains("/actions/") })
        let noCLI = await self.run(GitHubAPITests.everything, checks: logs, signIn: .noCLI)
        #expect(noCLI.steps[0]?.reason == "Install the GitHub CLI (brew install gh) and sign in with `gh auth login` in Terminal to check workflow logs.")
    }

    @Test func aWorkflowByItsNameOrNone() async {
        var answers = GitHubAPITests.everything
        answers.removeValue(forKey: GitHubAPITests.runsKey)
        answers["GET /repos/ada/notely/actions/workflows?per_page=100"] = .json(#"{"workflows":[{"id":77,"name":"ci","path":".github/workflows/tests.yml"}]}"#)
        answers["GET /repos/ada/notely/actions/workflows/77/runs?exclude_pull_requests=true&per_page=1"] = GitHubAPITests.runs("completed", "success")
        let checks = GitHubChecks(steps: [
            .init(kind: "workflow_status", check: .workflowStatus(workflow: "ci", conclusion: "success")),
            .init(kind: "workflow_status", check: .workflowStatus(workflow: "cd.yml", conclusion: "success")),
        ])
        let run = await self.run(answers, checks: checks)
        #expect(run.steps.map { $0?.reason } == ["The latest 'ci' run succeeded", "No workflow .github/workflows/cd.yml in ada/notely"])
    }

    @Test func limitsRefusalsAndNoNetworkStopTheRun() async throws {
        var answers = GitHubAPITests.everything
        answers["GET /repos/ada/notely/branches/addtests"] = .json(#"{"message":"API rate limit exceeded"}"#, status: 403,
                                                                   headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1800000000"])
        let limited = await self.run(answers)
        #expect(limited.status == .error && limited.steps.compactMap { $0 }.count == 2) // the steps before it
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(limited.error == GitHubError.rateLimited(resetsAt: reset, signedIn: true).errorDescription)
        #expect(limited.error?.contains(reset.formatted(date: .omitted, time: .shortened)) == true)

        GitHubStub.answer(["GET /repos/ada/notely": .json("{}", status: 429, headers: ["Retry-After": "30"])])
        await #expect(throws: GitHubError.slowDown(retryAfter: 30)) { try await GitHubStub.client().get("/repos/ada/notely", token: nil) }
        GitHubStub.answer(["GET /repos/ada/notely": .json(#"{"message":"rate limited"}"#, status: 403, headers: ["X-RateLimit-Remaining": "0"])])
        await #expect(throws: GitHubError.rateLimited(resetsAt: nil, signedIn: false)) { try await GitHubStub.client().get("/repos/ada/notely", token: nil) }

        let refused = await self.run(["GET /repos/ada/notely": .json(#"{"message":"Bad credentials"}"#, status: 401)])
        #expect(refused.status == .error && refused.error == GitHubError.badCredentials.errorDescription)
        let offline = await self.run(["GET /repos/ada/notely": .offline()])
        #expect(offline.status == .error && offline.error?.hasPrefix("GitHub can't be reached.") == true)
        let failing = await self.run(["GET /repos/ada/notely": .json("{}", status: 502)])
        #expect(failing.error == GitHubError.server(status: 502).errorDescription)
    }

    @Test func theTokenNeverFollowsARedirectElsewhere() async throws {
        let client = GitHubStub.client()
        GitHubStub.answer([
            "GET /repos/ada/old-name": .redirect("https://api.github.com/repositories/42", status: 301),
            "GET /repositories/42": .json(#"{"default_branch":"main"}"#),
            "GET /repos/ada/notely/actions/jobs/201/logs": .redirect("https://results.blob.example.net/logs/201.txt?sig=abc"),
            "GET https://results.blob.example.net/logs/201.txt": .text("log"),
            "GET /repos/ada/plain": .redirect("http://api.github.com/repos/ada/notely"),
        ])
        let moved = try await client.get("/repos/ada/old-name", token: GitHubAPITests.token)
        #expect(moved.status == 200)
        let log = try await client.get("/repos/ada/notely/actions/jobs/201/logs", token: GitHubAPITests.token)
        #expect(log.status == 200 && String(decoding: log.body, as: UTF8.self) == "log")
        await #expect(throws: GitHubError.self) { try await client.get("/repos/ada/plain", token: GitHubAPITests.token) }
        let seen = GitHubStub.seen
        #expect(seen.map(\.key) == ["GET /repos/ada/old-name", "GET /repositories/42", "GET /repos/ada/notely/actions/jobs/201/logs",
                                    "GET https://results.blob.example.net/logs/201.txt", "GET /repos/ada/plain"])
        #expect(seen.map { $0.headers["Authorization"] } == ["Bearer test-token-0000", "Bearer test-token-0000", "Bearer test-token-0000", nil, "Bearer test-token-0000"])
        #expect(seen[3].headers["X-GitHub-Api-Version"] == nil)

        // URLSession itself never follows a redirect: the client decides who gets the token.
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(fileURLWithPath: "/"))
        let response = try #require(HTTPURLResponse(url: URL(string: "https://api.github.com/x")!, statusCode: 302, httpVersion: nil, headerFields: nil))
        #expect(await RedirectRefusal().urlSession(session, task: task, willPerformHTTPRedirection: response,
                                                   newRequest: URLRequest(url: URL(string: "https://elsewhere.example.com")!)) == nil)
        session.invalidateAndCancel()
    }

    @Test func createsTheSolutionsRepositoryAndReadsTheAccount() async throws {
        let client = GitHubStub.client()
        GitHubStub.answer([
            "POST /user/repos": .json(#"{"name":"go-solutions","full_name":"ada/go-solutions","owner":{"login":"ada"},"private":true}"#, status: 201),
            "GET /user": .json(#"{"id":123,"login":"ada"}"#),
        ])
        let created = try await client.createRepository(name: "go-solutions", isPrivate: true, token: GitHubAPITests.token)
        #expect(created == CreatedRepository(repo: GitHubRepo(owner: "ada", name: "go-solutions")!, isPrivate: true))
        let user = try await client.user(token: GitHubAPITests.token)
        #expect(user.noreplyEmail == "123+ada@users.noreply.github.com")
        let post = try #require(GitHubStub.seen.first)
        #expect(post.method == "POST" && post.headers["Authorization"] == "Bearer test-token-0000")
        let body = try #require(try JSONSerialization.jsonObject(with: post.body ?? Data()) as? [String: Any])
        #expect(body["name"] as? String == "go-solutions" && body["private"] as? Bool == true && body["auto_init"] as? Bool == false)

        GitHubStub.answer(["POST /user/repos": .json(#"{"message":"Repository creation failed.","errors":[{"message":"name already exists on this account"}]}"#, status: 422)])
        await #expect(throws: GitHubError.refused("GitHub did not create go-solutions: name already exists on this account.")) {
            try await client.createRepository(name: "go-solutions", isPrivate: false, token: GitHubAPITests.token)
        }
    }
}
