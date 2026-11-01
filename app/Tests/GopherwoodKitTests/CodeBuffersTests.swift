import Foundation
import Testing
@testable import GopherwoodKit

/// Holds a load where it asks for the Go version, until opened, so a test can type while the
/// load is under way.
private actor Gate {
    private var isOpen = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var watchers: [CheckedContinuation<Void, Never>] = []

    /// Waits here until the gate opens.
    func pass() async {
        guard !isOpen else { return }
        for watcher in watchers { watcher.resume() }
        watchers = []
        await withCheckedContinuation { held.append($0) }
    }

    /// Returns once something waits at the gate.
    func somethingWaits() async {
        guard held.isEmpty else { return }
        await withCheckedContinuation { watchers.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in held { waiter.resume() }
        held = []
    }
}

/// What the buffers asked to remember across launches: whether a file is still in conflict.
@MainActor private final class Remembered {
    var files: [String: Bool] = [:]
}

/// The editor's buffers before, during and after the load: typing is never lost to a load
/// that lands late, nor overwritten by it.
@Suite struct CodeBuffersTests {
    struct Bench {
        let db: AppDatabase
        let dir: URL
        let lesson: LessonDetail
        let code: CodeExercise
        let workspace: Workspace

        init() async throws {
            let (db, dir) = try Fixtures.database()
            self.db = db
            self.dir = dir
            lesson = try #require(try await db.lesson(Fixtures.codeLesson))
            code = try #require(lesson.code)
            workspace = Workspace(root: dir.appendingPathComponent("work"))
        }

        var file: URL { workspace.folder(for: lesson).appendingPathComponent("main.go") }
        func stored() async throws -> String? { try await db.codeFiles(for: lesson.id)["main.go"]?.content }
        func onDisk() throws -> String { try String(contentsOf: file, encoding: .utf8) }

        /// Buffers opened with `saved` as code_file had it, whose load waits at `gate`.
        @MainActor
        fileprivate func buffers(saved: [String: CodeFileRecord] = [:], gate: Gate, remembered: @escaping @MainActor (String, Bool) -> Void = { _, _ in }) -> CodeBuffers {
            CodeBuffers(lesson: lesson, exercise: code, saved: saved, database: db, workspace: workspace, unsettled: [],
                        goVersion: { await gate.pass(); return "1.27" }, remember: remembered)
        }
    }

    /// The load is slow (Go is still being found); you type meanwhile and leave the lesson.
    /// Leaving waits for the load, then saves what you typed.
    @Test @MainActor func typingDuringASlowLoadIsSavedOnLeaving() async throws {
        let bench = try await Bench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        let gate = Gate()
        let buffers = bench.buffers(gate: gate)
        let main = try #require(buffers.files.first { $0.name == "main.go" })
        let typed = "package main\n\nfunc main() {} // typed while it loaded\n"

        let loading = Task { await buffers.load() }
        await gate.somethingWaits()
        #expect(!buffers.isLoaded)
        main.text = typed
        let leaving = Task { try await buffers.settle(within: nil) }
        for _ in 0..<5 { await Task.yield() }
        #expect(!buffers.isLoaded) // the load is still held, and leaving waits for it
        #expect(try await bench.stored() == nil)

        await gate.open()
        #expect(try await leaving.value.isEmpty)
        await loading.value
        #expect(buffers.isLoaded && main.text == typed && buffers.conflict == nil)
        #expect(try await bench.stored() == typed && bench.onDisk() == typed)
    }

    /// Another editor changed the file in the lesson folder; you typed here before the load
    /// read it. The load keeps your text and offers theirs as the other side of a conflict.
    @Test @MainActor func aLoadLandingAfterTypingNeverOverwritesIt() async throws {
        let bench = try await Bench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        let earlier = CodeFileRecord(name: "main.go", content: "package main // saved\n", updatedAt: Fixtures.ts)
        try await bench.db.saveCode(lesson: bench.lesson.id, files: [earlier])
        try FileManager.default.createDirectory(at: bench.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "package main // theirs\n".write(to: bench.file, atomically: true, encoding: .utf8) // newer than code_file
        let gate = Gate(), remembered = Remembered()
        let buffers = bench.buffers(saved: ["main.go": earlier], gate: gate) { remembered.files[$0] = $1 }
        let main = try #require(buffers.files.first { $0.name == "main.go" })
        #expect(main.text == earlier.content)

        let loading = Task { await buffers.load() }
        await gate.somethingWaits()
        main.text = "package main // mine\n"
        await gate.open()
        await loading.value
        #expect(buffers.isLoaded)
        #expect(main.text == "package main // mine\n") // not overwritten
        #expect(try await bench.stored() == earlier.content && bench.onDisk() == "package main // theirs\n") // neither side written

        // The first save asks which to keep.
        #expect(try await buffers.flush() == false)
        #expect(buffers.conflict == "main.go")
        #expect(try await bench.stored() == earlier.content && bench.onDisk() == "package main // theirs\n")
        #expect(try await buffers.resolveConflict(keepMine: true)?.value == true)
        #expect(buffers.conflict == nil && remembered.files == ["main.go": false])
        #expect(try await bench.stored() == "package main // mine\n" && bench.onDisk() == "package main // mine\n")
    }

    /// Without typing, the load takes in the other editor's newer edit, as before.
    @Test @MainActor func aLoadWithoutTypingTakesInTheFolder() async throws {
        let bench = try await Bench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        let earlier = CodeFileRecord(name: "main.go", content: "package main // saved\n", updatedAt: Fixtures.ts)
        try await bench.db.saveCode(lesson: bench.lesson.id, files: [earlier])
        try FileManager.default.createDirectory(at: bench.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "package main // theirs\n".write(to: bench.file, atomically: true, encoding: .utf8)
        let gate = Gate()
        await gate.open()
        let buffers = bench.buffers(saved: ["main.go": earlier], gate: gate)
        await buffers.load()
        #expect(buffers.isLoaded && buffers.files.first { $0.name == "main.go" }?.text == "package main // theirs\n")
        #expect(try await bench.stored() == "package main // theirs\n")
        #expect(try await buffers.flush() && buffers.conflict == nil)
    }
}
