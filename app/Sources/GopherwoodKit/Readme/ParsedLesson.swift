import Foundation

/// A lesson's Markdown as blocks, parsed once off the main actor: the readme, and a quiz's
/// questions or an interview's prompt and what a good answer covers.
public struct ParsedLesson: Sendable {
    public var readme: [MDBlock]
    public var questions: [[MDBlock]] = []
    public var prompt: [MDBlock] = []
    public var criteria: [MDBlock] = []

    public init(_ lesson: LessonDetail) {
        readme = Readme.parse(lesson.readme, droppingTitle: lesson.title)
        switch lesson.content {
        case .choice(let quiz):
            questions = quiz.questions.map { Readme.parse($0.question) }
        case .interviewChat(let interview):
            prompt = Readme.parse(interview.studentPrompt)
            criteria = interview.acceptanceCriteria.map { Readme.parse($0) } ?? []
        default:
            break
        }
    }
}

/// Parsed lessons kept for the recently opened ones. Lessons are named by id, which another
/// library or a pull can reuse with new text, so the cache is cleared whenever a library opens.
public actor ReadmeCache {
    private var parsed: [String: ParsedLesson] = [:]
    private var order: [String] = []

    public init() {}

    public func parsed(for lesson: LessonDetail) -> ParsedLesson {
        if let cached = parsed[lesson.id] { return cached }
        let result = ParsedLesson(lesson)
        parsed[lesson.id] = result
        order.append(lesson.id)
        if order.count > 120 { parsed[order.removeFirst()] = nil }
        return result
    }

    public func clear() {
        parsed = [:]
        order = []
    }
}
