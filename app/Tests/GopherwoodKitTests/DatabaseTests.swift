import Foundation
import GRDB
import Testing
@testable import GopherwoodKit

@Suite struct DatabaseTests {
    @Test func opensAnyFileNameAndKeepsTheRollbackJournal() async throws {
        let (db, dir) = try Fixtures.database()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try await db.catalog().lessonCount == 8)
        let journal = try await DatabaseQueue(path: dir.appendingPathComponent(Fixtures.libraryName).path).read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
        #expect(journal == "delete")
        let missing = dir.appendingPathComponent("missing.library")
        #expect(throws: AppDatabaseError.missing(path: missing.path)) { try AppDatabase(url: missing) }
        #expect(!FileManager.default.fileExists(atPath: missing.path)) // never created
    }

    @Test func catalogAndNavigation() async throws {
        let (db, dir) = try Fixtures.database()
        defer { try? FileManager.default.removeItem(at: dir) }
        let catalog = try await db.catalog()
        #expect(catalog.courses.map(\.title) == ["Learn Testing", "Build a Thing"])
        #expect(catalog.courses[1].isGuidedProject && !catalog.courses[0].isGuidedProject)
        #expect(catalog.courses[0].chapters.map(\.title) == ["Basics", "More"])
        #expect(catalog.courses[0].chapters[0].lessons.map(\.title) == ["Hello Gopher", "Adding Numbers", "Functions Quiz"])
        #expect(catalog.lessonCount == 8)
        #expect(catalog.courses[1].requiredLessons.isEmpty)
        #expect(catalog.next(after: Fixtures.quizLesson)?.id == Fixtures.cliLesson) // across chapters
        #expect(catalog.previous(before: Fixtures.cliLesson)?.id == Fixtures.quizLesson)
        #expect(catalog.previous(before: Fixtures.codeLesson) == nil)
        #expect(catalog.next(after: Fixtures.interviewLesson)?.id == Fixtures.askingLesson)
        #expect(catalog.next(after: Fixtures.askingLesson) == nil) // not into another course
        #expect(catalog.firstLesson?.id == Fixtures.codeLesson)
    }

    @Test func lessonContentForEveryType() async throws {
        let (db, dir) = try Fixtures.database()
        defer { try? FileManager.default.removeItem(at: dir) }

        let code = try #require(try await db.lesson(Fixtures.codeLesson))
        #expect(code.courseTitle == "Learn Testing" && code.chapterTitle == "Basics" && code.difficulty == 3)
        #expect(code.topics == ["fmt", "printing"])
        guard case .code(let exercise) = code.content else { Issue.record("not a code lesson"); return }
        #expect(exercise.expectedOutput == "Hello, gopher\n2 + 2 = 4\n")
        #expect(exercise.starterFiles.map(\.name) == ["main.go"])

        guard case .codeTests(let tests)? = try await db.lesson(Fixtures.testsLesson)?.content else { Issue.record("tests"); return }
        #expect(tests.expectedOutput == nil)
        #expect(tests.visibleFiles.map(\.name) == ["main.go", "main_test.go"])
        #expect(tests.visibleFiles.filter { !$0.isReadonly }.map(\.name) == ["main.go"])

        guard case .choice(let quiz)? = try await db.lesson(Fixtures.quizLesson)?.content else { Issue.record("quiz"); return }
        #expect(quiz.questions.count == 2)
        #expect(quiz.questions[0].answers == ["`fn`", "`func`", "`def`"])
        #expect(quiz.questions[0].isCorrect("`func`") && !quiz.questions[0].isCorrect("`fn`"))
        #expect(quiz.questions[1].answer == "Yes")

        guard case .cli(let cli)? = try await db.lesson(Fixtures.cliLesson)?.content else { Issue.record("cli"); return }
        #expect(cli.defaultBaseURL == "http://localhost:8080" && !cli.asksForBaseURL)
        #expect(cli.steps.count == 2 && cli.usesBaseURL && cli.hasCommands)
        guard case .command(let c) = cli.steps[0].action, case .http(let h) = cli.steps[1].action else { Issue.record("steps"); return }
        #expect(c.command == "echo built" && c.tests.count == 3 && c.variables == [NameValue("word", "(b\\w+)")])
        if case .stdoutJq(let q, let jsonl, let expected) = c.tests[2] {
            #expect(q == ".ok" && !jsonl && expected == [JqExpectation("==", .bool(true))])
        } else { Issue.record("jq test") }
        #expect(h.method == "POST" && !h.followRedirects && h.headers == [NameValue("X-Trace", "abc")])
        if case .json(let body)? = h.body { #expect(body.contains("ada@example.com")) } else { Issue.record("json body") }
        #expect(h.bodyVariables == [.init(name: "token", jsonPath: ".token")])
        #expect(h.headerVariables == [.init(name: "session", header: "Set-Cookie", regex: "^(session_id=[^;]+)")])
        #expect(h.tests.count == 3)
        if case .jsonValue(let path, let op, let value) = h.tests[1] { #expect(path == ".user.id" && op == "gte" && value == .int(7)) }
        if case .trailersEqual(let k, let v) = h.tests[2] { #expect(k == "X-Sum" && v == "42") }
        #expect(cli.steps[1].sleepAfterMs == 10)

        guard case .githubChecks(let gh)? = try await db.lesson(Fixtures.githubLesson)?.content else { Issue.record("github"); return }
        #expect(gh.steps.map(\.kind) == ["workflow_status", "workflow_logs_contains"])
        #expect(gh.steps[1].summary.contains("staticcheck") && gh.steps[1].summary.contains("Style"))

        guard case .interviewChat(let interview)? = try await db.lesson(Fixtures.interviewLesson)?.content else { Issue.record("interview"); return }
        #expect(interview.studentPrompt == "Explain tracing." && interview.acceptanceCriteria == "Mentions spans.")
        // Format 5: no criteria is NULL, and the answer section shows none.
        guard case .interviewChat(let open)? = try await db.lesson(Fixtures.optionalLesson)?.content else { Issue.record("optional"); return }
        #expect(open.acceptanceCriteria == nil)
        #expect(try await db.lesson("no-such-lesson") == nil)
    }

    @Test func fullTextSearch() async throws {
        let (db, dir) = try Fixtures.database()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hits = try await db.search("greeting")
        #expect(hits.map(\.id) == [Fixtures.codeLesson])
        let found = try await ReadmeTexts().search("greeting", in: db)
        #expect(found.hits == hits)
        #expect(found.snippets[Fixtures.codeLesson]?.contains { $0.matched && $0.text.lowercased() == "greeting" } == true)
        #expect(try await db.search("gre").map(\.id) == [Fixtures.codeLesson]) // the last word is a prefix
        #expect(try await db.search("Gopher").first?.id == Fixtures.codeLesson) // title matches rank first
        #expect(try await db.search("\"quoted\" OR (stuff").isEmpty) // FTS syntax stays literal
        #expect(try await db.search("   ").isEmpty)
    }

    /// The index also holds words a reader never sees: a code block's language, a callout's
    /// marker, a link's address. Search keeps a hit only when its title or its readme as
    /// rendered shows a match, so every hit has a word to point at.
    @Test func searchKeepsOnlyMatchesYouCanSee() async throws {
        let (db, dir) = try Fixtures.database()
        defer { try? FileManager.default.removeItem(at: dir) }
        let readmes = [
            Fixtures.testsLesson: "# Adding Numbers\n\nComplete `add` for the café.\n\n```zig\nconst sum = 1 + 2;\n```",
            // The address names warning three times, so the index ranks this lesson first for it.
            Fixtures.quizLesson: "# Functions Quiz\n\n> [!info]\n> Each answer counts once.\n\nSee [the guide](https://kettle.example.org/warning/warning/warning).",
            Fixtures.cliLesson: "# Your Server\n\n> [!warning]\n> Stop it when you are done.",
        ]
        try await db.dbQueue.write { db in
            for (id, readme) in readmes { try db.execute(sql: "UPDATE lesson SET readme = ? WHERE uuid = ?", arguments: [readme, id]) }
        }
        let texts = ReadmeTexts()
        // A fence's language, a callout's marker (info is drawn as Note), a link's address.
        for word in ["zig", "info", "kettle", "example", "https"] {
            #expect(try await db.search(word).isEmpty == false, "the index holds \(word)")
            #expect(try await texts.search(word, in: db).hits.isEmpty, "\(word) shows nowhere")
        }
        // A callout's title is drawn, so its marker's word is a match you can see; the hit the
        // index ranks first only had it in an address.
        #expect(try await db.search("warning").map(\.id) == [Fixtures.quizLesson, Fixtures.cliLesson])
        let warning = try await texts.search("warning", in: db)
        #expect(warning.hits.map(\.id) == [Fixtures.cliLesson])
        #expect(warning.snippets[Fixtures.cliLesson]?.filter(\.matched).map(\.text) == ["Warning"])
        // Dropped hits leave room for the next best.
        #expect(try await texts.search("warning", in: db, limit: 1).hits.map(\.id) == [Fixtures.cliLesson])
        // The title counts, code counts, and diacritics fold as the index folds them.
        #expect(try await texts.search("quiz", in: db).hits.map(\.id) == [Fixtures.quizLesson])
        #expect(try await texts.search("sum", in: db).hits.map(\.id) == [Fixtures.testsLesson])
        let cafe = try await texts.search("cafe", in: db)
        #expect(cafe.hits.map(\.id) == [Fixtures.testsLesson])
        #expect(cafe.snippets[Fixtures.testsLesson]?.filter(\.matched).map(\.text) == ["café"])
    }

    @Test func studyData() async throws {
        let (db, dir) = try Fixtures.database()
        defer { try? FileManager.default.removeItem(at: dir) }
        let contentBefore = try contentFingerprint(dir)

        try await db.setDone(Fixtures.quizLesson, true, at: "2026-10-31T10:00:00Z")
        try await db.setDone(Fixtures.quizLesson, true, at: "2026-10-31T11:00:00Z") // the first time stays
        try await db.markOpened(Fixtures.codeLesson, at: "2026-10-31T10:05:00Z")
        try await db.markOpened(Fixtures.testsLesson, at: "2026-10-31T10:06:00Z")
        try await db.setDone(Fixtures.testsLesson, true)
        try await db.setDone(Fixtures.testsLesson, false) // keeps the row: it was opened
        try await db.setDone(Fixtures.githubLesson, true)
        try await db.setDone(Fixtures.githubLesson, false) // a row with neither time goes
        #expect(try await db.doneLessons() == [Fixtures.quizLesson])
        #expect(try await db.lastOpenedLesson() == Fixtures.testsLesson)

        try await db.addAttempt(lesson: Fixtures.codeLesson, kind: .run, passed: false, output: "boom", durationMs: 120, at: "2026-10-31T10:00:00Z")
        try await db.addAttempt(lesson: Fixtures.codeLesson, kind: .submit, passed: true, output: "Hello", durationMs: 90, at: "2026-10-31T10:01:00Z")
        try await db.addAttempt(lesson: Fixtures.quizLesson, kind: .answer, passed: true, output: "`func`", durationMs: nil)
        let attempts = try Fixtures.rows(in: dir, "SELECT kind, passed, output, duration_ms FROM attempt WHERE lesson_uuid = ? ORDER BY at DESC", [Fixtures.codeLesson])
        #expect(attempts.map { $0["kind"] as String } == ["submit", "run"]) // newest first
        #expect(attempts[0]["passed"] as Int == 1 && attempts[1]["output"] as String == "boom" && attempts[1]["duration_ms"] as Int? == 120)

        try await db.saveNote(Fixtures.codeLesson, body: "Remember Println.", at: "2026-10-31T10:00:00Z")
        #expect(try await db.note(for: Fixtures.codeLesson) == "Remember Println.")
        // The same text again writes nothing: updated_at stays, and so does the file.
        let modified = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(Fixtures.libraryName).path)[.modificationDate] as? Date
        try await db.saveNote(Fixtures.codeLesson, body: "Remember Println.", at: "2026-10-31T11:00:00Z")
        #expect(try Fixtures.rows(in: dir, "SELECT updated_at FROM note").first?["updated_at"] == "2026-10-31T10:00:00Z")
        #expect(try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(Fixtures.libraryName).path)[.modificationDate] as? Date == modified)
        try await db.saveNote(Fixtures.codeLesson, body: "Remember Printf.", at: "2026-10-31T12:00:00Z")
        #expect(try Fixtures.rows(in: dir, "SELECT updated_at FROM note").first?["updated_at"] == "2026-10-31T12:00:00Z")
        try await db.saveNote(Fixtures.codeLesson, body: "  \n")
        #expect(try await db.note(for: Fixtures.codeLesson) == nil)

        try await db.saveProject(Fixtures.courseID, Project(dir: "/tmp/lantern", baseURL: nil))
        #expect(try await db.project(for: Fixtures.courseID) == Project(dir: "/tmp/lantern", baseURL: nil))
        try await db.saveProject(Fixtures.courseID, Project(dir: "/tmp/lantern", baseURL: "https://lantern.example.com"))
        #expect(try await db.project(for: Fixtures.courseID)?.baseURL == "https://lantern.example.com")
        try await db.saveProject(Fixtures.courseID, Project(dir: "/tmp/lantern", baseURL: " ")) // empty counts as missing
        #expect(try await db.project(for: Fixtures.courseID)?.baseURL == nil)
        // v4: an address without a folder, and with neither the row goes.
        try await db.saveProject(Fixtures.courseID, Project(dir: nil, baseURL: "https://lantern.example.com"))
        #expect(try await db.project(for: Fixtures.courseID) == Project(dir: nil, baseURL: "https://lantern.example.com"))
        try await db.saveProject(Fixtures.courseID, Project(dir: "", baseURL: nil))
        #expect(try await db.project(for: Fixtures.courseID) == nil)

        try await db.setSetting("editor_font_size", "15")
        #expect(try await db.setting("editor_font_size") == "15")

        let v1 = CodeFileRecord(name: "main.go", content: "v1", updatedAt: "2026-10-31T10:00:00Z")
        #expect(try await db.saveCode(lesson: Fixtures.codeLesson, files: [v1]))
        #expect(try await !db.saveCode(lesson: Fixtures.codeLesson, files: [v1])) // unchanged
        #expect(try await db.saveCode(lesson: Fixtures.codeLesson, files: [CodeFileRecord(name: "main.go", content: "v2", updatedAt: Clock.now())]))
        #expect(try await db.codeFiles(for: Fixtures.codeLesson)["main.go"]?.content == "v2")

        // The schema's CHECKs accept only UTC with a Z, and study data must point at a lesson.
        await #expect(throws: DatabaseError.self) { try await db.markOpened(Fixtures.codeLesson, at: "2026-10-31T10:00:00+04:00") }
        await #expect(throws: DatabaseError.self) { try await db.saveNote("no-such-lesson", body: "x") }
        #expect(Clock.now().wholeMatch(of: /\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ/) != nil)

        // The app never wrote a lesson table.
        #expect(try contentFingerprint(dir) == contentBefore)
    }

    /// The lesson tables' contents, to show the app left them alone.
    func contentFingerprint(_ dir: URL) throws -> String {
        let q = try DatabaseQueue(path: dir.appendingPathComponent(Fixtures.libraryName).path, configuration: { var c = Configuration(); c.readonly = true; return c }())
        defer { try? q.close() }
        return try q.read { db in
            var parts: [String] = []
            for table in ["course", "chapter", "lesson", "lesson_topic", "starter_file", "quiz_answer", "cli_step", "cli_http_test", "github_step", "interview_lesson"] {
                parts.append(try String.fetchOne(db, sql: "SELECT \(table == "lesson" ? "count(*) || ':' || sum(length(readme)) || max(synced_at)" : "count(*)") FROM \(table)") ?? "")
            }
            return parts.joined(separator: "/")
        }
    }

    @Test func doneMarksAreObserved() async throws {
        let (db, dir) = try Fixtures.database()
        defer { try? FileManager.default.removeItem(at: dir) }
        var iterator = db.doneLessonUpdates().makeAsyncIterator()
        #expect(try await iterator.next() == [])
        try await db.setDone(Fixtures.codeLesson, true)
        #expect(try await iterator.next() == [Fixtures.codeLesson])
        try await db.setDone(Fixtures.quizLesson, true)
        #expect(try await iterator.next() == [Fixtures.codeLesson, Fixtures.quizLesson])
    }

    @Test func holdingTheFileStillKeepsOtherWritersOut() async throws {
        let (db, dir) = try Fixtures.database()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent(Fixtures.libraryName).path
        let blocked = try await db.holdingFileStill { () -> Bool in
            // Another connection (think sync/) cannot write while git reads the file.
            var config = Configuration()
            config.busyMode = .immediateError
            guard let other = try? DatabaseQueue(path: path, configuration: config) else { return false }
            defer { try? other.close() }
            do {
                try other.write { try $0.execute(sql: "INSERT INTO setting(key, value) VALUES ('x', '1')") }
                return false
            } catch {
                return true
            }
        }
        #expect(blocked)
        // ...and can again afterwards.
        try await db.setSetting("x", "2")
        #expect(try await db.setting("x") == "2")
    }

    @Test func commitMessages() {
        var a = StudyActivity(finished: ["Basic Variables"], finishedCourses: ["Learn Go"], attempts: [.submit: 1], lessonsTried: ["Basic Variables"],
                              coursesTried: ["Learn Go"], notesChanged: 0, codeChanged: 1)
        #expect(a.commitMessage == "Study: finished Basic Variables")
        a.finished = ["A", "B", "C"]
        #expect(a.commitMessage == "Study: finished 3 lessons in Learn Go")
        a.finished = []
        a.attempts = [.run: 4, .submit: 1]
        #expect(a.commitMessage == "Study: 4 runs, 1 submit on Basic Variables")
        a.attempts = [:]
        #expect(a.commitMessage == "Study: code saved")
        a.codeChanged = 0
        #expect(a.commitMessage == "Study: progress saved")
        a.finished = [String(repeating: "Long title ", count: 10)]
        #expect(a.commitMessage.count <= 72)
    }
}

/// v4: where a command-line lesson's ${baseURL} comes from.
@Suite struct ServerAddressTests {
    @Test func baseURLFromTheSuggestionYourAddressOrYourServer() async throws {
        let (db, dir) = try Fixtures.database()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard case .cli(let suggests)? = try await db.lesson(Fixtures.cliLesson)?.content,
              case .cli(let asks)? = try await db.lesson(Fixtures.askingLesson)?.content else { Issue.record("cli lessons"); return }
        #expect(asks.asksForBaseURL && asks.baseURLDefault == nil && asks.defaultBaseURL == nil)

        // A suggested address, until you set yours; "Use Suggested" removes your row.
        #expect(try await db.baseURL(for: suggests, course: Fixtures.courseID) == .suggested("http://localhost:8080", yours: nil))
        try await db.setServerAddress("http://192.168.1.20:8080", for: "http://localhost:8080")
        let replaced = try await db.baseURL(for: suggests, course: Fixtures.courseID)
        #expect(replaced == .suggested("http://localhost:8080", yours: "http://192.168.1.20:8080") && replaced.url == "http://192.168.1.20:8080")
        try await db.setServerAddress("http://localhost:8080", for: "http://localhost:8080") // the suggestion itself
        #expect(try await db.serverAddress(for: "http://localhost:8080") == nil)
        try await db.setServerAddress("http://localhost:9090", for: "http://localhost:8080")
        try await db.setServerAddress(nil, for: "http://localhost:8080")
        #expect(try await db.baseURL(for: suggests, course: Fixtures.courseID).url == "http://localhost:8080")

        // Your own server: missing until the course's project has it; then the project wins.
        let missing = try await db.baseURL(for: asks, course: Fixtures.courseID)
        #expect(missing == .yourServer(nil) && missing.isMissing && missing.url == nil)
        try await db.saveProject(Fixtures.courseID, Project(dir: nil, baseURL: "https://quill.example.com"))
        #expect(try await db.baseURL(for: asks, course: Fixtures.courseID).url == "https://quill.example.com")

        // Neither: no ${baseURL}.
        #expect(BaseURL(lesson: CLILesson(steps: []), projectBaseURL: "https://x.example.com", serverAddress: nil) == .none)
    }
}

/// A quiz: graded answers go into the attempt history, and all right finishes the lesson.
@Suite struct QuizTests {
    @Test func aQuizIsDoneWhenEveryAnswerIsRight() async throws {
        let (db, dir) = try Fixtures.database()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard case .choice(let quiz)? = try await db.lesson(Fixtures.quizLesson)?.content else { Issue.record("quiz"); return }
        var state = QuizState(quiz: quiz)
        let early = state.submit()
        #expect(!state.canSubmit && early.isEmpty)

        // One wrong, one right.
        let picked = [state.pick(0, for: 0), state.pick(0, for: 1), state.pick(9, for: 0)]
        #expect(picked == [true, true, false]) // no answer 9
        let first = state.submit()
        #expect(first == [QuizState.Answer(text: "`fn`", right: false), QuizState.Answer(text: "Yes", right: true)])
        #expect(state.verdicts == [0: false, 1: true] && !state.allCorrect && !state.canSubmit)
        let changedRight = state.pick(1, for: 1)
        #expect(!changedRight) // a right answer stays
        try await db.addAnswers(Fixtures.quizLesson, first, at: "2026-10-31T22:00:00Z")

        // The wrong one again, now right: the quiz is passed and the lesson done.
        let repicked = state.pick(1, for: 0)
        #expect(repicked && state.canSubmit)
        let second = state.submit()
        #expect(second == [QuizState.Answer(text: "`func`", right: true)] && state.allCorrect && !state.canSubmit)
        try await db.addAnswers(Fixtures.quizLesson, second, at: "2026-10-31T23:00:00Z")
        if state.allCorrect { try await db.setDone(Fixtures.quizLesson, true) }
        #expect(try await db.doneLessons() == [Fixtures.quizLesson])

        let attempts = try Fixtures.rows(in: dir, "SELECT kind, passed, output FROM attempt WHERE lesson_uuid = ? ORDER BY at DESC, id DESC", [Fixtures.quizLesson])
        #expect(attempts.map { $0["output"] as String } == ["`func`", "Yes", "`fn`"])
        #expect(attempts.map { $0["passed"] as Int } == [1, 1, 0] && attempts.allSatisfy { $0["kind"] as String == "answer" })
    }
}
