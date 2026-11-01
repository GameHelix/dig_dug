import Foundation
import GRDB

// What the solutions repository needs from the library: where each Go code lesson's solution
// goes, and the done lessons whose saved code can be added as earlier solutions.

extension AppDatabase {
    /// Every Go code lesson (type_code and type_code_tests) in the catalog's order, with what
    /// its solution's folder and README row are made of.
    public func solutionPlaces() async throws -> [SolutionPlace] {
        try await dbQueue.read { db in try AppDatabase.fetchSolutionPlaces(db) }
    }

    /// Done Go code lessons that have code you saved, oldest first, each as a solution dated
    /// when you finished it (progress.done_at).
    public func earlierSolutions() async throws -> [Solution] {
        try await dbQueue.read { db in
            let places = Dictionary(try AppDatabase.fetchSolutionPlaces(db).map { ($0.lessonID, $0) }, uniquingKeysWith: { first, _ in first })
            var solutions: [Solution] = []
            for row in try Row.fetchAll(db, sql: """
                SELECT p.lesson_uuid, p.done_at FROM progress p
                WHERE p.done_at IS NOT NULL AND EXISTS (SELECT 1 FROM code_file f WHERE f.lesson_uuid = p.lesson_uuid)
                ORDER BY p.done_at, p.lesson_uuid
                """) {
                let id: String = row["lesson_uuid"]
                guard let place = places[id], let date = Clock.date(row["done_at"]) else { continue }
                let files = try AppDatabase.fetchEditableFiles(db, id)
                if !files.isEmpty { solutions.append(Solution(place: place, files: files, date: date)) }
            }
            return solutions
        }
    }

    static func fetchSolutionPlaces(_ db: Database) throws -> [SolutionPlace] {
        try Row.fetchAll(db, sql: """
            SELECT l.uuid, l.title, l.slug, l.position, ch.title AS chapter_title, ch.slug AS chapter_slug, ch.position AS chapter_position,
                   c.title AS course_title, c.slug AS course_slug
            FROM lesson l JOIN code_lesson k ON k.lesson_uuid = l.uuid
            JOIN chapter ch ON ch.uuid = l.chapter_uuid JOIN course c ON c.uuid = ch.course_uuid
            WHERE k.prog_lang = 'go'
            ORDER BY c.position, ch.position, l.position
            """).map {
            SolutionPlace(lessonID: $0["uuid"], lessonTitle: $0["title"], chapterTitle: $0["chapter_title"], courseTitle: $0["course_title"],
                          courseSlug: $0["course_slug"], chapterPosition: $0["chapter_position"], chapterSlug: $0["chapter_slug"],
                          lessonPosition: $0["position"], lessonSlug: $0["slug"])
        }
    }

    /// A lesson's editable files (neither hidden nor read-only), with your saved code, else
    /// the starter's.
    static func fetchEditableFiles(_ db: Database, _ lesson: String) throws -> [SolutionFile] {
        try Row.fetchAll(db, sql: """
            SELECT s.name, coalesce(f.content, s.content) AS content FROM starter_file s
            LEFT JOIN code_file f ON f.lesson_uuid = s.lesson_uuid AND f.name = s.name
            WHERE s.lesson_uuid = ? AND s.is_hidden = 0 AND s.is_readonly = 0
            ORDER BY s.position
            """, arguments: [lesson]).map { SolutionFile(name: $0["name"], content: $0["content"]) }
    }
}
