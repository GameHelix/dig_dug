import GopherwoodKit
import SwiftUI

/// Interview lessons: you answer in your own words and mark the lesson done.
struct ManualLessonView: View {
    let lesson: LessonModel

    var body: some View {
        ReadmeColumn(lesson: lesson) {
            VStack(alignment: .leading, spacing: 16) {
                if case .interviewChat = lesson.detail.content {
                    InterviewPrompt(lesson: lesson)
                }
                MarkDoneBar(lesson: lesson)
            }
        }
    }
}

struct InterviewPrompt: View {
    let lesson: LessonModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your answer")
                .font(.system(size: Theme.headingSize(3), weight: .semibold))
            // The prompt is Markdown, like the readme: inline code, fenced blocks, lists.
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "person.wave.2")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .padding(.top, 3)
                MarkdownBlocks(blocks: lesson.parsed.prompt)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            NoteEditor(lesson: lesson, placeholder: "Answer in your own words. This is saved as the lesson's note.", fontSize: 14,
                       accessibilityLabel: "Your answer")
                .padding(8)
                .frame(minHeight: 140)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if !lesson.parsed.criteria.isEmpty {
                DisclosureGroup("What a good answer covers") {
                    MarkdownBlocks(blocks: lesson.parsed.criteria)
                        .padding(.top, 4)
                }
                .font(.system(size: 13, weight: .medium))
            }
        }
    }
}

/// The lesson's note (an interview answer is one too). It reads the note on its own, so
/// typing redraws the editor and not the lesson around it.
struct NoteEditor: View {
    @Bindable var lesson: LessonModel
    let placeholder: String
    let fontSize: CGFloat
    let accessibilityLabel: String

    var body: some View {
        TextEditor(text: $lesson.note)
            .font(.system(size: fontSize))
            .scrollContentBackground(.hidden)
            .overlay(alignment: .topLeading) {
                if lesson.note.isEmpty {
                    Text(placeholder)
                        .font(.system(size: fontSize))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel(accessibilityLabel)
    }
}

struct MarkDoneBar: View {
    let lesson: LessonModel
    @Environment(AppModel.self) private var app

    var body: some View {
        let done = app.isDone(lesson.detail.id)
        HStack(spacing: 12) {
            // Always there, hidden until done, so the bounce plays when you mark it done.
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.tint)
                .font(.system(size: 14, weight: .semibold))
                .symbolEffect(.bounce, value: done)
                .frame(width: done ? nil : 0)
                .opacity(done ? 1 : 0)
                .accessibilityHidden(true)
            if done {
                Text("Done")
                    .foregroundStyle(.tint)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Mark as Not Done") { app.setDone(lesson.detail.id, false) }
                    .secondaryGlassButton()
                if let next = app.nextLesson {
                    Button("Next: \(next.title)", systemImage: "arrow.right") { app.openNext() }
                        .prominentGlassButton()
                        .lineLimit(1)
                }
            } else {
                Text("Mark the lesson done when you have finished it.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Button("Mark as Done", systemImage: "checkmark") { lesson.markPassed() }
                    .prominentGlassButton()
                    .controlSize(.large)
            }
        }
    }
}

/// The inspector: your note for the lesson, and its facts.
struct InspectorView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let lesson = app.lesson {
            InspectorContent(lesson: lesson)
        } else {
            ContentUnavailableView("No Lesson", systemImage: "info.circle", description: Text("Open a lesson to see its note and facts."))
        }
    }
}

struct InspectorContent: View {
    let lesson: LessonModel
    @Environment(AppModel.self) private var app

    var body: some View {
        let detail = lesson.detail
        Form {
            Section("Note") {
                NoteEditor(lesson: lesson, placeholder: "Write a note for this lesson…", fontSize: 13,
                           accessibilityLabel: "Note for this lesson")
                    .frame(minHeight: 160)
                Text("Saved as you type.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            Section("Lesson") {
                LabeledContent("Type") { Label(detail.type.label, systemImage: detail.type.symbol).lineLimit(1) }
                LabeledContent("Difficulty") { DifficultyView(level: detail.difficulty) }
                LabeledContent("Course") { FactText(detail.courseTitle) }
                LabeledContent("Chapter") { FactText(detail.chapterTitle) }
                LabeledContent("Status") { FactText(app.isDone(detail.id) ? "Done" : detail.summary.required ? "Not done" : "Optional") }
            }
            if !detail.topics.isEmpty {
                Section("Topics") {
                    TopicTags(topics: detail.topics)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// A fact's value in the inspector: one line, cut with an ellipsis when the column is narrow,
/// and whole in its help tag.
struct FactText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .foregroundStyle(Theme.secondaryText)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(text)
    }
}

/// Difficulty as five dots; the lessons' difficulty runs from about 5 to 70.
struct DifficultyView: View {
    let level: Int

    var dots: Int {
        switch level {
        case ..<12: 1
        case ..<20: 2
        case ..<30: 3
        case ..<45: 4
        default: 5
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                Circle()
                    .fill(i < dots ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: 7, height: 7)
            }
        }
        .help("Difficulty \(level) of 70")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Difficulty \(dots) of 5")
    }
}

struct TopicTags: View {
    let topics: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(topics, id: \.self) { topic in
                Text(topic)
                    .font(.system(size: 12))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.tint.opacity(0.12), in: Capsule())
                    .foregroundStyle(.tint)
            }
        }
    }
}

/// Lays children out in rows, wrapping as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 260
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += row + spacing
                x = 0
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += row + spacing
                x = bounds.minX
                row = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
