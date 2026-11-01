import GopherwoodKit
import SwiftUI

struct QuizLessonView: View {
    let lesson: LessonModel
    let session: QuizSession

    var body: some View {
        ReadmeColumn(lesson: lesson) {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(session.quiz.questions.enumerated()), id: \.offset) { i, question in
                    QuestionCard(session: session, index: i, question: question,
                                 blocks: lesson.parsed.questions.indices.contains(i) ? lesson.parsed.questions[i] : [])
                }
                QuizFooter(session: session, lesson: lesson)
            }
        }
    }
}

struct QuestionCard: View {
    let session: QuizSession
    let index: Int
    let question: Quiz.Question
    /// The question's Markdown, parsed when the lesson opened.
    let blocks: [MDBlock]
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if session.quiz.questions.count > 1 {
                Text("Question \(index + 1) of \(session.quiz.questions.count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
            }
            MarkdownBlocks(blocks: blocks)
            GlassEffectContainer(spacing: 8) {
                VStack(spacing: 8) {
                    ForEach(Array(question.answers.enumerated()), id: \.offset) { a, answer in
                        AnswerRow(number: a + 1, answer: answer, state: state(of: a)) {
                            session.pick(a, for: index)
                            focused = true
                        }
                    }
                }
            }
            if session.verdicts[index] == false {
                Label("Not quite. The right answer is marked.", systemImage: "info.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(focused ? AnyShapeStyle(.tint.opacity(0.6)) : AnyShapeStyle(.separator.opacity(0.5)), lineWidth: focused ? 1.5 : 0.5))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onChange(of: focused) { _, isFocused in if isFocused { session.focusedQuestion = index } }
        .onKeyPress(characters: .decimalDigits) { press in
            guard let n = Int(press.characters), (1...5).contains(n) else { return .ignored }
            session.pick(n - 1, for: index)
            return .handled
        }
        .onAppear { if index == 0 { focused = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Question \(index + 1)")
    }

    private func state(of answer: Int) -> AnswerRow.State {
        let picked = session.picks[index] == answer
        guard let verdict = session.verdicts[index] else { return picked ? .picked : .idle }
        if question.answers[answer] == question.answer && (verdict || picked == false) { return .right }
        if picked { return verdict ? .right : .wrong }
        return .idle
    }
}

struct AnswerRow: View {
    enum State { case idle, picked, right, wrong }

    let number: Int
    let answer: String
    let state: State
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(number)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 20, height: 20)
                    .background(.quaternary, in: Circle())
                Text(Inline.attributed(Readme.parseInline(answer), size: 14))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .opacity(state == .idle ? 0 : 1)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(glass, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel("Answer \(number): \(Readme.plainText(Readme.parseInline(answer)))")
        .accessibilityValue(accessibilityState)
        .accessibilityHint("Press \(number) to pick it")
    }

    private var symbol: String {
        switch state {
        case .idle, .picked: "circle.inset.filled"
        case .right: "checkmark.circle.fill"
        case .wrong: "xmark.circle.fill"
        }
    }

    private var tint: Color {
        switch state {
        case .idle, .picked: Theme.accent
        case .right: Theme.success
        case .wrong: Theme.failure
        }
    }

    private var glass: Glass {
        switch state {
        case .idle: .regular.interactive()
        case .picked: .regular.tint(Theme.accent.opacity(0.25)).interactive()
        case .right: .regular.tint(.green.opacity(0.3))
        case .wrong: .regular.tint(.red.opacity(0.3))
        }
    }

    private var accessibilityState: String {
        switch state {
        case .idle: ""
        case .picked: "Picked"
        case .right: "Right answer"
        case .wrong: "Wrong answer"
        }
    }
}

struct QuizFooter: View {
    let session: QuizSession
    let lesson: LessonModel
    @Environment(AppModel.self) private var app

    var body: some View {
        let correct = session.allCorrect
        let wrong = session.verdicts.values.contains(false)
        HStack(spacing: 12) {
            // One icon that stays and changes, so its bounce plays when the quiz is passed.
            Image(systemName: correct ? "checkmark.seal.fill" : wrong ? "arrow.uturn.backward.circle" : "keyboard")
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: session.successCount)
                .foregroundStyle(correct ? AnyShapeStyle(Theme.success) : AnyShapeStyle(.secondary))
                .font(.system(size: correct ? 14 : 13, weight: correct ? .semibold : .regular))
                .accessibilityHidden(true)
            if correct {
                Text("All correct")
                    .foregroundStyle(Theme.success)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if let next = app.nextLesson {
                    Button("Next: \(next.title)", systemImage: "arrow.right") { app.openNext() }
                        .prominentGlassButton()
                        .lineLimit(1)
                }
            } else {
                Text(wrong ? "Pick another answer where one is marked wrong, then submit again (⌘↩)."
                           : session.canSubmit ? "Ready: submit your answers (⌘↩)." : "Pick an answer for each question (keys 1 to 5), then submit.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
            }
        }
    }
}
