import Foundation

/// The lesson types the database knows, by the names it stores.
public enum LessonType: String, Sendable, CaseIterable {
    case code = "type_code"
    case codeTests = "type_code_tests"
    case choice = "type_choice"
    case cli = "type_cli"
    case githubChecks = "type_github_checks"
    case interview = "type_interview_chat"


    public var label: String {
        switch self {
        case .code: "Code"
        case .codeTests: "Code with tests"
        case .choice: "Quiz"
        case .cli: "Command line"
        case .githubChecks: "GitHub"
        case .interview: "Interview"
        }
    }

    /// The SF Symbol docs/design.md names for the type.
    public var symbol: String {
        switch self {
        case .code: "chevron.left.forwardslash.chevron.right"
        case .codeTests: "checklist"
        case .choice: "questionmark.bubble"
        case .cli: "terminal"
        case .githubChecks: "arrow.triangle.branch"
        case .interview: "person.wave.2"
        }
    }

    /// Lessons you finish by marking them done yourself.
    public var isManual: Bool { self == .githubChecks || self == .interview }
}

public struct LessonSummary: Identifiable, Hashable, Sendable {
    public let id: String
    public let chapterID: String
    public let title: String
    public let type: LessonType
    public let required: Bool

    public init(id: String, chapterID: String, title: String, type: LessonType, required: Bool) {
        self.id = id
        self.chapterID = chapterID
        self.title = title
        self.type = type
        self.required = required
    }
}

public struct Chapter: Identifiable, Hashable, Sendable {
    public let id: String
    public let courseID: String
    public let title: String
    public var lessons: [LessonSummary]

    public init(id: String, courseID: String, title: String, lessons: [LessonSummary] = []) {
        self.id = id
        self.courseID = courseID
        self.title = title
        self.lessons = lessons
    }
}

public struct Course: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    /// "Course" or "Guided Project".
    public let kind: String
    public var chapters: [Chapter]

    public init(id: String, title: String, kind: String, chapters: [Chapter] = []) {
        self.id = id
        self.title = title
        self.kind = kind
        self.chapters = chapters
    }

    public var isGuidedProject: Bool { kind == "Guided Project" }
    public var lessons: [LessonSummary] { chapters.flatMap(\.lessons) }
    /// The lessons that count toward finishing the course.
    public var requiredLessons: [LessonSummary] { lessons.filter(\.required) }
}

/// Where a lesson sits: indexes into `Catalog.courses`.
public struct LessonLocation: Hashable, Sendable {
    public let course: Int
    public let chapter: Int
    public let lesson: Int
}

/// All courses, chapters and lessons without their texts, for the sidebar and navigation.
public struct Catalog: Sendable {
    public let courses: [Course]
    private let locations: [String: LessonLocation]
    private let order: [String: [String]] // course id -> lesson ids in reading order

    public static let empty = Catalog(courses: [])

    public init(courses: [Course]) {
        self.courses = courses
        var locations: [String: LessonLocation] = [:]
        var order: [String: [String]] = [:]
        for (ci, c) in courses.enumerated() {
            var ids: [String] = []
            for (hi, ch) in c.chapters.enumerated() {
                for (li, l) in ch.lessons.enumerated() {
                    locations[l.id] = LessonLocation(course: ci, chapter: hi, lesson: li)
                    ids.append(l.id)
                }
            }
            order[c.id] = ids
        }
        self.locations = locations
        self.order = order
    }

    public var isEmpty: Bool { courses.isEmpty }
    public var lessonCount: Int { locations.count }

    public func location(of id: String) -> LessonLocation? { locations[id] }

    public func summary(_ id: String) -> LessonSummary? {
        guard let l = locations[id] else { return nil }
        return courses[l.course].chapters[l.chapter].lessons[l.lesson]
    }

    public func course(of id: String) -> Course? { locations[id].map { courses[$0.course] } }

    public func chapter(of id: String) -> Chapter? { locations[id].map { courses[$0.course].chapters[$0.chapter] } }

    /// The next lesson in the same course, across chapters.
    public func next(after id: String) -> LessonSummary? { step(from: id, by: 1) }

    /// The previous lesson in the same course, across chapters.
    public func previous(before id: String) -> LessonSummary? { step(from: id, by: -1) }

    private func step(from id: String, by delta: Int) -> LessonSummary? {
        guard let c = course(of: id), let ids = order[c.id], let i = ids.firstIndex(of: id) else { return nil }
        let j = i + delta
        guard ids.indices.contains(j) else { return nil }
        return summary(ids[j])
    }

    /// The first lesson of the first course, where a new learner starts.
    public var firstLesson: LessonSummary? {
        for c in courses { for ch in c.chapters { if let l = ch.lessons.first { return l } } }
        return nil
    }
}

/// A lesson with its text, its facts and what its type holds.
public struct LessonDetail: Sendable {
    public let summary: LessonSummary
    public let courseID: String
    public let courseTitle: String
    public let chapterTitle: String
    public let readme: String
    public let difficulty: Int
    public let topics: [String]
    public let content: LessonContent

    public init(summary: LessonSummary, courseID: String, courseTitle: String, chapterTitle: String, readme: String,
                difficulty: Int, topics: [String], content: LessonContent) {
        self.summary = summary
        self.courseID = courseID
        self.courseTitle = courseTitle
        self.chapterTitle = chapterTitle
        self.readme = readme
        self.difficulty = difficulty
        self.topics = topics
        self.content = content
    }

    public var id: String { summary.id }
    public var title: String { summary.title }
    public var type: LessonType { summary.type }

    /// The code exercise of a code or tests lesson.
    public var code: CodeExercise? {
        switch content {
        case .code(let c), .codeTests(let c): c
        default: nil
        }
    }
}

/// A lesson found by search. Full-text search finds and ranks it; the excerpt shown under it
/// comes from the readme as the app renders it (ReadmeTexts).
public struct SearchHit: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let courseTitle: String
    public let chapterTitle: String
    public let type: LessonType

    public init(id: String, title: String, courseTitle: String, chapterTitle: String, type: LessonType) {
        self.id = id
        self.title = title
        self.courseTitle = courseTitle
        self.chapterTitle = chapterTitle
        self.type = type
    }
}

/// An excerpt of text around the first word a query matches, with the matching words marked.
public enum Snippet {
    public struct Part: Hashable, Sendable {
        public let text: String
        public let matched: Bool
    }

    /// The query's words, as search splits them and the index compares them.
    static func terms(_ query: String) -> [String] {
        query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(comparable)
    }

    /// A word as the full-text index compares it: lowercased, without diacritics.
    static func comparable(_ word: some StringProtocol) -> String {
        let lower = word.lowercased()
        return lower.utf8.allSatisfy { $0 < 0x80 } ? lower : lower.folding(options: .diacriticInsensitive, locale: nil)
    }

    /// The words of `text`, read as needed: runs of letters and digits, as the full-text
    /// index splits them.
    struct Words: Sequence, IteratorProtocol {
        let text: String
        var at: String.Index

        init(_ text: String) {
            self.text = text
            at = text.startIndex
        }

        mutating func next() -> Range<String.Index>? {
            while at < text.endIndex, !(text[at].isLetter || text[at].isNumber) { at = text.index(after: at) }
            guard at < text.endIndex else { return nil }
            let start = at
            while at < text.endIndex, text[at].isLetter || text[at].isNumber { at = text.index(after: at) }
            return start..<at
        }
    }

    /// Whether a word of `text` starts with a query word: a match the reader can see, and
    /// the excerpt marks.
    public static func shows(_ query: String, in text: String) -> Bool {
        let terms = terms(query)
        return !terms.isEmpty && Words(text).contains { word in terms.contains(where: comparable(text[word]).hasPrefix) }
    }

    /// About `words` words of `text` around the first word starting with a query word (the
    /// text's start if none does), and the text itself left as it is.
    public static func make(_ text: String, query: String, words: Int = 16) -> [Part] {
        let terms = terms(query)
        func matches(_ r: Range<String.Index>) -> Bool {
            let word = comparable(text[r])
            return terms.contains { word.hasPrefix($0) }
        }
        // Words up to one past the excerpt's end, so it knows whether more follow.
        var tokens: [Range<String.Index>] = []
        var matched: Int?
        for word in Words(text) {
            if matched == nil, matches(word) { matched = tokens.count }
            tokens.append(word)
            if let m = matched, tokens.count > max(0, m - words / 4) + words { break }
        }
        guard !tokens.isEmpty else { return [] }
        let first = matched ?? 0
        let from = max(0, first - words / 4), to = min(tokens.count - 1, from + words - 1)
        let last = tokens.count - 1
        var parts: [Part] = []
        var plain = from > 0 ? "…" : ""
        var at = from > 0 ? tokens[from].lowerBound : text.startIndex
        for t in tokens[from...to] where matches(t) {
            plain += text[at..<t.lowerBound]
            parts.append(Part(text: fold(plain), matched: false))
            parts.append(Part(text: String(text[t]), matched: true))
            plain = ""
            at = t.upperBound
        }
        plain += text[at..<(to < last ? tokens[to].upperBound : text.endIndex)]
        if to < last { plain += "…" }
        parts.append(Part(text: fold(plain), matched: false))
        return parts.filter { !$0.text.isEmpty }
    }

    /// Line breaks and runs of spaces become one space.
    static func fold(_ s: String) -> String {
        s.replacing(/\s+/) { _ in " " }
    }
}
