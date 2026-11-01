import AppKit
import GopherwoodKit
import SwiftUI

@main
struct GopherwoodApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    private var app: AppModel { delegate.app }

    var body: some Scene {
        Window("Gopherwood", id: "main") {
            RootView()
                .environment(app)
                .frame(minWidth: 1100, minHeight: 700)
                .tint(Theme.accent)
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

/// Owns the app's model and starts it when the app has launched, whether or not its window is
/// visible yet (a window that can't be seen, such as on a locked screen, runs no view tasks).
/// Saves pending work and syncs before the app quits.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let app = AppModel()
    /// Another copy of this app was running at launch: this launch handed over to it and quits
    /// without opening anything.
    private var handingOver = false

    /// A second copy of the app (the same bundle id) brings the first one forward and quits
    /// before it opens the library, so two never compete for it (SingleInstance).
    func applicationWillFinishLaunching(_ notification: Notification) {
        let this = NSRunningApplication.current
        let copies = this.bundleIdentifier.map { NSRunningApplication.runningApplications(withBundleIdentifier: $0) } ?? []
        guard let first = SingleInstance.handOver(from: SingleInstance.App(this), running: copies.map(SingleInstance.App.init)),
              let other = copies.first(where: { $0.processIdentifier == first.pid }) else { return }
        handingOver = true
        Log.app.info("Gopherwood is running already (pid \(first.pid, privacy: .public)): handing over to it")
        NSApp.yieldActivation(to: other)
        other.activate()
        NSApp.terminate(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !handingOver else { return }
        Log.app.info("Launched")
        Task { await app.start() }
        if let folder = UserDefaults.standard.string(forKey: AppModel.LaunchArguments.snapshot) {
            Task { await AppDelegate.snapshot(into: URL(fileURLWithPath: folder, isDirectory: true)) }
        }
    }

    /// -GopherwoodSnapshot <folder>: ten seconds after launch, each window's content as a PNG,
    /// drawn here, for a window the window server can't capture, such as a sheet of an app
    /// that isn't active.
    static func snapshot(into folder: URL) async {
        try? await Task.sleep(for: .seconds(10))
        for (i, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = (window.isSheet ? "sheet-" : "window-") + "\(i)"
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name + ".png"))
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A launch that handed over opened nothing, so has nothing to save.
        if handingOver { return .terminateNow }
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
        app.lesson?.code?.save()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

extension SingleInstance.App {
    init(_ app: NSRunningApplication) {
        self.init(pid: app.processIdentifier, bundleID: app.bundleIdentifier, launched: app.launchDate, isTerminated: app.isTerminated)
    }
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
            Divider()
            Button("Push Solutions to GitHub") { app.solutions.push() }
                .disabled(app.solutions.repository == nil || app.solutions.isPushing)
        }
        CommandMenu("Editor") {
            editorButton(.format)
            editorButton(.toggleComment)
            Divider()
            editorButton(.indent)
            editorButton(.outdent)
        }
        CommandMenu("Lesson") {
            Button("Run") { app.lesson?.run() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!(app.lesson?.canRun ?? false) || (app.lesson?.isBusy ?? false))
            Button(app.lesson?.submitTitle ?? "Submit") { app.lesson?.submit() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!(app.lesson?.canSubmit ?? false) || (app.lesson?.isBusy ?? false))
            Button("Stop") { app.lesson?.stop() }
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

    /// An editor command for the code lesson on screen, off when there is none or it can't act.
    private func editorButton(_ command: EditorCommand) -> some View {
        let code = app.lesson?.code
        return Button(command.title) { code?.perform(command) }
            .keyboardShortcut(command.shortcut)
            .disabled(code.map { $0.unavailability(of: command) != nil } ?? true)
    }
}
