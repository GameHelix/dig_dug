import Foundation
import GRDB
import Testing
@testable import GopherwoodKit

/// Opening libraries: one at a time, newest wins, and nothing kept from the library before.
@Suite struct OpeningTests {
    @MainActor
    final class Log {
        var lines: [String] = []
        var running = 0
        var most = 0
    }

    @MainActor
    @Test func opensRunOneAtATimeAndTheNewestWins() async {
        let runner = Superseding()
        let log = Log()
        func job(_ name: String) -> @MainActor () async -> Void {
            {
                log.running += 1
                log.most = max(log.most, log.running)
                defer { log.running -= 1 }
                try? await Task.sleep(for: .milliseconds(150))
                log.lines.append(Task.isCancelled ? "\(name) stopped" : "\(name) opened")
            }
        }
        runner.run(job("A"))
        try? await Task.sleep(for: .milliseconds(30))
        runner.run(job("B"))
        runner.run(job("C"))
        await runner.wait()
        #expect(log.lines == ["A stopped", "C opened"], "\(log.lines)") // B never started
        #expect(log.most == 1)
    }

    @Test func theOpenLibraryIsStateNotTheLaunchSetting() {
        let a = URL(fileURLWithPath: "/tmp/a.library"), b = URL(fileURLWithPath: "/tmp/b.library")
        var libraries = OpenLibraries(launch: a, recent: [a])
        libraries.opened(b) // File > Open, though the launch argument still names a
        #expect(libraries.current == b && libraries.recent == [b, a])
        libraries.opened(a)
        #expect(libraries.current == a && libraries.recent == [a, b])
        for i in 0..<12 { libraries.opened(URL(fileURLWithPath: "/tmp/\(i).library")) }
        #expect(libraries.recent.count == OpenLibraries.recentLimit && libraries.recent.first?.lastPathComponent == "11.library")
        libraries.clearRecent()
        #expect(libraries.recent.isEmpty && libraries.current?.lastPathComponent == "11.library")
    }

    /// Lesson ids repeat across libraries and pulls: cleared caches give the new text.
    @Test func cachesForgetTheLibraryBefore() async throws {
        let (db, dir) = try Fixtures.database()
        defer { try? FileManager.default.removeItem(at: dir) }
        let texts = ReadmeTexts(), cache = ReadmeCache()
        let lesson = try #require(try await db.lesson(Fixtures.codeLesson))
        #expect(try await texts.search("greeting", in: db).hits.map(\.id) == [lesson.id])
        _ = await cache.parsed(for: lesson)

        // The same lesson, as another library (or a pull) has it.
        let (other, otherDir) = try Fixtures.database()
        defer { try? FileManager.default.removeItem(at: otherDir) }
        try await other.dbQueue.write { try $0.execute(sql: "UPDATE lesson SET readme = ? WHERE uuid = ?", arguments: ["# Hello Gopher\n\nA new kettle.", Fixtures.codeLesson]) }
        let renewed = try #require(try await other.lesson(Fixtures.codeLesson))

        #expect(try await texts.search("kettle", in: other).hits.isEmpty) // still the old text, which has no kettle
        await texts.clear()
        await cache.clear()
        #expect(try await texts.search("kettle", in: other).snippets[lesson.id]?.contains { $0.matched && $0.text == "kettle" } == true)
        #expect(await cache.parsed(for: renewed).readme == [.paragraph([.text("A new kettle.")])])
    }
}
