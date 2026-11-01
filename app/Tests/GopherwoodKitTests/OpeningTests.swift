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
        /// Holds a job until the test lets it end.
        var release: CheckedContinuation<Void, Never>?
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

    /// A push asked for while one runs is not dropped: it runs once more when that one ends,
    /// so a commit made meanwhile goes too.
    @MainActor
    @Test func aRequestWhileItRunsRunsOnceMoreAfter() async {
        let pushes = Coalescing()
        let log = Log()
        let first = Task { @MainActor in
            await pushes.run {
                log.lines.append("first")
                await withCheckedContinuation { log.release = $0 }
            }
        }
        while log.release == nil { await Task.yield() }
        #expect(pushes.isRunning)
        await pushes.run { log.lines.append("second") } // remembered, not run yet
        await pushes.run { log.lines.append("third") } // the newest of those waiting
        #expect(log.lines == ["first"])
        log.release?.resume()
        await first.value
        #expect(log.lines == ["first", "third"], "\(log.lines)")
        #expect(!pushes.isRunning)
        await pushes.run { log.lines.append("later") } // nothing running: at once
        #expect(log.lines == ["first", "third", "later"])
    }

    @Test func aSecondLaunchHandsOverToTheCopyAlreadyRunning() {
        let id = "io.github.jobloom.Gopherwood", early = Date(timeIntervalSince1970: 1_800_000_000)
        let installed = SingleInstance.App(pid: 500, bundleID: id, launched: early)
        let built = SingleInstance.App(pid: 900, bundleID: id, launched: early.addingTimeInterval(60))
        let qa = SingleInstance.App(pid: 700, bundleID: "io.github.jobloom.GopherwoodQA", launched: early)
        // Alone, or beside other apps and a QA copy, a launch goes on.
        #expect(SingleInstance.handOver(from: installed, running: [installed]) == nil)
        #expect(SingleInstance.handOver(from: built, running: [qa, built]) == nil)
        #expect(SingleInstance.handOver(from: qa, running: [installed, qa]) == nil)
        // A second copy of the same app hands over to the first, wherever either one lives.
        #expect(SingleInstance.handOver(from: built, running: [installed, built]) == installed)
        #expect(SingleInstance.handOver(from: installed, running: [installed, built]) == nil)
        // One that is quitting is not handed to.
        let quitting = SingleInstance.App(pid: 500, bundleID: id, launched: early, isTerminated: true)
        #expect(SingleInstance.handOver(from: built, running: [quitting, built]) == nil)
        // Two launched together: exactly one stays.
        let twin = SingleInstance.App(pid: 901, bundleID: id, launched: built.launched)
        #expect(SingleInstance.handOver(from: built, running: [built, twin]) == nil)
        #expect(SingleInstance.handOver(from: twin, running: [built, twin]) == built)
        // An app without a bundle id, such as a bare binary, is never stopped.
        #expect(SingleInstance.handOver(from: SingleInstance.App(pid: 1, bundleID: nil, launched: nil), running: [installed]) == nil)
    }
}
