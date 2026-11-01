import Foundation
import GRDB
import Network
import Testing
@testable import GopherwoodKit

/// A library unlike the test fixture, built here from db/schema.sql with made-up lessons: two
/// courses (one a guided project), three chapters, one lesson of every type.
enum KitchenLibrary {
    static let boil = "kitchen-boil-water", salt = "kitchen-measure-salt", acid = "kitchen-which-acid"
    static let oven = "kitchen-check-oven", publish = "garden-publish-plan", explain = "garden-explain-soil"
    static let kitchen = "course-kitchen", garden = "course-garden"

    static let saltTests = """
    package main

    import "testing"

    func TestPinches(t *testing.T) {
    \tfor grams, want := range map[int]int{2: 1, 10: 5} {
    \t\tif got := pinches(grams); got != want {
    \t\t\tt.Errorf("pinches(%d) = %d, want %d", grams, got, want)
    \t\t}
    \t}
    }
    """

    static func build(at url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: String(contentsOf: Fixtures.schemaURL, encoding: .utf8))
            try db.execute(sql: "PRAGMA journal_mode = DELETE")
        }
        try queue.write { db in
            let t = Fixtures.ts
            for (uuid, title, kind, position) in [(kitchen, "Kitchen Chemistry", "Course", 0), (garden, "Garden Planner", "Guided Project", 1)] {
                try db.execute(sql: "INSERT INTO course(uuid, slug, title, kind, short_description, description, position) VALUES (?,?,?,?,?,?,?)",
                               arguments: [uuid, uuid, title, kind, "", "", position])
            }
            for (uuid, course, position, title) in [("kitchen-basics", kitchen, 0, "Basics"), ("kitchen-practice", kitchen, 1, "Practice"),
                                                    ("garden-start", garden, 0, "Start")] {
                try db.execute(sql: "INSERT INTO chapter(uuid, course_uuid, position, slug, title, description) VALUES (?,?,?,?,?,?)",
                               arguments: [uuid, course, position, uuid, title, ""])
            }
            func lesson(_ uuid: String, _ chapter: String, _ position: Int, _ title: String, _ type: String, _ readme: String) throws {
                try db.execute(sql: """
                    INSERT INTO lesson(uuid, chapter_uuid, position, slug, title, type, required, difficulty, readme, created_at, last_mod, synced_at)
                    VALUES (?,?,?,?,?,?,1,4,?,?,?,?)
                    """, arguments: [uuid, chapter, position, uuid, title, type, readme, t, t, t])
            }

            try lesson(boil, "kitchen-basics", 0, "Boil Water", "type_code", "# Boil Water\n\nPrint `bubbles`.")
            try db.execute(sql: "INSERT INTO code_lesson(lesson_uuid, lesson_type, prog_lang, expected_output) VALUES (?,?,?,?)",
                           arguments: [boil, "type_code", "go", "bubbles\n"])
            try db.execute(sql: "INSERT INTO starter_file(lesson_uuid, name, position, content, is_hidden, is_readonly) VALUES (?,?,?,?,0,0)",
                           arguments: [boil, "main.go", 0, "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println(\"bubbles\")\n}\n"])

            try lesson(salt, "kitchen-basics", 1, "Measure Salt", "type_code_tests", "# Measure Salt\n\nA pinch is two grams.")
            try db.execute(sql: "INSERT INTO code_lesson(lesson_uuid, lesson_type, prog_lang) VALUES (?,?,?)", arguments: [salt, "type_code_tests", "go"])
            try db.execute(sql: "INSERT INTO starter_file(lesson_uuid, name, position, content, is_hidden, is_readonly) VALUES (?,?,?,?,0,0)",
                           arguments: [salt, "main.go", 0, "package main\n\nfunc pinches(grams int) int {\n\treturn grams / 2\n}\n"])
            try db.execute(sql: "INSERT INTO starter_file(lesson_uuid, name, position, content, is_hidden, is_readonly) VALUES (?,?,?,?,0,1)",
                           arguments: [salt, "main_test.go", 1, saltTests])

            try lesson(acid, "kitchen-basics", 2, "Which Is an Acid?", "type_choice", "# Which Is an Acid?")
            try db.execute(sql: "INSERT INTO quiz_lesson(lesson_uuid, contains_complete_dir) VALUES (?, 0)", arguments: [acid])
            for (q, question, answers) in [(0, "Which is an acid?", [("Vinegar", 1), ("Baking soda", 0)]), (1, "Does salt dissolve in water?", [("No", 0), ("Yes", 1)])] {
                try db.execute(sql: "INSERT INTO quiz_question(lesson_uuid, position, question) VALUES (?,?,?)", arguments: [acid, q, question])
                for (a, (answer, right)) in answers.enumerated() {
                    try db.execute(sql: "INSERT INTO quiz_answer(lesson_uuid, question_position, position, answer, is_correct) VALUES (?,?,?,?,?)",
                                   arguments: [acid, q, a, answer, right])
                }
            }

            // Command, then two requests: the command's capture fills the first request's URL.
            try lesson(oven, "kitchen-practice", 0, "Check the Oven", "type_cli", "# Check the Oven")
            try db.execute(sql: "INSERT INTO cli_lesson(lesson_uuid, base_url_default, use_agent_prompt, contains_complete_dir) VALUES (?,?,0,0)",
                           arguments: [oven, "http://localhost:8080"])
            try db.execute(sql: "INSERT INTO cli_step(lesson_uuid, position, kind, description, no_penalty_on_fail) VALUES (?,0,'command','Read the dial',0)", arguments: [oven])
            try db.execute(sql: "INSERT INTO cli_command(lesson_uuid, step_position, command) VALUES (?,0,'echo oven at 180')", arguments: [oven])
            try db.execute(sql: "INSERT INTO cli_command_variable(lesson_uuid, step_position, position, name, regex) VALUES (?,0,0,'degrees','at (\\d+)')", arguments: [oven])
            try db.execute(sql: "INSERT INTO cli_command_test(lesson_uuid, step_position, position, kind, exit_code) VALUES (?,0,0,'exit_code',0)", arguments: [oven])
            try db.execute(sql: "INSERT INTO cli_step(lesson_uuid, position, kind, description, no_penalty_on_fail) VALUES (?,1,'http','The oven agrees',0)", arguments: [oven])
            try db.execute(sql: "INSERT INTO cli_http_request(lesson_uuid, step_position, method, full_url, follow_redirects) VALUES (?,1,'GET','${baseURL}/oven/${degrees}',1)",
                           arguments: [oven])
            try db.execute(sql: "INSERT INTO cli_http_test(lesson_uuid, step_position, position, kind, status_code) VALUES (?,1,0,'status_code',200)", arguments: [oven])
            try db.execute(sql: """
                INSERT INTO cli_http_test(lesson_uuid, step_position, position, kind, json_path, json_operator, value_type, int_value)
                VALUES (?,1,1,'json_value','.celsius','eq','int',180)
                """, arguments: [oven])
            try db.execute(sql: "INSERT INTO cli_step(lesson_uuid, position, kind, description, no_penalty_on_fail) VALUES (?,2,'http','Set a timer',0)", arguments: [oven])
            try db.execute(sql: "INSERT INTO cli_http_request(lesson_uuid, step_position, method, full_url, follow_redirects, body_kind, body_json) VALUES (?,2,'POST','${baseURL}/timer',1,'json',?)",
                           arguments: [oven, #"{"minutes": 12, "for": "${degrees}"}"#])
            try db.execute(sql: "INSERT INTO cli_http_test(lesson_uuid, step_position, position, kind, status_code) VALUES (?,2,0,'status_code',201)", arguments: [oven])
            try db.execute(sql: "INSERT INTO cli_http_test(lesson_uuid, step_position, position, kind, text) VALUES (?,2,1,'body_contains','12 minutes at 180')", arguments: [oven])

            try lesson(publish, "garden-start", 0, "Publish the Plan", "type_github_checks", "# Publish the Plan")
            try db.execute(sql: "INSERT INTO github_lesson(lesson_uuid, showcase_repo, contains_complete_dir) VALUES (?,0,0)", arguments: [publish])
            try db.execute(sql: "INSERT INTO github_step(lesson_uuid, position, kind, branch_name) VALUES (?,0,'branch_exists','seedlings')", arguments: [publish])

            try lesson(explain, "garden-start", 1, "Explain the Soil", "type_interview_chat", "# Explain the Soil")
            try db.execute(sql: "INSERT INTO interview_lesson(lesson_uuid, student_prompt, acceptance_criteria) VALUES (?,?,?)",
                           arguments: [explain, "Why does clay hold water?", "Mentions particle size."])
        }
        try queue.close()
    }
}

/// A tiny HTTP/1.1 server on 127.0.0.1 for command-line checks, on Network.framework.
final class LocalServer: @unchecked Sendable {
    typealias Handler = @Sendable (_ method: String, _ path: String, _ body: Data) -> (status: Int, body: String)
    private let listener: NWListener
    let port: UInt16

    init(_ handler: @escaping Handler) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            LocalServer.read(connection, Data(), handler)
        }
        let started = ResumeOnce()
        port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if started.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error): if started.claim() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: .global())
        }
        self.listener = listener
    }

    func stop() { listener.cancel() }

    private static func read(_ connection: NWConnection, _ buffer: Data, _ handler: @escaping Handler) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, done, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let lines = head.components(separatedBy: "\r\n")
                let parts = lines.first?.split(separator: " ").map(String.init) ?? []
                let length = lines.compactMap { line -> Int? in
                    let pair = line.split(separator: ":", maxSplits: 1)
                    return pair.count == 2 && pair[0].lowercased() == "content-length" ? Int(pair[1].trimmingCharacters(in: .whitespaces)) : nil
                }.first ?? 0
                let body = buffer[end.upperBound...]
                if body.count >= length, parts.count >= 2 {
                    let (status, text) = handler(parts[0], parts[1], Data(body.prefix(length)))
                    let payload = Data(text.utf8)
                    let response = "HTTP/1.1 \(status) \(status < 300 ? "OK" : "Not Found")\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(response.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
            }
            if done || error != nil { connection.cancel() } else { read(connection, buffer, handler) }
        }
    }
}

/// Resumes a continuation once, whatever the listener reports after.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// The whole path with a library the app has never seen: open and check it, read every lesson
/// type, grade the quiz, run the command-line checks against a local server, and run the code
/// lessons when Go is here.
@Suite(.serialized) struct LibraryTests {
    @Test func anyLibraryInTheFormatWorks() async throws {
        let dir = try Fixtures.tempDir("kitchen")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("kitchen.gopherwood")
        try KitchenLibrary.build(at: url)

        // Opened through the same open-and-check path as the app's.
        let db = try AppDatabase(url: url)
        let catalog = try await db.catalog()
        #expect(catalog.courses.map(\.title) == ["Kitchen Chemistry", "Garden Planner"])
        #expect(catalog.courses.map(\.isGuidedProject) == [false, true])
        #expect(catalog.courses.flatMap(\.chapters).map(\.title) == ["Basics", "Practice", "Start"])
        #expect(catalog.lessonCount == 6 && catalog.firstLesson?.id == KitchenLibrary.boil)
        #expect(catalog.next(after: KitchenLibrary.acid)?.id == KitchenLibrary.oven)

        // Every type reads back as itself.
        var types: [LessonType] = []
        for summary in catalog.courses.flatMap(\.lessons) {
            let lesson = try #require(try await db.lesson(summary.id))
            types.append(lesson.type)
        }
        #expect(types == [.code, .codeTests, .choice, .cli, .githubChecks, .interview])
        guard case .githubChecks(let checks)? = try await db.lesson(KitchenLibrary.publish)?.content,
              case .interviewChat(let interview)? = try await db.lesson(KitchenLibrary.explain)?.content else { Issue.record("manual lessons"); return }
        #expect(checks.steps.count == 1 && checks.steps[0].summary.contains("seedlings"))
        #expect(interview.studentPrompt == "Why does clay hold water?")

        // The quiz: one wrong, then right; done.
        guard case .choice(let quiz)? = try await db.lesson(KitchenLibrary.acid)?.content else { Issue.record("quiz"); return }
        var state = QuizState(quiz: quiz)
        _ = state.pick(1, for: 0)
        _ = state.pick(1, for: 1)
        let first = state.submit()
        #expect(first.map(\.right) == [false, true] && !state.allCorrect)
        _ = state.pick(0, for: 0)
        let second = state.submit()
        #expect(second.map(\.right) == [true] && state.allCorrect)
        try await db.addAnswers(KitchenLibrary.acid, first + second)
        try await db.setDone(KitchenLibrary.acid, true)
        #expect(try await db.doneLessons() == [KitchenLibrary.acid])

        // The command-line lesson, against a local server standing in for yours.
        guard case .cli(let cli)? = try await db.lesson(KitchenLibrary.oven)?.content else { Issue.record("cli"); return }
        let server = try await LocalServer { method, path, body in
            switch (method, path) {
            case ("GET", "/oven/180"): return (200, #"{"celsius": 180}"#)
            case ("POST", "/timer"):
                let sent = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
                return (201, "\"\(sent?["minutes"] as? Int ?? 0) minutes at \(sent?["for"] as? String ?? "?")\"")
            default: return (404, "{}")
            }
        }
        defer { server.stop() }
        try await db.setServerAddress("http://127.0.0.1:\(server.port)", for: "http://localhost:8080")
        let base = try await db.baseURL(for: cli, course: KitchenLibrary.kitchen)
        #expect(base == .suggested("http://localhost:8080", yours: "http://127.0.0.1:\(server.port)"))
        let run = await CLIChecker(environment: ["PATH": "/usr/bin:/bin"]).run(cli, directory: dir.path, baseURL: base.url)
        #expect(run.status == .passed, "\(run.report)")
        #expect(run.steps.map(\.action) == ["echo oven at 180", "GET http://127.0.0.1:\(server.port)/oven/180", "POST http://127.0.0.1:\(server.port)/timer"])

        // The code lessons, with Go when it is here.
        guard let toolchain = await Fixtures.toolchain() else { return }
        let workspace = Workspace(root: dir.appendingPathComponent("work"))
        for id in [KitchenLibrary.boil, KitchenLibrary.salt] {
            let lesson = try #require(try await db.lesson(id))
            let code = try #require(lesson.code)
            let folder = try workspace.prepare(lesson, code: code, saved: [:], goVersion: toolchain.languageVersion).folder
            let result = await GoRunner(toolchain: toolchain, scratch: workspace.runsFolder).run(code, tests: lesson.type == .codeTests, folder: folder, submit: true)
            #expect(result.status == .passed, "\(lesson.title): \(result.output)")
        }
    }

    @Test func aLessonInAnotherLanguageOpensButDoesNotRun() async throws {
        let dir = try Fixtures.tempDir("python")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("kitchen.gopherwood")
        try KitchenLibrary.build(at: url)
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { try $0.execute(sql: "UPDATE code_lesson SET prog_lang = 'python' WHERE lesson_uuid = ?", arguments: [KitchenLibrary.boil]) }
        try queue.close()
        let db = try AppDatabase(url: url)
        let code = try #require(try await db.lesson(KitchenLibrary.boil)?.code)
        #expect(!code.runsHere && code.otherLanguageNote == "This lesson uses python; Gopherwood runs Go lessons.")
        guard let toolchain = await Fixtures.toolchain() else { return }
        let result = await GoRunner(toolchain: toolchain, scratch: dir.appendingPathComponent(".runs")).run(code, tests: false, folder: dir, submit: true)
        #expect(result.status == .error && result.output == code.otherLanguageNote)
    }
}
