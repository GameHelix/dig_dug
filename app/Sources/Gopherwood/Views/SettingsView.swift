import AppKit
import CodeEditor
import GopherwoodKit
import SwiftUI

struct SettingsView: View {
    /// The pane last shown, so Settings opens where you left it.
    @AppStorage("SettingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") { GeneralSettings() }
            Tab("Editor", systemImage: "character.cursor.ibeam", value: "editor") { EditorSettings() }
            Tab("Go", systemImage: "chevron.left.forwardslash.chevron.right", value: "go") { GoSettings() }
            Tab("Sync", systemImage: "arrow.triangle.2.circlepath", value: "sync") { SyncSettings() }
            Tab("GitHub", systemImage: "arrow.triangle.branch", value: "github") { GitHubSettings() }
        }
        .frame(width: 560)
        .scenePadding()
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section {
                LabeledContent("File") {
                    Text(app.libraryURL.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "None")
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Change…") { app.chooseLibrary() }
                        .disabled(app.isOpeningLibrary)
                    if let url = app.libraryURL {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                }
            } header: {
                Text("Library")
            } footer: {
                Text("A library is one SQLite file: its courses and your progress in them.")
            }
            if app.database != nil {
                Section("Lessons") {
                    LabeledContent("In the library", value: "\(app.catalog.lessonCount)")
                    LabeledContent("Done", value: "\(app.done.count)")
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct EditorSettings: View {
    @Environment(AppModel.self) private var app
    private static let sample = "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println(\"Hello, gopher\")\n}\n"

    var body: some View {
        Form {
            Section("Editor") {
                LabeledContent("Font size") {
                    Stepper(value: Binding(get: { app.editorFontSize }, set: { app.setEditorFontSize($0) }), in: 9...28, step: 1) {
                        Text("\(Int(app.editorFontSize)) pt").monospacedDigit()
                    }
                }
                Toggle("Line numbers", isOn: Binding(get: { app.showLineNumbers }, set: { app.setShowLineNumbers($0) }))
                CodeEditorView(
                    text: .constant(Self.sample),
                    highlighter: GoLexer(),
                    fontSize: app.editorFontSize,
                    isEditable: false,
                    showsLineNumbers: app.showLineNumbers,
                    accessibilityLabel: "Preview"
                )
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .formStyle(.grouped)
    }
}

struct GoSettings: View {
    @Environment(AppModel.self) private var app
    @ViewState private var path = ""

    var body: some View {
        Form {
            Section {
                TextField("Go command", text: $path, prompt: Text("Found automatically"))
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { app.rediscoverToolchain(goPath: path) }
                HStack {
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.message = "Choose the go command, for example /usr/local/go/bin/go"
                        if panel.runModal() == .OK, let url = panel.url {
                            path = url.path
                            app.rediscoverToolchain(goPath: path)
                        }
                    }
                    Button("Find Automatically") {
                        path = ""
                        app.rediscoverToolchain(goPath: nil)
                    }
                }
            } header: {
                Text("Toolchain")
            } footer: {
                Text("Gopherwood runs your code with this Go. Left empty, it uses the go your login shell finds.")
            }
            Section("Detected") {
                if let t = app.toolchain {
                    if let go = t.go {
                        LabeledContent("Version", value: t.goVersion ?? "unknown")
                        LabeledContent("Path") { Text(go).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                    } else {
                        GoMissingView()
                    }
                } else {
                    HStack { ProgressView().controlSize(.small); Text("Looking for Go…") }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { path = app.preferences.goPath ?? "" }
    }
}

/// How to install Go when it is missing.
struct GoMissingView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Go is not installed", systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .fontWeight(.medium)
            Text("Install it from go.dev/dl, or with Homebrew: brew install go. Then choose Find Automatically.")
                .foregroundStyle(.secondary)
            if let download = URL(string: "https://go.dev/dl/") {
                Link("Download Go", destination: download)
            }
        }
    }
}

struct SyncSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            if app.git == nil {
                Section("Sync") {
                    Text(app.syncOffReason ?? "No library is open.")
                        .foregroundStyle(.secondary)
                }
            } else {
                syncSection
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var syncSection: some View {
        @Bindable var app = app
            Section {
                LabeledContent("Last push") {
                    Text(app.preferences.lastPush.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                }
                if let error = app.syncError {
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .staleLock = error {
                        Button("Remove Lock File") { Task { await app.removeStaleLock() } }
                            .disabled(app.isSyncing)
                    }
                }
                HStack {
                    Button("Commit and Push Now") { Task { await app.commitAndPush() } }
                        .disabled(app.isSyncing)
                    Button("Pull") { app.pullNow() }
                        .disabled(app.isSyncing || app.isOpeningLibrary)
                    if app.isSyncing { ProgressView().controlSize(.small) }
                }
            } header: {
                Text("Sync")
            } footer: {
                Text("The library sits in a git repository. Gopherwood never pulls, commits or pushes on its own: use Commit and Push Now or Pull here or in the File menu. It commits only the library file and never merges; a conflict is shown here.")
            }
    }
}

/// The GitHub CLI's sign-in, asked for while this pane shows, and your solutions repository.
struct GitHubSettings: View {
    @Environment(AppModel.self) private var app
    @ViewState private var sheet: SolutionsModel.Sheet?

    var body: some View {
        Form {
            Section {
                switch app.githubAccount {
                case .unknown, .checking:
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Asking the GitHub CLI…")
                    }
                case .signedIn(let login, let gh):
                    Label("Signed in through the GitHub CLI as \(login)", systemImage: "checkmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                    LabeledContent("GitHub CLI") { Text(gh).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                case .notSignedIn(let gh):
                    Label("Not signed in", systemImage: "person.crop.circle.badge.questionmark")
                        .symbolRenderingMode(.hierarchical)
                    Text("Run \(Text(verbatim: "gh auth login").font(.system(.body, design: .monospaced))) in Terminal and follow its steps, then choose Check Again.")
                        .foregroundStyle(.secondary)
                    LabeledContent("GitHub CLI") { Text(gh).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                case .noCLI:
                    Label("The GitHub CLI isn't installed", systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                    Text("Install it with Homebrew, \(Text(verbatim: "brew install gh").font(.system(.body, design: .monospaced))), then run \(Text(verbatim: "gh auth login").font(.system(.body, design: .monospaced))) in Terminal and choose Check Again.")
                        .foregroundStyle(.secondary)
                    if let site = URL(string: "https://cli.github.com") {
                        Link("GitHub CLI", destination: site)
                    }
                case .refused(let gh):
                    Label("GitHub refused the GitHub CLI's sign-in", systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                    Text("It may have expired. Run \(Text(verbatim: "gh auth login").font(.system(.body, design: .monospaced))) in Terminal again, then choose Check Again.")
                        .foregroundStyle(.secondary)
                    LabeledContent("GitHub CLI") { Text(gh).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                case .failed(let why):
                    Label(why, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Check Again") { app.refreshGitHubAccount() }
                    .disabled(app.githubAccount == .checking)
            } header: {
                Text("GitHub")
            } footer: {
                Text("GitHub lessons check your repository through GitHub's API and only read it. Each time, Gopherwood asks the GitHub CLI for its sign-in and keeps it only for that check. Without a sign-in the checks reach public repositories, but not workflow logs.")
            }
            SolutionsSection(sheet: $sheet)
        }
        .formStyle(.grouped)
        // Tall enough for the sign-in and the solutions repository without scrolling.
        .frame(minHeight: 700)
        .onAppear {
            app.refreshGitHubAccount()
            if let requested = app.solutions.sheetRequest {
                app.solutions.sheetRequest = nil
                // Once the window is in place: a sheet asked for while it opens is never drawn.
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    sheet = requested
                }
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .create: CreateRepositorySheet()
            case .existing: UseRepositorySheet()
            }
        }
    }
}
