import AppKit
import GopherwoodKit
import Observation
import os
import SwiftUI

/// A failure the app shows: as an inline banner, or as the window's content when no library
/// can open.
enum AppError: LocalizedError, Identifiable, Equatable {
    case database(AppDatabaseError)
    case lesson(String)
    case files(String)

    var id: String { errorDescription ?? "error" }

    var errorDescription: String? {
        switch self {
        case .database(let e): e.errorDescription
        case .lesson(let m): m
        case .files(let m): m
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .database(let e): e.recoverySuggestion
        case .lesson, .files: nil
        }
    }

    /// The welcome view's headline for the error.
    var title: String {
        switch self {
        case .database(let e): e.title
        case .lesson: "The Lesson Cannot Open"
        case .files: "Files Error"
        }
    }
}

/// Settings that belong to this Mac, in UserDefaults; everything else lives in the library.
struct LocalPreferences {
    static let libraryKey = "LibraryPath"
    static let recentKey = "RecentLibraries"
    static let goPathKey = "GoPath"
    static let lastPushKey = "LastPush"
    static let unsettledKey = "UnsettledFiles"

    let defaults: UserDefaults

    /// The library to open at launch (LibraryPath, or -LibraryPath on the command line). The
    /// app reads it once; after that the open library is the model's state.
    var launchLibrary: URL? {
        guard let path = defaults.string(forKey: LocalPreferences.libraryKey)?.trimmingCharacters(in: .whitespaces), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    var recentLibraries: [URL] {
        (defaults.stringArray(forKey: LocalPreferences.recentKey) ?? []).map { URL(fileURLWithPath: $0) }
    }

    /// Stores what the model says is open now and what was opened lately.
    func store(_ libraries: OpenLibraries) {
        if let current = libraries.current { defaults.set(current.path, forKey: LocalPreferences.libraryKey) }
        if libraries.recent.isEmpty {
            defaults.removeObject(forKey: LocalPreferences.recentKey)
        } else {
            defaults.set(libraries.recent.map(\.path), forKey: LocalPreferences.recentKey)
        }
    }

    var goPath: String? {
        let p = defaults.string(forKey: LocalPreferences.goPathKey)?.trimmingCharacters(in: .whitespaces)
        return (p?.isEmpty ?? true) ? nil : p
    }

    func setGoPath(_ path: String?) { defaults.set(path ?? "", forKey: LocalPreferences.goPathKey) }

    /// Commit and push automatically (on by default).

    var lastPush: Date? { defaults.object(forKey: LocalPreferences.lastPushKey) as? Date }
    func setLastPush(_ date: Date) { defaults.set(date, forKey: LocalPreferences.lastPushKey) }

    /// Code files left in conflict when the app quit, as "<lesson>/<file>": the lesson folder on
    /// this Mac holds the other editor's version, so this list belongs to the Mac too.
    func unsettledFiles(in lesson: String) -> Set<String> {
        Set((defaults.stringArray(forKey: LocalPreferences.unsettledKey) ?? []).compactMap { entry in
            entry.hasPrefix(lesson + "/") ? String(entry.dropFirst(lesson.count + 1)) : nil
        })
    }

    func setUnsettled(_ file: String, in lesson: String, _ unsettled: Bool) {
        var list = (defaults.stringArray(forKey: LocalPreferences.unsettledKey) ?? []).filter { $0 != lesson + "/" + file }
        if unsettled { list.append(lesson + "/" + file) }
        if list.isEmpty { defaults.removeObject(forKey: LocalPreferences.unsettledKey) } else { defaults.set(list, forKey: LocalPreferences.unsettledKey) }
    }
}


/// Lessons visited, for the toolbar's back and forward buttons.
struct VisitHistory {
    private(set) var back: [String] = []
    private(set) var forward: [String] = []

    mutating func visit(from current: String?) {
        if let current { back.append(current) }
        if back.count > 200 { back.removeFirst() }
        forward.removeAll()
    }

    mutating func goBack(from current: String?) -> String? {
        guard let target = back.popLast() else { return nil }
        if let current { forward.append(current) }
        return target
    }

    mutating func goForward(from current: String?) -> String? {
        guard let target = forward.popLast() else { return nil }
        if let current { back.append(current) }
        return target
    }
}

/// The app's state: which database is open, the catalog with your progress, the lesson on
/// screen, search, and the services lessons use. Views read it from the environment.
@Observable @MainActor
final class AppModel {
    enum Phase: Equatable {
        case starting
        /// No library chosen yet.
        case welcome
        /// The library could not open; the welcome view says why.
        case failed(AppError)
        case ready
    }

    private(set) var phase: Phase = .starting
    private(set) var database: AppDatabase?
    private(set) var toolchain: Toolchain?
    private(set) var catalog: Catalog = .empty
    private(set) var done: Set<String> = []
    private(set) var lesson: LessonModel?
    private(set) var isLoadingLesson = false
    var selection: String?
    var expandedChapters: Set<String> = []
    var searchText = "" { didSet { searchChanged() } }
    private(set) var searchResults: [SearchHit] = []
    /// Excerpts for the results, by lesson; they arrive just after the results.
    private(set) var searchSnippets: [String: [Snippet.Part]] = [:]
    private(set) var searching = false
    var banner: AppError?

    /// Shows an error from work that has no place of its own on screen, such as a save. Work
    /// that was cancelled (another lesson, search or library replaced it) ends silently.
    func report(_ error: any Error) {
        guard !Reporting.isSilent(error) else { return }
        banner = (error as? AppError) ?? (error as? AppDatabaseError).map(AppError.database) ?? .database(.sqlite(error.localizedDescription))
    }

    /// The same, for a problem with a lesson's files.
    func reportFiles(_ error: any Error) {
        guard !Reporting.isSilent(error) else { return }
        banner = .files(error.localizedDescription)
    }
    /// Whether the inspector is open, remembered on this Mac.
    var showInspector: Bool {
        get { access(keyPath: \.showInspector); return preferences.defaults.bool(forKey: "ShowInspector") }
        set { withMutation(keyPath: \.showInspector) { preferences.defaults.set(newValue, forKey: "ShowInspector") } }
    }
    private(set) var history = VisitHistory()
    var editorFontSize: Double = 13
    var showLineNumbers = true
    private(set) var git: GitSync?
    /// A quiet line about git: the last push, or why it did not happen.
    private(set) var syncStatus = ""
    private(set) var syncError: GitSyncError?
    /// Git steps the app is waiting on (they run one at a time inside GitSync).
    private var syncsRunning = 0
    var isSyncing: Bool { syncsRunning > 0 }
    /// Set while the app saves and syncs before it quits.
    private(set) var isQuitting = false
    @ObservationIgnored private var started = false
    /// jq for command-line checks, compiled in; its programs are cached for the session.
    let jq = CompiledJQ()
    var confirmReset = false
    /// Bumped to open the Settings window (views own the openSettings action).
    private(set) var settingsRequests = 0

    let preferences: LocalPreferences
    let workspace = Workspace()
    private let readmes = ReadmeCache()
    /// Readmes as plain text, for search excerpts; made ahead of time once a library opens.
    private let readmeTexts = ReadmeTexts()
    private var warmTask: Task<Void, Never>?
    private var observeTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var toolchainTask: Task<Toolchain, Never>?
    private let signposter = OSSignposter(subsystem: Log.subsystem, category: .pointsOfInterest)
    private var launchInterval: OSSignpostIntervalState?

    init(defaults: UserDefaults = .standard) {
        preferences = LocalPreferences(defaults: defaults)
    }

    /// The library open now (or the one last tried) and the recent ones: model state, read
    /// from the stored setting once at launch.
    private(set) var libraries = OpenLibraries(launch: nil, recent: [])
    var libraryURL: URL? { libraries.current }
    var recentLibraries: [URL] { libraries.recent }
    /// Set when a library chosen while another is open fails its checks; the open one stays.
    var libraryError: AppError?
    /// While a library opens; the open commands wait.
    private(set) var isOpeningLibrary = false
    /// Why sync is off for the open library, if it is.
    private(set) var syncOffReason: String?
    @ObservationIgnored private let opener = Superseding()

    // MARK: Launch

    /// Opens the library and the lesson you had open. The app delegate calls it once the app
    /// has launched, before or without a visible window; only the first call does anything.
    func start() async {
        guard !started else { return }
        started = true
        libraries = OpenLibraries(launch: preferences.launchLibrary, recent: preferences.recentLibraries)
        // What runs left behind after a crash; not the lesson folders.
        let workspace = workspace
        Task.detached(priority: .background) { workspace.removeStaleRuns() }
        launchInterval = signposter.beginInterval("Launch")
        let goOverride = preferences.goPath
        toolchainTask = Task.detached(priority: .utility) { await Toolchain.discover(goOverride: goOverride) }
        open(libraries.current)
        await opener.wait()
        Task { [weak self] in
            guard let self, let task = self.toolchainTask else { return }
            self.toolchain = await task.value
        }
    }

    /// File > Open Library…: any file; it is checked before the open library lets go.
    func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Open"
        panel.message = "Choose a Gopherwood library: an SQLite file with courses and your progress in them"
        if let current = libraryURL { panel.directoryURL = current.deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(library: url)
    }

    /// Opens another library you chose (File > Open, Open Recent, Settings). It passes the
    /// format's checks first; one that fails is named in an alert and the open library stays.
    func open(library url: URL) {
        opener.run { [weak self] in
            guard let self else { return }
            if self.database != nil {
                self.isOpeningLibrary = true
                defer { self.isOpeningLibrary = false }
                let refused = await Task.detached(priority: .userInitiated) { () -> AppDatabaseError? in
                    do { try AppDatabase(url: url).close(); return nil } catch let e as AppDatabaseError { return e } catch { return .sqlite(error.localizedDescription) }
                }.value
                // Superseded: the newer choice speaks, not this one.
                if Task.isCancelled { return }
                if let refused {
                    self.libraryError = .database(refused)
                    return
                }
            }
            self.libraries.opened(url)
            self.preferences.store(self.libraries)
            await self.openLibrary(url, pull: false)
        }
    }

    /// Opens `url` again (Try Again), or the welcome view for nil.
    func open(_ url: URL?) {
        opener.run { [weak self] in await self?.openLibrary(url, pull: false) }
    }

    func clearRecentLibraries() {
        libraries.clearRecent()
        preferences.store(libraries)
    }

    /// Lets go of the open library: settles the lesson (a code conflict is asked about first),
    /// stops what works on it, commits and pushes it when asked (sync on, or a pull next), and
    /// closes the file.
    private func closeLibrary(commit: Bool) async {
        guard let db = database else { return }
        // A lesson still loading never takes the place of the one leaving.
        loadTask?.cancel()
        await lesson?.leave()
        searchTask?.cancel()
        warmTask?.cancel()
        observeTask?.cancel()
        if commit, git != nil { await commitAndPush() }
        lesson = nil
        database = nil
        do { try db.close() } catch { report(error) }
    }

    /// Opens a library, one at a time (`opener`): closes the open one first, since git must
    /// never replace a file under an open connection; finds whether git tracks the file;
    /// pulls; then opens and checks it off the main actor. Superseded by a newer request, it
    /// stops before it changes anything.
    private func openLibrary(_ url: URL?, pull: Bool) async {
        isOpeningLibrary = true
        defer { isOpeningLibrary = false }
        await closeLibrary(commit: pull)
        // Another library, or a pull, may give the same lesson ids new text.
        await readmes.clear()
        await readmeTexts.clear()
        searchResults = []
        searchSnippets = [:]
        if Task.isCancelled { return }
        guard let url else {
            git = nil
            syncOffReason = nil
            phase = .welcome
            finishLaunch()
            return
        }
        if libraries.current != url { libraries = OpenLibraries(launch: url, recent: libraries.recent) }
        Log.app.info("Opening library \(url.path, privacy: .public)")
        phase = .starting
        let openStarted = ContinuousClock.now
        defer { AppModel.logPhase("open (pull, check, catalog)", since: openStarted) }
        // Reading the file first: in a folder macOS protects, its question about access comes
        // now, and nothing below (git's timeouts included) starts before it is answered.
        if let refused = await Task.detached(priority: .userInitiated, operation: { AppDatabase.access(url) }).value {
            if Task.isCancelled { return }
            git = nil
            syncOffReason = nil
            phase = .failed(.database(refused))
            finishLaunch()
            return
        }
        if Task.isCancelled { return }
        let location = await GitSync.locate(url)
        if Task.isCancelled { return }
        // One GitSync per work tree and file, so its steps stay one at a time.
        if let found = location.sync, let current = git, current.repository == found.repository, current.file == found.file {
            // keep the current one
        } else {
            git = location.sync
        }
        switch location {
        case .tracked: syncOffReason = nil
        case .untracked: syncOffReason = "This library isn't tracked by git in the repository it sits in; changes stay on this Mac."
        case .outside: syncOffReason = "This library isn't in a git repository; changes stay on this Mac."
        }
        syncError = nil
        syncStatus = ""
        if let git, pull {
            // Before the library opens: fast-forward only; a conflict is reported.
            syncsRunning += 1
            do {
                if case .done = try await git.pullFastForward() {
                    syncStatus = "Pulled \(Date().formatted(date: .omitted, time: .shortened))"
                }
            } catch {
                syncError = error
                syncStatus = error.localizedDescription
                Log.git.notice("Pull before opening: \(error.localizedDescription, privacy: .public)")
            }
            syncsRunning -= 1
            AppModel.logPhase("pull", since: openStarted)
        }
        if Task.isCancelled { return }
        do {
            // Opening runs the format's checks, off the main actor.
            let db: AppDatabase = try await Task.detached(priority: .userInitiated) { try AppDatabase(url: url) }.value
            if Task.isCancelled {
                try db.close()
                return
            }
            database = db
            catalog = try await db.catalog()
            done = try await db.doneLessons()
            editorFontSize = Double(try await db.setting("editor_font_size") ?? "") ?? 13
            showLineNumbers = (try await db.setting("editor_line_numbers")) != "0"
            phase = .ready
            observeDone(db)
            let texts = readmeTexts
            warmTask = Task.detached(priority: .utility) {
                do { try await texts.warm(db) } catch { Log.app.notice("Search excerpts: \(error.localizedDescription, privacy: .public)") }
            }
            let last = try await db.lastOpenedLesson()
            let requested = preferences.defaults.string(forKey: LaunchArguments.openLesson)
            if let id = requested.flatMap({ catalog.summary($0)?.id }) ?? last.flatMap({ catalog.summary($0)?.id }) ?? catalog.firstLesson?.id {
                open(id, remember: false)
            } else {
                finishLaunch()
            }
        } catch let e as AppDatabaseError {
            phase = .failed(.database(e))
            finishLaunch()
        } catch {
            phase = .failed(.database(.sqlite(error.localizedDescription)))
            finishLaunch()
        }
    }

    private func finishLaunch() {
        guard let interval = launchInterval else { return }
        signposter.endInterval("Launch", interval)
        launchInterval = nil
        // From the process's start, so the dock click to a usable window is what counts.
        let sinceStart = AppModel.processStart.map { Date().timeIntervalSince($0) * 1000 } ?? -1
        Log.app.notice("Timing launch \(Int(sinceStart), privacy: .public) ms from process start")
    }

    static func logPhase(_ name: String, since start: ContinuousClock.Instant) {
        Log.app.notice("Timing \(name, privacy: .public) \(Int((ContinuousClock.now - start).milliseconds), privacy: .public) ms")
    }

    /// When this process started, from the kernel.
    static let processStart: Date? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
    }()

    /// Follows finished lessons as the app writes them.
    private func observeDone(_ db: AppDatabase) {
        observeTask?.cancel()
        observeTask = Task { [weak self] in
            do {
                for try await done in db.doneLessonUpdates() {
                    self?.done = done
                }
            } catch {
                self?.report(error)
            }
        }
    }

    // MARK: Lessons

    func summary(_ id: String) -> LessonSummary? { catalog.summary(id) }

    /// Shows a lesson; `remember` adds the one on screen to the back history.
    func open(_ id: String, remember: Bool = true) {
        guard let db = database, catalog.summary(id) != nil else { return }
        if remember && id != lesson?.detail.id { history.visit(from: lesson?.detail.id) }
        if selection != id { selection = id }
        if let loc = catalog.location(of: id) { expandedChapters.insert(catalog.courses[loc.course].chapters[loc.chapter].id) }
        guard lesson?.detail.id != id else { return }
        let interval = signposter.beginInterval("Lesson switch")
        let started = ContinuousClock.now
        isLoadingLesson = true
        loadTask?.cancel()
        let previous = lesson
        loadTask = Task { [weak self] in
            await previous?.leave()
            guard let self else { return }
            do {
                guard let detail = try await db.lesson(id) else { throw AppError.lesson("This lesson is not in the database.") }
                // Superseded: the readme cache may already belong to another library.
                try Task.checkCancellation()
                let parsed = await self.readmes.parsed(for: detail)
                var saved: [String: CodeFileRecord] = [:]
                if detail.code != nil { saved = try await db.codeFiles(for: id) }
                try Task.checkCancellation()
                let model = LessonModel(detail: detail, parsed: parsed, saved: saved, database: db, app: self)
                self.lesson = model
                self.isLoadingLesson = false
                self.signposter.endInterval("Lesson switch", interval)
                let ms = (ContinuousClock.now - started).milliseconds
                Log.app.notice("Timing lesson switch \(Int(ms), privacy: .public) ms (\(detail.type.rawValue, privacy: .public))")
                self.finishLaunch()
                await model.load()
                do { try await db.markOpened(id) } catch { self.report(error) }
                self.performLaunchAction(on: model)
            } catch let error where Reporting.isSilent(error) {
                self.signposter.endInterval("Lesson switch", interval)
            } catch let e as AppError {
                self.isLoadingLesson = false
                self.banner = e
            } catch {
                self.isLoadingLesson = false
                self.banner = .lesson(error.localizedDescription)
            }
        }
    }

    /// Launch arguments for scripted runs (screenshots, debugging): `-GopherwoodOpenLesson
    /// <uuid>` opens a lesson, and `-GopherwoodLaunchAction run|submit|check|answer` acts on
    /// it once, after it loads. They live in the argument domain only, never stored.
    enum LaunchArguments {
        static let openLesson = "GopherwoodOpenLesson"
        static let action = "GopherwoodLaunchAction"
    }

    @ObservationIgnored private var launchActionDone = false

    private func performLaunchAction(on model: LessonModel) {
        guard !launchActionDone, let action = preferences.defaults.string(forKey: LaunchArguments.action) else { return }
        launchActionDone = true
        if action.hasPrefix("search:") {
            // Types the query a letter at a time, as someone would.
            let query = String(action.dropFirst(7))
            Task { [weak self] in
                for end in query.indices {
                    try? await Task.sleep(for: .milliseconds(120))
                    self?.searchText = String(query[...end])
                }
            }
            return
        }
        if action == "walk" {
            // Opens the next ten lessons one after another, to measure switching.
            Task { [weak self] in
                for _ in 0..<10 {
                    try? await Task.sleep(for: .milliseconds(400))
                    self?.openNext()
                }
            }
            return
        }
        switch action {
        case "settings": settingsRequests += 1
        case "run": model.run()
        case "submit": model.submit()
        case "check": model.run()
        case "footer": model.showFooter()
        case "format":
            // Format waits for Go to be found.
            Task { [weak self] in
                _ = await self?.awaitToolchain()
                model.code?.perform(.format)
            }
        case "answer":
            // The first question right, the others wrong: both outcomes on screen.
            guard let quiz = model.quiz else { return }
            for (i, q) in quiz.quiz.questions.enumerated() {
                let right = q.answers.firstIndex(of: q.answer) ?? 0
                let wrong = q.answers.indices.first { $0 != right } ?? right
                quiz.pick(i == 0 ? right : wrong, for: i)
            }
            model.submit()
        default: break
        }
    }

    var canGoBack: Bool { !history.back.isEmpty }
    var canGoForward: Bool { !history.forward.isEmpty }

    func goBack() {
        if let id = history.goBack(from: lesson?.detail.id) { open(id, remember: false) }
    }

    func goForward() {
        if let id = history.goForward(from: lesson?.detail.id) { open(id, remember: false) }
    }

    var nextLesson: LessonSummary? { lesson.flatMap { catalog.next(after: $0.detail.id) } }
    var previousLesson: LessonSummary? { lesson.flatMap { catalog.previous(before: $0.detail.id) } }

    func openNext() { if let n = nextLesson { open(n.id) } }
    func openPrevious() { if let p = previousLesson { open(p.id) } }

    func isDone(_ id: String) -> Bool { done.contains(id) }

    func setDone(_ id: String, _ value: Bool) {
        guard let db = database else { return }
        if value { done.insert(id) } else { done.remove(id) }
        Task {
            do {
                try await db.setDone(id, value)
            } catch {
                report(error)
            }
        }
    }

    /// Finished lessons out of required ones, for a course's ring.
    func progress(of course: Course) -> (done: Int, total: Int) {
        let required = course.requiredLessons
        return (required.filter { done.contains($0.id) }.count, required.count)
    }

    func doneCount(_ chapter: Chapter) -> Int { chapter.lessons.filter { done.contains($0.id) }.count }

    // MARK: Search

    private func searchChanged() {
        searchTask?.cancel()
        let text = searchText
        guard let db = database, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            searching = false
            return
        }
        searching = true
        let texts = readmeTexts
        searchTask = Task { [weak self] in
            let interval = self?.signposter.beginInterval("Search")
            let started = ContinuousClock.now
            // The index's hits that show a match, with their excerpts, from the readmes as
            // the app renders them.
            let found: (hits: [SearchHit], snippets: [String: [Snippet.Part]])
            do {
                found = try await texts.search(text, in: db)
            } catch {
                found = ([], [:])
                self?.report(error)
            }
            guard let self, !Task.isCancelled else { return }
            self.searchResults = found.hits
            self.searchSnippets = found.snippets
            self.searching = false
            if let interval { self.signposter.endInterval("Search", interval) }
            let ms = (ContinuousClock.now - started).milliseconds
            Log.app.notice("Timing search \(String(format: "%.1f", ms), privacy: .public) ms for \(text.count, privacy: .public) characters")
        }
    }

    // MARK: Settings

    func setEditorFontSize(_ size: Double) {
        editorFontSize = min(max(size, 9), 28)
        guard let db = database else { return }
        let value = String(Int(editorFontSize))
        Task { [weak self] in
            do { try await db.setSetting("editor_font_size", value) } catch { self?.report(error) }
        }
    }

    func awaitToolchain() async -> Toolchain? {
        if let toolchain { return toolchain }
        guard let task = toolchainTask else { return nil }
        let t = await task.value
        toolchain = t
        return t
    }

    func rediscoverToolchain(goPath: String?) {
        preferences.setGoPath(goPath)
        toolchain = nil
        let override = preferences.goPath
        toolchainTask = Task.detached(priority: .userInitiated) { await Toolchain.discover(goOverride: override) }
        Task { [weak self] in
            guard let self, let task = self.toolchainTask else { return }
            self.toolchain = await task.value
        }
    }

    func setShowLineNumbers(_ on: Bool) {
        showLineNumbers = on
        guard let db = database else { return }
        Task { [weak self] in
            do { try await db.setSetting("editor_line_numbers", on ? "1" : "0") } catch { self?.report(error) }
        }
    }

    // MARK: Lesson folders

    /// The folder of the lesson on screen: its work folder for code, its project for
    /// command-line lessons.
    var lessonFolder: URL? {
        if let code = lesson?.code { return code.folder }
        if let checks = lesson?.checks, !checks.projectDir.isEmpty { return URL(fileURLWithPath: checks.projectDir, isDirectory: true) }
        return nil
    }

    func revealLessonFolder() {
        Task {
            await lesson?.code?.flush()
            guard let folder = lessonFolder else { return }
            let main = lesson?.code?.activeFile.map { folder.appendingPathComponent($0.name) }
            NSWorkspace.shared.activateFileViewerSelecting([main.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? folder])
        }
    }

    /// Opens the folder in the app that opens your Go files; an editor that only opens
    /// files gets the file you are editing.
    func openLessonFolderInEditor() {
        Task {
            await lesson?.code?.flush()
            guard let folder = lessonFolder else { return }
            let file = lesson?.code?.activeFile.map { folder.appendingPathComponent($0.name) }
            let probe = file ?? folder.appendingPathComponent("main.go")
            let config = NSWorkspace.OpenConfiguration()
            guard let editor = NSWorkspace.shared.urlForApplication(toOpen: probe) else {
                NSWorkspace.shared.activateFileViewerSelecting([folder])
                return
            }
            let fileOnly = ["com.apple.TextEdit", "com.apple.dt.Xcode"].contains(Bundle(url: editor)?.bundleIdentifier ?? "")
            let targets = fileOnly ? [file ?? probe] : [folder]
            do {
                _ = try await NSWorkspace.shared.open(targets, withApplicationAt: editor, configuration: config)
            } catch {
                banner = .files(error.localizedDescription)
            }
        }
    }

    // MARK: Command-line checks

    func makeChecker() -> CLIChecker? {
        CLIChecker(environment: toolchain?.environment ?? ProcessInfo.processInfo.environment, jq: jq)
    }

    // MARK: Git

    /// Commits the library file if it changed, then pushes. A call while another sync
    /// runs waits for it (GitSync runs its steps one at a time) and commits what changed
    /// since. Quiet: the outcome goes to the sync status line, and a conflict is reported,
    /// never merged.
    func commitAndPush() async {
        guard let git, let db = database else { return }
        syncsRunning += 1
        defer { syncsRunning -= 1 }
        do {
            let (_, push) = try await git.commitAndPush(db)
            if case .done = push { preferences.setLastPush(Date()) }
            syncError = nil
            syncStatus = preferences.lastPush.map { "Pushed \($0.formatted(.relative(presentation: .named)))" } ?? "Up to date"
        } catch {
            syncError = error
            syncStatus = error.localizedDescription
            Log.git.notice("Sync: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Pull, only when you ask: opens the library again with a pull first (closing it commits
    /// and pushes it, so the pull can fast-forward).
    func pullNow() {
        guard git != nil, database != nil, !isSyncing else { return }
        let url = libraryURL
        opener.run { [weak self] in await self?.openLibrary(url, pull: true) }
    }

    /// Removes git's lock file when git reported it stale (left by a git that stopped), then
    /// syncs again.
    func removeStaleLock() async {
        guard let git else { return }
        do {
            try await git.removeStaleLock()
            syncError = nil
            syncStatus = ""
            await commitAndPush()
        } catch {
            syncError = error
            syncStatus = error.localizedDescription
        }
    }

    /// Saves what is pending before the app quits. Lesson programs stop at once; a sync you
    /// started is not stopped, and the app delegate bounds the whole wait.
    func prepareToQuit() async {
        isQuitting = true
        // A code conflict asks first; without a choice in 15 seconds both versions are kept.
        await lesson?.leave(within: .seconds(15))
        ProcessRunner.terminateAll(.lesson)
    }
}
