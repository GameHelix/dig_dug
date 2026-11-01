import AppKit
import CodeEditor
import GopherwoodKit
import SwiftUI

struct CodeLessonView: View {
    let lesson: LessonModel
    let session: CodeSession

    var body: some View {
        // The minimums fit the narrowest lesson pane: a 1100 pt window with the inspector open.
        PersistentSplit(.horizontal, key: "CodeSplitReadme", defaultFraction: 0.46, minFirst: 260, minSecond: 320) {
            ReadmeColumn(lesson: lesson) { EmptyView() }
        } second: {
            PersistentSplit(.vertical, key: "CodeSplitConsole", defaultFraction: 0.62, minFirst: 180, minSecond: 140) {
                EditorPane(session: session)
            } second: {
                ConsolePane(session: session)
            }
        }
        .alert(
            "\(session.conflict ?? "A file") changed in another editor",
            isPresented: Binding(get: { session.conflict != nil }, set: { _ in }),
            presenting: session.conflict
        ) { _ in
            Button("Keep Mine") { session.resolveConflict(keepMine: true) }
                .keyboardShortcut(.defaultAction)
            Button("Use the File on Disk") { session.resolveConflict(keepMine: false) }
        } message: { name in
            Text("You changed \(name) here, and it changed in the lesson folder too, since it was last saved. Which version do you want to keep?")
        }
    }
}

struct EditorPane: View {
    let session: CodeSession
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if session.files.count > 1 {
                    Picker("File", selection: Binding(get: { session.activeIndex }, set: { session.activeIndex = $0 })) {
                        ForEach(Array(session.files.enumerated()), id: \.offset) { i, file in
                            Label(file.name, systemImage: file.readOnly ? "lock" : "doc.text").tag(i)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    // The selected file's white label needs the deeper fill in dark mode.
                    .tint(Theme.prominent)
                } else if let file = session.activeFile {
                    Label(file.name, systemImage: file.readOnly ? "lock" : "doc.text")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                if session.activeFile?.readOnly == true {
                    Text("Read only")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                EditorCommandButtons(session: session)
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(height: 38)
            Divider()
            if let file = session.activeFile {
                if let error = session.loadError, !session.isLoaded {
                    CodeLoadFailed(message: error, session: session)
                } else {
                    FileEditor(buffer: file, session: session)
                        // A new editor, with its own undo history, for each file.
                        .id("\(session.lesson.id)/\(file.name)")
                        // Until your code has loaded the editor shows it but takes no typing;
                        // a small spinner says why, in a corner, so nothing moves.
                        .overlay(alignment: .topTrailing) {
                            if !session.isLoaded {
                                ProgressView()
                                    .controlSize(.small)
                                    .padding(12)
                                    .help("Loading your code")
                                    .accessibilityLabel("Loading your code")
                            }
                        }
                }
            } else {
                ContentUnavailableView("No Files", systemImage: "doc", description: Text("This lesson has no code to edit."))
            }
        }
        .background(Color(nsColor: SyntaxTheme.xcode.background))
    }
}

/// The editor for one file. Typing changes only the buffer's text, which only this view
/// reads, so a keystroke redraws the editor and not the lesson or the toolbar around it.
struct FileEditor: View {
    @Bindable var buffer: FileBuffer
    let session: CodeSession
    @Environment(AppModel.self) private var app

    var body: some View {
        CodeEditorView(
            text: $buffer.text,
            highlighter: Highlighting.forFile(buffer.name),
            lineSyntax: LineSyntax(fileName: buffer.name),
            fontSize: app.editorFontSize,
            // Typing before your code has loaded could be lost, so it waits for the load.
            isEditable: session.isLoaded && !buffer.readOnly,
            showsLineNumbers: app.showLineNumbers,
            accessibilityLabel: buffer.readOnly ? "\(buffer.name), read only" : buffer.name,
            proxy: session.editor,
            onIdle: { _ in session.save() }
        )
    }
}

/// The editor's place when your code could not load: why, and a way to try again.
struct CodeLoadFailed: View {
    let message: String
    let session: CodeSession
    @ViewState private var retrying = false

    var body: some View {
        ContentUnavailableView {
            Label("Your Code Could Not Load", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
                .foregroundStyle(Theme.secondaryText)
                .textSelection(.enabled)
        } actions: {
            Button {
                retrying = true
                Task {
                    await session.load()
                    retrying = false
                }
            } label: {
                if retrying {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Try Again")
                }
            }
            .secondaryGlassButton()
            .disabled(retrying)
            .help("Load the lesson's code again")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Console

struct ConsolePane: View {
    let session: CodeSession
    @Environment(AppModel.self) private var app

    var body: some View {
        if !session.exercise.runsHere {
            ContentUnavailableView {
                Label(session.exercise.otherLanguageNote, systemImage: "chevron.left.forwardslash.chevron.right")
            } description: {
                Text("You can read the lesson and edit its code here; run it with that language's own tools.")
                    .foregroundStyle(Theme.secondaryText)
            }
            .background(Color(nsColor: .textBackgroundColor))
        } else if let toolchain = app.toolchain, toolchain.go == nil {
            ContentUnavailableView {
                Label("Go Is Not Installed", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Install Go from go.dev/dl, or with Homebrew: brew install go. Then Gopherwood finds it, or set its path in Settings.")
                    .foregroundStyle(Theme.secondaryText)
            } actions: {
                SettingsLink { Text("Open Settings…") }
                    .prominentGlassButton()
            }
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            console
        }
    }

    private var console: some View {
        VStack(spacing: 0) {
            GlassEffectContainer {
                RunStatusBar(session: session)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(8)
            ScrollView {
                ConsoleBody(session: session)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            }
            .textSelection(.enabled)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct RunStatusBar: View {
    let session: CodeSession

    var body: some View {
        let shown = session.isRunning ? nil : session.result
        HStack(spacing: 8) {
            // One icon that stays and changes, so its bounce plays when a Submit passes; during
            // a run it is the turning spinner symbol the command-line steps use.
            Image(systemName: session.isRunning ? "progress.indicator" : shown.map { Self.symbol($0.status) } ?? "terminal")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(session.isRunning ? .primary : shown.map { Self.color($0.status) } ?? .secondary)
                .contentTransition(.symbolEffect(.replace))
                .runningSymbolEffect(session.isRunning)
                .symbolEffect(.bounce, value: session.passCount)
            if session.isRunning {
                Text(session.resultKind == .submit ? "Submitting…" : "Running…")
            } else if let result = shown {
                Text(result.status.label)
                    .fontWeight(.semibold)
                    .foregroundStyle(Self.color(result.status))
                Text(session.resultKind.title)
                    .foregroundStyle(Theme.secondaryText)
                if let summary = result.tests?.summary {
                    // The tests' own count, as they print it.
                    Text(Self.counts(summary))
                        .foregroundStyle(Theme.secondaryText)
                        .monospacedDigit()
                }
            } else {
                Text("Console")
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            if let result = session.result, !session.isRunning {
                Text(result.duration.shortText)
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .font(.system(size: 12.5))
        .accessibilityElement(children: .combine)
    }

    static func counts(_ s: TestOutput.Summary) -> String {
        var parts = ["\(s.passed) passed", "\(s.failed) failed"]
        if s.skipped > 0 { parts.append("\(s.skipped) skipped") }
        return "· " + parts.joined(separator: ", ")
    }

    static func symbol(_ status: RunStatus) -> String {
        switch status {
        case .passed: "checkmark.circle.fill"
        case .ran: "play.circle.fill"
        case .failed: "xmark.circle.fill"
        case .buildError: "hammer.circle.fill"
        case .timeout: "clock.badge.exclamationmark"
        case .cancelled: "stop.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    static func color(_ status: RunStatus) -> Color {
        switch status {
        case .passed: Theme.success
        case .ran: .primary
        case .failed, .buildError, .error: Theme.failure
        case .timeout: Theme.warning
        case .cancelled: Theme.secondaryText
        }
    }

}

struct ConsoleBody: View {
    let session: CodeSession

    var body: some View {
        if let result = session.result {
            VStack(alignment: .leading, spacing: 10) {
                // The cases and the comparison were made off the main actor with the result.
                if let parsed = result.tests, !parsed.cases.isEmpty {
                    if !parsed.before.isEmpty { LongText(text: parsed.before) }
                    let firstFailure = parsed.cases.firstIndex { !$0.passed }
                    ForEach(Array(parsed.cases.enumerated()), id: \.offset) { i, c in
                        TestCaseRow(number: i + 1, testCase: c, expandedAtFirst: i == firstFailure)
                    }
                    if !parsed.after.isEmpty { LongText(text: parsed.after) }
                } else {
                    LongText(text: result.output.isEmpty ? "No output." : result.output, dim: result.output.isEmpty)
                }
                if let comparison = result.comparison {
                    ExpectedOutputDiff(comparison: comparison)
                }
            }
        } else if !session.isRunning {
            Text(session.tests
                 ? "Run checks your code against a few test cases; Submit runs them all and finishes the lesson when they pass."
                 : "Run shows what your program prints; Submit compares it with the expected output.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Monospaced output, shown up to 32 KB; Show All shows the rest.
struct LongText: View {
    let text: String
    var dim = false
    static let limit = 32 << 10
    @ViewState private var showAll = false

    var body: some View {
        let cut = !showAll && text.utf8.count > Self.limit
        VStack(alignment: .leading, spacing: 6) {
            Text(cut ? String(decoding: text.utf8.prefix(Self.limit), as: UTF8.self) + "\n…" : text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(dim ? Theme.secondaryText : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if cut {
                Button("Show All (\(text.utf8.count.formatted(.byteCount(style: .file))))") { showAll = true }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
        }
    }
}

/// One test case, collapsed unless it is the first one that failed.
struct TestCaseRow: View {
    let number: Int
    let testCase: TestOutput.Case
    @ViewState private var expanded: Bool

    init(number: Int, testCase: TestOutput.Case, expandedAtFirst: Bool) {
        self.number = number
        self.testCase = testCase
        _expanded = State(initialValue: expandedAtFirst)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            LongText(text: testCase.body)
                .padding(.top, 4)
                .padding(.leading, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: testCase.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(testCase.passed ? Theme.success : Theme.failure)
                Text("Case \(number)")
                    .fontWeight(.medium)
                Text(testCase.summary)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.system(size: 12.5))
        }
    }
}

/// Expected output against yours, line by line, for a Submit whose output differs: the usual
/// diff, "−" lines (expected) in red and "+" lines (your output) in green. Long lines wrap
/// like readme code, so nothing is out of sight.
struct ExpectedOutputDiff: View {
    let comparison: OutputComparison
    /// Rows shown before Show All.
    static let limit = 300
    @ViewState private var showAll = false

    var body: some View {
        let rows = showAll ? comparison.rows[...] : comparison.rows.prefix(Self.limit)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                Text("Expected output compared with yours")
                    .font(.system(size: 12, weight: .semibold))
                Text(verbatim: "− expected").foregroundStyle(Theme.failure)
                Text(verbatim: "+ your output").foregroundStyle(Theme.success)
            }
            .font(.system(size: 11, design: .monospaced))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Expected output compared with yours: minus lines are expected, plus lines are your output")
            WrappingText(text: Self.text(rows), accessibilityLabel: "Expected output compared with your output")
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            if !showAll && comparison.rows.count > Self.limit {
                Button("Show All \(comparison.rows.count) Lines") { showAll = true }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
        }
    }

    static let size: CGFloat = 12

    /// The rows as one block of text: a two-character marker on each line, continuation lines
    /// hanging past the marker and the line's own indentation.
    static func text(_ rows: ArraySlice<OutputComparison.Row>) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let removed: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.failureNS]
        let added: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.successNS]
        let text = NSMutableAttributedString()
        func line(_ marker: String, _ content: String, _ attributes: [NSAttributedString.Key: Any]) {
            if text.length > 0 { text.append(NSAttributedString(string: "\n", attributes: attributes)) }
            text.append(NSAttributedString(string: marker + content, attributes: attributes))
        }
        for row in rows {
            if row.matches {
                line("  ", row.expected ?? "", plain)
            } else {
                if let expected = row.expected { line("− ", expected, removed) }
                line("+ ", row.actual ?? "(missing)", added)
            }
        }
        CodeText.hangLines(of: text, size: size, marker: 2)
        return text
    }
}
