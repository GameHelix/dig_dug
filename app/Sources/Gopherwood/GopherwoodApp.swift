import AppKit
import GopherwoodKit
import SwiftUI

@main
struct GopherwoodApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ViewState private var app = AppModel()

    var body: some Scene {
        Window("Gopherwood", id: "main") {
            RootView()
                .environment(app)
                .frame(minWidth: 1100, minHeight: 700)
                .tint(Theme.accent)
                .task {
                    delegate.app = app
                    await app.start()
                }
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified)
        .commands {
            GopherwoodCommands(app: app)
            // Find (⌘F, ⌘G, ⌘E) for the editor's find bar, and the other text commands.
            TextEditingCommands()
        }

        Settings {
            SettingsView()
                .environment(app)
                .tint(Theme.accent)
        }
    }
}

/// Saves pending work and syncs before the app quits.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var app: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let app else { return .terminateNow }
        // Saves and syncs, but quits within 20 seconds even if git is slow or offline: a git
        // still pushing then finishes on its own.
        let reply = ReplyOnce { sender.reply(toApplicationShouldTerminate: true) }
        Task {
            await app.prepareToQuit()
            reply.send()
        }
        Task {
            try? await Task.sleep(for: .seconds(20))
            reply.send()
        }
        return .terminateLater
    }

    /// Back from another app, such as the editor the lesson folder is open in: take in edits
    /// made there.
    func applicationDidBecomeActive(_ notification: Notification) {
        app?.lesson?.code?.save()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Calls its action the first time `send` is called.
@MainActor
final class ReplyOnce {
    private var action: (() -> Void)?
    init(_ action: @escaping () -> Void) { self.action = action }
    func send() {
        action?()
        action = nil
    }
}

struct GopherwoodCommands: Commands {
    let app: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Library…") { app.chooseLibrary() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(app.isOpeningLibrary)
            Menu("Open Recent") {
                ForEach(app.recentLibraries, id: \.self) { url in
                    Button(url.lastPathComponent) { app.open(library: url) }
                        .help(url.path)
                }
                if !app.recentLibraries.isEmpty {
                    Divider()
                    Button("Clear Menu") { app.clearRecentLibraries() }
                }
            }
            .disabled(app.recentLibraries.isEmpty || app.isOpeningLibrary)
        }
        CommandGroup(after: .saveItem) {
            Button("Commit and Push Now") { Task { await app.commitAndPush() } }
                .disabled(app.database == nil || app.git == nil || app.isSyncing)
            Button("Pull") { app.pullNow() }
                .disabled(app.database == nil || app.git == nil || app.isSyncing || app.isOpeningLibrary)
        }
        CommandMenu("Lesson") {
            Button("Run") { app.lesson?.run() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!(app.lesson?.canRun ?? false) || (app.lesson?.isBusy ?? false))
            Button("Submit") { app.lesson?.submit() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!(app.lesson?.canSubmit ?? false) || (app.lesson?.isBusy ?? false))
            Button("Stop") {
                app.lesson?.code?.stop()
                app.lesson?.checks?.stop()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!(app.lesson?.isBusy ?? false))
            Divider()
            Button("Next Lesson") { app.openNext() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(app.nextLesson == nil)
            Button("Previous Lesson") { app.openPrevious() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(app.previousLesson == nil)
            Button("Back") { app.goBack() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!app.canGoBack)
            Button("Forward") { app.goForward() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!app.canGoForward)
            Divider()
            if let lesson = app.lesson {
                let done = app.isDone(lesson.detail.id)
                Button(done ? "Mark as Not Done" : "Mark as Done") { app.setDone(lesson.detail.id, !done) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
            Button("Reset to Starter Code…") { app.confirmReset = true }
                .disabled(app.lesson?.code == nil)
            Divider()
            Button("Reveal Lesson Folder in Finder") { app.revealLessonFolder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(app.lessonFolder == nil)
            Button("Open Lesson Folder in Editor") { app.openLessonFolderInEditor() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(app.lessonFolder == nil)
        }
        CommandGroup(after: .sidebar) {
            Button("Show Inspector") { app.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Button("Bigger Code") { app.setEditorFontSize(app.editorFontSize + 1) }
                .keyboardShortcut("=", modifiers: .command)
            Button("Smaller Code") { app.setEditorFontSize(app.editorFontSize - 1) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { app.setEditorFontSize(13) }
                .keyboardShortcut("0", modifiers: .command)
        }
    }
}
