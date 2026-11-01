import SwiftUI

/// The code editor's commands: buttons at the end of its file bar, in this order, and the
/// Editor menu.
enum EditorCommand: CaseIterable {
    case format, toggleComment, outdent, indent

    /// The Editor menu's name for it.
    var title: String {
        switch self {
        case .format: "Format Code"
        case .toggleComment: "Toggle Comment"
        case .outdent: "Outdent"
        case .indent: "Indent"
        }
    }

    /// Its button's help when it can act; otherwise the help says why not.
    var help: String {
        switch self {
        case .format: "Format with gofmt (⇧⌥F)"
        case .toggleComment: "Comment or Uncomment Lines (⌘/)"
        case .outdent: "Outdent (⌥⌘[)"
        case .indent: "Indent (⌥⌘])"
        }
    }

    var shortcut: KeyboardShortcut {
        switch self {
        case .format: KeyboardShortcut("f", modifiers: [.shift, .option])
        case .toggleComment: KeyboardShortcut("/", modifiers: .command)
        case .outdent: KeyboardShortcut("[", modifiers: [.command, .option])
        case .indent: KeyboardShortcut("]", modifiers: [.command, .option])
        }
    }
}

/// The commands' buttons: borderless and compact, with the reason in the help when one can't
/// act on the file shown.
struct EditorCommandButtons: View {
    let session: CodeSession

    var body: some View {
        HStack(spacing: 2) {
            ForEach(EditorCommand.allCases, id: \.self) { command in
                let reason = session.unavailability(of: command)
                Button { session.perform(command) } label: {
                    Label { Text(command.title) } icon: { icon(command) }
                        .labelStyle(.iconOnly)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                // A style of its own takes the place of the button's dimming when disabled.
                .foregroundStyle(reason == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .disabled(reason != nil)
                // Outside the disabled button, so it shows on a disabled one too.
                .help(reason ?? command.help)
            }
        }
    }

    @ViewBuilder private func icon(_ command: EditorCommand) -> some View {
        switch command {
        case .format: Image(systemName: "wand.and.stars")
        case .toggleComment: Text(verbatim: "//").font(.system(size: 13, weight: .semibold, design: .monospaced))
        case .outdent: Image(systemName: "decrease.indent")
        case .indent: Image(systemName: "increase.indent")
        }
    }
}
