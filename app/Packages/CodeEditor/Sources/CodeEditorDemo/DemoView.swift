import AppKit
import CodeEditor
import SwiftUI
import SyntaxCore

/// SwiftUI's `@State` is a macro in the macOS 27 SDK, and its plugin ships only with Xcode.
/// The property wrapper behind it works under the Command Line Tools through this alias.
typealias ViewState<Value> = SwiftUI.State<Value>

enum DemoAppearance: String, CaseIterable {
    case system, light, dark

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// The code lives in an observable model that only the editor pane reads, so a keystroke does
/// not re-render the rest of the window.
@Observable
@MainActor
final class DemoDocument {
    var code: String
    var status = "Not saved yet"

    init(code: String) {
        self.code = code
    }
}

struct DemoView: View {
    @ViewState private var document: DemoDocument
    @ViewState private var isLarge: Bool
    @ViewState private var isReadOnly: Bool
    @ViewState private var fontSize: CGFloat
    @ViewState private var showsLineNumbers: Bool
    @ViewState private var appearance: DemoAppearance

    init(options: DemoOptions) {
        _document = ViewState(initialValue: DemoDocument(code: options.isLarge ? SampleCode.large : SampleCode.lesson))
        _isLarge = ViewState(initialValue: options.isLarge)
        _isReadOnly = ViewState(initialValue: options.isReadOnly)
        _fontSize = ViewState(initialValue: options.fontSize)
        _showsLineNumbers = ViewState(initialValue: options.showsLineNumbers)
        _appearance = ViewState(initialValue: options.appearance)
    }

    var body: some View {
        HStack(spacing: 0) {
            ReadmePanel()
                .frame(width: 360)
            Divider()
            EditorPane(document: document, fontSize: fontSize, showsLineNumbers: showsLineNumbers, isReadOnly: isReadOnly)
        }
        .frame(minWidth: 900, minHeight: 560)
        .toolbar {
            ToolbarItem {
                Picker("Sample", selection: $isLarge) {
                    Text("Lesson").tag(false)
                    Text("5,000 Lines").tag(true)
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Toggle("Read Only", systemImage: "lock", isOn: $isReadOnly)
            }
            ToolbarItem {
                Toggle("Line Numbers", systemImage: "list.number", isOn: $showsLineNumbers)
            }
            ToolbarItem {
                Picker("Font Size", selection: $fontSize) {
                    ForEach([11, 12, 13, 14, 16, 18] as [CGFloat], id: \.self) { size in
                        Text("\(Int(size)) pt").tag(size)
                    }
                }
            }
            ToolbarItem {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag(DemoAppearance.system)
                    Text("Light").tag(DemoAppearance.light)
                    Text("Dark").tag(DemoAppearance.dark)
                }
                .pickerStyle(.segmented)
            }
        }
        .onChange(of: isLarge) {
            document.code = isLarge ? SampleCode.large : SampleCode.lesson
            document.status = "Not saved yet"
        }
        .onChange(of: appearance) {
            NSApp.appearance = appearance.nsAppearance
        }
    }
}

/// The editor and a status line. Kept apart so the window's other views do not depend on the
/// code.
private struct EditorPane: View {
    let document: DemoDocument
    let fontSize: CGFloat
    let showsLineNumbers: Bool
    let isReadOnly: Bool

    var body: some View {
        VStack(spacing: 0) {
            CodeEditorView(
                text: Bindable(document).code,
                highlighter: DemoHighlighter(),
                lineSyntax: LineSyntax(fileName: "main.go"),
                fontSize: fontSize,
                isEditable: !isReadOnly,
                showsLineNumbers: showsLineNumbers,
                accessibilityLabel: isReadOnly ? "Test code, read only" : "Code editor"
            ) { [document] text in
                let lines = text.reduce(into: 1) { count, character in
                    if character == "\n" { count += 1 }
                }
                document.status = "Saved \(lines) lines at \(Date.now.formatted(date: .omitted, time: .standard))"
            }
            Divider()
            Text(isReadOnly ? "Read only" : document.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
    }
}

/// A readme column with a code block highlighted by `SyntaxTheme.attributedString`.
private struct ReadmePanel: View {
    private let snippet = SyntaxTheme.xcode.attributedString(
        for: SampleCode.readmeSnippet, highlighter: DemoHighlighter(), fontSize: 13
    )

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Bakery Orders")
                    .font(.system(size: 22, weight: .semibold))
                Text("Every loaf costs two dollars fifty. Write `price` so it turns down orders without an item and returns what the others cost.")
                    .font(.system(size: 15))
                    .lineSpacing(4)
                Text(snippet)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: .rect(cornerRadius: 10))
            }
            .padding(24)
        }
    }
}
