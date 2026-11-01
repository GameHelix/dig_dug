import Foundation

/// How lines are commented out and indented in a kind of file, which its name tells: Go
/// takes "// " and tabs, as gofmt lays it out; shell scripts, Python, YAML, TOML and
/// Makefiles take "# "; SQL takes "-- ".
public struct LineSyntax: Hashable, Sendable {
    /// What starts a line comment, with the space after it, such as "// ". Nil when the editor
    /// knows no line comment for the file.
    public let commentMarker: String?
    /// The one level of indentation the file always takes, such as a tab in Go; nil when it
    /// follows the indentation the file already has.
    let fixedIndent: String?
    /// One level of indentation for a file that has none to follow yet.
    let defaultIndent: String

    /// For a file by its name, or its path: only the last component counts.
    public init(fileName: String) {
        let name = (fileName as NSString).lastPathComponent.lowercased()
        // go.mod and Makefile by name, the others by extension.
        switch ["go.mod", "makefile"].contains(name) ? name : (name as NSString).pathExtension {
        case "go", "go.mod": self.init(commentMarker: "// ", fixedIndent: "\t")
        case "makefile": self.init(commentMarker: "# ", fixedIndent: "\t")
        case "sh", "bash", "toml": self.init(commentMarker: "# ")
        case "py": self.init(commentMarker: "# ", defaultIndent: "    ")
        case "yaml", "yml": self.init(commentMarker: "# ", defaultIndent: "  ")
        case "sql": self.init(commentMarker: "-- ")
        default: self = .plainText
        }
    }

    init(commentMarker: String?, fixedIndent: String? = nil, defaultIndent: String = "\t") {
        self.commentMarker = commentMarker
        self.fixedIndent = fixedIndent
        self.defaultIndent = defaultIndent
    }

    /// Text with no line comments, indented the way it already is, else with tabs.
    public static let plainText = LineSyntax(commentMarker: nil)

    /// One level of indentation in `text`, as the file's kind and its own lines say.
    func indentUnit(in text: NSString) -> String {
        fixedIndent ?? Indentation.unit(in: text) ?? defaultIndent
    }
}
