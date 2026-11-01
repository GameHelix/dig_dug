import Foundation
import GRDB

/// Why a library could not be opened or used. The checks and their words are those of the
/// library tool's validator (`go run ./cmd/library check <file>`), so the app and the tool say
/// the same thing about a file.
public enum AppDatabaseError: Error, LocalizedError, Equatable, Sendable {
    case missing(path: String)
    /// macOS refused access: the file sits in a folder it protects (Documents, Desktop, an
    /// external drive) and the learner said no, or file permissions forbid reading it.
    case notPermitted(path: String)
    case unreadable(path: String, detail: String)
    case notLibrary(path: String, applicationID: Int)
    case olderFormat(path: String, version: Int)
    case newerFormat(path: String, version: Int)
    /// quick_check's findings, one line each.
    case damaged(path: String, problems: [String])
    /// The foreign key, per-type row, quiz answer and command-line step checks' findings.
    case failedChecks(path: String, problems: [String])
    case journalMode(path: String, mode: String)
    /// Another program held the file locked for longer than the open waits.
    case busy(path: String)
    case sqlite(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let path): "There is no file at \(path)."
        case .notPermitted, .unreadable, .notLibrary, .olderFormat, .newerFormat, .damaged, .failedChecks, .journalMode, .busy: problems.joined(separator: "\n")
        case .sqlite(let message): message
        }
    }

    /// What is wrong, in the validator's words, one problem per line.
    public var problems: [String] {
        let id = AppDatabase.applicationID, version = AppDatabase.schemaVersion
        return switch self {
        case .missing(let path): ["There is no file at \(path)."]
        case .notPermitted(let path): ["Gopherwood isn't allowed to read \(path)."]
        case .unreadable(_, let detail): ["the file is not an SQLite database SQLite can read: \(detail)"]
        case .notLibrary(_, let found): ["application_id is \(found), not \(id): the file is not a Gopherwood library"]
        case .olderFormat(_, let found): ["user_version is \(found), not \(version): the library is of an older format; migrating brings it up to date"]
        case .newerFormat(_, let found): ["user_version is \(found), not \(version): the library is of a newer format than this program knows"]
        case .damaged(_, let lines), .failedChecks(_, let lines): lines
        case .journalMode(_, let mode): ["the library uses the \(mode) journal and could not switch to the rollback journal"]
        case .busy: ["another program is writing to this library; try again"]
        case .sqlite(let message): [message]
        }
    }

    /// A headline for the error.
    public var title: String {
        switch self {
        case .missing: "Library Not Found"
        case .notPermitted: "No Access to the Library"
        case .unreadable: "Not an SQLite File"
        case .notLibrary: "Not a Gopherwood Library"
        case .olderFormat: "Library Needs Migrating"
        case .newerFormat: "Library Too New"
        case .damaged: "Damaged Library"
        case .failedChecks: "Library Failed Its Checks"
        case .journalMode: "Library in Use"
        case .busy: "Library Busy"
        case .sqlite: "Library Error"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .missing: "Open another library, or put the file back."
        case .notPermitted: "Allow Gopherwood in System Settings › Privacy & Security › Files and Folders, then try again."
        case .unreadable, .notLibrary: "Open a Gopherwood library."
        case .olderFormat(let path, _): "Run go run ./cmd/library migrate \(path), then open it again."
        case .newerFormat: "Update Gopherwood to open it."
        case .damaged: "Restore the file from a backup or from git, or open another library."
        case .failedChecks(let path, _): "Whoever made the library can list the same problems with go run ./cmd/library check \(path)."
        case .journalMode: "Quit other programs that have the library open, then try again."
        case .busy: "Try again when the other program is done with the library."
        case .sqlite: nil
        }
    }
}

/// A library file through one GRDB DatabaseQueue (a DatabasePool would need WAL).
///
/// It opens a file only when it passes the format's checks (docs/library-format.md), run on a
/// read-only connection first, so nothing is written to a file that fails them; it never
/// creates or migrates a file, keeps the rollback journal, and turns on foreign keys. It reads
/// the lesson tables and writes only your tables: progress, attempt, note, code_file, project,
/// server_address and setting. Timestamps are written as ISO 8601 UTC strings (Clock),
/// because GRDB's own date format fails the schema's CHECKs.
public final class AppDatabase: Sendable {
    public static let schemaVersion = 5
    /// 'GPWD'.
    public static let applicationID = 1_196_447_556

    let dbQueue: DatabaseQueue

    /// How long opening waits for another program's lock, as the library tool does.
    static let busyTimeout: TimeInterval = 10

    public init(url: URL) throws(AppDatabaseError) {
        let path = url.path
        if let refused = AppDatabase.access(url) { throw refused }
        try AppDatabase.check(path)
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(AppDatabase.busyTimeout)
        config.label = "Gopherwood"
        config.prepareDatabase { db in
            // The committed file must be whole whenever no write is under way: rollback journal, never WAL.
            let mode = try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE") ?? ""
            if mode.lowercased() != "delete" { throw AppDatabaseError.journalMode(path: path, mode: mode) }
        }
        do {
            dbQueue = try DatabaseQueue(path: path, configuration: config)
        } catch let e as AppDatabaseError {
            throw e
        } catch {
            throw .sqlite("\(error)")
        }
    }

    /// The format's checks, on a read-only connection of their own, waiting up to
    /// `busyTimeout` for another program's lock. A write that was cut short (a hot journal)
    /// is rolled back first, as SQLite does on any read-write open.
    /// Opens the file for reading and closes it again. In a folder macOS protects, this is where
    /// macOS asks the learner for access; the call waits for the answer, however long it takes.
    /// Nil when the file can be read.
    public static func access(_ url: URL) -> AppDatabaseError? {
        let fd = Darwin.open(url.path, O_RDONLY)
        if fd >= 0 {
            Darwin.close(fd)
            return nil
        }
        switch errno {
        case ENOENT, ENOTDIR: return .missing(path: url.path)
        case EPERM, EACCES: return .notPermitted(path: url.path)
        default: return nil // the checks that follow report it in their words
        }
    }

    static func check(_ path: String, busyTimeout: TimeInterval = AppDatabase.busyTimeout) throws(AppDatabaseError) {
        if FileManager.default.fileExists(atPath: path + "-journal") {
            try recover(path, busyTimeout: busyTimeout)
        }
        var result = checkReadOnly(path, busyTimeout: busyTimeout)
        if case .failure(.unreadable(_, let detail)) = result, detail.hasSuffix("(\(ResultCode.SQLITE_READONLY_ROLLBACK.rawValue))") {
            try recover(path, busyTimeout: busyTimeout)
            result = checkReadOnly(path, busyTimeout: busyTimeout)
        }
        try result.get()
    }

    private static func checkReadOnly(_ path: String, busyTimeout: TimeInterval) -> Result<Void, AppDatabaseError> {
        var config = Configuration()
        config.readonly = true
        config.busyMode = .timeout(busyTimeout)
        config.label = "Gopherwood checks"
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: path, configuration: config)
        } catch {
            return .failure(isBusy(error) ? .busy(path: path) : .unreadable(path: path, detail: describe(error)))
        }
        defer { try? queue.close() }
        // Outside a transaction: on a damaged file, ending one would fail too and hide what
        // the checks found.
        var outcome: Result<Void, AppDatabaseError> = .success(())
        queue.inDatabase { db in outcome = AppDatabase.validate(db, path: path) }
        return outcome
    }

    /// Opens the file read-write once, so SQLite rolls back an interrupted write from its hot
    /// journal; a read inside a transaction is enough. A journal another program is still
    /// writing, or one that never became hot, stays where it is.
    private static func recover(_ path: String, busyTimeout: TimeInterval) throws(AppDatabaseError) {
        var config = Configuration()
        config.busyMode = .timeout(busyTimeout)
        config.label = "Gopherwood recovery"
        do {
            let queue = try DatabaseQueue(path: path, configuration: config)
            try queue.read { db in _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_schema") }
            try queue.close()
            if !FileManager.default.fileExists(atPath: path + "-journal") {
                Log.app.notice("Library \(path, privacy: .public): recovered an interrupted write")
            }
        } catch {
            throw isBusy(error) ? .busy(path: path) : .unreadable(path: path, detail: describe(error))
        }
    }

    static func isBusy(_ error: any Error) -> Bool {
        guard let e = error as? DatabaseError else { return false }
        return e.resultCode == .SQLITE_BUSY || e.resultCode == .SQLITE_LOCKED
    }

    /// The library tool's validator (db.Validate), check for check and word for word. After a
    /// wrong header or a damaged file it stops: the other checks would only fail to read it.
    static func validate(_ db: Database, path: String) -> Result<Void, AppDatabaseError> {
        let id: Int, version: Int
        do {
            let row = try Row.fetchOne(db, sql: "SELECT (SELECT application_id FROM pragma_application_id) AS a, (SELECT user_version FROM pragma_user_version) AS v")
            id = row?["a"] ?? 0
            version = row?["v"] ?? 0
        } catch {
            return .failure(isBusy(error) ? .busy(path: path) : .unreadable(path: path, detail: describe(error)))
        }
        if id != applicationID { return .failure(.notLibrary(path: path, applicationID: id)) }
        if version < schemaVersion { return .failure(.olderFormat(path: path, version: version)) }
        if version > schemaVersion { return .failure(.newerFormat(path: path, version: version)) }

        var damage: [String] = []
        do {
            // A cursor, so the lines found before a failure are kept.
            let messages = try String.fetchCursor(db, sql: "SELECT quick_check FROM pragma_quick_check")
            while let message = try messages.next() {
                guard message != "ok" else { continue }
                for line in message.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
                where !line.isEmpty && !line.hasPrefix("*** in database") {
                    damage.append("quick_check: \(line)")
                }
            }
        } catch {
            // A lock is not damage: waiting ran out, so the file is busy, not broken.
            if isBusy(error) { return .failure(.busy(path: path)) }
            damage.append("quick_check: \(describe(error))") // too damaged for the check to finish
        }
        if !damage.isEmpty { return .failure(.damaged(path: path, problems: damage)) }

        var problems: [String] = []
        do {
            for row in try Row.fetchAll(db, sql: #"SELECT "table" AS t, rowid AS r, parent AS p FROM pragma_foreign_key_check ORDER BY 1, 2"#) {
                problems.append("foreign key: \(row["t"] as String) row \(row["r"] as Int64? ?? 0) points at a missing \(row["p"] as String) row")
            }
            let typeTables: [(table: String, types: [String])] = [
                ("code_lesson", ["type_code", "type_code_tests"]), ("quiz_lesson", ["type_choice"]), ("cli_lesson", ["type_cli"]),
                ("github_lesson", ["type_github_checks"]), ("interview_lesson", ["type_interview_chat"]),
            ]
            let counts = typeTables.enumerated().map { "(SELECT count(*) FROM \($1.table) x WHERE x.lesson_uuid = l.uuid) AS n\($0)" }
            for row in try Row.fetchAll(db, sql: "SELECT l.uuid AS uuid, l.type AS type, \(counts.joined(separator: ", ")) FROM lesson l ORDER BY l.uuid") {
                let uuid: String = row["uuid"], type: String = row["type"]
                for (i, t) in typeTables.enumerated() {
                    let want = t.types.contains(type) ? 1 : 0
                    let n: Int = row["n\(i)"]
                    if n != want { problems.append("lesson \(uuid) (\(type)) has \(n) \(t.table) rows, want \(want)") }
                }
            }
            for row in try Row.fetchAll(db, sql: """
                SELECT lesson_uuid, position, n FROM (
                    SELECT q.lesson_uuid, q.position, (SELECT count(*) FROM quiz_answer a
                        WHERE a.lesson_uuid = q.lesson_uuid AND a.question_position = q.position AND a.is_correct = 1) AS n
                    FROM quiz_question q)
                WHERE n <> 1 ORDER BY 1, 2
                """) {
                problems.append("quiz question \(row["position"] as Int) of lesson \(row["lesson_uuid"] as String) has \(row["n"] as Int) right answers, want 1")
            }
            for row in try Row.fetchAll(db, sql: """
                SELECT s.lesson_uuid, s.position, s.kind FROM cli_step s
                WHERE (s.kind = 'command' AND NOT EXISTS (SELECT 1 FROM cli_command c WHERE c.lesson_uuid = s.lesson_uuid AND c.step_position = s.position AND c.step_kind = s.kind))
                   OR (s.kind = 'http' AND NOT EXISTS (SELECT 1 FROM cli_http_request h WHERE h.lesson_uuid = s.lesson_uuid AND h.step_position = s.position AND h.step_kind = s.kind))
                ORDER BY 1, 2
                """) {
                let kind: String = row["kind"]
                let detail = kind == "command" ? "cli_command" : "cli_http_request"
                problems.append("cli_step \(row["position"] as Int) of lesson \(row["lesson_uuid"] as String) (\(kind)) has no \(detail) row")
            }
        } catch {
            if isBusy(error) { return .failure(.busy(path: path)) }
            return .failure(.sqlite("the library's checks could not run: \(describe(error))"))
        }
        return problems.isEmpty ? .success(()) : .failure(.failedChecks(path: path, problems: problems))
    }

    /// SQLite's message and result code, as the library tool shows them: "file is not a
    /// database (26)".
    static func describe(_ error: any Error) -> String {
        guard let e = error as? DatabaseError else { return error.localizedDescription }
        return "\(e.message ?? "SQLite error") (\(e.extendedResultCode.rawValue))"
    }

    /// Closes the file, for a pull that may replace it.
    public func close() throws {
        try dbQueue.close()
    }

    /// Runs `body` while the file holds still: no write of the app is under way (the queue is
    /// held), and a read transaction's shared lock keeps other programs, such as sync/, from
    /// writing until `body` returns. GitSync commits the file from inside.
    public func holdingFileStill<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "BEGIN DEFERRED")
            defer { try? db.execute(sql: "ROLLBACK") }
            _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_schema") // takes the shared lock
            return try body()
        }
    }

    // MARK: Reads

    public func catalog() async throws -> Catalog {
        try await dbQueue.read { db in try AppDatabase.fetchCatalog(db) }
    }

    public func lesson(_ uuid: String) async throws -> LessonDetail? {
        try await dbQueue.read { db in try AppDatabase.fetchLesson(db, uuid) }
    }

    public func search(_ text: String, limit: Int = 60) async throws -> [SearchHit] {
        try await dbQueue.read { db in try AppDatabase.fetchSearch(db, text, limit: limit) }
    }

    /// Lessons' titles and readmes, for search excerpts.
    public func readmes(_ ids: [String]? = nil) async throws -> [(id: String, title: String, readme: String)] {
        try await dbQueue.read { db in
            let rows: [Row]
            if let ids {
                guard !ids.isEmpty else { return [] }
                rows = try Row.fetchAll(db, sql: "SELECT uuid, title, readme FROM lesson WHERE uuid IN (\(ids.map { _ in "?" }.joined(separator: ",")))",
                                        arguments: StatementArguments(ids))
            } else {
                rows = try Row.fetchAll(db, sql: "SELECT uuid, title, readme FROM lesson")
            }
            return rows.map { (id: $0["uuid"], title: $0["title"], readme: $0["readme"]) }
        }
    }

    public func doneLessons() async throws -> Set<String> {
        try await dbQueue.read { db in try AppDatabase.fetchDone(db) }
    }

    public func lastOpenedLesson() async throws -> String? {
        try await dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT lesson_uuid FROM progress WHERE last_opened_at IS NOT NULL ORDER BY last_opened_at DESC LIMIT 1")
        }
    }

    public func note(for lesson: String) async throws -> String? {
        try await dbQueue.read { db in try String.fetchOne(db, sql: "SELECT body FROM note WHERE lesson_uuid = ?", arguments: [lesson]) }
    }

    public func project(for course: String) async throws -> Project? {
        try await dbQueue.read { db in try AppDatabase.fetchProject(db, course) }
    }

    static func fetchProject(_ db: Database, _ course: String) throws -> Project? {
        try Row.fetchOne(db, sql: "SELECT dir, base_url FROM project WHERE course_uuid = ?", arguments: [course]).map {
            Project(dir: $0["dir"], baseURL: $0["base_url"])
        }
    }

    /// Where your server answers instead of an address lessons suggest (server_address).
    public func serverAddress(for suggested: String) async throws -> String? {
        try await dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT url FROM server_address WHERE default_url = ?", arguments: [suggested])
        }
    }

    /// Stores your address for a suggested one; nil, empty or the suggestion itself removes
    /// the row, so the lessons use their suggestion again ("Use Suggested").
    public func setServerAddress(_ url: String?, for suggested: String) async throws {
        let url = url.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty || $0 == suggested ? nil : $0 }
        try await dbQueue.write { db in
            if let url {
                try db.execute(sql: """
                    INSERT INTO server_address(default_url, url) VALUES (?, ?)
                    ON CONFLICT(default_url) DO UPDATE SET url = excluded.url WHERE url IS NOT excluded.url
                    """, arguments: [suggested, url])
            } else {
                try db.execute(sql: "DELETE FROM server_address WHERE default_url = ?", arguments: [suggested])
            }
        }
    }

    /// The address a command-line lesson's ${baseURL} stands for, with where it comes from.
    public func baseURL(for lesson: CLILesson, course: String) async throws -> BaseURL {
        try await dbQueue.read { db in
            let project = lesson.asksForBaseURL ? try AppDatabase.fetchProject(db, course) : nil
            let yours = try lesson.defaultBaseURL.flatMap {
                try String.fetchOne(db, sql: "SELECT url FROM server_address WHERE default_url = ?", arguments: [$0])
            }
            return BaseURL(lesson: lesson, projectBaseURL: project?.baseURL, serverAddress: yours)
        }
    }

    public func codeFiles(for lesson: String) async throws -> [String: CodeFileRecord] {
        try await dbQueue.read { db in try AppDatabase.fetchCode(db, lesson) }
    }

    public func setting(_ key: String) async throws -> String? {
        try await dbQueue.read { db in try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [key]) }
    }

    /// The finished lessons, now and after every change the app makes.
    public func doneLessonUpdates() -> AsyncThrowingStream<Set<String>, Error> {
        let observation = ValueObservation.tracking { db in try AppDatabase.fetchDone(db) }.removeDuplicates()
        let queue = dbQueue
        return AsyncThrowingStream { continuation in
            let cancellable = observation.start(in: queue, scheduling: .async(onQueue: .main),
                                                onError: { continuation.finish(throwing: $0) },
                                                onChange: { continuation.yield($0) })
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }

    // MARK: Writes to your tables

    public func setDone(_ lesson: String, _ done: Bool, at: String = Clock.now()) async throws {
        try await dbQueue.write { db in try AppDatabase.writeDone(db, lesson, done, at: at) }
    }

    public func markOpened(_ lesson: String, at: String = Clock.now()) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO progress(lesson_uuid, last_opened_at) VALUES (?, ?)
                ON CONFLICT(lesson_uuid) DO UPDATE SET last_opened_at = excluded.last_opened_at
                """, arguments: [lesson, at])
        }
    }

    /// Records a quiz submit's graded answers, one attempt each, in one write.
    public func addAnswers(_ lesson: String, _ answers: [QuizState.Answer], at: String = Clock.now()) async throws {
        guard !answers.isEmpty else { return }
        try await dbQueue.write { db in
            for a in answers {
                try db.execute(sql: "INSERT INTO attempt(lesson_uuid, kind, passed, output, duration_ms, at) VALUES (?, ?, ?, ?, NULL, ?)",
                               arguments: [lesson, AttemptKind.answer.rawValue, a.right ? 1 : 0, a.text, at])
            }
        }
    }

    public func addAttempt(lesson: String, kind: AttemptKind, passed: Bool, output: String, durationMs: Int?, at: String = Clock.now()) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "INSERT INTO attempt(lesson_uuid, kind, passed, output, duration_ms, at) VALUES (?, ?, ?, ?, ?, ?)",
                           arguments: [lesson, kind.rawValue, passed ? 1 : 0, output, durationMs.map { max(0, $0) }, at])
        }
    }

    /// Saves a note; an empty one is removed. Saving the same text again changes nothing,
    /// not even updated_at, so the file (and git) sees no change.
    public func saveNote(_ lesson: String, body: String, at: String = Clock.now()) async throws {
        try await dbQueue.write { db in
            if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try db.execute(sql: "DELETE FROM note WHERE lesson_uuid = ?", arguments: [lesson])
            } else {
                try db.execute(sql: """
                    INSERT INTO note(lesson_uuid, body, updated_at) VALUES (?, ?, ?)
                    ON CONFLICT(lesson_uuid) DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at
                    WHERE note.body IS NOT excluded.body
                    """, arguments: [lesson, body, at])
            }
        }
    }

    /// Saves a course's project: the folder its command-line lessons run in, and your own
    /// server's address for the lessons that ask for one. Empty values count as missing; with
    /// both missing the row goes.
    public func saveProject(_ course: String, _ p: Project) async throws {
        func clean(_ s: String?) -> String? { s.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 } }
        let dir = clean(p.dir), base = clean(p.baseURL)
        try await dbQueue.write { db in
            if dir == nil && base == nil {
                try db.execute(sql: "DELETE FROM project WHERE course_uuid = ?", arguments: [course])
            } else {
                try db.execute(sql: """
                    INSERT INTO project(course_uuid, dir, base_url) VALUES (?, ?, ?)
                    ON CONFLICT(course_uuid) DO UPDATE SET dir = excluded.dir, base_url = excluded.base_url
                    WHERE dir IS NOT excluded.dir OR base_url IS NOT excluded.base_url
                    """, arguments: [course, dir, base])
            }
        }
    }

    /// Stores your files; rows that already hold the same content are left alone. Returns
    /// whether anything changed.
    @discardableResult
    public func saveCode(lesson: String, files: [CodeFileRecord]) async throws -> Bool {
        try await dbQueue.write { db in
            var changed = false
            for f in files {
                try db.execute(sql: """
                    INSERT INTO code_file(lesson_uuid, name, content, updated_at) VALUES (?, ?, ?, ?)
                    ON CONFLICT(lesson_uuid, name) DO UPDATE SET content = excluded.content, updated_at = excluded.updated_at
                    WHERE code_file.content IS NOT excluded.content
                    """, arguments: [lesson, f.name, f.content, f.updatedAt])
                changed = changed || db.changesCount > 0
            }
            return changed
        }
    }

    public func setSetting(_ key: String, _ value: String?) async throws {
        try await dbQueue.write { db in
            if let value {
                try db.execute(sql: "INSERT INTO setting(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                               arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM setting WHERE key = ?", arguments: [key])
            }
        }
    }

    /// What changed since a moment, for a commit message.
    public func activity(since: String) async throws -> StudyActivity {
        try await dbQueue.read { db in try AppDatabase.fetchActivity(db, since: since) }
    }

    // MARK: Queries shared by the async methods and the tests

    static func writeDone(_ db: Database, _ lesson: String, _ done: Bool, at: String) throws {
        if done {
            try db.execute(sql: """
                INSERT INTO progress(lesson_uuid, done_at) VALUES (?, ?)
                ON CONFLICT(lesson_uuid) DO UPDATE SET done_at = coalesce(progress.done_at, excluded.done_at)
                """, arguments: [lesson, at])
        } else {
            // A progress row needs done_at or last_opened_at; one that would have neither goes.
            try db.execute(sql: "DELETE FROM progress WHERE lesson_uuid = ? AND last_opened_at IS NULL", arguments: [lesson])
            try db.execute(sql: "UPDATE progress SET done_at = NULL WHERE lesson_uuid = ?", arguments: [lesson])
        }
    }

    static func fetchDone(_ db: Database) throws -> Set<String> {
        Set(try String.fetchAll(db, sql: "SELECT lesson_uuid FROM progress WHERE done_at IS NOT NULL"))
    }

    static func fetchCode(_ db: Database, _ lesson: String) throws -> [String: CodeFileRecord] {
        var out: [String: CodeFileRecord] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT name, content, updated_at FROM code_file WHERE lesson_uuid = ?", arguments: [lesson]) {
            let r = CodeFileRecord(name: row["name"], content: row["content"], updatedAt: row["updated_at"])
            out[r.name] = r
        }
        return out
    }

    static func fetchCatalog(_ db: Database) throws -> Catalog {
        var courses = try Row.fetchAll(db, sql: "SELECT uuid, title, kind FROM course ORDER BY position").map {
            Course(id: $0["uuid"], title: $0["title"], kind: $0["kind"])
        }
        var lessonsByChapter: [String: [LessonSummary]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT uuid, chapter_uuid, title, type, required FROM lesson ORDER BY chapter_uuid, position") {
            guard let type = LessonType(rawValue: row["type"]) else { continue }
            let l = LessonSummary(id: row["uuid"], chapterID: row["chapter_uuid"], title: row["title"], type: type, required: row["required"] as Int != 0)
            lessonsByChapter[l.chapterID, default: []].append(l)
        }
        var chaptersByCourse: [String: [Chapter]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT uuid, course_uuid, title FROM chapter ORDER BY course_uuid, position") {
            var ch = Chapter(id: row["uuid"], courseID: row["course_uuid"], title: row["title"])
            ch.lessons = lessonsByChapter[ch.id] ?? []
            chaptersByCourse[ch.courseID, default: []].append(ch)
        }
        for i in courses.indices { courses[i].chapters = chaptersByCourse[courses[i].id] ?? [] }
        return Catalog(courses: courses)
    }

    static func fetchSearch(_ db: Database, _ text: String, limit: Int) throws -> [SearchHit] {
        guard let match = ftsQuery(text) else { return [] }
        return try Row.fetchAll(db, sql: """
            SELECT l.uuid, l.title, l.type, c.title AS course, ch.title AS chapter
            FROM lesson_search
            JOIN lesson l ON l.id = lesson_search.rowid
            JOIN chapter ch ON ch.uuid = l.chapter_uuid
            JOIN course c ON c.uuid = ch.course_uuid
            WHERE lesson_search MATCH ?
            ORDER BY bm25(lesson_search, 5.0, 1.0), c.position, ch.position, l.position
            LIMIT ?
            """, arguments: [match, limit]).compactMap { row in
            guard let type = LessonType(rawValue: row["type"]) else { return nil }
            return SearchHit(id: row["uuid"], title: row["title"], courseTitle: row["course"], chapterTitle: row["chapter"], type: type)
        }
    }

    /// Turns what someone typed into an FTS5 query: every word must appear, the last one as
    /// a prefix. Quotes keep FTS5 syntax characters literal.
    static func ftsQuery(_ text: String) -> String? {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).map(String.init)
        guard !words.isEmpty else { return nil }
        return words.enumerated().map { i, w in
            "\"" + w.replacingOccurrences(of: "\"", with: "\"\"") + "\"" + (i == words.count - 1 ? "*" : "")
        }.joined(separator: " ")
    }

    static func fetchActivity(_ db: Database, since: String) throws -> StudyActivity {
        let finished = try Row.fetchAll(db, sql: """
            SELECT l.title, c.title AS course FROM progress p
            JOIN lesson l ON l.uuid = p.lesson_uuid JOIN chapter ch ON ch.uuid = l.chapter_uuid JOIN course c ON c.uuid = ch.course_uuid
            WHERE p.done_at >= ? ORDER BY p.done_at
            """, arguments: [since])
        var counts: [AttemptKind: Int] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT kind, count(*) AS n FROM attempt WHERE at >= ? GROUP BY kind", arguments: [since]) {
            if let k = AttemptKind(rawValue: row["kind"]) { counts[k] = row["n"] }
        }
        let tried = try Row.fetchAll(db, sql: """
            SELECT DISTINCT l.title, c.title AS course FROM attempt a
            JOIN lesson l ON l.uuid = a.lesson_uuid JOIN chapter ch ON ch.uuid = l.chapter_uuid JOIN course c ON c.uuid = ch.course_uuid
            WHERE a.at >= ?
            """, arguments: [since])
        let notes = try Int.fetchOne(db, sql: "SELECT count(*) FROM note WHERE updated_at >= ?", arguments: [since]) ?? 0
        let code = try Int.fetchOne(db, sql: "SELECT count(*) FROM code_file WHERE updated_at >= ?", arguments: [since]) ?? 0
        return StudyActivity(finished: finished.map { $0["title"] }, finishedCourses: Set(finished.map { $0["course"] }),
                             attempts: counts, lessonsTried: tried.map { $0["title"] }, coursesTried: Set(tried.map { $0["course"] }),
                             notesChanged: notes, codeChanged: code)
    }
}

// MARK: - Study records

/// What an attempt row records: a Run, a Submit, a quiz answer or a run of the checks.
public enum AttemptKind: String, Sendable, CaseIterable {
    case run, submit, answer, check
}

/// A course's project (the project table): the folder its command-line lessons run in, and
/// the address of your own server for the lessons that ask for one. Either may be missing.
public struct Project: Hashable, Sendable {
    public var dir: String?
    public var baseURL: String?

    public init(dir: String?, baseURL: String?) {
        self.dir = dir
        self.baseURL = baseURL
    }
}

public struct CodeFileRecord: Hashable, Sendable {
    public let name: String
    public let content: String
    public let updatedAt: String

    public init(name: String, content: String, updatedAt: String) {
        self.name = name
        self.content = content
        self.updatedAt = updatedAt
    }
}

/// A summary of study since the last commit.
public struct StudyActivity: Sendable {
    public var finished: [String]
    public var finishedCourses: Set<String>
    public var attempts: [AttemptKind: Int]
    public var lessonsTried: [String]
    public var coursesTried: Set<String>
    public var notesChanged: Int
    public var codeChanged: Int

    public init(finished: [String], finishedCourses: Set<String>, attempts: [AttemptKind: Int], lessonsTried: [String],
                coursesTried: Set<String>, notesChanged: Int, codeChanged: Int) {
        self.finished = finished
        self.finishedCourses = finishedCourses
        self.attempts = attempts
        self.lessonsTried = lessonsTried
        self.coursesTried = coursesTried
        self.notesChanged = notesChanged
        self.codeChanged = codeChanged
    }

    /// A short commit message, "Study: …".
    public var commitMessage: String {
        func list(_ titles: [String]) -> String {
            titles.count == 2 ? "\(titles[0]) and \(titles[1])" : titles.joined(separator: ", ")
        }
        var text: String
        if finished.count == 1 || finished.count == 2 {
            text = "finished " + list(finished)
        } else if finished.count > 2 {
            text = "finished \(finished.count) lessons" + (finishedCourses.count == 1 ? finishedCourses.first.map { " in \($0)" } ?? "" : "")
        } else if !attempts.isEmpty {
            let order: [(AttemptKind, String, String)] = [(.run, "run", "runs"), (.submit, "submit", "submits"),
                                                           (.answer, "quiz answer", "quiz answers"), (.check, "check", "checks")]
            text = order.compactMap { k, one, many in attempts[k].map { "\($0) \($0 == 1 ? one : many)" } }.joined(separator: ", ")
            if lessonsTried.count == 1 { text += " on \(lessonsTried[0])" } else if coursesTried.count == 1, let course = coursesTried.first { text += " in \(course)" }
        } else if codeChanged > 0 || notesChanged > 0 {
            text = [codeChanged > 0 ? "code" : nil, notesChanged > 0 ? "notes" : nil].compactMap { $0 }.joined(separator: " and ") + " saved"
        } else {
            text = "progress saved"
        }
        let message = "Study: " + text
        return message.count > 72 ? String(message.prefix(71)) + "…" : message
    }
}
