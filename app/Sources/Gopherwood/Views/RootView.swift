import AppKit
import GopherwoodKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var app = app
        content
            // Declared once, here, for the window's whole life: the items follow the app's
            // state, so changing lessons, lesson types or libraries never adds a second set.
            .toolbar { LessonToolbar() }
            .onChange(of: app.settingsRequests) { openSettings() }
            .alert(app.libraryError?.title ?? "", isPresented: Binding(get: { app.libraryError != nil }, set: { if !$0 { app.libraryError = nil } }),
                   presenting: app.libraryError) { _ in
                Button("OK") { app.libraryError = nil }
            } message: { error in
                Text([error.errorDescription, error.recoverySuggestion].compactMap { $0 }.joined(separator: "\n\n"))
            }
            .overlay {
                if app.isQuitting {
                    SavingOverlay()
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch app.phase {
        case .starting:
            ProgressView("Opening your lessons…")
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .welcome:
            WelcomeView()
        case .failed(let error):
            WelcomeView(error: error)
        case .ready:
            MainView()
        }
    }
}

/// While the app saves and syncs before it quits.
struct SavingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.12).ignoresSafeArea()
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Saving…")
                    .font(.system(size: 14, weight: .medium))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: Capsule())
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Saving your study data before Gopherwood quits")
    }
}

/// Without a library: open one. When the library could not open, why, in the words of the
/// library tool's checks, and what to do.
struct WelcomeView: View {
    var error: AppError?
    @Environment(AppModel.self) private var app

    var body: some View {
        ContentUnavailableView {
            if let error {
                Label(error.title, systemImage: "books.vertical.trianglebadge.exclamationmark")
            } else {
                Label("Open a Library", systemImage: "books.vertical")
            }
        } description: {
            VStack(spacing: 8) {
                if let error {
                    if case .database(let e) = error {
                        ForEach(Array(e.problems.prefix(6).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(.callout, design: .monospaced))
                        }
                        if e.problems.count > 6 { Text("and \(e.problems.count - 6) more") }
                    } else if let text = error.errorDescription {
                        Text(text)
                    }
                    if let suggestion = error.recoverySuggestion { Text(suggestion) }
                    if let path = app.libraryURL?.path, error.recoverySuggestion?.contains(path) != true {
                        Text(path).font(.system(.callout, design: .monospaced)).foregroundStyle(Theme.secondaryText)
                    }
                } else {
                    Text("A library is one SQLite file with courses, their lessons and your progress in them. Gopherwood opens any library.")
                }
            }
            .foregroundStyle(Theme.secondaryText)
            .textSelection(.enabled)
        } actions: {
            VStack(spacing: 10) {
                HStack {
                    Button("Open Library…") { app.chooseLibrary() }
                        .prominentGlassButton()
                        .keyboardShortcut(.defaultAction)
                        .disabled(app.isOpeningLibrary)
                    if error != nil {
                        Button("Try Again") { app.open(app.libraryURL) }
                            .secondaryGlassButton()
                            .disabled(app.isOpeningLibrary)
                    }
                }
                let others = app.recentLibraries.filter { $0 != app.libraryURL }.prefix(4)
                if !others.isEmpty {
                    HStack {
                        ForEach(Array(others), id: \.self) { url in
                            Button(url.lastPathComponent, systemImage: "clock") { app.open(library: url) }
                                .secondaryGlassButton()
                                .disabled(app.isOpeningLibrary)
                                .help(url.path)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var app
    @ViewState private var columns: NavigationSplitViewVisibility = .all
    @ViewState private var windowWidth: CGFloat = 0
    @ViewState private var sidebarWidth: CGFloat = 0

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .safeAreaBar(edge: .bottom) { SyncFooter() }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { sidebarWidth = $0 }
                // On the column's outermost view, where the split view reads it. The split view
                // keeps the sidebar and the inspector at their ideal widths, so those ideals plus
                // the lesson's 600 fit the 1100 pt minimum window: 240 + 600 + 240.
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 400)
        } detail: {
            DetailView(minWidth: lessonMinimum)
        }
        .searchable(text: $app.searchText, placement: .toolbar, prompt: "Search Lessons")
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
    }

    /// 600, or less when a sidebar dragged wide and the inspector leave less room in the
    /// window: the split view keeps the sidebar's width, so a fixed minimum would push the
    /// inspector out of the window.
    private var lessonMinimum: CGFloat {
        guard windowWidth > 0 else { return 600 }
        let sidebar = columns == .detailOnly ? 0 : sidebarWidth
        let room = windowWidth - sidebar - (app.showInspector ? 240 : 0) - 2
        return min(600, max(440, room.rounded(.down)))
    }
}

/// A quiet line under the sidebar about git.
struct SyncFooter: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if !app.syncStatus.isEmpty || app.isSyncing {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    if app.isSyncing {
                        ProgressView().controlSize(.mini)
                        Text("Syncing…")
                    } else {
                        Image(systemName: app.syncError == nil ? "checkmark.icloud" : "exclamationmark.icloud")
                            .symbolRenderingMode(.hierarchical)
                        Text(app.syncStatus).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(app.syncError == nil ? AnyShapeStyle(Theme.secondaryText) : AnyShapeStyle(Theme.warning))
                .help(app.syncError?.recoverySuggestion ?? app.syncStatus)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                if case .staleLock? = app.syncError {
                    Button("Remove Lock File") { Task { await app.removeStaleLock() } }
                        .secondaryGlassButton()
                        .controlSize(.small)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                        .help("No git is running, so its lock file is left over; removing it lets Gopherwood commit again")
                }
            }
        }
    }
}

struct DetailView: View {
    var minWidth: CGFloat = 600
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            if let lesson = app.lesson {
                LessonView(lesson: lesson)
                    .id(lesson.detail.id)
            } else if app.isLoadingLesson {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("No Lesson Selected", systemImage: "book.closed",
                                       description: Text("Choose a lesson in the sidebar, or search for one.").foregroundStyle(Theme.secondaryText))
            }
        }
        // Sidebar 240 + lesson 600 + inspector 240 fit the 1100 pt minimum window.
        .frame(minWidth: minWidth)
        .safeAreaInset(edge: .top, spacing: 0) { ErrorBanner() }
        .navigationTitle(app.lesson?.detail.title ?? "Gopherwood")
        .navigationSubtitle(app.lesson.map { "\($0.detail.courseTitle) › \($0.detail.chapterTitle)" } ?? "")
        .inspector(isPresented: $app.showInspector) {
            InspectorView()
                .inspectorColumnWidth(min: 240, ideal: 240, max: 380)
        }
        .confirmationDialog("Reset to the starter code?", isPresented: $app.confirmReset) {
            Button("Reset to Starter Code", role: .destructive) { app.lesson?.code?.resetToStarter() }
        } message: {
            Text("Your code for this lesson is replaced by the lesson's starter code.")
        }
    }
}

struct LessonView: View {
    let lesson: LessonModel

    var body: some View {
        if let code = lesson.code {
            CodeLessonView(lesson: lesson, session: code)
        } else if let quiz = lesson.quiz {
            QuizLessonView(lesson: lesson, session: quiz)
        } else if let checks = lesson.checks {
            ChecksLessonView(lesson: lesson, session: checks)
        } else if let github = lesson.github {
            GitHubLessonView(lesson: lesson, session: github)
        } else {
            ManualLessonView(lesson: lesson)
        }
    }
}

struct ErrorBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let error = app.banner {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(error.errorDescription ?? "Something went wrong").fontWeight(.medium)
                    if let s = error.recoverySuggestion { Text(s).foregroundStyle(Theme.secondaryText) }
                }
                .font(.system(size: 12.5))
                Spacer()
                Button("Dismiss") { app.banner = nil }
                    .secondaryGlassButton()
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(.regular.tint(.orange.opacity(0.15)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// The window's toolbar items, all of them, as a function of the app's state: navigation,
/// the lesson's actions for its type and state, and the inspector toggle. Only the root view
/// declares it, so no lesson view adds items of its own.
struct LessonToolbar: ToolbarContent {
    @Environment(AppModel.self) private var app

    var body: some ToolbarContent {
        if app.phase == .ready {
            ToolbarItemGroup(placement: .navigation) {
                Button { app.goBack() } label: { Label("Back", systemImage: "chevron.backward") }
                    .disabled(!app.canGoBack)
                    .help("Back (⌥⌘←)")
                Button { app.goForward() } label: { Label("Forward", systemImage: "chevron.forward") }
                    .disabled(!app.canGoForward)
                    .help("Forward (⌥⌘→)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if let lesson = app.lesson {
                    LessonActions(lesson: lesson)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                @Bindable var app = app
                Button { app.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                    .help("Show the note and lesson facts (⌥⌘I)")
            }
        }
    }
}

/// The open lesson's actions: Next Lesson after a pass, Run or Stop, and Submit, Check or Mark
/// as Done, by its type and state.
struct LessonActions: View {
    let lesson: LessonModel
    @Environment(AppModel.self) private var app

    var body: some View {
        if lesson.justPassed, let next = app.nextLesson {
            Button { app.openNext() } label: { Label("Next Lesson", systemImage: "arrow.right") }
                .labelStyle(.titleAndIcon)
                .help("Next lesson: \(next.title) (⌘])")
        }
        if lesson.canRun {
            let run = Button {
                if lesson.isBusy { lesson.stop() } else { lesson.run() }
            } label: {
                Label(lesson.isBusy ? "Stop" : lesson.checks != nil ? "Run Checks" : "Run",
                      systemImage: lesson.isBusy ? "stop.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .labelStyle(.titleAndIcon)
            .help(lesson.isBusy ? "Stop (⌘.)" : "Run (⌘R)")
            // A command-line lesson's checks are its main action, styled like Submit and Mark as Done.
            if lesson.checks != nil {
                run.prominentGlassButton()
            } else {
                run
            }
        }
        if lesson.code != nil || lesson.quiz != nil {
            Button { lesson.submit() } label: { Label("Submit", systemImage: "paperplane.fill") }
                .labelStyle(.titleAndIcon)
                .prominentGlassButton()
                .disabled(lesson.isBusy || !lesson.canSubmit)
                .help("Submit (⌘↩)")
        }
        // A GitHub lesson's checks are its main action; Mark as Done stays in the lesson.
        if let github = lesson.github {
            Button {
                if github.isRunning { github.stop() } else { lesson.submit() }
            } label: {
                Label(github.isRunning ? "Stop" : "Check", systemImage: github.isRunning ? "stop.fill" : "checkmark.seal")
                    .contentTransition(.symbolEffect(.replace))
            }
            .labelStyle(.titleAndIcon)
            .prominentGlassButton()
            .help(github.isRunning ? "Stop (⌘.)" : "Check your repository on GitHub (⌘↩)")
        }
        if lesson.detail.type.isManual {
            let done = app.isDone(lesson.detail.id)
            Button { app.setDone(lesson.detail.id, !done) } label: {
                Label(done ? "Done" : "Mark as Done", systemImage: done ? "checkmark.circle.fill" : "checkmark.circle")
                    .contentTransition(.symbolEffect(.replace))
            }
            .labelStyle(.titleAndIcon)
            .prominentGlassButton()
            .help(done ? "Mark as not done (⇧⌘D)" : "Mark as done (⇧⌘D)")
        }
    }
}
