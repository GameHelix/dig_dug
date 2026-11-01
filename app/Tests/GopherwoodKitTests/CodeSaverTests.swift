import Foundation
import Testing
@testable import GopherwoodKit

/// Saving code when another editor can change the lesson folder too.
@Suite struct CodeSaverTests {
    @Test func decisions() {
        #expect(CodeSaver.decide(editor: "a", saved: "a", disk: "a") == .nothing)
        #expect(CodeSaver.decide(editor: "b", saved: "a", disk: "a") == .write) // you typed
        #expect(CodeSaver.decide(editor: "a", saved: "a", disk: "c") == .adopt("c")) // another editor changed it
        #expect(CodeSaver.decide(editor: "c", saved: "a", disk: "c") == .adopt("c")) // both made the same change
        #expect(CodeSaver.decide(editor: "b", saved: "a", disk: "c") == .conflict("c")) // both, differently
        #expect(CodeSaver.decide(editor: "a", saved: "a", disk: nil) == .write) // gone from the folder
    }

    @Test func outsideEditsAreTakenInNotOverwritten() async throws {
        let (db, dir) = try Fixtures.database()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let lesson = try await db.lesson(Fixtures.codeLesson), let code = lesson.code else { Issue.record("lesson"); return }
        let workspace = Workspace(root: dir.appendingPathComponent("work"))
        let prepared = try workspace.prepare(lesson, code: code, saved: [:], goVersion: "1.27")
        let file = prepared.folder.appendingPathComponent("main.go")
        let start = try String(contentsOf: file, encoding: .utf8)
        let saver = CodeSaver(database: db, workspace: workspace, lesson: lesson, saved: ["main.go": start])
        func stored() async throws -> String? { try await db.codeFiles(for: lesson.id)["main.go"]?.content }
        func onDisk() throws -> String { try String(contentsOf: file, encoding: .utf8) }

        // You type: code_file and the folder get it.
        #expect(try await saver.sync(["main.go": "mine 1"]) == ["main.go": .saved])
        #expect(try await stored() == "mine 1" && onDisk() == "mine 1")
        #expect(try await saver.sync(["main.go": "mine 1"]) == ["main.go": .unchanged])

        // Another editor saves the file; you type one key here before the app looks: the
        // other editor's version is taken in, not overwritten.
        try "theirs 2".write(to: file, atomically: true, encoding: .utf8)
        #expect(try await saver.sync(["main.go": "mine 1"]) == ["main.go": .adopted("theirs 2")])
        #expect(try await stored() == "theirs 2" && onDisk() == "theirs 2")

        // Both change it: nothing is written until you choose.
        try "theirs 3".write(to: file, atomically: true, encoding: .utf8)
        #expect(try await saver.sync(["main.go": "mine 3"]) == ["main.go": .conflict(disk: "theirs 3")])
        #expect(try await stored() == "theirs 2" && onDisk() == "theirs 3")
        #expect(await saver.conflicts == ["main.go"])
        try await saver.resolve("main.go", .mine("mine 3")) // Keep Mine
        #expect(await saver.conflicts.isEmpty)
        #expect(try await stored() == "mine 3" && onDisk() == "mine 3")
        #expect(try await saver.sync(["main.go": "mine 3"]) == ["main.go": .unchanged])

        try "theirs 4".write(to: file, atomically: true, encoding: .utf8)
        #expect(try await saver.sync(["main.go": "mine 4"]) == ["main.go": .conflict(disk: "theirs 4")])
        #expect(try await saver.resolve("main.go", .disk) == "theirs 4") // Use the File on Disk
        #expect(try await stored() == "theirs 4" && onDisk() == "theirs 4")
        #expect(try await saver.sync(["main.go": "theirs 4"]) == ["main.go": .unchanged])
    }

    @Test func savesLandInOrder() async throws {
        let (db, dir) = try Fixtures.database()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let lesson = try await db.lesson(Fixtures.codeLesson), let code = lesson.code else { Issue.record("lesson"); return }
        let workspace = Workspace(root: dir.appendingPathComponent("work"))
        let prepared = try workspace.prepare(lesson, code: code, saved: [:], goVersion: "1.27")
        let start = try String(contentsOf: prepared.folder.appendingPathComponent("main.go"), encoding: .utf8)
        let saver = CodeSaver(database: db, workspace: workspace, lesson: lesson, saved: ["main.go": start])

        // Idle saves and a run's save at once: each waits for the one before, so none sees a
        // half-written save, nothing counts as a conflict, and code_file and the folder agree.
        let texts = (1...12).map { "typed \($0)" }
        let outcomes = try await withThrowingTaskGroup(of: [String: CodeSaver.Outcome].self) { group in
            for text in texts { group.addTask { try await saver.sync(["main.go": text]) } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(outcomes.count == texts.count && outcomes.allSatisfy { $0["main.go"] == .saved })
        let stored = try await db.codeFiles(for: lesson.id)["main.go"]?.content
        let onDisk = try String(contentsOf: prepared.folder.appendingPathComponent("main.go"), encoding: .utf8)
        #expect(stored == onDisk && texts.contains(onDisk))
        #expect(try await saver.sync(["main.go": onDisk]) == ["main.go": .unchanged])
    }

    /// A saver over a lesson folder with one file, and helpers to read both copies.
    struct Bench {
        let db: AppDatabase
        let dir: URL
        let lesson: LessonDetail
        let workspace: Workspace
        let file: URL

        init() async throws {
            (db, dir) = try Fixtures.database()
            lesson = try #require(try await db.lesson(Fixtures.codeLesson))
            workspace = Workspace(root: dir.appendingPathComponent("work"))
            let prepared = try workspace.prepare(lesson, code: try #require(lesson.code), saved: [:], goVersion: "1.27")
            file = prepared.folder.appendingPathComponent("main.go")
        }

        func saver(unsettled: Set<String> = []) throws -> CodeSaver {
            CodeSaver(database: db, workspace: workspace, lesson: lesson, saved: ["main.go": try onDisk()], unsettled: unsettled)
        }
        func stored() async throws -> String? { try await db.codeFiles(for: lesson.id)["main.go"]?.content }
        func onDisk() throws -> String { try String(contentsOf: file, encoding: .utf8) }
        func otherEditorSaves(_ text: String) throws { try text.write(to: file, atomically: true, encoding: .utf8) }
    }

    /// "Use the File on Disk" takes the file as it is when you choose, not as it was when the
    /// conflict appeared.
    @Test func theFileOnDiskIsReadWhenYouChoose() async throws {
        let bench = try await Bench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        let saver = try bench.saver()
        try bench.otherEditorSaves("theirs D1")
        #expect(try await saver.sync(["main.go": "mine"]) == ["main.go": .conflict(disk: "theirs D1")])
        try bench.otherEditorSaves("theirs D2") // saved again, after the alert came up
        #expect(try await saver.resolve("main.go", .disk) == "theirs D2")
        #expect(try await bench.stored() == "theirs D2" && bench.onDisk() == "theirs D2")

        // And a later save sees the newer file too while the conflict waits.
        try bench.otherEditorSaves("theirs D3")
        #expect(try await saver.sync(["main.go": "mine again"]) == ["main.go": .conflict(disk: "theirs D3")])
        try bench.otherEditorSaves("theirs D4")
        #expect(try await saver.sync(["main.go": "mine again"]) == ["main.go": .conflict(disk: "theirs D4")])
    }

    /// Leaving a lesson waits for your choice; when quitting runs out of time, both versions
    /// are kept and the next open asks again.
    @Test func leavingWaitsForTheChoiceOrKeepsBoth() async throws {
        let bench = try await Bench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        let saver = try bench.saver()
        try bench.otherEditorSaves("theirs")
        _ = try await saver.sync(["main.go": "mine"])

        // A choice made while leaving waits: leaving goes on with it.
        async let settled = saver.waitUntilSettled(within: .seconds(10))
        try await Task.sleep(for: .milliseconds(100))
        try await saver.resolve("main.go", .mine("mine"))
        #expect(await settled)
        #expect(try await bench.stored() == "mine" && bench.onDisk() == "mine")

        // No choice before the limit: both versions stay. Yours is in code_file, theirs on
        // disk, and the file is still in conflict.
        try bench.otherEditorSaves("theirs again")
        _ = try await saver.sync(["main.go": "mine again"])
        #expect(await !saver.waitUntilSettled(within: .milliseconds(200)))
        #expect(try await saver.keepBoth(["main.go": "mine again"]) == ["main.go"])
        #expect(try await bench.stored() == "mine again" && bench.onDisk() == "theirs again")

        // The next session leaves the disk alone, shows yours, and asks again.
        let prepared = try bench.workspace.prepare(bench.lesson, code: try #require(bench.lesson.code),
                                                   saved: try await bench.db.codeFiles(for: bench.lesson.id), goVersion: "1.27", unsettled: ["main.go"])
        #expect(prepared.files.first { $0.name == "main.go" }?.content == "mine again" && prepared.readBack.isEmpty)
        #expect(try bench.onDisk() == "theirs again")
        let next = CodeSaver(database: bench.db, workspace: bench.workspace, lesson: bench.lesson, saved: ["main.go": "mine again"], unsettled: ["main.go"])
        #expect(try await next.sync(["main.go": "mine again"]) == ["main.go": .conflict(disk: "theirs again")])
    }
}
