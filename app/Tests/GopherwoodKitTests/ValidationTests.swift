import Foundation
import GRDB
import Testing
@testable import GopherwoodKit

/// Each check docs/library-format.md lists refuses a file that breaks it, with the same words
/// as the library tool, and writes nothing to the file.
@Suite struct ValidationTests {
    /// A good library, broken by `change` (run with foreign keys off), then opened.
    func open(_ change: (Database) throws -> Void) throws -> (error: AppDatabaseError?, untouched: Bool) {
        let dir = try Fixtures.tempDir("broken")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(Fixtures.libraryName)
        try Fixtures.makeDatabase(at: url)
        let queue = try DatabaseQueue(path: url.path)
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try change(db)
        }
        try queue.close()
        let before = try Data(contentsOf: url)
        let opened = Result { () throws(AppDatabaseError) in _ = try AppDatabase(url: url) }
        let untouched = try Data(contentsOf: url) == before
        if case .failure(let error) = opened { return (error, untouched) }
        return (nil, untouched)
    }

    func problems(_ change: (Database) throws -> Void) throws -> [String] {
        let (error, untouched) = try open(change)
        #expect(untouched, "a refused file must not be written")
        return error?.problems ?? []
    }

    @Test func header() throws {
        #expect(try problems { try $0.execute(sql: "PRAGMA application_id = 7") }
            == ["application_id is 7, not 1196447556: the file is not a Gopherwood library"])
        // Format 6 (no project.github_repo) is older now.
        #expect(try problems { try $0.execute(sql: "PRAGMA user_version = 6") }
            == ["user_version is 6, not 7: the library is of an older format; migrating brings it up to date"])
        #expect(try problems { try $0.execute(sql: "PRAGMA user_version = 8") }
            == ["user_version is 8, not 7: the library is of a newer format than this program knows"])
        // An older file is to be migrated with the tool; the app never migrates.
        let older = try open { try $0.execute(sql: "PRAGMA user_version = 6") }.error
        #expect(older?.recoverySuggestion?.contains("go run ./cmd/library migrate") == true)
    }

    @Test func notSQLite() throws {
        let dir = try Fixtures.tempDir("text")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("notes.library")
        try String(repeating: "not a database\n", count: 400).write(to: url, atomically: true, encoding: .utf8)
        do {
            _ = try AppDatabase(url: url)
            Issue.record("opened a text file")
        } catch {
            guard case .unreadable = error else { Issue.record("\(error)"); return }
            // The library tool's words, with SQLite's result code.
            #expect(error.problems == ["the file is not an SQLite database SQLite can read: file is not a database (26)"], "\(error.problems)")
        }
    }

    @Test func damage() throws {
        let (big, dir) = try BudgetTests.bigDatabase()
        defer { try? FileManager.default.removeItem(at: dir) }
        try big.close()
        let url = dir.appendingPathComponent(Fixtures.libraryName)
        // Overwrite readme pages near the end, so the header reads but quick_check finds damage.
        let handle = try FileHandle(forWritingTo: url)
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: size / 4 * 3)
        try handle.write(contentsOf: Data(repeating: 0xA5, count: 16384))
        try handle.close()
        do {
            _ = try AppDatabase(url: url)
            Issue.record("opened a damaged file")
        } catch {
            guard case .damaged(_, let lines) = error else { Issue.record("\(error)"); return }
            #expect(!lines.isEmpty && lines.allSatisfy { $0.hasPrefix("quick_check: ") })
        }
    }

    @Test func foreignKeys() throws {
        let found = try problems {
            try $0.execute(sql: "INSERT INTO lesson_topic(lesson_uuid, topic) VALUES ('nowhere', 'ghosts')")
        }
        #expect(found.count == 1 && found[0].hasPrefix("foreign key: lesson_topic row ") && found[0].hasSuffix(" points at a missing lesson row"), "\(found)")
    }

    @Test func oneTypeRowPerLesson() throws {
        #expect(try problems { try $0.execute(sql: "DELETE FROM interview_lesson WHERE lesson_uuid = ?", arguments: [Fixtures.interviewLesson]) }
            == ["lesson \(Fixtures.interviewLesson) (type_interview_chat) has 0 interview_lesson rows, want 1"])
    }

    @Test func oneRightAnswerPerQuestion() throws {
        #expect(try problems { try $0.execute(sql: "UPDATE quiz_answer SET is_correct = 0 WHERE lesson_uuid = ? AND question_position = 1", arguments: [Fixtures.quizLesson]) }
            == ["quiz question 1 of lesson \(Fixtures.quizLesson) has 0 right answers, want 1"])
    }

    @Test func everyStepHasItsDetail() throws {
        // The command goes with its own parts, so only the step itself is left without detail.
        let found = try problems { db in
            for table in ["cli_command_test_text", "cli_command_test_jq_result", "cli_command_test", "cli_command_variable", "cli_command"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE lesson_uuid = ? AND step_position = 0", arguments: [Fixtures.cliLesson])
            }
        }
        #expect(found == ["cli_step 0 of lesson \(Fixtures.cliLesson) (command) has no cli_command row"], "\(found)")
    }

    @Test func everySolutionSolvesAnEditableFile() throws {
        // A solution for the editable main.go passes; one for a file the lesson doesn't have, or
        // for a read-only test file, is refused in the tool's words.
        let found = try problems { db in
            for (lesson, name) in [(Fixtures.codeLesson, "main.go"), (Fixtures.codeLesson, "other.go"), (Fixtures.testsLesson, "main_test.go")] {
                try db.execute(sql: "INSERT INTO solution_file(lesson_uuid, name, content) VALUES (?, ?, ?)", arguments: [lesson, name, "package main\n"])
            }
        }
        #expect(found.sorted() == [
            "solution_file main_test.go of lesson \(Fixtures.testsLesson) solves no editable starter file",
            "solution_file other.go of lesson \(Fixtures.codeLesson) solves no editable starter file",
        ].sorted(), "\(found)")
    }

    @Test func aGoodLibraryPasses() throws {
        let (error, untouched) = try open { _ in }
        #expect(error == nil && untouched)
    }

    /// While another program holds the file locked, opening waits; still locked when waiting
    /// runs out, the library is busy, never damaged or not a database.
    @Test func aLockedLibraryIsBusyNotBroken() async throws {
        let dir = try Fixtures.tempDir("locked")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(Fixtures.libraryName)
        try Fixtures.makeDatabase(at: url)
        // Another program holds the file locked for a while.
        let holder = try DatabaseQueue(path: url.path)
        let holding = Task.detached {
            try await holder.writeWithoutTransaction { db in
                try db.execute(sql: "BEGIN EXCLUSIVE")
                Thread.sleep(forTimeInterval: 1.0)
                try db.execute(sql: "ROLLBACK")
            }
        }
        try await Task.sleep(for: .milliseconds(150))
        do {
            try AppDatabase.check(url.path, busyTimeout: 0.2)
            Issue.record("checked a locked file")
        } catch {
            #expect(error == .busy(path: url.path) && error.problems == ["another program is writing to this library; try again"])
            #expect(error.title == "Library Busy")
        }
        // Waiting longer than the lock lasts: the library opens.
        try AppDatabase.check(url.path, busyTimeout: 5)
        try await holding.value
    }

    /// A write cut short leaves a hot journal; opening rolls it back first, then checks.
    @Test func anInterruptedWriteIsRecovered() throws {
        let dir = try Fixtures.tempDir("interrupted")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(Fixtures.libraryName), copy = dir.appendingPathComponent("interrupted.library")
        try Fixtures.makeDatabase(at: url)
        // Copy the file and its journal in the middle of a write too big for the cache, so part of
        // it has reached the file, as a crash leaves them.
        let writer = try DatabaseQueue(path: url.path)
        try writer.writeWithoutTransaction { db in
            // The system SQLite spills only past 20,000 cached pages unless told otherwise.
            try db.execute(sql: "PRAGMA cache_size = 10")
            try db.execute(sql: "PRAGMA cache_spill = 1")
            try db.execute(sql: "BEGIN IMMEDIATE")
            try db.execute(sql: "CREATE TABLE spill (x BLOB)")
            try db.execute(sql: """
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 6000)
                INSERT INTO spill SELECT randomblob(500) FROM n
                """)
            try FileManager.default.copyItem(at: url, to: copy)
            try FileManager.default.copyItem(atPath: url.path + "-journal", toPath: copy.path + "-journal")
            try db.execute(sql: "ROLLBACK")
        }
        try writer.close()
        #expect(try Data(contentsOf: copy) != Data(contentsOf: url)) // the copy holds part of the write
        _ = try AppDatabase(url: copy)
        #expect(!FileManager.default.fileExists(atPath: copy.path + "-journal"))
        let spill = try DatabaseQueue(path: copy.path).read { try $0.tableExists("spill") }
        #expect(!spill, "the interrupted write is rolled back")
    }

    @Test func accessIsAskedForFirstAndARefusalIsNamed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gopherwood-tests-access-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("library.sqlite")
        try Data("x".utf8).write(to: file)
        #expect(AppDatabase.access(file) == nil)
        #expect(AppDatabase.access(dir.appendingPathComponent("gone.sqlite")) == .missing(path: dir.appendingPathComponent("gone.sqlite").path))

        // File permissions forbid reading: the same refusal macOS gives for a protected folder.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        #expect(AppDatabase.access(file) == .notPermitted(path: file.path))
        #expect(throws: AppDatabaseError.notPermitted(path: file.path)) { try AppDatabase(url: file) }
        #expect(AppDatabaseError.notPermitted(path: file.path).title == "No Access to the Library")
    }
}
