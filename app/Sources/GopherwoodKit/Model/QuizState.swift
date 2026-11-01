import Foundation

/// A quiz in progress: the answer picked for each question and, after a submit, which picks
/// were right. A question answered right stays answered; a wrong one can be picked again.
public struct QuizState: Sendable {
    /// One graded answer, for the attempt history.
    public struct Answer: Sendable, Equatable {
        public let text: String
        public let right: Bool
    }

    public let quiz: Quiz
    /// The answer picked for each question, by index.
    public private(set) var picks: [Int: Int] = [:]
    /// After a submit: whether each question's pick was right.
    public private(set) var verdicts: [Int: Bool] = [:]

    public init(quiz: Quiz) {
        self.quiz = quiz
    }

    public var allCorrect: Bool {
        !quiz.questions.isEmpty && quiz.questions.indices.allSatisfy { verdicts[$0] == true }
    }

    /// Every question has a pick, and none is a pick already marked wrong.
    public var canSubmit: Bool {
        !quiz.questions.isEmpty && quiz.questions.indices.allSatisfy { picks[$0] != nil } && !allCorrect
            && !verdicts.values.contains(false)
    }

    /// Picks an answer; returns false for a question already answered right, or one out of range.
    @discardableResult
    public mutating func pick(_ answer: Int, for question: Int) -> Bool {
        guard quiz.questions.indices.contains(question), quiz.questions[question].answers.indices.contains(answer),
              verdicts[question] != true else { return false }
        picks[question] = answer
        verdicts[question] = nil
        return true
    }

    /// Grades every pick not yet right, and returns those answers.
    public mutating func submit() -> [Answer] {
        guard canSubmit else { return [] }
        var graded: [Answer] = []
        for (i, q) in quiz.questions.enumerated() where verdicts[i] != true {
            guard let p = picks[i] else { continue }
            let text = q.answers[p]
            let right = q.isCorrect(text)
            verdicts[i] = right
            graded.append(Answer(text: text, right: right))
        }
        return graded
    }
}
