import Foundation

/// Why the solutions repository could not do something.
public enum SolutionsError: Error, LocalizedError, Equatable, Sendable {
    /// The folder can't hold the repository.
    case folder(String)
    case notARepository(String)
    /// Git has no user.name or user.email, and no GitHub account gave its noreply address.
    case noAuthor
    /// Pushing goes through the GitHub CLI's sign-in, and gh isn't there.
    case noCLI
    /// GitHub has commits the folder lacks.
    case behind(String)
    case offline(String)
    /// GitHub refused the sign-in.
    case refused(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .folder(let m), .failed(let m): m
        case .notARepository(let path): "\((path as NSString).abbreviatingWithTildeInPath) is not a git repository any more."
        case .noAuthor: "Commits need an author: set git config --global user.email, or sign in with gh auth login so Gopherwood can use your GitHub noreply address."
        case .noCLI: "Pushing goes through the GitHub CLI's sign-in: install it (brew install gh), then run gh auth login in Terminal."
        case .behind(let m): "GitHub has commits your solutions folder doesn't: \(m) Bring them in with git pull --rebase in Terminal; Gopherwood never merges."
        case .offline(let m): "GitHub can't be reached: \(m) The commits wait for the next push."
        case .refused(let m): "GitHub refused the push: \(m) Run gh auth login in Terminal, then push again."
        }
    }
}

/// Who solution commits are by when git has no user.name or user.email of its own: your
/// GitHub login and noreply address, so the commits count on your contribution graph.
public struct SolutionsAuthor: Equatable, Sendable {
    public let name: String
    public let email: String

    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }

    public init(_ user: GitHubUser) {
        self.init(name: user.login, email: user.noreplyEmail)
    }
}

/// Your solutions repository: a git repository of its own on this Mac, whose origin is your
/// repository on GitHub. A solved lesson is written to its folder and committed, dated when
/// you solved it; pushing is a step of its own, through the GitHub CLI's credential helper.
/// It runs /usr/bin/git -C <folder>, one step at a time, and never touches the library's
/// repository.
public actor SolutionsRepository {
    /// How long git gets to stop after SIGTERM.
    static let gracePeriod: Duration = .seconds(5)

    public nonisolated let folder: URL
    public nonisolated let repo: GitHubRepo
    private let environment: [String: String]
    private var queue: Task<Void, Never>?

    public init(folder: URL, repo: GitHubRepo, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.folder = folder
        self.repo = repo
        self.environment = GitSync.environment(environment)
    }

    public enum CommitOutcome: Equatable, Sendable {
        case committed
        /// The files are as the last commit has them: no commit.
        case unchanged
    }

    public enum PushOutcome: Equatable, Sendable {
        case pushed(Int)
        case nothing
    }

    // MARK: Setting up

    /// https://github.com/<owner>/<name>.git, origin's address: never with a token in it.
    public static func remote(_ repo: GitHubRepo) -> String {
        "https://github.com/\(repo.owner)/\(repo.name).git"
    }

    /// The options that make git ask the GitHub CLI for credentials, in place of any helper
    /// configured elsewhere. The token goes from gh to git on a pipe: never into a URL, a
    /// config file or an argument.
    static func credentialOptions(gh: String) -> [String] {
        let safe = gh.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || "/._-+".unicodeScalars.contains($0)) }
        let command = safe ? gh : "'" + gh.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return ["-c", "credential.helper=", "-c", "credential.helper=!\(command) auth git-credential"]
    }

    /// Why `folder` can't hold a solutions repository, or nil. It must not be or hold one of
    /// `outside` (~/Documents/jobloom, the library's own repository) nor sit inside one, and a
    /// new repository needs a new or empty folder.
    public static func problem(with folder: URL, outside: [URL], mustBeEmpty: Bool) -> String? {
        let path = resolved(folder).lowercased()
        for root in outside {
            let r = resolved(root).lowercased()
            if path == r || path.hasPrefix(r + "/") || r.hasPrefix(path + "/") {
                return "Choose a folder outside \((root.path as NSString).abbreviatingWithTildeInPath)."
            }
        }
        let shown = (folder.path as NSString).abbreviatingWithTildeInPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir) {
            if !isDir.boolValue { return "\(shown) is a file: choose a folder." }
            let items = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            if mustBeEmpty && items.contains(where: { $0 != ".DS_Store" }) { return "\(shown) isn't empty: choose a new or empty folder." }
        }
        return nil
    }

    /// The path with symbolic links resolved as far as it exists.
    static func resolved(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path) && existing.pathComponents.count > 1 {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        return ([GoRunner.realPath(existing.path)] + rest).joined(separator: "/").replacingOccurrences(of: "//", with: "/")
    }

    /// Makes `folder` (new or empty) a git repository for `repo`: git init -b main, then
    /// origin set to its address. Nothing is committed until the first solution.
    public static func create(at folder: URL, repo: GitHubRepo, environment: [String: String] = ProcessInfo.processInfo.environment) async throws(SolutionsError) -> SolutionsRepository {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw .folder("\((folder.path as NSString).abbreviatingWithTildeInPath) could not be made: \(error.localizedDescription)")
        }
        let s = SolutionsRepository(folder: folder, repo: repo, environment: environment)
        try await s.initialize()
        return s
    }

    private func initialize() async throws(SolutionsError) {
        let made = await git(["init", "--quiet", "-b", "main"])
        guard made.succeeded else { throw .failed(GitSync.message(made)) }
        let url = SolutionsRepository.remote(repo)
        if !(await git(["remote", "add", "origin", url])).succeeded {
            let set = await git(["remote", "set-url", "origin", url])
            guard set.succeeded else { throw .failed(GitSync.message(set)) }
        }
    }

    /// Takes `folder` when it already is a clone of `repo`, else clones `repo` into it (new or
    /// empty), through the GitHub CLI's sign-in when there is one, so a private one works too.
    public static func useExisting(_ repo: GitHubRepo, in folder: URL, gh: String?,
                                   environment: [String: String] = ProcessInfo.processInfo.environment) async throws(SolutionsError) -> SolutionsRepository {
        let s = SolutionsRepository(folder: folder, repo: repo, environment: environment)
        let shown = (folder.path as NSString).abbreviatingWithTildeInPath
        switch await s.origin() {
        case .clone(let origin?):
            guard origin.fullName.lowercased() == repo.fullName.lowercased() else { throw .folder("\(shown) is a clone of \(origin), not of \(repo).") }
            return s
        case .clone(nil):
            throw .folder("\(shown) is a git repository whose origin is not \(repo).")
        case .notRepository:
            if let problem = problem(with: folder, outside: [], mustBeEmpty: true) { throw .folder(problem) }
        }
        do {
            try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw .folder("\(shown) could not be made: \(error.localizedDescription)")
        }
        let parent = folder.deletingLastPathComponent()
        let out = await ProcessRunner.run(SolutionsRepository.request(parent, s.environment, (gh.map(credentialOptions) ?? [])
            + ["clone", "--quiet", remote(repo), folder.path], timeout: .seconds(180)))
        guard out.succeeded else { throw SolutionsRepository.classify(out) }
        return s
    }

    /// Whether origin is on GitHub, as git resolves it (url.insteadOf included).
    public func pushesToGitHub() async -> Bool {
        if case .clone(_?) = await origin() { true } else { false }
    }

    enum Origin: Equatable {
        /// A git repository with its own top level here, and its origin if that is on GitHub.
        case clone(GitHubRepo?)
        case notRepository
    }

    /// Whether the folder is a git repository of its own (not a folder inside another one),
    /// and which repository on GitHub its origin is.
    func origin() async -> Origin {
        guard FileManager.default.fileExists(atPath: folder.path) else { return .notRepository }
        let top = await git(["rev-parse", "--show-toplevel"])
        guard top.succeeded, GoRunner.realPath(top.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) == GoRunner.realPath(folder.path) else {
            return .notRepository
        }
        let url = await git(["remote", "get-url", "origin"])
        return .clone(url.succeeded ? GitHubRepo(parsing: url.stdout) : nil)
    }

    // MARK: Committing

    /// Writes the solution's files to its lesson's folder and commits them with the README,
    /// dated when you solved it. Files that are as the last commit has them make no commit.
    /// `index` is every code lesson of the library, for the README's titles; `author` is
    /// used when git has no user.name or user.email.
    public func commit(_ solution: Solution, index: [SolutionPlace], author: SolutionsAuthor?) async throws(SolutionsError) -> CommitOutcome {
        try await serialized { await $0.commitNow(solution, index: index, author: author) }
    }

    private func commitNow(_ solution: Solution, index: [SolutionPlace], author: SolutionsAuthor?) async -> Result<CommitOutcome, SolutionsError> {
        guard case .clone = await origin() else { return .failure(.notARepository(folder.path)) }
        let title = solution.place.lessonTitle
        guard let path = solution.place.path else { return .failure(.failed("“\(title)” has a name that makes no folder.")) }
        guard !solution.files.isEmpty, solution.files.allSatisfy(\.isSafe) else {
            return .failure(.failed("“\(title)” has no files to commit, or a file name that leaves its folder."))
        }
        let dir = folder.appendingPathComponent(path, isDirectory: true)
        do {
            for file in solution.files {
                let url = dir.appendingPathComponent(file.name)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? String(contentsOf: url, encoding: .utf8)) != file.content {
                    try Data(file.content.utf8).write(to: url, options: .atomic)
                }
            }
        } catch {
            return .failure(.failed("\(path) could not be written: \(error.localizedDescription)"))
        }
        let added = await git(["add", "--", path])
        guard added.succeeded else { return .failure(.failed(GitSync.message(added))) }
        let status = await git(["status", "--porcelain", "--", path])
        guard status.succeeded else { return .failure(.failed(GitSync.message(status))) }
        if status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .success(.unchanged) }

        let readme = folder.appendingPathComponent("README.md")
        let text = await readmeText(adding: path, on: solution.date, index: index)
        if (try? String(contentsOf: readme, encoding: .utf8)) != text {
            do { try Data(text.utf8).write(to: readme, options: .atomic) } catch {
                return .failure(.failed("README.md could not be written: \(error.localizedDescription)"))
            }
        }
        let addedReadme = await git(["add", "--", "README.md"])
        guard addedReadme.succeeded else { return .failure(.failed(GitSync.message(addedReadme))) }

        var env = environment
        let date = SolutionsRepository.gitDate(solution.date)
        env["GIT_AUTHOR_DATE"] = date
        env["GIT_COMMITTER_DATE"] = date
        let name = await config("user.name"), email = await config("user.email")
        if name == nil || email == nil {
            guard let author else { return .failure(.noAuthor) }
            if name == nil {
                env["GIT_AUTHOR_NAME"] = author.name
                env["GIT_COMMITTER_NAME"] = author.name
            }
            if email == nil {
                env["GIT_AUTHOR_EMAIL"] = author.email
                env["GIT_COMMITTER_EMAIL"] = author.email
            }
        }
        // --only: what you staged yourself in this repository stays out of the commit.
        let out = await ProcessRunner.run(SolutionsRepository.request(folder, env, ["commit", "--quiet", "--only", "-m", solution.message, "--", path, "README.md"]))
        guard out.succeeded else { return .failure(.failed(GitSync.message(out))) }
        return .success(.committed)
    }

    /// Git's own date format, "@<seconds> <+hhmm>", in this Mac's time zone at that moment.
    static func gitDate(_ date: Date, timeZone: TimeZone = .current) -> String {
        let offset = timeZone.secondsFromGMT(for: date) / 60
        let sign = offset < 0 ? "-" : "+"
        return String(format: "@%lld %@%02d%02d", Int64(date.timeIntervalSince1970.rounded(.down)), sign, abs(offset) / 60, abs(offset) % 60)
    }

    /// A git setting as git resolves it in this repository, or nil when it is not set.
    private func config(_ key: String) async -> String? {
        let out = await git(["config", "--get", key])
        let value = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.succeeded && !value.isEmpty ? value : nil
    }

    /// The README with the lesson at `path` in it: each lesson folder in the repository, its
    /// title from the library (else its folder's name), and the day of its first commit.
    private func readmeText(adding path: String, on date: Date, index: [SolutionPlace]) async -> String {
        var firstDates = await firstCommitDates()
        if firstDates[path] == nil { firstDates[path] = date }
        var places: [String: SolutionPlace] = [:], courseOrder: [String: Int] = [:]
        for place in index {
            if let p = place.path, places[p] == nil { places[p] = place }
            if courseOrder[place.courseTitle] == nil { courseOrder[place.courseTitle] = courseOrder.count }
        }
        let rows = lessonFolders().map { folder -> SolutionsReadme.Row in
            if let place = places[folder] {
                return SolutionsReadme.Row(path: folder, lessonTitle: place.lessonTitle, chapterTitle: place.chapterTitle, courseTitle: place.courseTitle,
                                           courseOrder: courseOrder[place.courseTitle] ?? Int.max, date: firstDates[folder])
            }
            let parts = folder.split(separator: "/").map(String.init)
            return SolutionsReadme.Row(path: folder, lessonTitle: parts.last ?? folder, chapterTitle: nil, courseTitle: parts.first ?? folder,
                                       courseOrder: Int.max, date: firstDates[folder])
        }
        return SolutionsReadme.render(title: repo.name, rows: rows)
    }

    /// When each lesson folder was first committed, from the history.
    private func firstCommitDates() async -> [String: Date] {
        let out = await git(["log", "--reverse", "--no-renames", "--format=%x1e%aI", "--name-only"])
        guard out.succeeded else { return [:] }
        var dates: [String: Date] = [:]
        for record in out.stdout.split(separator: "\u{1e}") {
            let lines = record.split(separator: "\n").map(String.init)
            guard let first = lines.first, let date = try? Date(first.trimmingCharacters(in: .whitespaces), strategy: .iso8601) else { continue }
            for file in lines.dropFirst() {
                let parts = file.split(separator: "/")
                guard parts.count > 3 else { continue }
                let folder = parts.prefix(3).joined(separator: "/")
                if dates[folder] == nil { dates[folder] = date }
            }
        }
        return dates
    }

    /// The lesson folders in the repository: <course>/<chapter>/<lesson> holding a file.
    func lessonFolders() -> [String] {
        let fm = FileManager.default
        func folders(_ path: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: (folder.path as NSString).appendingPathComponent(path))) ?? []).filter { name in
                var isDir: ObjCBool = false
                let full = (folder.path as NSString).appendingPathComponent(path.isEmpty ? name : path + "/" + name)
                return !name.hasPrefix(".") && fm.fileExists(atPath: full, isDirectory: &isDir) && isDir.boolValue
            }.map { path.isEmpty ? $0 : path + "/" + $0 }
        }
        var found: [String] = []
        for course in folders("") {
            for chapter in folders(course) {
                for lesson in folders(chapter) {
                    let files = fm.enumerator(atPath: (folder.path as NSString).appendingPathComponent(lesson))
                    if let files, files.contains(where: { _ in files.fileAttributes?[.type] as? FileAttributeType == .typeRegular }) {
                        found.append(lesson)
                    }
                }
            }
        }
        return found.sorted()
    }

    /// Which of these solutions have no folder in the repository yet.
    public func missing(_ solutions: [Solution]) -> [Solution] {
        let present = Set(lessonFolders())
        return solutions.filter { $0.place.path.map { !present.contains($0) } ?? false }
    }

    // MARK: Pushing

    /// How many commits origin does not have yet: all of them before the first push.
    public func unpushed() async -> Int? {
        try? await serialized { await $0.unpushedNow() }
    }

    private func unpushedNow() async -> Result<Int, SolutionsError> {
        guard await git(["rev-parse", "--verify", "--quiet", "HEAD"]).succeeded else { return .success(0) }
        let branch = await git(["symbolic-ref", "--quiet", "--short", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let tracking = "refs/remotes/origin/\(branch)"
        var pushedBefore = false
        if !branch.isEmpty { pushedBefore = await git(["rev-parse", "--verify", "--quiet", tracking]).succeeded }
        let out = await git(["rev-list", "--count", pushedBefore ? "\(tracking)..HEAD" : "HEAD"])
        guard out.succeeded, let count = Int(out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failure(.failed(GitSync.message(out)))
        }
        return .success(count)
    }

    /// `git -c credential.helper= -c 'credential.helper=!<gh> auth git-credential' push origin
    /// HEAD`. A push that fails leaves every commit here for the next one.
    public func push(gh: String?) async throws(SolutionsError) -> PushOutcome {
        try await serialized { await $0.pushNow(gh: gh) }
    }

    private func pushNow(gh: String?) async -> Result<PushOutcome, SolutionsError> {
        let ahead: Int
        switch await unpushedNow() {
        case .success(let n): ahead = n
        case .failure(let e): return .failure(e)
        }
        guard ahead > 0 else { return .success(.nothing) }
        guard let gh else { return .failure(.noCLI) }
        let out = await git(SolutionsRepository.credentialOptions(gh: gh) + ["push", "--quiet", "origin", "HEAD"], timeout: .seconds(120))
        return out.succeeded ? .success(.pushed(ahead)) : .failure(SolutionsRepository.classify(out))
    }

    static func classify(_ out: ProcessOutput) -> SolutionsError {
        let message = GitSync.message(out)
        let text = (out.stdout + out.stderr).lowercased()
        if text.contains("rejected") || text.contains("non-fast-forward") || text.contains("fetch first") { return .behind(message) }
        if out.timedOut || text.contains("could not resolve host") || text.contains("unable to access") && !text.contains("403")
            || text.contains("connection") || text.contains("timed out") {
            return .offline(message)
        }
        if text.contains("authentication") || text.contains("could not read username") || text.contains("permission")
            || text.contains("403") || text.contains("denied") {
            return .refused(message)
        }
        return .failed(message)
    }

    // MARK: Running git

    /// Runs `step` after every step asked for before it has finished.
    private func serialized<T: Sendable>(_ step: @escaping @Sendable (SolutionsRepository) async -> Result<T, SolutionsError>) async throws(SolutionsError) -> T {
        let previous = queue
        let task = Task { [self] in
            await previous?.value
            return await step(self)
        }
        queue = Task { _ = await task.value }
        return try await task.value.get()
    }

    private func git(_ args: [String], timeout: Duration = .seconds(60)) async -> ProcessOutput {
        await ProcessRunner.run(SolutionsRepository.request(folder, environment, args, timeout: timeout))
    }

    /// Git in `folder`, never killed outright: a timeout sends SIGTERM and waits, so git can
    /// remove its lock file, and quitting the app leaves a push running to its end.
    static func request(_ folder: URL, _ environment: [String: String], _ args: [String], timeout: Duration = .seconds(60)) -> ProcessRequest {
        ProcessRequest(executable: SystemTools.git, arguments: ["-C", folder.path] + args, directory: folder.path,
                       environment: environment, timeout: timeout, outputLimit: 4 << 20, kind: .git, gracePeriod: gracePeriod)
    }
}
