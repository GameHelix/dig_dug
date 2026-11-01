import Foundation
import Testing
@testable import GopherwoodKit

/// Stands in for the app's banner: what reaches it, and what stayed silent.
@MainActor private final class Banner {
    var shown: [String] = []
    var silent = 0
    var results: [String] = []

    func report(_ error: any Error) {
        if Reporting.isSilent(error) { silent += 1 } else { shown.append("\(error)") }
    }
}

/// Work is cancelled whenever something newer replaces it. What it throws on the way out is
/// never shown, and what it was saving still lands.
@Suite struct CancellationTests {
    private struct Broken: Error {}

    @Test func whatStaysSilent() async {
        #expect(Reporting.isSilent(CancellationError()))
        #expect(!Reporting.isSilent(Broken()))
        // Anything thrown in a cancelled task, whatever its type.
        let cancelled = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            return Reporting.isSilent(Broken())
        }
        #expect(await cancelled.value)
    }

    /// Typing a search a key at a time and switching lessons as fast: each task cancels the
    /// one before, as the app's search and lesson switch do. Nothing reaches the banner, and
    /// the newest task still finishes.
    @Test @MainActor func rapidCancellationNeverReports() async throws {
        let (db, dir) = try Fixtures.database()
        defer { try? FileManager.default.removeItem(at: dir) }
        let texts = ReadmeTexts(), banner = Banner()
        let query = "greeting"
        var task: Task<Void, Never>?
        for round in 0..<2 {
            for typed in query.indices.map({ String(query[...$0]) }) {
                task?.cancel()
                task = Task { @MainActor in
                    do {
                        let found = try await texts.search(typed, in: db)
                        _ = try await db.lesson(Fixtures.codeLesson)
                        _ = try await db.note(for: Fixtures.codeLesson)
                        _ = try await db.codeFiles(for: Fixtures.codeLesson)
                        try await db.markOpened(Fixtures.codeLesson)
                        guard !Task.isCancelled else { return }
                        banner.results = found.hits.map(\.id)
                    } catch {
                        banner.report(error)
                    }
                }
                // The first round cancels each task before it starts; the second lets it
                // start, so some stop part way, inside a query.
                if round == 1 { await Task.yield() }
            }
        }
        await task?.value
        #expect(banner.shown.isEmpty, "\(banner.shown)")
        #expect(banner.silent >= query.count) // the cancellations happened
        #expect(banner.results == [Fixtures.codeLesson]) // the newest search finished
    }

    /// In a cancelled task the database refuses to write, so leaving a lesson saves in a task
    /// of its own, which a newer lesson or library cancelling the caller does not stop.
    @Test func savingOutlivesACancelledCaller() async throws {
        let (db, dir) = try Fixtures.database()
        defer { try? FileManager.default.removeItem(at: dir) }
        let caller = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            let refused = (try? await db.saveNote(Fixtures.codeLesson, body: "lost")) == nil
            await Task { try? await db.saveNote(Fixtures.codeLesson, body: "kept") }.value
            return refused
        }
        #expect(await caller.value)
        #expect(try await db.note(for: Fixtures.codeLesson) == "kept")
    }
}
