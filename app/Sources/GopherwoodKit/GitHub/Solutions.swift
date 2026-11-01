import Foundation

/// Where a code lesson's solution goes in your solutions repository, and what to call it.
public struct SolutionPlace: Hashable, Sendable {
    public let lessonID: String
    public let lessonTitle: String
    public let chapterTitle: String
    public let courseTitle: String
    public let courseSlug: String
    /// The chapter's and the lesson's position, counted from 0 as the library counts them.
    public let chapterPosition: Int
    public let chapterSlug: String
    public let lessonPosition: Int
    public let lessonSlug: String

    public init(lessonID: String, lessonTitle: String, chapterTitle: String, courseTitle: String, courseSlug: String,
                chapterPosition: Int, chapterSlug: String, lessonPosition: Int, lessonSlug: String) {
        self.lessonID = lessonID
        self.lessonTitle = lessonTitle
        self.chapterTitle = chapterTitle
        self.courseTitle = courseTitle
        self.courseSlug = courseSlug
        self.chapterPosition = chapterPosition
        self.chapterSlug = chapterSlug
        self.lessonPosition = lessonPosition
        self.lessonSlug = lessonSlug
    }

    /// <course slug>/<NN>-<chapter slug>/<NN>-<lesson slug>, NN counted from 01, such as
    /// learn-golang/01-variables/02-var. A slug that starts with its own number, as 1-variables
    /// does, loses it, so a folder is numbered once. Nil when a slug makes no folder name.
    public var path: String? {
        guard let course = SolutionPlace.folderName(courseSlug),
              let chapter = SolutionPlace.folderName(SolutionPlace.unnumbered(chapterSlug)),
              let lesson = SolutionPlace.folderName(SolutionPlace.unnumbered(lessonSlug)) else { return nil }
        return "\(course)/\(SolutionPlace.number(chapterPosition))-\(chapter)/\(SolutionPlace.number(lessonPosition))-\(lesson)"
    }

    static func number(_ position: Int) -> String {
        let n = position + 1
        return n < 10 ? "0\(n)" : "\(n)"
    }

    /// The slug without a leading "<digits>-", when something is left after it.
    static func unnumbered(_ slug: String) -> String {
        guard let dash = slug.firstIndex(of: "-"), dash != slug.startIndex,
              slug[..<dash].allSatisfy(\.isASCII), slug[..<dash].allSatisfy(\.isNumber),
              slug.index(after: dash) != slug.endIndex else { return slug }
        return String(slug[slug.index(after: dash)...])
    }

    /// A slug as a folder name: letters, digits, '.', '_' and '-', anything else a hyphen,
    /// and no leading dot, so it never names .git or a hidden folder.
    static func folderName(_ slug: String) -> String? {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        let name = String(slug.map { allowed.contains($0) ? $0 : "-" }.drop(while: { $0 == "." }))
        return name.isEmpty ? nil : name
    }
}

/// One of your files in a solution: its path inside the lesson, such as main.go.
public struct SolutionFile: Hashable, Sendable {
    public let name: String
    public let content: String

    public init(name: String, content: String) {
        self.name = name
        self.content = content
    }

    /// Whether the name stays inside the lesson's folder: no empty, ., .. or .git part.
    var isSafe: Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && !name.contains("\0")
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" }
    }
}

/// A solved lesson to commit: your editable files, and when you solved it (the Submit, or
/// when you finished it, for an earlier solution).
public struct Solution: Hashable, Sendable {
    public let place: SolutionPlace
    public let files: [SolutionFile]
    public let date: Date

    public init(place: SolutionPlace, files: [SolutionFile], date: Date) {
        self.place = place
        self.files = files
        self.date = date
    }

    /// `Solve "<lesson title>" (<course title>)`.
    public var message: String { "Solve \"\(place.lessonTitle)\" (\(place.courseTitle))" }
}

/// The repository's README.md: a short table of the solved lessons per course, with the day
/// each was first committed.
public enum SolutionsReadme {
    public struct Row: Hashable, Sendable {
        /// The lesson's folder, such as learn-golang/01-variables/02-var.
        public let path: String
        public let lessonTitle: String
        public let chapterTitle: String?
        public let courseTitle: String
        /// Where the course comes in the library, so the README keeps its order.
        public let courseOrder: Int
        public let date: Date?

        public init(path: String, lessonTitle: String, chapterTitle: String?, courseTitle: String, courseOrder: Int, date: Date?) {
            self.path = path
            self.lessonTitle = lessonTitle
            self.chapterTitle = chapterTitle
            self.courseTitle = courseTitle
            self.courseOrder = courseOrder
            self.date = date
        }
    }

    public static func render(title: String, rows: [Row], timeZone: TimeZone = .current) -> String {
        var lines = ["# \(title)", "", "My solutions to Go lessons. Gopherwood commits each one when its Submit passes, dated that day.", ""]
        let courses = Dictionary(grouping: rows, by: \.courseTitle).sorted {
            ($0.value[0].courseOrder, $0.key) < ($1.value[0].courseOrder, $1.key)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        for (course, rows) in courses {
            lines += ["## \(escape(course))", "", "| Lesson | Chapter | Solved |", "|---|---|---|"]
            for row in rows.sorted(by: { $0.path < $1.path }) {
                let day = row.date.map { d -> String in
                    let c = calendar.dateComponents([.year, .month, .day], from: d)
                    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
                } ?? ""
                lines.append("| [\(escape(row.lessonTitle))](\(row.path)/) | \(escape(row.chapterTitle ?? "")) | \(day) |")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Text safe in a table cell and a link's text.
    static func escape(_ s: String) -> String {
        var out = ""
        for c in s.replacingOccurrences(of: "\n", with: " ") {
            if "|[]\\*_`<>".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }
}
