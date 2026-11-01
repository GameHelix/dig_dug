import Foundation
import GRDB

// A lesson and its content, read from the per-type tables of format version 5, in position
// order. The app never writes these tables; sync/ owns them.

extension AppDatabase {
    static func fetchLesson(_ db: Database, _ uuid: String) throws -> LessonDetail? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT l.uuid, l.chapter_uuid, l.title, l.type, l.required, l.readme, l.difficulty,
                   c.uuid AS course_uuid, c.title AS course_title, ch.title AS chapter_title
            FROM lesson l JOIN chapter ch ON ch.uuid = l.chapter_uuid JOIN course c ON c.uuid = ch.course_uuid
            WHERE l.uuid = ?
            """, arguments: [uuid]), let type = LessonType(rawValue: row["type"]) else { return nil }
        let summary = LessonSummary(id: row["uuid"], chapterID: row["chapter_uuid"], title: row["title"], type: type, required: row["required"] as Int != 0)
        let topics = try String.fetchAll(db, sql: "SELECT topic FROM lesson_topic WHERE lesson_uuid = ? ORDER BY topic", arguments: [uuid])
        let content: LessonContent
        switch type {
        case .code: content = .code(try fetchCode(db, lesson: uuid))
        case .codeTests: content = .codeTests(try fetchCode(db, lesson: uuid))
        case .choice: content = .choice(try fetchQuiz(db, uuid))
        case .cli: content = .cli(try fetchCLI(db, uuid))
        case .githubChecks: content = .githubChecks(try fetchGitHub(db, uuid))
        case .interview:
            let r = try Row.fetchOne(db, sql: "SELECT student_prompt, acceptance_criteria FROM interview_lesson WHERE lesson_uuid = ?", arguments: [uuid])
            content = .interviewChat(Interview(studentPrompt: r?["student_prompt"] ?? "", acceptanceCriteria: r?["acceptance_criteria"]))
        }
        return LessonDetail(summary: summary, courseID: row["course_uuid"], courseTitle: row["course_title"], chapterTitle: row["chapter_title"],
                            readme: row["readme"], difficulty: row["difficulty"], topics: topics, content: content)
    }

    static func fetchCode(_ db: Database, lesson uuid: String) throws -> CodeExercise {
        let head = try Row.fetchOne(db, sql: "SELECT prog_lang, expected_output FROM code_lesson WHERE lesson_uuid = ?", arguments: [uuid])
        let files = try Row.fetchAll(db, sql: """
            SELECT name, content, is_hidden, is_readonly FROM starter_file WHERE lesson_uuid = ? ORDER BY position
            """, arguments: [uuid]).map {
            StarterFile(name: $0["name"], content: $0["content"], isHidden: $0["is_hidden"] as Int != 0, isReadonly: $0["is_readonly"] as Int != 0)
        }
        return CodeExercise(progLang: head?["prog_lang"] ?? "go", starterFiles: files, expectedOutput: head?["expected_output"])
    }

    static func fetchQuiz(_ db: Database, _ uuid: String) throws -> Quiz {
        let answers = try Row.fetchAll(db, sql: """
            SELECT question_position, answer, is_correct FROM quiz_answer WHERE lesson_uuid = ? ORDER BY question_position, position
            """, arguments: [uuid])
        let questions = try Row.fetchAll(db, sql: "SELECT position, question FROM quiz_question WHERE lesson_uuid = ? ORDER BY position", arguments: [uuid])
        return Quiz(questions: questions.map { q in
            let position: Int = q["position"]
            let own = answers.filter { ($0["question_position"] as Int) == position }
            return Quiz.Question(question: q["question"], answers: own.map { $0["answer"] },
                                 answer: own.first(where: { ($0["is_correct"] as Int) != 0 }).map { $0["answer"] } ?? "")
        })
    }

    static func typedValue(_ row: Row) -> TypedValue {
        switch row["value_type"] as String? {
        case "bool": .bool((row["bool_value"] as Int?) == 1)
        case "int": .int(row["int_value"] ?? 0)
        default: .string(row["string_value"] ?? "")
        }
    }

    static func fetchCLI(_ db: Database, _ uuid: String) throws -> CLILesson {
        let head = try Row.fetchOne(db, sql: "SELECT base_url_default, asks_for_base_url FROM cli_lesson WHERE lesson_uuid = ?", arguments: [uuid])
        let base: String? = head?["base_url_default"]
        let asks = (head?["asks_for_base_url"] as Int?) == 1

        // Command steps and their parts, by step position.
        var commands: [Int: CLICommand] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT step_position, command, stdout_filter_tmdl FROM cli_command WHERE lesson_uuid = ?", arguments: [uuid]) {
            commands[row["step_position"]] = CLICommand(command: row["command"], stdoutFilterTmdl: row["stdout_filter_tmdl"])
        }
        for row in try Row.fetchAll(db, sql: """
            SELECT step_position, name, regex FROM cli_command_variable WHERE lesson_uuid = ? ORDER BY step_position, position
            """, arguments: [uuid]) {
            commands[row["step_position"]]?.variables.append(NameValue(row["name"], row["regex"]))
        }
        var texts: [String: [String]] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT step_position, test_position, text FROM cli_command_test_text WHERE lesson_uuid = ? ORDER BY step_position, test_position, position
            """, arguments: [uuid]) {
            texts["\(row["step_position"] as Int)/\(row["test_position"] as Int)", default: []].append(row["text"])
        }
        var expectations: [String: [JqExpectation]] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT step_position, test_position, operator, value_type, bool_value, int_value, string_value
            FROM cli_command_test_jq_result WHERE lesson_uuid = ? ORDER BY step_position, test_position, position
            """, arguments: [uuid]) {
            expectations["\(row["step_position"] as Int)/\(row["test_position"] as Int)", default: []]
                .append(JqExpectation(row["operator"], typedValue(row)))
        }
        for row in try Row.fetchAll(db, sql: """
            SELECT step_position, position, kind, exit_code, lines_gt, jq_query, jq_input
            FROM cli_command_test WHERE lesson_uuid = ? ORDER BY step_position, position
            """, arguments: [uuid]) {
            let step: Int = row["step_position"]
            let key = "\(step)/\(row["position"] as Int)"
            let test: CommandTest? = switch row["kind"] as String {
            case "exit_code": .exitCode(row["exit_code"] ?? 0)
            case "stdout_contains_all": .stdoutContainsAll(texts[key] ?? [])
            case "stdout_contains_none": .stdoutContainsNone(texts[key] ?? [])
            case "stdout_lines_gt": .stdoutLinesGT(row["lines_gt"] ?? 0)
            case "stdout_jq": .stdoutJq(query: row["jq_query"] ?? "", jsonl: (row["jq_input"] as String?) == "jsonl", expected: expectations[key] ?? [])
            default: nil
            }
            if let test { commands[step]?.tests.append(test) }
        }

        // HTTP steps and their parts, by step position.
        var requests: [Int: HTTPStep] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT step_position, method, full_url, follow_redirects, basic_auth_username, basic_auth_password, body_kind, body_json
            FROM cli_http_request WHERE lesson_uuid = ?
            """, arguments: [uuid]) {
            var h = HTTPStep(method: row["method"], fullURL: row["full_url"], followRedirects: row["follow_redirects"] as Int != 0)
            if let user: String = row["basic_auth_username"] { h.basicAuth = NameValue(user, row["basic_auth_password"] ?? "") }
            switch row["body_kind"] as String? {
            case "json": h.body = .json(row["body_json"] ?? "null")
            case "form": h.body = .form([])
            default: break
            }
            requests[row["step_position"]] = h
        }
        for row in try Row.fetchAll(db, sql: "SELECT step_position, name, value FROM cli_http_header WHERE lesson_uuid = ? ORDER BY step_position, position", arguments: [uuid]) {
            requests[row["step_position"]]?.headers.append(NameValue(row["name"], row["value"]))
        }
        for row in try Row.fetchAll(db, sql: "SELECT step_position, name, value FROM cli_http_form_field WHERE lesson_uuid = ? ORDER BY step_position, position", arguments: [uuid]) {
            let step: Int = row["step_position"]
            if case .form(var fields)? = requests[step]?.body {
                fields.append(NameValue(row["name"], row["value"]))
                requests[step]?.body = .form(fields)
            }
        }
        for row in try Row.fetchAll(db, sql: """
            SELECT step_position, name, json_path, regex FROM cli_http_body_variable WHERE lesson_uuid = ? ORDER BY step_position, position
            """, arguments: [uuid]) {
            requests[row["step_position"]]?.bodyVariables.append(.init(name: row["name"], jsonPath: row["json_path"], regex: row["regex"]))
        }
        for row in try Row.fetchAll(db, sql: """
            SELECT step_position, name, header, regex FROM cli_http_header_variable WHERE lesson_uuid = ? ORDER BY step_position, position
            """, arguments: [uuid]) {
            requests[row["step_position"]]?.headerVariables.append(.init(name: row["name"], header: row["header"], regex: row["regex"]))
        }
        for row in try Row.fetchAll(db, sql: """
            SELECT step_position, kind, status_code, text, field_name, field_value, json_path, json_operator,
                   value_type, bool_value, int_value, string_value
            FROM cli_http_test WHERE lesson_uuid = ? ORDER BY step_position, position
            """, arguments: [uuid]) {
            let name: String = row["field_name"] ?? ""
            let value: String = row["field_value"] ?? ""
            let test: HTTPTest? = switch row["kind"] as String {
            case "status_code": .statusCode(row["status_code"] ?? 0)
            case "body_contains": .bodyContains(row["text"] ?? "")
            case "body_contains_none": .bodyContainsNone(row["text"] ?? "")
            case "headers_contain": .headersContain(name, value)
            case "headers_equal": .headersEqual(name, value)
            case "trailers_contain": .trailersContain(name, value)
            case "trailers_equal": .trailersEqual(name, value)
            case "json_value": .jsonValue(path: row["json_path"] ?? ".", op: row["json_operator"] ?? "eq", value: typedValue(row))
            default: nil
            }
            if let test { requests[row["step_position"]]?.tests.append(test) }
        }

        let steps = try Row.fetchAll(db, sql: """
            SELECT position, kind, description, sleep_after_ms FROM cli_step WHERE lesson_uuid = ? ORDER BY position
            """, arguments: [uuid]).compactMap { row -> CLIStep? in
            let position: Int = row["position"]
            let action: CLIStep.Action
            switch row["kind"] as String {
            case "command":
                guard let c = commands[position] else { return nil }
                action = .command(c)
            case "http":
                guard let h = requests[position] else { return nil }
                action = .http(h)
            default:
                return nil
            }
            return CLIStep(description: row["description"], sleepAfterMs: row["sleep_after_ms"], action: action)
        }
        return CLILesson(baseURLDefault: base, asksForBaseURL: asks, steps: steps)
    }

    static func fetchGitHub(_ db: Database, _ uuid: String) throws -> GitHubChecks {
        var fileTexts: [Int: [String]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT step_position, text FROM github_file_text WHERE lesson_uuid = ? ORDER BY step_position, position", arguments: [uuid]) {
            fileTexts[row["step_position"], default: []].append(row["text"])
        }
        var logTexts: [Int: [(job: String, text: String)]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT step_position, job, text FROM github_log_text WHERE lesson_uuid = ? ORDER BY step_position, job, position", arguments: [uuid]) {
            logTexts[row["step_position"], default: []].append((row["job"], row["text"]))
        }
        let steps = try Row.fetchAll(db, sql: """
            SELECT position, kind, branch_name, file_path, pr_base_owner, pr_base_repo, pr_base_branch, pr_compare_branch,
                   workflow_name, workflow_status
            FROM github_step WHERE lesson_uuid = ? ORDER BY position
            """, arguments: [uuid]).map { row -> GitHubChecks.Step in
            let position: Int = row["position"]
            let kind: String = row["kind"]
            let quoted = { (s: [String]) in s.map { "“\($0)”" }.joined(separator: ", ") }
            let summary: String
            switch kind {
            case "repo_exists":
                summary = "Your repository exists on GitHub"
            case "submit_repo_for_course":
                summary = "Your repository is linked to the course"
            case "branch_exists":
                summary = "Branch \(row["branch_name"] as String? ?? "") exists"
            case "file_contains":
                summary = "\(row["file_path"] as String? ?? "A file") contains \(quoted(fileTexts[position] ?? []))"
            case "pr_exists":
                let branch: String = row["pr_base_branch"] ?? "main"
                let owner: String? = row["pr_base_owner"]
                let target = owner.map { "\($0)/\(row["pr_base_repo"] as String? ?? ""):\(branch)" } ?? branch
                summary = "A pull request from \(row["pr_compare_branch"] as String? ?? "your branch") into \(target) is open"
            case "workflow_status":
                summary = "The \(row["workflow_name"] as String? ?? "workflow") run ends in \(row["workflow_status"] as String? ?? "success")"
            case "workflow_logs_contains":
                let byJob = Dictionary(grouping: logTexts[position] ?? [], by: \.job)
                let parts = byJob.sorted { $0.key < $1.key }.map { job, texts in "the \(job) job's log shows \(quoted(texts.map(\.text)))" }
                summary = "In the \(row["workflow_name"] as String? ?? "workflow") run, " + (parts.isEmpty ? "the logs match" : parts.joined(separator: "; "))
            default:
                summary = kind.replacingOccurrences(of: "_", with: " ")
            }
            return GitHubChecks.Step(kind: kind, summary: summary)
        }
        return GitHubChecks(steps: steps)
    }
}
