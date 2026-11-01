import AppKit
import Foundation
import GopherwoodKit
import Observation

/// A quiz: pick an answer per question (click, or keys 1 to 5), then Submit checks them all.
@Observable @MainActor
final class QuizSession {
    let lesson: LessonDetail
    /// The picks and verdicts (GopherwoodKit's QuizState, which the tests cover).
    private(set) var state: QuizState
    var focusedQuestion = 0
    private(set) var successCount = 0
    @ObservationIgnored private weak var app: AppModel?

    init(lesson: LessonDetail, quiz: Quiz, app: AppModel) {
        self.lesson = lesson
        self.state = QuizState(quiz: quiz)
        self.app = app
    }

    var quiz: Quiz { state.quiz }
    var picks: [Int: Int] { state.picks }
    var verdicts: [Int: Bool] { state.verdicts }
    var allCorrect: Bool { state.allCorrect }
    var canSubmit: Bool { state.canSubmit }

    func pick(_ answer: Int, for question: Int) {
        if state.pick(answer, for: question) { focusedQuestion = question }
    }

    /// Key 1 to 5 picks an answer of the focused question.
    func pick(number: Int) {
        pick(number - 1, for: focusedQuestion)
    }

    /// Grades the picks, records them, and finishes the lesson when every answer is right.
    func submit() {
        guard canSubmit, let app else { return }
        let answers = state.submit()
        if let db = app.database {
            let id = lesson.id
            Task {
                do { try await db.addAnswers(id, answers) } catch { app.report(error) }
            }
        }
        if allCorrect {
            successCount += 1
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            app.lesson?.markPassed()
        }
    }
}

/// Where a step of a command-line or GitHub lesson's checks stands.
enum StepState: Equatable { case pending, running, passed, failed }

/// A command-line lesson: where it runs, the server it calls, and each step's state.
@Observable @MainActor
final class ChecksSession {
    let lesson: LessonDetail
    let cli: CLILesson
    /// The course's project folder (project.dir); empty until you choose one.
    var projectDir = ""
    /// What the address field holds: your own server's address for a lesson that asks for
    /// it, else the address of the server the lesson suggests, or yours for it.
    var addressField = ""
    /// What ${baseURL} stands for, as last loaded or saved.
    private(set) var baseURL: BaseURL = .none
    /// The course's own server address (project.base_url), kept when the folder changes.
    @ObservationIgnored private var projectBaseURL: String?
    /// The course's repository on GitHub (project.github_repo), kept when the folder or the
    /// address changes.
    @ObservationIgnored private var projectGitHubRepo: String?
    private(set) var states: [StepState]
    private(set) var results: [Int: StepResult] = [:]
    private(set) var isRunning = false
    private(set) var runError: String?
    private(set) var lastStatus: CheckRun.Status?
    private(set) var lastDuration: Duration?
    private(set) var successCount = 0
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(lesson: LessonDetail, cli: CLILesson, app: AppModel) {
        self.lesson = lesson
        self.cli = cli
        self.app = app
        states = Array(repeating: .pending, count: cli.steps.count)
    }

    var needsFolder: Bool { cli.hasCommands }
    /// The address the lesson suggests, when you have set another one for it.
    var replacedSuggestion: String? {
        if case .suggested(let suggested, let yours) = baseURL, yours != nil { suggested } else { nil }
    }

    func load() async {
        guard let app, let db = app.database else { return }
        do {
            let project = try await db.project(for: lesson.courseID)
            projectDir = project?.dir ?? ""
            projectBaseURL = project?.baseURL
            projectGitHubRepo = project?.githubRepo
            baseURL = try await db.baseURL(for: cli, course: lesson.courseID)
        } catch {
            app.report(error)
        }
        addressField = baseURL.url ?? ""
    }

    /// Stores what the address field holds where it belongs: the course's project for a
    /// lesson that asks for your server, else server_address for the suggested address
    /// (the suggestion itself, or nothing, removes your row). Called on Return, before a
    /// run, and when the lesson closes.
    func commitAddress() {
        guard let db = app?.database else { return }
        let typed = addressField.trimmingCharacters(in: .whitespaces)
        switch baseURL {
        case .yourServer(let current):
            let url: String? = typed.isEmpty ? nil : typed
            guard url != current else { return }
            projectBaseURL = url
            baseURL = .yourServer(url)
            saveProject()
        case .suggested(let suggested, let yours):
            let url: String? = typed.isEmpty || typed == suggested ? nil : typed
            if url == nil { addressField = suggested }
            guard url != yours else { return }
            baseURL = .suggested(suggested, yours: url)
            Task { [weak app] in
                do { try await db.setServerAddress(url, for: suggested) } catch { app?.report(error) }
            }
        case .none:
            break
        }
    }

    /// "Use Suggested": forgets your address for the suggested one, for every lesson that
    /// suggests it.
    func useSuggestedAddress() {
        guard case .suggested(let suggested, _) = baseURL else { return }
        addressField = suggested
        commitAddress()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder of your \(lesson.courseTitle) project"
        if !projectDir.isEmpty { panel.directoryURL = URL(fileURLWithPath: projectDir) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        projectDir = url.path
        saveProject()
    }

    /// The course's project: the folder and your own server's address.
    private func saveProject() {
        guard let db = app?.database else { return }
        let course = lesson.courseID
        let project = Project(dir: projectDir.isEmpty ? nil : projectDir, baseURL: projectBaseURL, githubRepo: projectGitHubRepo)
        Task { [weak app] in
            do { try await db.saveProject(course, project) } catch { app?.report(error) }
        }
    }

    func runAll() {
        guard !isRunning, let app else { return }
        guard let checker = app.makeChecker() else {
            runError = "The command-line checker is not available in this build."
            return
        }
        commitAddress()
        if needsFolder && projectDir.isEmpty {
            runError = "Choose the folder your \(lesson.courseTitle) project is in first."
            return
        }
        if baseURL.isMissing {
            runError = "This lesson checks a server you run: enter its address above first."
            return
        }
        isRunning = true
        runError = nil
        lastStatus = nil
        results = [:]
        states = Array(repeating: .pending, count: cli.steps.count)
        let cli = cli, dir = projectDir, address = baseURL.url, id = lesson.id
        let report: @Sendable (Int, StepResult?) async -> Void = { [weak self] index, result in
            await self?.apply(index, result)
        }
        task = Task { [weak self] in
            let run = await checker.run(cli, directory: dir, baseURL: address, onStep: report)
            guard let self else { return }
            self.isRunning = false
            self.lastStatus = run.status
            self.lastDuration = run.duration
            if let error = run.error { self.runError = error }
            if run.status == .cancelled { return }
            if let db = app.database {
                let ms = Int(run.duration.components.seconds * 1000 + run.duration.components.attoseconds / 1_000_000_000_000_000)
                do { try await db.addAttempt(lesson: id, kind: .check, passed: run.status == .passed, output: run.report, durationMs: ms) }
                catch { app.report(error) }
            }
            if run.status == .passed {
                self.successCount += 1
                app.lesson?.markPassed()
            }
        }
    }

    private func apply(_ index: Int, _ result: StepResult?) {
        guard states.indices.contains(index) else { return }
        if let result {
            results[index] = result
            states[index] = result.passed ? .passed : .failed
        } else {
            states[index] = .running
        }
    }

    func stop() {
        task?.cancel()
    }
}

/// A GitHub lesson: the course's repository on GitHub, and each step's state as the checks
/// read it.
@Observable @MainActor
final class GitHubSession {
    let lesson: LessonDetail
    let checks: GitHubChecks
    /// The course's repository (project.github_repo), as last loaded or saved.
    private(set) var repo: GitHubRepo?
    /// What the repository field holds while you enter or change the repository.
    var repoField = ""
    /// Change… was clicked: the field shows although a repository is set.
    private(set) var isChangingRepo = false
    /// Why the field's text is not a repository, after Return, Save or Check.
    private(set) var repoProblem: String?
    /// Bumped to put the caret in the repository field.
    private(set) var focusRequests = 0
    /// The course's project as loaded; its folder and server address stay when the repository
    /// changes.
    @ObservationIgnored private var project = Project(dir: nil, baseURL: nil)
    private(set) var states: [StepState]
    private(set) var results: [Int: GitHubStepResult] = [:]
    private(set) var isRunning = false
    private(set) var runError: String?
    private(set) var lastStatus: CheckRun.Status?
    private(set) var lastDuration: Duration?
    private(set) var successCount = 0
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(lesson: LessonDetail, checks: GitHubChecks, app: AppModel) {
        self.lesson = lesson
        self.checks = checks
        self.app = app
        states = Array(repeating: .pending, count: checks.steps.count)
    }

    /// The field shows while there is no repository yet, or while you change it.
    var showsField: Bool { repo == nil || isChangingRepo }

    func load() async {
        guard let app, let db = app.database else { return }
        do {
            project = try await db.project(for: lesson.courseID) ?? Project(dir: nil, baseURL: nil)
            repo = project.githubRepo.flatMap(GitHubRepo.init(parsing:))
        } catch {
            app.report(error)
        }
    }

    /// Change…: the field, holding the repository, with the caret in it.
    func changeRepo() {
        repoField = repo?.fullName ?? ""
        repoProblem = nil
        isChangingRepo = true
        focusRequests += 1
    }

    /// Leaves the repository as it was.
    func cancelChange() {
        guard repo != nil else { return }
        isChangingRepo = false
        repoProblem = nil
        repoField = ""
    }

    /// Saves what the field holds as the course's repository, as owner/name. Text that names
    /// no repository is refused with `repoProblem`, unless `quietly` (the lesson is closing);
    /// an empty field while changing keeps the repository. Returns whether a repository is set.
    @discardableResult
    func commitRepo(quietly: Bool = false) -> Bool {
        guard showsField else { return repo != nil }
        let typed = repoField.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty {
            cancelChange()
            return repo != nil
        }
        guard let parsed = GitHubRepo(parsing: typed) else {
            if !quietly {
                repoProblem = "Enter owner/name, or the repository's address, such as https://github.com/owner/name."
                focusRequests += 1
            }
            return false
        }
        repoProblem = nil
        isChangingRepo = false
        repoField = ""
        guard parsed != repo else { return true }
        repo = parsed
        // The results were about the other repository.
        results = [:]
        states = Array(repeating: .pending, count: checks.steps.count)
        lastStatus = nil
        runError = nil
        save()
        return true
    }

    /// The course's project, with the repository; its other lessons see it too.
    private func save() {
        guard let db = app?.database else { return }
        project.githubRepo = repo?.fullName
        let course = lesson.courseID, project = project
        Task { [weak app] in
            do { try await db.saveProject(course, project) } catch { app?.report(error) }
        }
    }

    /// Check ⌘↩: every step against the repository on GitHub, then an attempt of kind check;
    /// all passed finishes the lesson.
    func runAll() {
        guard !isRunning, let app else { return }
        // A repository typed but not saved yet counts; Change… with nothing typed keeps the one set.
        if showsField {
            if repoField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cancelChange()
            } else if !commitRepo() {
                return
            }
        }
        guard let repo else {
            runError = "Enter your repository for \(lesson.courseTitle) first: owner/name, or its address on GitHub."
            focusRequests += 1
            return
        }
        isRunning = true
        runError = nil
        lastStatus = nil
        results = [:]
        states = Array(repeating: .pending, count: checks.steps.count)
        let checks = checks, id = lesson.id
        let report: @Sendable (Int, GitHubStepResult?) async -> Void = { [weak self] index, result in
            await self?.apply(index, result)
        }
        task = Task { [weak self] in
            // gh is found on the login shell's PATH, as Go is.
            let environment = await app.awaitToolchain()?.environment ?? ProcessInfo.processInfo.environment
            let run = await app.makeGitHubChecker(environment: environment).run(checks, repo: repo, onStep: report)
            guard let self else { return }
            self.isRunning = false
            self.lastStatus = run.status
            self.lastDuration = run.duration
            // A step the run did not finish is pending again.
            for i in self.states.indices where self.states[i] == .running { self.states[i] = .pending }
            if let error = run.error { self.runError = error }
            if run.status == .cancelled { return }
            if let db = app.database {
                let ms = Int(run.duration.components.seconds * 1000 + run.duration.components.attoseconds / 1_000_000_000_000_000)
                do { try await db.addAttempt(lesson: id, kind: .check, passed: run.status == .passed, output: run.report, durationMs: ms) }
                catch { app.report(error) }
            }
            if run.status == .passed {
                self.successCount += 1
                app.lesson?.markPassed()
            }
        }
    }

    private func apply(_ index: Int, _ result: GitHubStepResult?) {
        guard states.indices.contains(index) else { return }
        if let result {
            results[index] = result
            states[index] = result.passed ? .passed : .failed
        } else {
            states[index] = .running
        }
    }

    func stop() {
        task?.cancel()
    }
}
