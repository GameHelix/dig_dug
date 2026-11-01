import Foundation

/// What a GitHub step found: whether it passed, why, and where to see it on GitHub.
public struct GitHubStepResult: Hashable, Sendable {
    public var passed: Bool
    /// Short and specific, such as "No branch addtests in ada/notely".
    public var reason: String
    /// The repository, branch, file, pull request, run or job on github.com.
    public var link: URL?

    public init(passed: Bool, reason: String, link: URL? = nil) {
        self.passed = passed
        self.reason = reason
        self.link = link
    }

    static func pass(_ reason: String, _ link: URL? = nil) -> GitHubStepResult { GitHubStepResult(passed: true, reason: reason, link: link) }
    static func fail(_ reason: String, _ link: URL? = nil) -> GitHubStepResult { GitHubStepResult(passed: false, reason: reason, link: link) }
}

/// The result of running a GitHub lesson's checks.
public struct GitHubCheckRun: Sendable {
    public var status: CheckRun.Status
    public var repo: GitHubRepo
    /// Each step's result; nil for a step the run did not reach.
    public var steps: [GitHubStepResult?]
    /// Why the run stopped before the end: no network, a used-up rate limit, a refused sign-in.
    public var error: String?
    /// Whether the GitHub CLI gave a token; without one the checks ask GitHub anonymously.
    public var signedIn: Bool
    public var duration: Duration = .zero
    /// A plain-text account of the run, for the attempt history; made when the run ends.
    public private(set) var report = ""

    mutating func finish(_ checks: GitHubChecks) {
        var lines = ["Repository \(repo), " + (signedIn ? "signed in through the GitHub CLI" : "not signed in")]
        if let error { lines.append(error) }
        for (i, step) in checks.steps.enumerated() {
            guard steps.indices.contains(i), let result = steps[i] else { continue }
            lines.append("\(result.passed ? "✓" : "✗") \(i + 1). \(step.summary)")
            lines.append("  " + result.reason)
        }
        report = lines.joined(separator: "\n")
    }
}

extension GitHubSignIn {
    /// How to sign in, for a step that needs it.
    var signInHint: String {
        switch self {
        case .noCLI: "install the GitHub CLI (brew install gh) and sign in with `gh auth login` in Terminal"
        default: "sign in with `gh auth login` in Terminal"
        }
    }
}

/// Runs a GitHub lesson's steps against your repository through GitHub's REST API. It only
/// reads: every request is a GET. It asks the GitHub CLI for a token once per run; without one
/// it asks anonymously, which reaches public repositories but not workflow logs.
public struct GitHubChecker: Sendable {
    public let client: GitHubClient
    /// The GitHub CLI's sign-in, asked for as a run starts.
    public let signIn: @Sendable () async -> GitHubSignIn

    public init(client: GitHubClient, signIn: @escaping @Sendable () async -> GitHubSignIn) {
        self.client = client
        self.signIn = signIn
    }

    /// Runs every step in order; `onStep` hears about each as it starts (nil) and as it
    /// finishes. A problem on the way to GitHub stops the run: the steps after it have no result.
    @concurrent
    public func run(_ checks: GitHubChecks, repo: GitHubRepo,
                    onStep: (@Sendable (Int, GitHubStepResult?) async -> Void)? = nil) async -> GitHubCheckRun {
        let clock = ContinuousClock()
        let started = clock.now
        let access = await signIn()
        var run = GitHubCheckRun(status: .passed, repo: repo, steps: Array(repeating: nil, count: checks.steps.count),
                                 error: nil, signedIn: access.token != nil)
        var lookups = GitHubLookups(client: client, repo: repo, token: access.token, signInHint: access.signInHint)
        do throws(GitHubError) {
            for (i, step) in checks.steps.enumerated() {
                if Task.isCancelled { throw .cancelled }
                await onStep?(i, nil)
                let result = try await lookups.check(step.check)
                run.steps[i] = result
                if !result.passed { run.status = .failed }
                await onStep?(i, result)
            }
        } catch .cancelled {
            run.status = .cancelled
        } catch {
            run.status = .error
            run.error = error.localizedDescription
        }
        run.duration = clock.now - started
        run.finish(checks)
        return run
    }
}

/// One run's answers from GitHub, each asked for once: the repository, the latest run of each
/// workflow, a run's jobs and a job's log.
struct GitHubLookups {
    let client: GitHubClient
    let repo: GitHubRepo
    let token: GitHubToken?
    /// How to sign in, for the steps that need it.
    let signInHint: String
    private var knownRepository: Found<Repository>?
    private var knownRuns: [String: Found<Run>] = [:]
    private var knownJobs: [Int: Found<[Job]>] = [:]
    private var knownLogs: [Int: Found<String>] = [:]

    init(client: GitHubClient, repo: GitHubRepo, token: GitHubToken?, signInHint: String) {
        self.client = client
        self.repo = repo
        self.token = token
        self.signInHint = signInHint
    }

    /// An answer, or the step's failure without one.
    enum Found<T> {
        case found(T)
        case failed(GitHubStepResult)
    }

    struct Repository: Decodable {
        let defaultBranch: String
    }

    struct Contents: Decodable {
        let type: String
        let encoding: String?
        let content: String?
        let htmlUrl: URL?
    }

    struct Pull: Decodable {
        let number: Int
        let state: String
        let mergedAt: String?
        let htmlUrl: URL?
    }

    struct Runs: Decodable {
        let workflowRuns: [Run]
    }

    struct Run: Decodable {
        let id: Int
        let name: String?
        let status: String?
        let conclusion: String?
        let htmlUrl: URL?
    }

    struct Workflows: Decodable {
        let workflows: [Workflow]
    }

    struct Workflow: Decodable {
        let id: Int
        let name: String
        let path: String
    }

    struct Jobs: Decodable {
        let jobs: [Job]
    }

    struct Job: Decodable {
        let id: Int
        let name: String
        let htmlUrl: URL?
    }

    private var segments: [String] { ["repos", repo.owner, repo.name] }

    private func get(_ more: [String], query: [String: String] = [:]) async throws(GitHubError) -> GitHubResponse {
        try await client.get(GitHubClient.path(segments + more), query: query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) },
                             token: token)
    }

    /// A status the step has no words for, with GitHub's message.
    private func unexpected(_ r: GitHubResponse) -> GitHubStepResult {
        .fail("GitHub answered \(r.status)" + (r.message.map { ": \($0)" } ?? ""))
    }

    mutating func check(_ check: GitHubCheck) async throws(GitHubError) -> GitHubStepResult {
        if case .unknown(let kind) = check { return .fail("Gopherwood can't check \(kind) steps") }
        let info: Repository
        switch try await repository() {
        case .found(let found): info = found
        case .failed(let failure): return failure
        }
        switch check {
        case .repoExists, .submitRepoForCourse:
            return .pass("\(repo) is on GitHub", repo.webURL)
        case .branchExists(let branch):
            let r = try await get(["branches", branch])
            switch r.status {
            case 200: return .pass("Branch \(branch) is in \(repo)", repo.webURL.appending(path: "tree/\(branch)"))
            case 404: return .fail("No branch \(branch) in \(repo)", repo.webURL.appending(path: "branches"))
            default: return unexpected(r)
            }
        case .fileContains(let path, let texts):
            return try await fileContains(path, texts, branch: info.defaultBranch)
        case .prExists(let baseOwner, let baseRepo, let baseBranch, let compare):
            return try await pullRequest(baseOwner: baseOwner, baseRepo: baseRepo, baseBranch: baseBranch, compare: compare)
        case .workflowStatus(let workflow, let want):
            let run: Run
            switch try await latestRun(workflow) {
            case .found(let found): run = found
            case .failed(let failure): return failure
            }
            let label = GitHubLookups.label(run, workflow)
            guard run.status == "completed" else { return .fail("\(label) is still running, check again in a moment", run.htmlUrl) }
            if run.conclusion == want {
                return .pass(want == "failure" ? "\(label) failed, as this step wants" : "\(label) \(GitHubLookups.ended(run.conclusion))", run.htmlUrl)
            }
            let wanted = want == "success" ? "succeed" : want == "failure" ? "fail" : "end in \(want)"
            return .fail("\(label) \(GitHubLookups.ended(run.conclusion)); this step wants it to \(wanted)", run.htmlUrl)
        case .workflowLogsContains(let workflow, let wanted):
            return try await logsContain(workflow, wanted)
        case .unknown:
            return .fail("Gopherwood can't check this step")
        }
    }

    // MARK: The repository and its files

    private mutating func repository() async throws(GitHubError) -> Found<Repository> {
        if let knownRepository { return knownRepository }
        let r = try await get([])
        let found: Found<Repository> = switch r.status {
        case 200: .found(try r.decode(Repository.self))
        case 404: .failed(.fail("No repository \(repo) on GitHub" + (token == nil ? ". If it's private, \(signInHint)." : ""), repo.webURL))
        default: .failed(unexpected(r))
        }
        knownRepository = found
        return found
    }

    private func fileContains(_ path: String, _ texts: [String], branch: String) async throws(GitHubError) -> GitHubStepResult {
        let r = try await get(["contents"] + path.split(separator: "/").map(String.init))
        let on = "\(path) on \(branch)"
        switch r.status {
        case 200:
            // A folder's contents are a list.
            if r.body.first(where: { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }) == UInt8(ascii: "[") {
                return .fail("\(path) is a folder in \(repo), not a file", repo.webURL.appending(path: "tree/\(branch)/\(path)"))
            }
            let file = try r.decode(Contents.self)
            guard file.type == "file" else { return .fail("\(on) is a \(file.type), not a file", file.htmlUrl) }
            guard file.encoding == "base64", let content = file.content, let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else {
                return .fail("\(on) is too big to read through GitHub's API", file.htmlUrl)
            }
            let text = String(decoding: data, as: UTF8.self)
            let missing = texts.filter { !text.contains($0) }
            return missing.isEmpty ? .pass("\(on) contains \(GitHubCheck.quoted(texts))", file.htmlUrl)
                : .fail("\(on) doesn't contain \(GitHubCheck.quoted(missing))", file.htmlUrl)
        case 404:
            return .fail("No \(path) on \(branch) in \(repo)", repo.webURL)
        default:
            return unexpected(r)
        }
    }

    private func pullRequest(baseOwner: String?, baseRepo: String?, baseBranch: String, compare: String) async throws(GitHubError) -> GitHubStepResult {
        // The base repository is yours unless the step names another.
        let target = baseOwner.flatMap { owner in baseRepo.map { (owner, $0) } } ?? (repo.owner, repo.name)
        let yours = target == (repo.owner, repo.name)
        let head = "\(repo.owner):\(compare)", from = yours ? compare : head
        let r = try await client.get(GitHubClient.path("repos", target.0, target.1, "pulls"), query: [
            URLQueryItem(name: "state", value: "all"), URLQueryItem(name: "head", value: head),
            URLQueryItem(name: "base", value: baseBranch), URLQueryItem(name: "per_page", value: "1"),
        ], token: token)
        let pulls = URL(string: "https://github.com/\(target.0)/\(target.1)/pulls")
        switch r.status {
        case 200:
            guard let pull = try r.decode([Pull].self).first else {
                return .fail("No pull request from \(from) into \(baseBranch) in \(target.0)/\(target.1)", pulls)
            }
            let state = pull.mergedAt != nil ? "merged" : pull.state
            return .pass("Pull request #\(pull.number) from \(from) into \(baseBranch) is \(state)", pull.htmlUrl)
        case 404:
            return .fail("No repository \(target.0)/\(target.1) on GitHub")
        default:
            return unexpected(r)
        }
    }

    // MARK: Workflows

    /// "The latest 'ci' run": the run's name, as its workflow file declares it.
    static func label(_ run: Run, _ workflow: String) -> String {
        "The latest '\(run.name ?? workflow)' run"
    }

    /// How a run ended, after "The latest 'ci' run".
    static func ended(_ conclusion: String?) -> String {
        switch conclusion {
        case "success": "succeeded"
        case "failure": "failed"
        case "cancelled": "was cancelled"
        case "skipped": "was skipped"
        case "timed_out": "timed out"
        case "action_required": "is waiting for approval"
        case "startup_failure": "failed to start"
        case "neutral": "ended neutral"
        case "stale": "went stale"
        case let other?: "ended in \(other)"
        case nil: "ended"
        }
    }

    /// The most recent run of a workflow on any branch. The workflow is its file, such as
    /// ci.yml, or else the name its file declares.
    private mutating func latestRun(_ workflow: String) async throws(GitHubError) -> Found<Run> {
        if let known = knownRuns[workflow] { return known }
        let newest = ["per_page": "1", "exclude_pull_requests": "true"]
        var r = try await get(["actions", "workflows", workflow, "runs"], query: newest)
        if r.status == 404 {
            let list = try await get(["actions", "workflows"], query: ["per_page": "100"])
            guard list.status == 200 else { return remember(workflow, list.status == 404 ? noWorkflow(workflow) : .failed(unexpected(list))) }
            let named = try list.decode(Workflows.self).workflows.first { $0.name == workflow || ($0.path as NSString).lastPathComponent == workflow }
            guard let named else { return remember(workflow, noWorkflow(workflow)) }
            r = try await get(["actions", "workflows", String(named.id), "runs"], query: newest)
        }
        guard r.status == 200 else { return remember(workflow, r.status == 404 ? noWorkflow(workflow) : .failed(unexpected(r))) }
        guard let run = try r.decode(Runs.self).workflowRuns.first else {
            return remember(workflow, .failed(.fail("No runs of \(workflow) in \(repo) yet", repo.webURL.appending(path: "actions"))))
        }
        return remember(workflow, .found(run))
    }

    private mutating func remember(_ workflow: String, _ found: Found<Run>) -> Found<Run> {
        knownRuns[workflow] = found
        return found
    }

    private func noWorkflow(_ workflow: String) -> Found<Run> {
        let file = workflow.hasSuffix(".yml") || workflow.hasSuffix(".yaml") ? ".github/workflows/\(workflow)" : workflow
        return .failed(.fail("No workflow \(file) in \(repo)", repo.webURL.appending(path: "actions")))
    }

    private mutating func logsContain(_ workflow: String, _ wanted: [GitHubCheck.JobTexts]) async throws(GitHubError) -> GitHubStepResult {
        // GitHub gives workflow logs only to someone signed in.
        guard token != nil else { return .fail(signInHint.prefix(1).uppercased() + signInHint.dropFirst() + " to check workflow logs.") }
        let run: Run
        switch try await latestRun(workflow) {
        case .found(let found): run = found
        case .failed(let failure): return failure
        }
        let label = GitHubLookups.label(run, workflow)
        guard run.status == "completed" else { return .fail("\(label) is still running, check again in a moment", run.htmlUrl) }
        let runJobs: [Job]
        switch try await jobs(of: run) {
        case .found(let found): runJobs = found
        case .failed(let failure): return failure
        }
        let lower = label.prefix(1).lowercased() + label.dropFirst()
        var shown: [String] = [], link = run.htmlUrl
        for want in wanted {
            guard let job = runJobs.first(where: { $0.name == want.job }) ?? runJobs.first(where: { $0.name.caseInsensitiveCompare(want.job) == .orderedSame }) else {
                return .fail("\(label) has no job named \(want.job)", run.htmlUrl)
            }
            let text: String
            switch try await log(of: job, in: lower) {
            case .found(let found): text = found
            case .failed(let failure): return failure
            }
            let missing = want.texts.filter { !text.contains($0) }
            guard missing.isEmpty else {
                return .fail("In \(lower), the \(job.name) job's log doesn't show \(GitHubCheck.quoted(missing))", job.htmlUrl ?? run.htmlUrl)
            }
            shown.append("the \(job.name) job's log shows \(GitHubCheck.quoted(want.texts))")
            if wanted.count == 1 { link = job.htmlUrl ?? link }
        }
        return .pass(shown.isEmpty ? "\(label) has finished" : "In \(lower), " + shown.joined(separator: "; "), link)
    }

    private mutating func jobs(of run: Run) async throws(GitHubError) -> Found<[Job]> {
        if let known = knownJobs[run.id] { return known }
        let r = try await get(["actions", "runs", String(run.id), "jobs"], query: ["per_page": "100"])
        let found: Found<[Job]> = r.status == 200 ? .found(try r.decode(Jobs.self).jobs) : .failed(unexpected(r))
        knownJobs[run.id] = found
        return found
    }

    /// A job's log: GitHub redirects to blob storage, which the client asks without the token.
    private mutating func log(of job: Job, in run: String) async throws(GitHubError) -> Found<String> {
        if let known = knownLogs[job.id] { return known }
        let r = try await get(["actions", "jobs", String(job.id), "logs"])
        let found: Found<String> = switch r.status {
        case 200: .found(String(decoding: r.body, as: UTF8.self))
        case 404, 410: .failed(.fail("GitHub has no log for the \(job.name) job of \(run); logs are kept for 90 days", job.htmlUrl))
        default: .failed(unexpected(r))
        }
        knownLogs[job.id] = found
        return found
    }
}
