import AppKit

/// Edits an editor's code from outside it, for menu commands and buttons. Pass it to a
/// `CodeEditorView`: it acts on that editor while the editor is on screen, and on the newest
/// one when several take turns, such as one per file. Each edit is one step on the editor's
/// undo stack, and the selection keeps covering the same lines.
@MainActor
public final class CodeEditorProxy {
    private weak var coordinator: CodeEditorView.Coordinator?

    public init() {}

    /// The code as the editor holds it, or nil while no editor is on screen.
    public var text: String? { coordinator?.text }

    /// Indents the selected lines, or the insertion point's line, by one level of the file's
    /// indentation: a tab in Go. Returns whether the code changed.
    @discardableResult
    public func indent() -> Bool {
        perform { $0.indentLines() }
    }

    /// Takes one level of indentation off the selected lines, or the insertion point's line.
    /// Returns whether the code changed.
    @discardableResult
    public func outdent() -> Bool {
        perform { $0.outdentLines() }
    }

    /// Comments out the selected lines, or the insertion point's line, with the file's line
    /// comment, or uncomments them when they all are commented out. Returns whether the code
    /// changed; it does not for a file with no line comments.
    @discardableResult
    public func toggleComment() -> Bool {
        perform { $0.toggleLineComments() }
    }

    /// Replaces the code with `newText`, such as a formatter's output, as one undo step named
    /// `actionName`. The selection keeps its lines and columns where they still exist. Returns
    /// whether the code changed: the same text changes nothing and adds no undo step.
    @discardableResult
    public func replaceText(with newText: String, actionName: String) -> Bool {
        perform { textView in
            guard let edit = TextEdit.replacing(textView.characters, with: newText as NSString, selection: textView.selectedRange()) else {
                return false
            }
            return textView.apply(edit, actionName: actionName)
        }
    }

    func attach(_ coordinator: CodeEditorView.Coordinator) {
        self.coordinator = coordinator
    }

    /// Lets go of an editor that goes away, unless a newer one took its place already.
    func detach(_ coordinator: CodeEditorView.Coordinator) {
        if self.coordinator === coordinator {
            self.coordinator = nil
        }
    }

    /// Edits through the editor's text view, then gives it the keyboard focus, so the result
    /// shows with its selection.
    private func perform(_ edit: (CodeTextView) -> Bool) -> Bool {
        guard let textView = coordinator?.textView else { return false }
        let changed = edit(textView)
        if let window = textView.window, window.firstResponder !== textView {
            window.makeFirstResponder(textView)
        }
        return changed
    }
}
