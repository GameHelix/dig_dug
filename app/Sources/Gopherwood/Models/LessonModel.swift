import CodeEditor
import Foundation
import GopherwoodKit
import Observation
import os

/// The lesson on screen: its content and parsed readme, plus the state its type needs.
@Observable @MainActor
final class LessonModel {
    let detail: LessonDetail
    /// The readme, quiz questions and interview prompt as blocks.
    let parsed: ParsedLesson
    private(set) var code: CodeSession?
    private(set) var quiz: QuizSession?
    private(set) var checks: ChecksSession?
    var note = "" { didSet { if noteLoaded && note != oldValue { scheduleNoteSave() } } }
    private var noteLoaded = false
    /// The note as the database holds it, so an unchanged note is never written.
    @ObservationIgnored private var savedNote = ""
    private var noteTask: Task<Void, Never>?
    /// Set when the last Run or Submit passed, so the toolbar offers the next lesson.
    var justPassed = false
    /// Bumped to bring the part below the readme (quiz, checks) into view.
    private(set) var footerRequests = 0
    @ObservationIgnored weak var app: AppModel?

    /// `saved` is your code from code_file, so a code lesson opens with it rather than the
    /// starter code; `database` is the library it came from.
    init(detail: LessonDetail, parsed: ParsedLesson, saved: [String: CodeFileRecord], database: AppDatabase, app: AppModel) {
        self.detail = detail
        self.parsed = parsed
        self.app = app
        switch detail.content {
        case .code(let c): code = CodeSession(lesson: detail, exercise: c, tests: false, saved: saved, database: database, app: app)
        case .codeTests(let c): code = CodeSession(lesson: detail, exercise: c, tests: true, saved: saved, database: database, app: app)
        case .choice(let q): quiz = QuizSession(lesson: detail, quiz: q, app: app)
        case .cli(let c): checks = ChecksSession(lesson: detail, cli: c, app: app)
        case .githubChecks, .interviewChat: break
        }
    }

    var isDone: Bool { app?.isDone(detail.id) ?? false }

    /// Reads what this lesson needs from the database and the work folder.
    func load() async {
        if let app, let db = app.database {
            do {
                note = try await db.note(for: detail.id) ?? ""
                savedNote = note
                noteLoaded = true
            } catch {
                // Without the saved note, typing must not replace it: saving stays off.
                app.report(error)
            }
        }
        await code?.load()
        await checks?.load()
    }

    /// Saves pending edits; called before another lesson or library opens and when the app
    /// quits. A code conflict is asked about first; `limit` bounds the wait when quitting.
    /// Saving runs to the end even when the caller was cancelled (a newer lesson or library
    /// replaced it): in a cancelled task the database refuses to write.
    func leave(within limit: Duration? = nil) async {
        await Task {
            noteTask?.cancel()
            await saveNote()
            await code?.settle(within: limit)
            code?.stop()
            checks?.commitAddress()
            checks?.stop()
        }.value
    }

    private func scheduleNoteSave() {
        noteTask?.cancel()
        noteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.saveNote()
        }
    }

    /// Writes the note if it changed since it was loaded or last saved.
    private func saveNote() async {
        guard noteLoaded, note != savedNote, let db = app?.database else { return }
        let body = note
        do {
            try await db.saveNote(detail.id, body: body)
            savedNote = body
        } catch {
            app?.report(error)
        }
    }

    /// Run ⌘R: runs code, or a command-line lesson's checks.
    func run() {
        if let code {
            code.run(submit: false)
        } else if let checks {
            footerRequests += 1
            checks.runAll()
        }
    }

    /// Submit ⌘↩: submits code, checks a quiz, or runs the checks.
    func submit() {
        if let code {
            code.run(submit: true)
        } else if let quiz {
            footerRequests += 1
            quiz.submit()
        } else if let checks {
            footerRequests += 1
            checks.runAll()
        }
    }

    /// Brings the part below the readme into view.
    func showFooter() {
        footerRequests += 1
    }

    /// Code in another language opens and reads as usual, but does not run.
    var canRun: Bool { code?.exercise.runsHere == true || checks != nil }
    var canSubmit: Bool { code?.exercise.runsHere == true || quiz?.canSubmit == true || checks != nil }
    var isBusy: Bool { code?.isRunning == true || checks?.isRunning == true }

    func markPassed() {
        justPassed = true
        app?.setDone(detail.id, true)
    }
}

/// A code lesson's files, saves, runs and editor commands. The files, their loading and
/// saving live in `buffers` (GopherwoodKit), where they are tested.
@Observable @MainActor
final class CodeSession {
    /// What the console shows the outcome of.
    enum ResultKind {
        case run, submit, format

        var title: String {
            switch self {
            case .run: "Run"
            case .submit: "Submit"
            case .format: "Format"
            }
        }
    }

    let buffers: CodeBuffers
    let tests: Bool
    /// The editor of the file shown, for the editor bar's buttons and the Editor menu.
    let editor = CodeEditorProxy()
    private(set) var isRunning = false
    private(set) var isFormatting = false
    private(set) var result: RunResult?
    private(set) var resultKind = ResultKind.run
    /// Counts passes, so the done mark can bounce.
    private(set) var passCount = 0
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// A Run (false) or Submit (true) waiting for a conflict to be settled.
    @ObservationIgnored private var pendingRun: Bool?

    init(lesson: LessonDetail, exercise: CodeExercise, tests: Bool, saved: [String: CodeFileRecord], database: AppDatabase, app: AppModel) {
        self.tests = tests
        self.app = app
        let id = lesson.id
        buffers = CodeBuffers(lesson: lesson, exercise: exercise, saved: saved, database: database, workspace: app.workspace,
                              unsettled: app.preferences.unsettledFiles(in: id),
                              goVersion: { [weak app] in await app?.awaitToolchain()?.languageVersion ?? "1.27" },
                              remember: { [weak app] name, unsettled in app?.preferences.setUnsettled(name, in: id, unsettled) })
    }

    var lesson: LessonDetail { buffers.lesson }
    var exercise: CodeExercise { buffers.exercise }
    var files: [FileBuffer] { buffers.files }
    var activeIndex: Int {
        get { buffers.activeIndex }
        set { buffers.activeIndex = newValue }
    }
    var activeFile: FileBuffer? { files.indices.contains(activeIndex) ? files[activeIndex] : nil }
    /// True once the editor holds your code as code_file and the lesson folder have it, and
    /// saving is ready: the editor takes typing from then on. Until then it shows a load
    /// under way, or `loadError` when the load failed.
    var isLoaded: Bool { buffers.isLoaded }
    var loadError: String? { buffers.loadError }
    var folder: URL? { buffers.folder }
    /// A file that changed both here and in another editor; the lesson asks which to keep.
    var conflict: String? { buffers.conflict }

    /// Your code from the database, reconciled with the work folder (an edit made there in
    /// another editor wins when it is newer). Then a save, which asks about a file left in
    /// conflict when the app last quit.
    func load() async {
        await buffers.load()
        if buffers.isLoaded { await flush() }
    }

    /// Saves your edits soon; the editor calls this a second after typing stops, and the app
    /// when it comes to the front (to pick up edits made in another editor).
    func save() {
        Task { await flush() }
    }

    /// Saves now (see `CodeBuffers.flush`). Runs, lesson switches and quitting call this
    /// first. Returns false while a conflict waits for your answer or the save failed.
    @discardableResult
    func flush() async -> Bool {
        do {
            return try await buffers.flush()
        } catch {
            app?.reportFiles(error)
            return false
        }
    }

    /// Settles a conflict with your version or the one on disk (read again now), then asks
    /// about the next one, or runs what was waiting.
    func resolveConflict(keepMine: Bool) {
        guard let resolving = buffers.resolveConflict(keepMine: keepMine) else { return }
        Task {
            do {
                guard try await resolving.value else { return }
            } catch {
                app?.reportFiles(error)
                return
            }
            if let submit = pendingRun {
                pendingRun = nil
                run(submit: submit)
            }
        }
    }

    /// Saves before the lesson closes, after a load under way (see `CodeBuffers.settle`).
    func settle(within limit: Duration?) async {
        do {
            let kept = try await buffers.settle(within: limit)
            if !kept.isEmpty {
                app?.report(AppError.files("Kept both versions of \(kept.joined(separator: ", ")): yours is saved in the library, the other editor's stays in the lesson folder. Gopherwood asks which to keep when you open the lesson."))
            }
        } catch {
            app?.reportFiles(error)
        }
    }

    func run(submit: Bool) {
        guard !isRunning, exercise.runsHere, let app else { return }
        isRunning = true
        result = nil
        resultKind = submit ? .submit : .run
        let lesson = lesson, exercise = exercise, tests = tests
        runTask = Task { [weak self] in
            guard let self else { return }
            if self.folder == nil { await self.load() }
            // Saving waits for a save under way and takes in other editors' edits, so the
            // build sees the code on screen.
            guard await self.flush() else {
                self.isRunning = false
                if self.conflict != nil { self.pendingRun = submit }
                return
            }
            guard let folder = self.folder else {
                self.isRunning = false
                self.result = RunResult(status: .error, output: self.loadError ?? "The lesson folder could not be prepared.")
                return
            }
            guard let toolchain = await app.awaitToolchain() else { return }
            let result = await GoRunner(toolchain: toolchain, scratch: app.workspace.runsFolder).run(exercise, tests: tests, folder: folder, submit: submit)
            self.result = result
            self.isRunning = false
            let passed = submit ? result.status == .passed : result.status.isSuccess
            var output = result.output
            if let expected = result.expected { output += "\n\n--- expected output ---\n" + expected }
            if result.status != .cancelled, let db = app.database {
                do {
                    try await db.addAttempt(lesson: lesson.id, kind: submit ? .submit : .run, passed: passed, output: output, durationMs: result.durationMs)
                } catch {
                    app.report(error)
                }
            }
            // Only a passing Submit finishes the lesson; a Run shows the output (or the tests'
            // results) and leaves the lesson as it was.
            if submit && result.status == .passed {
                self.passCount += 1
                app.lesson?.markPassed()
            }
        }
    }

    /// Stops a run under way; its process group is killed.
    func stop() {
        runTask?.cancel()
    }

    /// Puts the starter code back into every file of yours.
    func resetToStarter() {
        for buffer in files where !buffer.readOnly {
            if let starter = exercise.starterFiles.first(where: { $0.name == buffer.name }) {
                buffer.text = starter.content
            }
        }
        save()
    }

    // MARK: Editor commands

    /// Why a command can't act on the file shown now, said the way its button's help does,
    /// or nil when it can.
    func unavailability(of command: EditorCommand) -> String? {
        guard let file = activeFile else { return "This lesson has no code to edit" }
        if command == .format, !file.name.lowercased().hasSuffix(".go") { return "Format works on .go files" }
        if command == .toggleComment, LineSyntax(fileName: file.name).commentMarker == nil {
            return "\(file.name) has no line comments"
        }
        if file.readOnly { return "This file is read-only" }
        if !isLoaded { return loadError == nil ? "Your code is still loading" : "Your code could not load" }
        guard command == .format else { return nil }
        guard let toolchain = app?.toolchain else { return "Looking for Go…" }
        if toolchain.go == nil { return "Go wasn't found: choose it in Settings" }
        if toolchain.gofmt == nil { return "gofmt wasn't found with Go: choose another Go in Settings" }
        return isFormatting ? "Formatting…" : nil
    }

    func perform(_ command: EditorCommand) {
        guard unavailability(of: command) == nil else { return }
        switch command {
        case .format: format()
        case .toggleComment: editor.toggleComment()
        case .outdent: editor.outdent()
        case .indent: editor.indent()
        }
    }

    /// Lays out the file shown with gofmt, as one undo step. Code that does not parse stays as
    /// it is, and gofmt's messages show in the console.
    private func format() {
        guard let file = activeFile, let toolchain = app?.toolchain, let formatter = GoFormatter(toolchain: toolchain),
              let source = editor.text else { return }
        isFormatting = true
        let started = ContinuousClock.now
        Task { [weak self] in
            let formatted: Result<String, any Error>
            do {
                formatted = .success(try await formatter.format(source, fileName: file.name))
            } catch {
                formatted = .failure(error)
            }
            guard let self else { return }
            self.isFormatting = false
            // Another file is shown, or the code changed while gofmt ran: the result is stale.
            guard self.activeFile === file, self.editor.text == source else { return }
            switch formatted {
            case .success(let text):
                self.editor.replaceText(with: text, actionName: "Format")
                // The code parses now, so an error from an earlier Format no longer holds.
                if self.resultKind == .format && !self.isRunning { self.result = nil }
            case .failure(let error):
                guard !Reporting.isSilent(error), !self.isRunning else { return }
                let status: RunStatus = if case GoFormatError.syntax = error { .failed } else { .error }
                self.result = RunResult(status: status, output: error.localizedDescription, duration: ContinuousClock.now - started)
                self.resultKind = .format
            }
        }
    }
}
