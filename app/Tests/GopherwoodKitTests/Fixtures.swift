import Foundation
import GRDB
@testable import GopherwoodKit

/// Test databases made from the repository's db/schema.sql, filled with lessons written for
/// these tests (they only mimic the shape of real lessons). Nothing here touches
/// libraries/practice.library or the repository's git.
enum Fixtures {
    static let schemaURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("db/schema.sql")

    /// A code lesson outside any database, for runs and folders.
    static func codeLesson(_ id: String, _ type: LessonType, _ code: CodeExercise) -> LessonDetail {
        LessonDetail(summary: LessonSummary(id: id, chapterID: "h", title: "Test", type: type, required: true),
                     courseID: "c", courseTitle: "Test Course", chapterTitle: "Chapter",
                     readme: "# Test lesson", difficulty: 1, topics: [], content: type == .code ? .code(code) : .codeTests(code))
    }

    /// A fresh directory under $TMPDIR; the caller removes it.
    static func tempDir(_ name: String = "test") throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gopherwood-tests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(fileURLWithPath: GoRunner.realPath(url.path), isDirectory: true)
    }

    static let ts = "2026-10-01T09:00:00Z"
    /// Test libraries' file name: any name works.
    static let libraryName = "practice.library"
    static let courseID = "c0000000-0000-0000-0000-000000000001"
    static let projectCourseID = "c0000000-0000-0000-0000-000000000002"
    static let chapter1 = "h0000000-0000-0000-0000-000000000001"
    static let chapter2 = "h0000000-0000-0000-0000-000000000002"
    static let chapter3 = "h0000000-0000-0000-0000-000000000003"
    static let codeLesson = "l0000000-0000-0000-0000-000000000001"
    static let testsLesson = "l0000000-0000-0000-0000-000000000002"
    static let quizLesson = "l0000000-0000-0000-0000-000000000003"
    static let cliLesson = "l0000000-0000-0000-0000-000000000004"
    static let githubLesson = "l0000000-0000-0000-0000-000000000005"
    static let interviewLesson = "l0000000-0000-0000-0000-000000000006"
    static let optionalLesson = "l0000000-0000-0000-0000-000000000007"
    /// A command-line lesson that checks a server you deployed: no suggested address.
    static let askingLesson = "l0000000-0000-0000-0000-000000000008"

    static let addTests = """
    package main

    import (
    \t"fmt"
    \t"testing"
    )

    func TestAdd(t *testing.T) {
    \trunCases := [][3]int{{1, 2, 3}, {2, 2, 4}}
    \tsubmitCases := append(runCases, [][3]int{{1000, 1, 1001}}...)
    \tcases := runCases
    \tif withSubmit {
    \t\tcases = submitCases
    \t}
    \tfor _, c := range cases {
    \t\tif got := add(c[0], c[1]); got != c[2] {
    \t\t\tt.Errorf("add(%d, %d) = %d, want %d", c[0], c[1], got, c[2])
    \t\t} else {
    \t\t\tfmt.Printf("add(%d, %d) = %d ok\\n", c[0], c[1], got)
    \t\t}
    \t}
    }

    var withSubmit = true

    """

    static let wasmOnly = """
    //go:build js && wasm

    package main

    func init() { withSubmit = false }

    """

    /// Creates a database from db/schema.sql with lessons of every type.
    static func makeDatabase(at url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: String(contentsOf: schemaURL, encoding: .utf8))
            try db.execute(sql: "PRAGMA journal_mode = DELETE")
        }
        try queue.write { db in
            try db.execute(sql: "INSERT INTO course(uuid, slug, title, kind, short_description, description, position) VALUES (?,?,?,?,?,?,?)",
                           arguments: [courseID, "learn-testing", "Learn Testing", "Course", "Short", "Long", 0])
            try db.execute(sql: "INSERT INTO course(uuid, slug, title, kind, short_description, description, position) VALUES (?,?,?,?,?,?,?)",
                           arguments: [projectCourseID, "build-a-thing", "Build a Thing", "Guided Project", "Short", "Long", 1])
            for (id, course, pos, slug, title) in [(chapter1, courseID, 0, "1-basics", "Basics"), (chapter2, courseID, 1, "2-more", "More"),
                                                   (chapter3, projectCourseID, 0, "1-start", "Start")] {
                try db.execute(sql: "INSERT INTO chapter(uuid, course_uuid, position, slug, title, description) VALUES (?,?,?,?,?,?)",
                               arguments: [id, course, pos, slug, title, ""])
            }
            func lesson(_ id: String, _ chapter: String, _ pos: Int, _ slug: String, _ title: String, _ type: String, _ readme: String, required: Int = 1) throws {
                try db.execute(sql: """
                    INSERT INTO lesson(uuid, chapter_uuid, position, slug, title, type, required, difficulty, readme, created_at, last_mod, synced_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                    """, arguments: [id, chapter, pos, slug, title, type, required, 3, readme, ts, ts, ts])
            }
            try lesson(codeLesson, chapter1, 0, "1-hello", "Hello Gopher", "type_code", "# Hello Gopher\n\nPrint a greeting with `fmt.Println`.")
            try db.execute(sql: "INSERT INTO code_lesson(lesson_uuid, lesson_type, prog_lang, expected_output) VALUES (?,?,?,?)",
                           arguments: [codeLesson, "type_code", "go", "Hello, gopher\n2 + 2 = 4\n"])
            try db.execute(sql: "INSERT INTO starter_file(lesson_uuid, name, position, content, is_hidden, is_readonly) VALUES (?,?,?,?,?,?)",
                           arguments: [codeLesson, "main.go", 0, "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println(\"Hello, world\")\n}\n", 0, 0])
            try db.execute(sql: "INSERT INTO lesson_topic(lesson_uuid, topic) VALUES (?,?)", arguments: [codeLesson, "printing"])
            try db.execute(sql: "INSERT INTO lesson_topic(lesson_uuid, topic) VALUES (?,?)", arguments: [codeLesson, "fmt"])

            try lesson(testsLesson, chapter1, 1, "2-add", "Adding Numbers", "type_code_tests", "# Adding Numbers\n\nComplete `add`.")
            try db.execute(sql: "INSERT INTO code_lesson(lesson_uuid, lesson_type, prog_lang) VALUES (?,?,?)", arguments: [testsLesson, "type_code_tests", "go"])
            for (i, f) in [("main.go", "package main\n\nfunc add(a, b int) int {\n\treturn 0\n}\n", 0, 0),
                           ("main_test.go", addTests, 0, 1), ("main_js_test.go", wasmOnly, 1, 1)].enumerated() {
                try db.execute(sql: "INSERT INTO starter_file(lesson_uuid, name, position, content, is_hidden, is_readonly) VALUES (?,?,?,?,?,?)",
                               arguments: [testsLesson, f.0, i, f.1, f.2, f.3])
            }

            try lesson(quizLesson, chapter1, 2, "3-quiz", "Functions Quiz", "type_choice", "# Functions Quiz\n\nWhich keyword declares a function?")
            try db.execute(sql: "INSERT INTO quiz_lesson(lesson_uuid, contains_complete_dir) VALUES (?,?)", arguments: [quizLesson, 0])
            try db.execute(sql: "INSERT INTO quiz_question(lesson_uuid, position, question) VALUES (?,?,?)", arguments: [quizLesson, 0, "Which keyword declares a function?"])
            for (i, a) in ["`fn`", "`func`", "`def`"].enumerated() {
                try db.execute(sql: "INSERT INTO quiz_answer(lesson_uuid, question_position, position, answer, is_correct) VALUES (?,?,?,?,?)",
                               arguments: [quizLesson, 0, i, a, a == "`func`" ? 1 : 0])
            }
            try db.execute(sql: "INSERT INTO quiz_question(lesson_uuid, position, question) VALUES (?,?,?)", arguments: [quizLesson, 1, "Is Go compiled?"])
            for (i, a) in ["Yes", "No"].enumerated() {
                try db.execute(sql: "INSERT INTO quiz_answer(lesson_uuid, question_position, position, answer, is_correct) VALUES (?,?,?,?,?)",
                               arguments: [quizLesson, 1, i, a, a == "Yes" ? 1 : 0])
            }

            try lesson(cliLesson, chapter2, 0, "1-server", "Your Server", "type_cli", "# Your Server\n\nStart it.")
            try db.execute(sql: "INSERT INTO cli_lesson(lesson_uuid, base_url_default, use_agent_prompt, contains_complete_dir) VALUES (?,?,?,?)",
                           arguments: [cliLesson, "http://localhost:8080", 0, 1])
            try db.execute(sql: "INSERT INTO cli_lesson_os(lesson_uuid, os) VALUES (?,?)", arguments: [cliLesson, "darwin"])
            try db.execute(sql: "INSERT INTO cli_step(lesson_uuid, position, kind, description, no_penalty_on_fail) VALUES (?,?,?,?,?)",
                           arguments: [cliLesson, 0, "command", "Build it", 0])
            try db.execute(sql: "INSERT INTO cli_command(lesson_uuid, step_position, command) VALUES (?,?,?)", arguments: [cliLesson, 0, "echo built"])
            try db.execute(sql: "INSERT INTO cli_command_variable(lesson_uuid, step_position, position, name, regex) VALUES (?,?,?,?,?)",
                           arguments: [cliLesson, 0, 0, "word", "(b\\w+)"])
            try db.execute(sql: "INSERT INTO cli_command_test(lesson_uuid, step_position, position, kind, exit_code) VALUES (?,?,?,?,?)",
                           arguments: [cliLesson, 0, 0, "exit_code", 0])
            try db.execute(sql: "INSERT INTO cli_command_test(lesson_uuid, step_position, position, kind) VALUES (?,?,?,?)",
                           arguments: [cliLesson, 0, 1, "stdout_contains_all"])
            try db.execute(sql: "INSERT INTO cli_command_test_text(lesson_uuid, step_position, test_position, test_kind, position, text) VALUES (?,?,?,?,?,?)",
                           arguments: [cliLesson, 0, 1, "stdout_contains_all", 0, "built"])
            try db.execute(sql: "INSERT INTO cli_command_test(lesson_uuid, step_position, position, kind, jq_query, jq_input) VALUES (?,?,?,?,?,?)",
                           arguments: [cliLesson, 0, 2, "stdout_jq", ".ok", "json"])
            try db.execute(sql: "INSERT INTO cli_command_test_jq_result(lesson_uuid, step_position, test_position, position, operator, value_type, bool_value) VALUES (?,?,?,?,?,?,?)",
                           arguments: [cliLesson, 0, 2, 0, "==", "bool", 1])
            try db.execute(sql: "INSERT INTO cli_step(lesson_uuid, position, kind, description, no_penalty_on_fail, sleep_after_ms) VALUES (?,?,?,?,?,?)",
                           arguments: [cliLesson, 1, "http", "It answers", 1, 10])
            try db.execute(sql: "INSERT INTO cli_http_request(lesson_uuid, step_position, method, full_url, follow_redirects, body_kind, body_json) VALUES (?,?,?,?,?,?,?)",
                           arguments: [cliLesson, 1, "POST", "${baseURL}/api/login", 0, "json", #"{"email":"ada@example.com"}"#])
            try db.execute(sql: "INSERT INTO cli_http_header(lesson_uuid, step_position, position, name, value) VALUES (?,?,?,?,?)",
                           arguments: [cliLesson, 1, 0, "X-Trace", "abc"])
            try db.execute(sql: "INSERT INTO cli_http_body_variable(lesson_uuid, step_position, position, name, json_path) VALUES (?,?,?,?,?)",
                           arguments: [cliLesson, 1, 0, "token", ".token"])
            try db.execute(sql: "INSERT INTO cli_http_header_variable(lesson_uuid, step_position, position, name, header, regex) VALUES (?,?,?,?,?,?)",
                           arguments: [cliLesson, 1, 1, "session", "Set-Cookie", "^(session_id=[^;]+)"])
            try db.execute(sql: "INSERT INTO cli_http_test(lesson_uuid, step_position, position, kind, status_code) VALUES (?,?,?,?,?)",
                           arguments: [cliLesson, 1, 0, "status_code", 200])
            try db.execute(sql: "INSERT INTO cli_http_test(lesson_uuid, step_position, position, kind, json_path, json_operator, value_type, int_value) VALUES (?,?,?,?,?,?,?,?)",
                           arguments: [cliLesson, 1, 1, "json_value", ".user.id", "gte", "int", 7])
            try db.execute(sql: "INSERT INTO cli_http_test(lesson_uuid, step_position, position, kind, field_name, field_value) VALUES (?,?,?,?,?,?)",
                           arguments: [cliLesson, 1, 2, "trailers_equal", "X-Sum", "42"])

            try lesson(githubLesson, chapter2, 1, "2-ci", "CI", "type_github_checks", "# CI\n\nPush it.")
            try db.execute(sql: "INSERT INTO github_lesson(lesson_uuid, showcase_repo, contains_complete_dir) VALUES (?,?,?)", arguments: [githubLesson, 0, 1])
            try db.execute(sql: "INSERT INTO github_step(lesson_uuid, position, kind, workflow_name, workflow_status) VALUES (?,?,?,?,?)",
                           arguments: [githubLesson, 0, "workflow_status", "ci.yml", "success"])
            try db.execute(sql: "INSERT INTO github_step(lesson_uuid, position, kind, workflow_name) VALUES (?,?,?,?)",
                           arguments: [githubLesson, 1, "workflow_logs_contains", "ci.yml"])
            try db.execute(sql: "INSERT INTO github_log_text(lesson_uuid, step_position, job, position, text) VALUES (?,?,?,?,?)",
                           arguments: [githubLesson, 1, "Style", 0, "staticcheck"])

            try lesson(interviewLesson, chapter2, 2, "3-talk", "Explain It", "type_interview_chat", "# Explain It")
            try db.execute(sql: "INSERT INTO interview_lesson(lesson_uuid, student_prompt, acceptance_criteria) VALUES (?,?,?)",
                           arguments: [interviewLesson, "Explain tracing.", "Mentions spans."])

            try lesson(askingLesson, chapter2, 3, "4-deployed", "Your Deployed App", "type_cli", "# Your Deployed App")
            try db.execute(sql: "INSERT INTO cli_lesson(lesson_uuid, base_url_default, asks_for_base_url, use_agent_prompt, contains_complete_dir) VALUES (?,?,?,?,?)",
                           arguments: [askingLesson, nil, 1, 0, 0])
            try db.execute(sql: "INSERT INTO cli_step(lesson_uuid, position, kind, description, no_penalty_on_fail) VALUES (?,?,?,?,?)",
                           arguments: [askingLesson, 0, "http", "It is up", 0])
            try db.execute(sql: "INSERT INTO cli_http_request(lesson_uuid, step_position, method, full_url, follow_redirects) VALUES (?,?,?,?,?)",
                           arguments: [askingLesson, 0, "GET", "${baseURL}/healthz", 1])
            try db.execute(sql: "INSERT INTO cli_http_test(lesson_uuid, step_position, position, kind, status_code) VALUES (?,?,?,?,?)",
                           arguments: [askingLesson, 0, 0, "status_code", 200])

            try lesson(optionalLesson, chapter3, 0, "1-extra", "Extra Credit", "type_interview_chat", "# Extra Credit", required: 0)
            try db.execute(sql: "INSERT INTO interview_lesson(lesson_uuid, student_prompt, acceptance_criteria) VALUES (?,?,NULL)",
                           arguments: [optionalLesson, "Anything."])
        }
        try queue.close()
    }

    /// An AppDatabase over a fresh fixture in its own directory.
    /// Rows of a test database, read on a connection of their own (the app's API has no
    /// reader for these tables).
    static func rows(in dir: URL, _ sql: String, _ arguments: StatementArguments = []) throws -> [Row] {
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: dir.appendingPathComponent(Fixtures.libraryName).path, configuration: config)
        return try queue.read { try Row.fetchAll($0, sql: sql, arguments: arguments) }
    }

    static func database() throws -> (AppDatabase, URL) {
        let dir = try tempDir("db")
        let url = dir.appendingPathComponent(Fixtures.libraryName)
        try makeDatabase(at: url)
        return (try AppDatabase(url: url), dir)
    }

    static func toolchain() async -> Toolchain? {
        let t = await Toolchain.discover(goOverride: nil)
        return t.go == nil ? nil : t
    }
}
