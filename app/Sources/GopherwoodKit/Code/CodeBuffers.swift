import Foundation
import Observation

/// One file in the editor. Its text is observed on its own, so typing redraws the editor and
/// nothing else.
@Observable @MainActor
public final class FileBuffer {
    public let name: String
    public let readOnly: Bool
    public var text: String
    /// The text the buffer was last filled with; typing makes the two differ.
    @ObservationIgnored private(set) var loadedText: String

    init(_ file: EditorFile) {
        name = file.name
        readOnly = file.readOnly
        text = file.content
        loadedText = file.content
    }

    /// Replaces the text from outside the editor: the saved code, or another editor's edit.
    func fill(_ text: String) {
        if self.text != text { self.text = text }
        loadedText = text
    }

    /// Whether the text changed since the buffer was last filled.
    var isEdited: Bool { text != loadedText }
}

/// A code lesson's files as the editor shows them, kept in step with code_file and the
/// lesson folder by a `CodeSaver`.
///
/// The buffers open with your code from code_file, or the starter code. `load` then makes
/// the lesson folder, takes in what it holds (an edit another editor made there, say) and
/// gets saving ready: `isLoaded`, from which on the editor takes typing. Text that changed
/// before the load landed is never overwritten. It stays, and where the loaded text differs
/// from what it started from, the loaded text is the other side of a conflict, asked about
/// like any other. Leaving waits for a load under way, so whatever the buffers hold is saved.
@Observable @MainActor
public final class CodeBuffers {
    public let lesson: LessonDetail
    public let exercise: CodeExercise
    public private(set) var files: [FileBuffer]
    public var activeIndex: Int
    /// True once the buffers hold your code as code_file and the lesson folder have it, and
    /// saving is ready. The editor takes typing from then on.
    public private(set) var isLoaded = false
    /// The lesson folder, once made.
    public private(set) var folder: URL?
    /// Why the last load failed; the next load (a run starts one) tries again.
    public private(set) var loadError: String?
    /// A file that changed both here and in another editor; the lesson asks which to keep.
    public private(set) var conflict: String?

    private let database: AppDatabase
    private let workspace: Workspace
    private let unsettled: Set<String>
    private let goVersion: @MainActor () async -> String
    private let remember: @MainActor (_ name: String, _ unsettled: Bool) -> Void
    @ObservationIgnored private var saver: CodeSaver?
    @ObservationIgnored private var loading: Task<Void, Never>?

    /// `saved` is your code from code_file, and `unsettled` names the files left in conflict
    /// when the app last quit. `goVersion` gives the Go version for a new folder's go.mod;
    /// `remember` keeps, across launches, whether a file is still in conflict.
    public init(lesson: LessonDetail, exercise: CodeExercise, saved: [String: CodeFileRecord], database: AppDatabase,
                workspace: Workspace, unsettled: Set<String>, goVersion: @escaping @MainActor () async -> String,
                remember: @escaping @MainActor (_ name: String, _ unsettled: Bool) -> Void) {
        self.lesson = lesson
        self.exercise = exercise
        self.database = database
        self.workspace = workspace
        self.unsettled = unsettled
        self.goVersion = goVersion
        self.remember = remember
        let buffers = exercise.visibleFiles.map { f in
            FileBuffer(EditorFile(name: f.name, content: f.isReadonly ? f.content : saved[f.name]?.content ?? f.content, readOnly: f.isReadonly))
        }
        files = buffers
        activeIndex = max(0, buffers.firstIndex { !$0.readOnly } ?? 0)
    }

    /// Makes the lesson folder, takes in what it holds and gets saving ready. One load at a
    /// time: a second call waits for the one under way. It runs to its end even when the
    /// caller is cancelled; after a failure the next call tries again.
    public func load() async {
        if let loading { return await loading.value }
        let task = Task { await loadNow() }
        loading = task
        await task.value
    }

    private func loadNow() async {
        do {
            let saved = try await database.codeFiles(for: lesson.id)
            let version = await goVersion()
            let lesson = lesson, exercise = exercise, workspace = workspace, unsettled = unsettled
            let prepared = try await Task.detached(priority: .userInitiated) {
                try workspace.prepare(lesson, code: exercise, saved: saved, goVersion: version, unsettled: unsettled)
            }.value
            folder = prepared.folder
            let (start, conflicted) = adopt(prepared.files)
            // The folder's newer edits go into code_file, except where they meet text typed
            // before the load landed: those wait for your choice.
            let readBack = prepared.readBack.filter { !conflicted.contains($0.name) }
            if !readBack.isEmpty { try await database.saveCode(lesson: lesson.id, files: readBack) }
            saver = CodeSaver(database: database, workspace: workspace, lesson: lesson, saved: start, unsettled: unsettled)
            loadError = nil
            isLoaded = true
        } catch {
            loading = nil
            if !Reporting.isSilent(error) { loadError = error.localizedDescription }
        }
    }

    /// Takes the loaded files into the buffers and returns each editable file's text as
    /// code_file and the folder have it, the saver's starting point. A buffer that changed
    /// before the load landed keeps its text. Where the loaded text also differs from what
    /// that text started from, the starting point stays the text it started from, so the
    /// first save finds both sides changed and asks.
    private func adopt(_ loaded: [EditorFile]) -> (start: [String: String], conflicted: Set<String>) {
        var start: [String: String] = [:]
        var conflicted: Set<String> = []
        let buffers = loaded.map { file -> FileBuffer in
            guard let buffer = files.first(where: { $0.name == file.name && $0.readOnly == file.readOnly }) else {
                if !file.readOnly { start[file.name] = file.content }
                return FileBuffer(file)
            }
            if file.readOnly || !buffer.isEdited {
                buffer.fill(file.content)
                if !file.readOnly { start[file.name] = file.content }
            } else if file.content == buffer.loadedText {
                start[file.name] = file.content
            } else {
                start[file.name] = buffer.loadedText
                conflicted.insert(file.name)
            }
            return buffer
        }
        if !buffers.elementsEqual(files, by: ===) {
            files = buffers
            activeIndex = max(0, buffers.firstIndex { !$0.readOnly } ?? 0)
        }
        return (start, conflicted)
    }

    /// Saves now, one save at a time: each file is compared with the lesson folder first, so
    /// an edit made in another editor is taken in rather than overwritten. A save asked for
    /// during the load waits for it. Returns false while a conflict waits for your answer.
    @discardableResult
    public func flush() async throws -> Bool {
        if !isLoaded, let loading { await loading.value }
        guard let saver else {
            // No folder (the load failed): your text still goes into code_file.
            let edited = files.filter { !$0.readOnly && $0.isEdited }
            guard !edited.isEmpty else { return true }
            let now = Clock.now()
            try await database.saveCode(lesson: lesson.id, files: edited.map { CodeFileRecord(name: $0.name, content: $0.text, updatedAt: now) })
            for buffer in edited { buffer.fill(buffer.text) }
            return true
        }
        let editable = files.filter { !$0.readOnly }
        let texts = Dictionary(editable.map { ($0.name, $0.text) }, uniquingKeysWith: { a, _ in a })
        let outcomes = try await saver.sync(texts)
        var settled = true
        for buffer in editable {
            switch outcomes[buffer.name] {
            case .adopted(let disk)?:
                // The other editor's version, unless you typed again meanwhile.
                if buffer.text == texts[buffer.name] { buffer.fill(disk) }
            case .conflict?:
                if conflict == nil { conflict = buffer.name }
                settled = false
            default:
                break
            }
        }
        return settled
    }

    /// Settles the conflict with your version, or with the file on disk, read again now. The
    /// question goes away at once; the task says whether no conflict is left, and asks about
    /// the next one if there is.
    public func resolveConflict(keepMine: Bool) -> Task<Bool, any Error>? {
        guard let name = conflict, let saver, let buffer = files.first(where: { $0.name == name }) else { return nil }
        conflict = nil
        let mine = buffer.text
        return Task {
            let kept = try await saver.resolve(name, keepMine ? .mine(mine) : .disk)
            if !keepMine { buffer.fill(kept) }
            remember(name, false)
            if let next = await saver.conflicts.sorted().first {
                conflict = next
                return false
            }
            return true
        }
    }

    /// Saves before the lesson closes, once a load under way has landed, so whatever the
    /// buffers hold is saved. With a conflict the alert asks, and closing waits for the
    /// choice. With a limit (quitting) and no choice in time, both versions are kept: yours in
    /// code_file, the other editor's on disk, and the lesson asks again when it opens.
    /// Returns the files kept so.
    public func settle(within limit: Duration?) async throws -> [String] {
        if !isLoaded, loading != nil || files.contains(where: \.isEdited) { await load() }
        guard !(try await flush()), let saver else { return [] }
        if await saver.waitUntilSettled(within: limit) {
            try await flush() // edits made while the alert was up
            return []
        }
        let texts = Dictionary(files.filter { !$0.readOnly }.map { ($0.name, $0.text) }, uniquingKeysWith: { a, _ in a })
        let kept = try await saver.keepBoth(texts)
        for name in kept { remember(name, true) }
        return kept
    }
}
