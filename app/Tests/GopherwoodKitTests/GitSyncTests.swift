import Foundation
import GRDB
import Testing
@testable import GopherwoodKit

/// A throwaway clone with a bare remote in $TMPDIR; this repository's git is never touched.
struct ThrowawayRepo {
    let root: URL
    let clone: URL
    let remote: URL
    let env: [String: String]

    init() throws {
        root = try Fixtures.tempDir("git")
        clone = root.appendingPathComponent("clone", isDirectory: true)
        remote = root.appendingPathComponent("remote.git", isDirectory: true)
        env = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
               "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
               "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.invalid"]
        try FileManager.default.createDirectory(at: clone.appendingPathComponent("libraries"), withIntermediateDirectories: true)
        try git(root, "init", "-q", "--bare", "-b", "main", remote.path)
        try git(clone, "init", "-q", "-b", "main")
        try Fixtures.makeDatabase(at: clone.appendingPathComponent("libraries/practice.library"))
        try "*.sqlite-journal\n".write(to: clone.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try git(clone, "add", "-A")
        try git(clone, "commit", "-q", "-m", "Start")
        try git(clone, "remote", "add", "origin", remote.path)
        try git(clone, "push", "-q", "-u", "origin", "main")
    }

    var library: URL { clone.appendingPathComponent("libraries/practice.library") }

    /// The app's way in: the work tree the library sits in.
    func sync(isGitRunning: @escaping @Sendable () async -> Bool = GitSync.gitIsRunning) async throws -> GitSync {
        try #require(await GitSync.locate(library, environment: env, isGitRunning: isGitRunning).sync)
    }

    @discardableResult
    func git(_ dir: URL, _ args: String...) throws -> String {
        let out = ProcessRunner.runBlocking(ProcessRequest(executable: "/usr/bin/git", arguments: ["-C", dir.path] + args, directory: dir.path,
                                                           environment: env, timeout: .seconds(60)))
        guard out.succeeded else { throw GitSyncError.failed("git \(args.joined(separator: " ")): \(out.combined)") }
        return out.stdout
    }
}

@Suite(.serialized) struct GitSyncTests {
    @Test func commitsOnlyTheDatabaseAndPushes() async throws {
        let repo = try ThrowawayRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        let db = try AppDatabase(url: repo.library)
        let sync = try await repo.sync()

        let idle = try await sync.commitAndPush(db) // nothing changed yet
        #expect(idle.commit == .nothing && idle.push == .nothing)

        // Something else is staged: the commit must leave it alone.
        try "notes".write(to: repo.clone.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        try repo.git(repo.clone, "add", "other.txt")

        try await db.setDone(Fixtures.codeLesson, true)
        try await db.addAttempt(lesson: Fixtures.codeLesson, kind: .submit, passed: true, output: "ok", durationMs: 5)
        let pushed = try await sync.commitAndPush(db)
        #expect(pushed.commit == .done("Study: finished Hello Gopher") && pushed.push == .done("Pushed"))
        let files = try repo.git(repo.clone, "show", "--name-only", "--format=", "HEAD")
        #expect(files.trimmingCharacters(in: .whitespacesAndNewlines) == "libraries/practice.library")
        #expect(try repo.git(repo.clone, "diff", "--cached", "--name-only").contains("other.txt")) // still staged, not committed
        #expect(try repo.git(repo.clone, "log", "-1", "--format=%s") == "Study: finished Hello Gopher\n")
        #expect(try repo.git(repo.remote, "log", "-1", "--format=%s", "main") == "Study: finished Hello Gopher\n")
        let again = try await sync.commitAndPush(db)
        #expect(again.push == .nothing)

        // What was committed is the whole file as it is on disk.
        let committed = try repo.git(repo.clone, "cat-file", "-s", "HEAD:libraries/practice.library").trimmingCharacters(in: .whitespacesAndNewlines)
        let size = try FileManager.default.attributesOfItem(atPath: repo.clone.appendingPathComponent("libraries/practice.library").path)[.size] as? NSNumber
        #expect(committed == size?.stringValue)
        #expect(try repo.git(repo.clone, "status", "--porcelain", "--", "libraries/practice.library").isEmpty)
    }

    @Test func pullFastForwardsAndReportsConflicts() async throws {
        let repo = try ThrowawayRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        // Another Mac pushes a new commit.
        let other = repo.root.appendingPathComponent("other", isDirectory: true)
        try repo.git(repo.root, "clone", "-q", repo.remote.path, other.path)
        try "x".write(to: other.appendingPathComponent("NOTE.md"), atomically: true, encoding: .utf8)
        try repo.git(other, "add", "NOTE.md")
        try repo.git(other, "commit", "-q", "-m", "From another Mac")
        try repo.git(other, "push", "-q")

        let sync = try await repo.sync()
        #expect(try await sync.pullFastForward() == .done("Pulled"))
        #expect(FileManager.default.fileExists(atPath: repo.clone.appendingPathComponent("NOTE.md").path))
        #expect(try await sync.pullFastForward() == .nothing)

        // Both sides change: reported, never merged.
        try "y".write(to: other.appendingPathComponent("NOTE.md"), atomically: true, encoding: .utf8)
        try repo.git(other, "commit", "-q", "-am", "Again")
        try repo.git(other, "push", "-q")
        let db = try AppDatabase(url: repo.library)
        try await db.setDone(Fixtures.quizLesson, true)
        await #expect(throws: GitSyncError.self) { try await sync.commitAndPush(db) } // the push is rejected
        do {
            _ = try await sync.pullFastForward()
            Issue.record("a diverged pull should fail")
        } catch {
            if case .conflict = error {} else { Issue.record("expected a conflict, got \(error)") }
        }
        #expect(try repo.git(repo.clone, "status", "--porcelain").isEmpty) // nothing half-merged
    }

    @Test func syncFollowsTheLibraryFile() async throws {
        let repo = try ThrowawayRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        // In a work tree: the top level, and the file's path in it.
        let sync = try await repo.sync()
        #expect(GoRunner.realPath(sync.repository.path) == GoRunner.realPath(repo.clone.path) && sync.file == "libraries/practice.library")

        // Outside one: sync is off, and the library opens all the same.
        let dir = try Fixtures.tempDir("nogit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let loose = dir.appendingPathComponent("loose.library")
        try Fixtures.makeDatabase(at: loose)
        if case .outside = await GitSync.locate(loose, environment: repo.env) {} else { Issue.record("a file outside git") }
        let db = try AppDatabase(url: loose)
        #expect(try await db.catalog().lessonCount > 0)
    }
}

/// The time budgets of docs/architecture.md, on a database the size of the real catalog.
@Suite(.serialized) struct BudgetTests {
    static func bigDatabase() throws -> (AppDatabase, URL) {
        let dir = try Fixtures.tempDir("big")
        let url = dir.appendingPathComponent(Fixtures.libraryName)
        try Fixtures.makeDatabase(at: url)
        let queue = try DatabaseQueue(path: url.path)
        let words = ["goroutine", "channel", "interface", "struct", "pointer", "slice", "map", "closure", "mutex", "context",
                     "handler", "middleware", "json", "token", "cookie", "server", "client", "request", "response", "error"]
        try queue.write { db in
            for c in 0..<13 {
                let course = "bc\(c)"
                try db.execute(sql: "INSERT INTO course(uuid, slug, title, kind, short_description, description, position) VALUES (?,?,?,?,?,?,?)",
                               arguments: [course, "course-\(c)", "Course \(c)", "Course", "", "", c + 10])
                for h in 0..<8 {
                    let chapter = "\(course)h\(h)"
                    try db.execute(sql: "INSERT INTO chapter(uuid, course_uuid, position, slug, title, description) VALUES (?,?,?,?,?,?)",
                                   arguments: [chapter, course, h, "chapter-\(h)", "Chapter \(h)", ""])
                    for l in 0..<7 {
                        var readme = "# Lesson \(c)-\(h)-\(l)\n\n"
                        for p in 0..<12 {
                            readme += (0..<60).map { words[($0 * 7 + p * 3 + l + h + c) % words.count] }.joined(separator: " ") + ".\n\n"
                            if p % 4 == 0 { readme += "```go\nfunc main() {\n\tfmt.Println(\"hi\")\n}\n```\n\n" }
                        }
                        try db.execute(sql: """
                            INSERT INTO lesson(uuid, chapter_uuid, position, slug, title, type, required, difficulty, readme, created_at, last_mod, synced_at)
                            VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                            """, arguments: ["\(chapter)l\(l)", chapter, l, "lesson-\(l)", "Lesson \(words[l + h]) \(c)-\(h)-\(l)", "type_github_checks", 1, 2,
                                             readme, Fixtures.ts, Fixtures.ts, Fixtures.ts])
                        try db.execute(sql: "INSERT INTO github_lesson(lesson_uuid, showcase_repo, contains_complete_dir) VALUES (?,?,?)",
                                       arguments: ["\(chapter)l\(l)", 0, 0])
                    }
                }
            }
        }
        try queue.close()
        return (try AppDatabase(url: url), dir)
    }

    @Test func searchCatalogLessonAndReadmeAreFast() async throws {
        let (db, dir) = try Self.bigDatabase()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = ContinuousClock()
        #expect(try await db.catalog().lessonCount > 700)

        // Search while typing, as the app does it (the readmes' text made when the library
        // opens): each prefix under 50 ms, hits kept only where a match shows, with excerpts.
        let texts = ReadmeTexts()
        try await texts.warm(db)
        var slowest = Duration.zero
        for prefix in ["g", "go", "gor", "goro", "gorou", "goroutine", "goroutine ch", "goroutine channel"] {
            let t = clock.now
            let found = try await texts.search(prefix, in: db)
            slowest = max(slowest, clock.now - t)
            #expect(!found.hits.isEmpty && found.hits.count <= 60, "\(prefix)")
        }
        #expect(slowest < .milliseconds(50), "slowest search \(slowest)")

        // A lesson switch reads the lesson and parses its readme: under 100 ms.
        let t = clock.now
        let lesson = try #require(try await db.lesson("bc5h3l2"))
        _ = Readme.parse(lesson.readme, droppingTitle: lesson.title)
        #expect(clock.now - t < .milliseconds(100), "lesson switch \(clock.now - t)")

        let c = clock.now
        _ = try await db.catalog()
        #expect(clock.now - c < .milliseconds(200), "catalog \(clock.now - c)")
    }
}

/// Git and quitting: steps one at a time, never a killed git, and a stale lock said as such.
@Suite(.serialized) struct GitSafetyTests {
    @Test func syncsAskedForTogetherRunOneAfterAnother() async throws {
        let repo = try ThrowawayRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        let db = try AppDatabase(url: repo.library)
        let sync = try await repo.sync()

        // A sync is under way when the app quits and asks for the last one: the second waits
        // for the first and commits what changed meanwhile, instead of being skipped.
        try await db.setDone(Fixtures.codeLesson, true)
        async let first = sync.commitAndPush(db)
        try await db.setDone(Fixtures.testsLesson, true)
        async let last = sync.commitAndPush(db)
        let (a, b) = try await (first, last)
        #expect(a.push == .done("Pushed"))
        if case .done = a.commit {} else { Issue.record("first sync committed nothing") }
        #expect(try repo.git(repo.clone, "status", "--porcelain", "--", "libraries/practice.library").isEmpty, "the last change is committed too: \(b)")
        #expect(try repo.git(repo.remote, "rev-parse", "main") == repo.git(repo.clone, "rev-parse", "HEAD"))
    }

    @Test func aStaleLockIsReportedAndCanBeRemoved() async throws {
        let repo = try ThrowawayRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        let db = try AppDatabase(url: repo.library)
        let lock = repo.clone.appendingPathComponent(".git/index.lock")
        try Data().write(to: lock) // as a killed git leaves it
        try await db.setDone(Fixtures.codeLesson, true)

        // While some git runs, the lock may be in use: only the plain failure.
        let busy = try await repo.sync(isGitRunning: { true })
        await #expect(throws: GitSyncError.self) { try await busy.commitAndPush(db) }
        do { _ = try await busy.commitAndPush(db) } catch { #expect(error != .staleLock(GoRunner.realPath(lock.path)) && error.localizedDescription.contains("index.lock")) }
        try await busy.removeStaleLock()
        #expect(FileManager.default.fileExists(atPath: lock.path)) // not removed while git may hold it

        // No git running: the error says the lock is stale, and removing it lets the commit through.
        let sync = try await repo.sync(isGitRunning: { false })
        do {
            _ = try await sync.commitAndPush(db)
            Issue.record("committed through a lock file")
        } catch {
            guard case .staleLock(let path) = error else { Issue.record("\(error)"); return }
            #expect(GoRunner.realPath(path) == GoRunner.realPath(lock.path) && error.recoverySuggestion?.contains("Remove") == true)
        }
        try await sync.removeStaleLock()
        #expect(!FileManager.default.fileExists(atPath: lock.path))
        if case .done = try await sync.commitAndPush(db).commit {} else { Issue.record("no commit after removing the lock") }
    }

    @Test func quittingStopsLessonProgramsButNotGit() async throws {
        let env = ["PATH": "/usr/bin:/bin"]
        let git = Task { await ProcessRunner.run(ProcessRequest(executable: "/bin/sleep", arguments: ["1"], directory: "/", environment: env, timeout: .seconds(10), kind: .git)) }
        let lesson = Task { await ProcessRunner.run(ProcessRequest(executable: "/bin/sleep", arguments: ["30"], directory: "/", environment: env, timeout: .seconds(60), kind: ProcessKind("quit-test"))) }
        try await Task.sleep(for: .milliseconds(300))
        ProcessRunner.terminateAll(ProcessKind("quit-test"))
        ProcessRunner.terminateAll(.git) // never stops git
        let stopped = await lesson.value
        #expect(stopped.signal == SIGKILL && stopped.duration < .seconds(10))
        let finished = await git.value
        #expect(finished.exitCode == 0 && finished.signal == 0)
    }

    @Test func aGracePeriodLetsAProgramCleanUp() async {
        let env = ["PATH": "/usr/bin:/bin"]
        // Git removes its lock file on SIGTERM; this program removes its own the same way.
        let tidy = await ProcessRunner.run(ProcessRequest(
            executable: "/bin/sh", arguments: ["-c", "trap 'echo cleaned up; exit 3' TERM; while :; do sleep 0.1; done"],
            directory: "/", environment: env, timeout: .milliseconds(400), gracePeriod: .seconds(5)))
        #expect(tidy.timedOut && tidy.exitCode == 3 && tidy.stdout.contains("cleaned up"), "\(tidy)")
        #expect(tidy.duration < .seconds(4))

        // One that ignores SIGTERM is killed when the grace period ends.
        let stubborn = await ProcessRunner.run(ProcessRequest(
            executable: "/bin/sh", arguments: ["-c", "trap '' TERM; while :; do sleep 0.1; done"],
            directory: "/", environment: env, timeout: .milliseconds(300), gracePeriod: .milliseconds(500)))
        #expect(stubborn.timedOut && stubborn.signal == SIGKILL)
        #expect(stubborn.duration >= .milliseconds(750) && stubborn.duration < .seconds(5), "\(stubborn)")
    }

    /// A library file name is a name, not a pattern: lib[1] never commits lib1.
    @Test func fileNamesAreLiteral() async throws {
        let repo = try ThrowawayRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        let bracketed = repo.clone.appendingPathComponent("libraries/lib[1].library"), plain = repo.clone.appendingPathComponent("libraries/lib1.library")
        try Fixtures.makeDatabase(at: bracketed)
        try Fixtures.makeDatabase(at: plain)
        try repo.git(repo.clone, "add", "-A")
        try repo.git(repo.clone, "commit", "-q", "-m", "Two libraries")
        let db = try AppDatabase(url: bracketed), other = try AppDatabase(url: plain)
        try await db.setDone(Fixtures.codeLesson, true)
        try await other.setDone(Fixtures.quizLesson, true)
        let sync = try #require(await GitSync.locate(bracketed, environment: repo.env).sync)
        #expect(sync.file == "libraries/lib[1].library")
        if case .done = try await sync.commitAndPush(db).commit {} else { Issue.record("no commit") }
        #expect(try repo.git(repo.clone, "show", "--name-only", "--format=", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines) == "libraries/lib[1].library")
        #expect(try repo.git(repo.clone, "status", "--porcelain").contains("lib1.library")) // left alone
    }

    /// A library in a repository that does not track it is not synced.
    @Test func anUntrackedLibraryDoesNotSync() async throws {
        let repo = try ThrowawayRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        let stray = repo.clone.appendingPathComponent("libraries/stray.library")
        try Fixtures.makeDatabase(at: stray)
        if case .untracked = await GitSync.locate(stray, environment: repo.env) {} else { Issue.record("an untracked library") }
        if case .tracked = await GitSync.locate(repo.library, environment: repo.env) {} else { Issue.record("the tracked library") }
    }
}
