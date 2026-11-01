import GopherwoodKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if !app.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                SearchResultsList()
            } else {
                ScrollViewReader { proxy in
                List(selection: app.lessonSelection) {
                    let courses = app.catalog.courses.filter { !$0.isGuidedProject }
                    let projects = app.catalog.courses.filter(\.isGuidedProject)
                    ForEach(courses) { course in
                        Section {
                            ForEach(course.chapters) { chapter in
                                ChapterGroup(chapter: chapter)
                            }
                        } header: {
                            CourseHeader(course: course)
                        }
                    }
                    if !projects.isEmpty {
                        Section("Guided Projects") {
                            ForEach(projects) { project in
                                ProjectGroup(course: project)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .task(id: app.lesson?.detail.id) {
                    // Bring the lesson on screen into view once its chapter has opened.
                    guard let id = app.lesson?.detail.id else { return }
                    try? await Task.sleep(for: .milliseconds(120))
                    withAnimation(reduceMotion ? nil : .snappy) { proxy.scrollTo(id, anchor: .center) }
                }
                }
            }
        }
    }
}

private extension AppModel {
    /// The lists' selection. A row chosen in a list is only recorded here; the lesson opens on
    /// the next turn of the main actor, after the list has finished its selection callback.
    /// The model's own selections (Back, Next Lesson, launch) come back unchanged and open
    /// nothing, so they are not opened twice.
    var lessonSelection: Binding<String?> {
        Binding(
            get: { self.selection },
            set: { id in
                guard id != self.selection else { return }
                self.selection = id
                guard let id else { return }
                Task { @MainActor in
                    guard self.selection == id else { return }
                    self.open(id)
                }
            })
    }
}

struct CourseHeader: View {
    let course: Course
    @Environment(AppModel.self) private var app

    var body: some View {
        let progress = app.progress(of: course)
        HStack(spacing: 8) {
            Text(course.title)
                .lineLimit(1)
            Spacer(minLength: 6)
            ProgressRing(done: progress.done, total: progress.total)
                .padding(.trailing, 6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(course.title), \(progress.done) of \(progress.total) required lessons done")
    }
}

/// Finished lessons out of required ones.
struct ProgressRing: View {
    let done: Int
    let total: Int
    var size: CGFloat = 14
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let fraction = total == 0 ? 0 : Double(done) / Double(total)
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : .smooth, value: fraction)
        .help("\(done) of \(total) required lessons done")
    }
}

struct ProjectGroup: View {
    let course: Course
    @Environment(AppModel.self) private var app

    var body: some View {
        let expanded = Binding(
            get: { app.expandedChapters.contains(course.id) || course.chapters.contains { app.expandedChapters.contains($0.id) } },
            set: { open in
                if open { app.expandedChapters.insert(course.id) } else {
                    app.expandedChapters.remove(course.id)
                    for ch in course.chapters { app.expandedChapters.remove(ch.id) }
                }
            })
        DisclosureGroup(isExpanded: expanded) {
            ForEach(course.chapters) { chapter in
                ChapterGroup(chapter: chapter)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "hammer")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                Text(course.title).lineLimit(1)
                Spacer(minLength: 6)
                let p = app.progress(of: course)
                ProgressRing(done: p.done, total: p.total)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(course.title), guided project, \(app.progress(of: course).done) of \(app.progress(of: course).total) required lessons done")
        }
    }
}

struct ChapterGroup: View {
    let chapter: Chapter
    @Environment(AppModel.self) private var app

    var body: some View {
        let expanded = Binding(
            get: { app.expandedChapters.contains(chapter.id) },
            set: { open in
                if open { app.expandedChapters.insert(chapter.id) } else { app.expandedChapters.remove(chapter.id) }
            })
        DisclosureGroup(isExpanded: expanded) {
            ForEach(chapter.lessons) { lesson in
                LessonRow(lesson: lesson)
                    .tag(lesson.id)
            }
        } label: {
            let done = app.doneCount(chapter)
            HStack(spacing: 6) {
                Text(chapter.title)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("\(done)/\(chapter.lessons.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(done == chapter.lessons.count && done > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(Theme.secondaryText))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(chapter.title), \(done) of \(chapter.lessons.count) done")
        }
    }
}

struct LessonRow: View {
    let lesson: LessonSummary
    @Environment(AppModel.self) private var app
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let done = app.isDone(lesson.id)
        HStack(spacing: 7) {
            Image(systemName: lesson.type.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(lesson.title)
                .lineLimit(1)
                // Selected, the row is white on the accent, so an optional title takes the list's own secondary.
                .foregroundStyle(lesson.required ? AnyShapeStyle(.primary) : prominence == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.secondaryText))
            Spacer(minLength: 4)
            // Always there, hidden until done, so the bounce plays when the lesson is finished.
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.tint)
                .opacity(done ? 1 : 0)
                .symbolEffect(.bounce, value: done)
        }
        .frame(minHeight: 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(lesson.title), \(lesson.type.label)\(done ? ", done" : "")\(lesson.required ? "" : ", optional")")
    }
}

struct SearchResultsList: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.searchResults.isEmpty && !app.searching {
            ContentUnavailableView.search(text: app.searchText)
        } else {
            List(selection: app.lessonSelection) {
                Section("\(app.searchResults.count) Lesson\(app.searchResults.count == 1 ? "" : "s")") {
                    ForEach(app.searchResults) { hit in
                        SearchHitRow(hit: hit)
                            .tag(hit.id)
                    }
                }
            }
            .listStyle(.sidebar)
            // A new list for each set of results. Updated in place, the table measures rows of
            // differing heights while it keeps its top row still, resizes in the middle of that
            // and re-enters its own row-height cache, which AppKit logs as a reentrant
            // operation in its delegate and will turn into an assertion.
            .id(app.searchResults.map(\.id))
        }
    }
}

struct SearchHitRow: View {
    let hit: SearchHit
    @Environment(AppModel.self) private var app
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: hit.type.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                Text(title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if app.isDone(hit.id) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
            }
            Text("\(hit.courseTitle) › \(hit.chapterTitle)")
                .font(.caption)
                .foregroundStyle(secondary)
                .lineLimit(1)
            // A lesson found by its title alone may have no readme text to quote.
            if !(app.searchSnippets[hit.id] ?? []).isEmpty {
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    /// A focused list draws its selected row in white on the accent, where colors of our own
    /// would sink in.
    private var emphasized: Bool { prominence == .increased }
    private var secondary: AnyShapeStyle { emphasized ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.secondaryText) }
    /// On the selected row, gray or accent, the matched words keep their weight but drop the
    /// accent, which reads poorly on either fill.
    private var plainMarks: Bool { emphasized || app.selection == hit.id }

    /// The title with the words the query matches marked by the excerpt's rule: words that
    /// start with a word of the query.
    private var title: AttributedString {
        // Enough words that the excerpt is the whole title.
        let parts = Snippet.make(hit.title, query: app.searchText, words: 4 * (hit.title.count + 1))
        guard parts.contains(where: \.matched) else { return AttributedString(hit.title) }
        var out = AttributedString()
        for part in parts {
            var a = AttributedString(part.text)
            if part.matched {
                a.inlinePresentationIntent = .stronglyEmphasized
                if !plainMarks { a.foregroundColor = Theme.searchMark }
            }
            out += a
        }
        return out
    }

    private var snippet: AttributedString {
        var out = AttributedString()
        for part in app.searchSnippets[hit.id] ?? [] {
            var a = AttributedString(part.text)
            if part.matched {
                a.font = .caption.weight(.semibold)
                if !plainMarks { a.foregroundColor = Theme.searchMark }
            }
            out += a
        }
        return out
    }
}
