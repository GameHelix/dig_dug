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

/// A command-line lesson: where it runs, the server it calls, and each step's state.
@Observable @MainActor
final class ChecksSession {
    enum StepState: Equatable { case pending, running, passed, failed }

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
        let course = lesson.courseID, project = Project(dir: projectDir.isEmpty ? nil : projectDir, baseURL: projectBaseURL)
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
