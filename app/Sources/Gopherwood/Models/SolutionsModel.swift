import Foundation
import GopherwoodKit
import Observation

/// Your solutions on GitHub: a repository of your own, with a folder on this Mac, where each
/// passing Submit of a code lesson is committed, dated at the Submit, so your contribution
/// graph shows your study. Committing works offline; pushing happens after each passing
/// Submit only when you turn it on, and whenever you choose File › Push Solutions to GitHub.
/// Its settings belong to this Mac (UserDefaults), never to the library, and its repository
/// is never the library's.
@Observable @MainActor
final class SolutionsModel {
    enum Sheet: String, Identifiable {
        case create, existing
        var id: String { rawValue }
    }

    private(set) var repository: SolutionsRepository?
    /// Commits GitHub doesn't have yet; nil until counted.
    private(set) var unpushed: Int?
    /// Done lessons with saved code that the repository doesn't hold yet, oldest first.
    private(set) var earlier: [Solution] = []
    private(set) var isPushing = false
    private(set) var isAddingEarlier = false
    /// The last commit or push, in a line.
    private(set) var status: String?
    /// What went wrong last; the next success clears it.
    private(set) var problem: String?
    /// How the last push went, for the quiet git line under the sidebar, so a push from the
    /// File menu or after a Submit is heard of without Settings open.
    private(set) var notice: SolutionsNotice?
    /// Why commits here don't count on your contribution graph: a branch other than the default.
    private(set) var branchWarning: String?
    /// Pushes, one at a time; one asked for while another runs pushes again after it.
    @ObservationIgnored private let pushes = Coalescing()
    /// A sheet Settings should show (a scripted launch asks for one).
    var sheetRequest: Sheet?
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private let preferences: LocalPreferences

    init(preferences: LocalPreferences) {
        self.preferences = preferences
        if let saved = preferences.solutions { repository = SolutionsRepository(folder: saved.folder, repo: saved.repo) }
    }

    var pushAfterSubmit: Bool {
        get {
            access(keyPath: \.pushAfterSubmit)
            return preferences.solutionsPushAfterSubmit
        }
        set { withMutation(keyPath: \.pushAfterSubmit) { preferences.setSolutionsPushAfterSubmit(newValue) } }
    }

    /// ~/Documents/<name>, where a new repository's folder goes unless you choose another.
    static func defaultFolder(_ name: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Documents/\(name.isEmpty ? "go-solutions" : name)", isDirectory: true)
    }

    /// Folders a solutions repository never goes in: ~/Documents/jobloom, where the projects
    /// live, and the library's own repository.
    var forbiddenFolders: [URL] {
        [URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Documents/jobloom", isDirectory: true)]
            + (app?.git.map { [$0.repository] } ?? [])
    }

    private func environment() async -> [String: String] {
        await app?.awaitToolchain()?.environment ?? ProcessInfo.processInfo.environment
    }

    // MARK: Setting up

    /// Create Repository…: a new repository on your GitHub account (POST /user/repos, the one
    /// request that writes to GitHub), then a git repository in `folder` with it as origin.
    /// Returns why it could not, or nil.
    func create(name: String, isPrivate: Bool, folder: URL) async -> String? {
        guard GitHubRepo.isName(name) else { return "A repository name is letters, digits, '.', '_' and '-'." }
        if let problem = SolutionsRepository.problem(with: folder, outside: forbiddenFolders, mustBeEmpty: true) { return problem }
        guard let app else { return nil }
        guard !app.isScriptedRun else { return "A scripted run never creates a repository on GitHub." }
        let environment = await environment()
        guard let token = await GitHubCLI.signIn(environment: environment).token else {
            return "Sign in with gh auth login in Terminal first: GitHub makes the repository on your account."
        }
        let created: CreatedRepository
        do {
            created = try await app.github.createRepository(name: name, isPrivate: isPrivate, token: token)
        } catch {
            return error.localizedDescription
        }
        if let user = try? await app.github.user(token: token) { preferences.setSolutionsAuthor(SolutionsAuthor(user)) }
        do {
            adopt(try await SolutionsRepository.create(at: folder, repo: created.repo))
        } catch {
            return "\(created.repo) is on GitHub, but its folder could not be set up: \(error.localizedDescription) Use Existing Repository… finishes it."
        }
        status = "Created \(created.repo)"
        return nil
    }

    /// Use Existing Repository…: `text` names it (owner/name or its address); `folder` is a
    /// clone of it already, or new or empty and gets one.
    func useExisting(_ text: String, folder: URL) async -> String? {
        guard let repo = GitHubRepo(parsing: text) else { return "Enter owner/name, or the repository's address, such as https://github.com/owner/name." }
        if let problem = SolutionsRepository.problem(with: folder, outside: forbiddenFolders, mustBeEmpty: false) { return problem }
        let environment = await environment()
        do {
            adopt(try await SolutionsRepository.useExisting(repo, in: folder, gh: GitHubCLI.locate(environment: environment)))
        } catch {
            return error.localizedDescription
        }
        if let app, let token = await GitHubCLI.signIn(environment: environment).token, let user = try? await app.github.user(token: token) {
            preferences.setSolutionsAuthor(SolutionsAuthor(user))
        }
        status = "Using \(repo): the table of solved lessons goes in \(SolutionsReadme.file(in: folder))"
        return nil
    }

    private func adopt(_ repository: SolutionsRepository) {
        self.repository = repository
        preferences.setSolutions(repository.repo, folder: repository.folder)
        problem = nil
        Task { await refresh() }
    }

    /// Stops committing to the repository. Its folder and the repository on GitHub stay.
    func forget() {
        preferences.setSolutions(nil, folder: nil)
        repository = nil
        unpushed = nil
        earlier = []
        status = nil
        problem = nil
        notice = nil
        branchWarning = nil
    }

    // MARK: Committing and pushing

    /// A Submit of a code lesson passed: its files go to the repository, dated at the Submit.
    /// Then a push, when Push after each passing Submit is on.
    func solved(_ lessonID: String, files: [SolutionFile], at date: Date) {
        guard repository != nil, let db = app?.database else { return }
        Task {
            do {
                guard let place = try await db.solutionPlaces().first(where: { $0.lessonID == lessonID }) else { return }
                let committed = await commit([Solution(place: place, files: files, date: date)], db)
                await refresh()
                if committed > 0 && pushAfterSubmit { await pushNow() }
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    /// Add N Earlier Solutions: the done lessons with saved code the repository lacks, oldest
    /// first, each dated when you finished it.
    func addEarlier() {
        guard repository != nil, !isAddingEarlier, let db = app?.database else { return }
        isAddingEarlier = true
        Task {
            defer { isAddingEarlier = false }
            let solutions = earlier.isEmpty ? await missingEarlier(db) : earlier
            let added = await commit(solutions, db)
            if added > 0 { status = "Added \(added) earlier solution\(added == 1 ? "" : "s")" }
            await refresh()
        }
    }

    /// Commits the solutions in order; returns how many made a commit. A missing author is
    /// fetched from GitHub once (GET /user), then remembered for working offline.
    private func commit(_ solutions: [Solution], _ db: AppDatabase) async -> Int {
        guard let repository else { return 0 }
        let index: [SolutionPlace]
        do { index = try await db.solutionPlaces() } catch {
            fail(error.localizedDescription)
            return 0
        }
        var committed = 0
        for solution in solutions {
            do {
                if try await commitOne(solution, repository, index) == .committed {
                    committed += 1
                    status = "Committed “\(solution.place.lessonTitle)”"
                    problem = nil
                }
            } catch {
                fail("“\(solution.place.lessonTitle)” was not committed: \(error.localizedDescription)")
                break
            }
        }
        return committed
    }

    private func commitOne(_ solution: Solution, _ repository: SolutionsRepository, _ index: [SolutionPlace]) async throws(SolutionsError) -> SolutionsRepository.CommitOutcome {
        do {
            return try await repository.commit(solution, index: index, author: preferences.solutionsAuthor)
        } catch .noAuthor {
            guard let author = await fetchAuthor() else { throw .noAuthor }
            return try await repository.commit(solution, index: index, author: author)
        }
    }

    private func fetchAuthor() async -> SolutionsAuthor? {
        guard let app, let token = await GitHubCLI.signIn(environment: await environment()).token,
              let user = try? await app.github.user(token: token) else { return nil }
        let author = SolutionsAuthor(user)
        preferences.setSolutionsAuthor(author)
        return author
    }

    /// File › Push Solutions to GitHub, and Push Now in Settings.
    func push() {
        Task { await pushNow() }
    }

    /// A push asked for while one runs is not dropped: it pushes again once that one ends.
    private func pushNow() async {
        await pushes.run { [weak self] in await self?.pushOnce() }
    }

    /// Pushes, then says how it went in the quiet git line under the sidebar (and here in
    /// Settings): pushed, nothing to push, or why not. A failure is quiet like a library sync's.
    private func pushOnce() async {
        guard let repository else { return }
        isPushing = true
        defer { isPushing = false }
        let result: Result<SolutionsRepository.PushOutcome, SolutionsError>
        if app?.isScriptedRun == true, await repository.pushesToGitHub() {
            result = .failure(.failed("A scripted run never pushes to GitHub."))
        } else {
            let gh = GitHubCLI.locate(environment: await environment())
            do { result = .success(try await repository.push(gh: gh)) } catch { result = .failure(error) }
        }
        let said = SolutionsNotice(pushing: repository.repo, result)
        notice = said
        if said.failed {
            problem = said.text
            Log.git.notice("Solutions push: \(said.text, privacy: .public)")
        } else {
            status = said.text
            problem = nil
        }
        await refresh()
    }

    /// Counts what is not pushed yet and the earlier solutions to add.
    func refresh() async {
        guard let repository else { return }
        unpushed = await repository.unpushed()
        branchWarning = await repository.branchWarning()
        if let db = app?.database { earlier = await missingEarlier(db) }
    }

    private func missingEarlier(_ db: AppDatabase) async -> [Solution] {
        guard let repository, let all = try? await db.earlierSolutions() else { return [] }
        return await repository.missing(all)
    }

    private func fail(_ message: String) {
        problem = message
        app?.report(AppError.solutions(message))
    }
}
