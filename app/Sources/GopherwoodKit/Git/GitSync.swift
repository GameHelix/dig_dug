import Foundation

/// Why a git step did not happen.
public enum GitSyncError: Error, LocalizedError, Equatable, Sendable {
    case notARepository(String)
    /// The library file (its path in the work tree) is not tracked.
    case notTracked(String)
    case conflict(String)
    case offline(String)
    /// Git's index lock file is there although no git is running: a git that was killed
    /// left it behind, and every commit and pull fails until it is removed.
    case staleLock(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notARepository(let path): "\(path) is not in a git work tree."
        case .notTracked(let file): "\(file) is not tracked by git."
        case .conflict(let m): "The library's repository and its remote both have new commits: \(m)"
        case .offline(let m): "Could not reach the remote: \(m)"
        case .staleLock(let path): "Git cannot work in the library's repository: \(path) was left behind by a git that stopped, and no git is running now."
        case .failed(let m): m
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .conflict: "Gopherwood never merges. Resolve it in Terminal (git status in the library's folder), then open the library again."
        case .offline: "Gopherwood tries again next time."
        case .staleLock: "Remove the lock file, and Gopherwood commits and pulls again."
        default: nil
        }
    }
}

/// Keeps a library file in git when it sits in a work tree: pulls before the library opens,
/// then commits only that file and pushes, while no write is under way. It runs
/// /usr/bin/git -C <work tree>.
///
/// Steps run one at a time, in the order asked: a commit asked for while a push runs waits
/// for it instead of racing it for .git/index.lock. Git is never killed outright: a timeout
/// sends SIGTERM and waits, so git can remove its lock file, and quitting the app leaves git
/// running to the end of its step.
public actor GitSync {
    /// How long git gets to stop after SIGTERM.
    static let gracePeriod: Duration = .seconds(5)

    public nonisolated let repository: URL
    /// The library file's path inside the work tree, as git names it.
    public nonisolated let file: String
    private let environment: [String: String]
    private let isGitRunning: @Sendable () async -> Bool
    private var queue: Task<Void, Never>?

    /// `isGitRunning` tells whether a git process runs on this Mac, so a lock file may be in
    /// use; tests replace it.
    public init(repository: URL, file: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                isGitRunning: @escaping @Sendable () async -> Bool = GitSync.gitIsRunning) {
        self.repository = repository
        self.file = file
        self.isGitRunning = isGitRunning
        self.environment = GitSync.environment(environment)
    }

    /// The environment every git step runs in.
    static func environment(_ base: [String: String]) -> [String: String] {
        var env = base
        env["GIT_TERMINAL_PROMPT"] = "0" // never wait for a password prompt nobody can see
        env["GIT_OPTIONAL_LOCKS"] = "0" // status and friends leave the index lock alone
        env["GIT_LITERAL_PATHSPECS"] = "1" // lib[1].sqlite is that file, not a pattern
        env["LC_ALL"] = "C"
        return env
    }

    /// Where a library file stands with git.
    public enum Location: Sendable {
        /// Tracked in a work tree: sync is on.
        case tracked(GitSync)
        /// In a work tree that does not track it: sync is off.
        case untracked
        /// Not in a work tree: sync is off.
        case outside

        public var sync: GitSync? {
            if case .tracked(let sync) = self { sync } else { nil }
        }
    }

    /// The git work tree a library file sits in (`git rev-parse --show-toplevel` in its
    /// folder), and whether that work tree tracks the file (`git ls-files --error-unmatch`).
    /// Only a tracked file is synced: a pull would otherwise update a repository the library
    /// only happens to sit in.
    public static func locate(_ library: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
                              isGitRunning: @escaping @Sendable () async -> Bool = GitSync.gitIsRunning) async -> Location {
        let folder = library.deletingLastPathComponent()
        let env = GitSync.environment(environment)
        let out = await ProcessRunner.run(request(folder, env, ["rev-parse", "--show-toplevel"], timeout: .seconds(15)))
        let top = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard out.succeeded, !top.isEmpty else { return .outside }
        let root = GoRunner.realPath(top), path = GoRunner.realPath(library.path)
        guard path.hasPrefix(root + "/") else { return .outside }
        let repository = URL(fileURLWithPath: root, isDirectory: true), file = String(path.dropFirst(root.count + 1))
        let tracked = await ProcessRunner.run(request(repository, env, ["ls-files", "--error-unmatch", "--", file], timeout: .seconds(15)))
        guard tracked.succeeded else { return .untracked }
        return .tracked(GitSync(repository: repository, file: file, environment: environment, isGitRunning: isGitRunning))
    }

    public enum Outcome: Equatable, Sendable {
        case done(String)
        case nothing
    }

    /// Runs `step` after every step asked for before it has finished.
    private func serialized<T: Sendable>(_ step: @escaping @Sendable (GitSync) async -> Result<T, GitSyncError>) async throws(GitSyncError) -> T {
        let previous = queue
        let task = Task { [self] in
            await previous?.value
            return await step(self)
        }
        queue = Task { _ = await task.value }
        return try await task.value.get()
    }

    private func git(_ args: [String], timeout: Duration = .seconds(60)) async -> ProcessOutput {
        await ProcessRunner.run(GitSync.request(repository, environment, args, timeout: timeout))
    }

    nonisolated static func gitBlocking(_ repository: URL, _ environment: [String: String], _ args: [String], timeout: Duration) -> ProcessOutput {
        ProcessRunner.runBlocking(request(repository, environment, args, timeout: timeout))
    }

    nonisolated static func request(_ repository: URL, _ environment: [String: String], _ args: [String], timeout: Duration) -> ProcessRequest {
        ProcessRequest(executable: SystemTools.git, arguments: ["-C", repository.path] + args, directory: repository.path,
                       environment: environment, timeout: timeout, outputLimit: 1 << 20, kind: .git, gracePeriod: gracePeriod)
    }

    static func message(_ out: ProcessOutput) -> String {
        let text = (out.stderr.isEmpty ? out.stdout : out.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("hint:") }
        if out.timedOut { return "git took too long" }
        return lines.first(where: { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") || $0.hasPrefix("!") }) ?? lines.first ?? "git exited with status \(out.exitCode)"
    }

    /// A failed step's error: a stale lock file when that is what stopped git.
    private func failure(_ out: ProcessOutput) async -> GitSyncError {
        if (out.stdout + out.stderr).contains("index.lock"), let path = await staleLockPath() { return .staleLock(path) }
        return .failed(GitSync.message(out))
    }

    private func isRepository() async -> Bool {
        await git(["rev-parse", "--is-inside-work-tree"], timeout: .seconds(15)).stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// `git pull --ff-only`. A pull that would need a merge is reported, never merged. The
    /// caller closes the library first: git must not replace the file under an open connection.
    public func pullFastForward() async throws(GitSyncError) -> Outcome {
        try await serialized { await $0.pullNow() }
    }

    private func pullNow() async -> Result<Outcome, GitSyncError> {
        guard await isRepository() else { return .failure(.notARepository(repository.path)) }
        let hasUpstream = await git(["rev-parse", "--abbrev-ref", "@{upstream}"], timeout: .seconds(15)).succeeded
        guard hasUpstream else { return .success(.nothing) }
        let before = await git(["rev-parse", "HEAD"], timeout: .seconds(15)).stdout
        let out = await git(["pull", "--ff-only", "--quiet"], timeout: .seconds(90))
        if out.succeeded {
            let after = await git(["rev-parse", "HEAD"], timeout: .seconds(15)).stdout
            return .success(before == after ? .nothing : .done("Pulled"))
        }
        let text = (out.stdout + out.stderr).lowercased()
        if text.contains("not possible to fast-forward") || text.contains("diverging") || text.contains("would be overwritten") || text.contains("divergent") {
            return .failure(.conflict(GitSync.message(out)))
        }
        if out.timedOut || text.contains("could not resolve host") || text.contains("unable to access") || text.contains("could not read from remote") {
            return .failure(.offline(GitSync.message(out)))
        }
        return .failure(await failure(out))
    }

    /// Commits the library file if it changed, then pushes, as one step: nothing else runs in
    /// between. The commit is `git commit --only`, which leaves anything else you staged
    /// alone; the database holds still meanwhile: every write of the app has landed, and a
    /// shared lock keeps other programs from writing while git reads it.
    public func commitAndPush(_ database: AppDatabase) async throws(GitSyncError) -> (commit: Outcome, push: Outcome) {
        try await serialized { s in
            let commit = await s.commitNow(database)
            guard case .success(let c) = commit else { return commit.map { ($0, .nothing) } }
            return await s.pushNow().map { (c, $0) }
        }
    }

    private func commitNow(_ database: AppDatabase) async -> Result<Outcome, GitSyncError> {
        guard await git(["ls-files", "--error-unmatch", "--", file], timeout: .seconds(15)).succeeded else {
            return .failure(.notTracked(file))
        }
        let repository = repository, environment = environment, file = file
        let since = await lastCommitDate().map(Clock.string) ?? "1970-01-01T00:00:00Z"
        let message = ((try? await database.activity(since: since)) ?? StudyActivity(finished: [], finishedCourses: [], attempts: [:], lessonsTried: [], coursesTried: [], notesChanged: 0, codeChanged: 0)).commitMessage
        let out: ProcessOutput?
        do {
            out = try await database.holdingFileStill { () -> ProcessOutput? in
                let status = GitSync.gitBlocking(repository, environment, ["status", "--porcelain", "--", file], timeout: .seconds(30))
                guard status.succeeded, !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return GitSync.gitBlocking(repository, environment, ["commit", "--only", "--quiet", "-m", message, "--", file], timeout: .seconds(60))
            }
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
        guard let out else { return .success(.nothing) }
        if out.succeeded { return .success(.done(message)) }
        if (out.stdout + out.stderr).contains("nothing to commit") { return .success(.nothing) }
        return .failure(await failure(out))
    }

    /// Pushes if this work tree has commits its upstream lacks.
    private func pushNow() async -> Result<Outcome, GitSyncError> {
        let ahead = await git(["rev-list", "--count", "@{upstream}..HEAD"], timeout: .seconds(15))
        if ahead.succeeded, Int(ahead.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) == 0 { return .success(.nothing) }
        let out = await git(["push", "--quiet"], timeout: .seconds(60))
        if out.succeeded { return .success(.done("Pushed")) }
        let text = (out.stdout + out.stderr).lowercased()
        if text.contains("rejected") || text.contains("non-fast-forward") || text.contains("fetch first") {
            return .failure(.conflict(GitSync.message(out)))
        }
        if out.timedOut || text.contains("could not resolve host") || text.contains("unable to access") || text.contains("could not read from remote") {
            return .failure(.offline(GitSync.message(out)))
        }
        return .failure(await failure(out))
    }

    /// The index lock file, if it is there while no git process runs on this Mac.
    func staleLockPath() async -> String? {
        let out = await git(["rev-parse", "--git-path", "index.lock"], timeout: .seconds(15))
        guard out.succeeded else { return nil }
        var path = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.hasPrefix("/") { path = repository.appendingPathComponent(path).path }
        guard FileManager.default.fileExists(atPath: path), !(await isGitRunning()) else { return nil }
        return path
    }

    /// Whether any git process is running: then a lock file may be in use and stays.
    public static func gitIsRunning() async -> Bool {
        let out = await ProcessRunner.run(ProcessRequest(executable: "/usr/bin/pgrep", arguments: ["-x", "git"], directory: "/",
                                                         environment: [:], timeout: .seconds(5), kind: .git))
        return out.exitCode == 0
    }

    /// Removes a stale index lock file (one no running git holds).
    public func removeStaleLock() async throws(GitSyncError) {
        try await serialized { s in
            guard let path = await s.staleLockPath() else { return .success(()) }
            do {
                try FileManager.default.removeItem(atPath: path)
                return .success(())
            } catch {
                return .failure(.failed("\(path) could not be removed: \(error.localizedDescription)"))
            }
        }
    }

    /// When the database file was last committed.
    private func lastCommitDate() async -> Date? {
        let out = await git(["log", "-1", "--format=%cI", "--", file], timeout: .seconds(15))
        let text = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.succeeded && !text.isEmpty ? Clock.date(text) : nil
    }

    /// Whether the database differs from its last commit.
    public func hasChanges() async -> Bool {
        let out = await git(["status", "--porcelain", "--", file], timeout: .seconds(30))
        return out.succeeded && !out.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
