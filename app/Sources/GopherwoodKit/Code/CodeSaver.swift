import Foundation

/// Keeps a code lesson's editable files in step between the editor, code_file and the work
/// folder, one save at a time.
///
/// Another editor can change the folder (Lesson > Open Lesson Folder in Editor), so every
/// save first compares each file on disk with the text last saved:
/// - only the folder changed: its text goes into code_file, and the caller puts it in the
///   editor;
/// - only the editor changed: the editor's text goes into code_file and the folder;
/// - both changed: nothing is written, and the caller asks which to keep (`resolve`).
///
/// Saves run in the order asked, each after the one before has landed, so a run that saves
/// first never builds while an earlier save is still writing.
public actor CodeSaver {
    public enum Outcome: Equatable, Sendable {
        case unchanged
        /// The editor's text is in code_file and the folder.
        case saved
        /// The folder held a newer edit; it is in code_file now and belongs in the editor.
        case adopted(String)
        /// Both the editor and the folder changed; nothing was written.
        case conflict(disk: String)
    }

    /// What one file needs, given its text in the editor, the text last saved and the file
    /// on disk (nil when it is missing).
    public enum Decision: Equatable, Sendable {
        case nothing
        case write
        case adopt(String)
        case conflict(String)
    }

    public static func decide(editor: String, saved: String, disk: String?) -> Decision {
        guard let disk else { return .write } // gone from the folder: put it back
        if disk == saved { return editor == saved ? .nothing : .write }
        // The folder changed since the last save.
        if editor == saved || editor == disk { return .adopt(disk) }
        return .conflict(disk)
    }

    /// A choice for a file in conflict.
    public enum Choice: Sendable {
        /// Your text, from the editor.
        case mine(String)
        /// The file on disk, read again when the choice is made.
        case disk
    }

    let database: AppDatabase
    let workspace: Workspace
    let lesson: LessonDetail
    private var saved: [String: String]
    /// Files that changed both here and on disk since the last save. Nothing is written for
    /// them until a choice is made; each save looks at the disk again.
    private var unsettled: Set<String>
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var queue: Task<Void, Never>?

    /// `saved` is each editable file's text as code_file and the folder hold it now;
    /// `unsettled` names files still in conflict from an earlier session.
    public init(database: AppDatabase, workspace: Workspace, lesson: LessonDetail, saved: [String: String], unsettled: Set<String> = []) {
        self.database = database
        self.workspace = workspace
        self.lesson = lesson
        self.saved = saved
        self.unsettled = unsettled
    }

    /// The files waiting for a choice.
    public var conflicts: Set<String> { unsettled }

    /// Brings code_file and the folder in step with the editor's texts (by file name).
    public func sync(_ texts: [String: String]) async throws -> [String: Outcome] {
        try await serialized { try await $0.syncNow(texts) }
    }

    /// Settles a conflict. Your text goes into code_file and the folder; the file on disk is
    /// read again now, since the other editor may have saved it again after the conflict
    /// appeared, and goes into code_file. Returns the text kept.
    @discardableResult
    public func resolve(_ name: String, _ choice: Choice) async throws -> String {
        try await serialized { try await $0.resolveNow(name, choice) }
    }

    /// Waits until no conflict is left (true), or until `limit` runs out first (false).
    public func waitUntilSettled(within limit: Duration?) async -> Bool {
        if unsettled.isEmpty { return true }
        let id = UUID()
        if let limit {
            Task { [weak self] in
                try? await Task.sleep(for: limit)
                await self?.stopWaiting(id)
            }
        }
        return await withCheckedContinuation { waiters[id] = $0 }
    }

    /// When no choice came in time (the app is quitting): keeps both versions. Your text goes
    /// into code_file, the file on disk stays as the other editor left it, and the conflict
    /// stays open, to be asked about when the lesson opens again. Returns the files kept so.
    public func keepBoth(_ texts: [String: String]) async throws -> [String] {
        try await serialized { s in try await s.keepBothNow(texts) }
    }

    private func stopWaiting(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: false)
    }

    private func settled() {
        guard unsettled.isEmpty else { return }
        for (_, waiter) in waiters { waiter.resume(returning: true) }
        waiters = [:]
    }

    private func serialized<T: Sendable>(_ step: @escaping @Sendable (CodeSaver) async throws -> T) async throws -> T {
        let previous = queue
        let task = Task { [self] () async throws -> T in
            await previous?.value
            return try await step(self)
        }
        queue = Task { _ = await task.result }
        return try await task.value
    }

    private func diskText(_ name: String) -> String? {
        (try? Workspace.lessonPath(workspace.folder(for: lesson), name)).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    private func syncNow(_ texts: [String: String]) async throws -> [String: Outcome] {
        var outcomes: [String: Outcome] = [:]
        var written: [(String, String)] = []
        var adopted: [(String, String)] = []
        for (name, text) in texts.sorted(by: { $0.key < $1.key }) {
            let disk = diskText(name)
            if unsettled.contains(name) {
                // Still waiting for a choice, unless both sides now say the same.
                if let disk, disk == text {
                    unsettled.remove(name)
                    adopted.append((name, disk))
                    outcomes[name] = .adopted(disk)
                } else {
                    outcomes[name] = .conflict(disk: disk ?? "")
                }
                continue
            }
            switch CodeSaver.decide(editor: text, saved: saved[name] ?? text, disk: disk) {
            case .nothing:
                outcomes[name] = .unchanged
            case .write:
                written.append((name, text))
                outcomes[name] = .saved
            case .adopt(let text):
                adopted.append((name, text))
                outcomes[name] = .adopted(text)
            case .conflict(let text):
                unsettled.insert(name)
                outcomes[name] = .conflict(disk: text)
            }
        }
        try await write(adopted, toDisk: false)
        try await write(written, toDisk: true)
        settled()
        return outcomes
    }

    private func resolveNow(_ name: String, _ choice: Choice) async throws -> String {
        let text: String
        switch choice {
        case .mine(let mine):
            text = mine
            try await write([(name, mine)], toDisk: true)
        case .disk:
            // A file the other editor removed has nothing to give: yours stays.
            if let disk = diskText(name) {
                text = disk
                try await write([(name, disk)], toDisk: false)
            } else {
                text = saved[name] ?? ""
                try await write([(name, text)], toDisk: true)
            }
        }
        unsettled.remove(name)
        settled()
        return text
    }

    private func keepBothNow(_ texts: [String: String]) async throws -> [String] {
        let kept = unsettled.sorted().filter { texts[$0] != nil }
        guard !kept.isEmpty else { return [] }
        let now = Clock.now()
        try await database.saveCode(lesson: lesson.id, files: kept.compactMap { name in
            texts[name].map { CodeFileRecord(name: name, content: $0, updatedAt: now) }
        })
        return kept
    }

    /// code_file first, then the folder; `saved` only once both have landed.
    private func write(_ files: [(name: String, text: String)], toDisk: Bool) async throws {
        guard !files.isEmpty else { return }
        let now = Clock.now()
        try await database.saveCode(lesson: lesson.id, files: files.map { CodeFileRecord(name: $0.name, content: $0.text, updatedAt: now) })
        if toDisk {
            for f in files { try workspace.write(lesson, name: f.name, content: f.text) }
        }
        for f in files { saved[f.name] = f.text }
    }
}
