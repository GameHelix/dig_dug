import Foundation
import Markdown

// Lesson readmes: Apple's swift-markdown parses them (CommonMark with GitHub's tables, task
// lists, strikethrough and autolinks), and visitors map the tree to this render model.
// Three extensions are applied on top: callouts like `> [!NOTE]`, OS-tagged headings like
// `## [!windows] Install`, and `^superscript^` in prose (never in code).
// Images and videos become `.image` and are never shown; other inline HTML shows as literal
// code-styled text.

public indirect enum MDInline: Equatable, Sendable {
    case text(String)
    case code(String)
    case emphasis([MDInline])
    case strong([MDInline])
    case strike([MDInline])
    /// `^text^`: m^e^ is m to the power e.
    case superscript([MDInline])
    case link(destination: String, title: String?, children: [MDInline])
    /// An image or a video embed; shown as nothing.
    case image(alt: String)
    case lineBreak
    case softBreak
}

public enum MDAlignment: Equatable, Sendable { case none, left, center, right }

public indirect enum MDBlock: Equatable, Sendable {
    /// `tags` are the operating systems a heading is for, from `## [!windows] …`.
    case heading(level: Int, tags: [String], inlines: [MDInline])
    case paragraph([MDInline])
    case code(language: String, text: String)
    /// `callout` is the kind of a `> [!tip]` callout, lowercased.
    case quote(callout: String?, blocks: [MDBlock])
    case list(ordered: Bool, start: Int, tight: Bool, items: [MDListItem])
    case table(alignments: [MDAlignment], header: [[MDInline]], rows: [[[MDInline]]])
    case rule
    /// The readable text of a raw HTML block, a line per entry; media and scripts removed.
    case html([String])
}

public struct MDListItem: Equatable, Sendable {
    /// nil for a plain item; for a task item, whether it is ticked.
    public var task: Bool?
    public var blocks: [MDBlock]

    public init(task: Bool?, blocks: [MDBlock]) {
        self.task = task
        self.blocks = blocks
    }
}

public enum Readme {
    /// Parses a readme. A first heading that repeats `title` is left out, since the lesson
    /// header shows the title; it repeats it when the two read the same once case, quotes,
    /// code marks, punctuation and spacing are set aside.
    public static func parse(_ markdown: String, droppingTitle title: String? = nil) -> [MDBlock] {
        let document = Document(parsing: markdown, options: [.disableSmartOpts])
        var builder = BlockBuilder()
        var blocks = builder.visit(document)
        if let title, case .heading(1, _, let inlines)? = blocks.first, comparable(plainText(inlines)) == comparable(title) {
            blocks.removeFirst()
        }
        return blocks
    }

    /// Letters, digits and single spaces, lowercased: "Why Is It Called a 'mutex'?" and
    /// "Why is it called a `mutex`" are the same title.
    static func comparable(_ title: String) -> String {
        title.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0) }
            .map(String.init).joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// One line of inline Markdown, such as a quiz answer.
    public static func parseInline(_ markdown: String) -> [MDInline] {
        let blocks = parse(markdown)
        if case .paragraph(let inlines)? = blocks.first, blocks.count == 1 { return inlines }
        return [.text(markdown)]
    }

    /// The text of inlines without markup.
    public static func plainText(_ inlines: [MDInline]) -> String {
        inlines.map { i -> String in
            switch i {
            case .text(let s), .code(let s): s
            case .emphasis(let c), .strong(let c), .strike(let c), .link(_, _, let c): plainText(c)
            case .superscript(let c): "^" + plainText(c)
            case .image: ""
            case .lineBreak, .softBreak: " "
            }
        }.joined()
    }

    /// The text of blocks as the reader sees it, a block per line: no Markdown marks, no
    /// callout or system markers, but a callout's title and a heading's system labels, as
    /// they are drawn.
    public static func plainText(_ blocks: [MDBlock]) -> String {
        blocks.map { block -> String in
            switch block {
            case .heading(_, let tags, let inlines): (tags + [plainText(inlines)]).joined(separator: " ")
            case .paragraph(let inlines): plainText(inlines)
            case .code(_, let text): text
            case .quote(let callout, let blocks): (callout.map { calloutTitle($0) + "\n" } ?? "") + plainText(blocks)
            case .list(_, _, _, let items): items.map { plainText($0.blocks) }.joined(separator: "\n")
            case .table(_, let header, let rows): ([header] + rows).map { $0.map(plainText).joined(separator: "  ") }.joined(separator: "\n")
            case .html(let lines): lines.joined(separator: "\n")
            case .rule: ""
            }
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// The five kinds of callout look as GitHub draws them; info is a note and danger a
    /// caution. Any other kind (a callout named for someone, say) looks like a note, titled
    /// with its kind.
    static func calloutStyle(_ kind: String) -> String {
        switch kind {
        case "tip", "important", "warning", "caution": kind
        case "danger": "caution"
        default: "note"
        }
    }

    /// A callout's title: Note, Tip, Important, Warning or Caution, else its kind, capitalized.
    public static func calloutTitle(_ kind: String) -> String {
        switch kind {
        case "note", "info": "Note"
        case "tip", "important", "warning", "caution", "danger": calloutStyle(kind).capitalized
        default: kind.prefix(1).uppercased() + kind.dropFirst().lowercased()
        }
    }

    public static func calloutSymbol(_ kind: String) -> String {
        switch calloutStyle(kind) {
        case "tip": "lightbulb"
        case "important": "exclamationmark.bubble"
        case "warning": "exclamationmark.triangle"
        case "caution": "exclamationmark.octagon"
        default: "info.circle"
        }
    }

    /// The style a callout is drawn in: note, tip, important, warning or caution.
    public static func calloutKind(_ kind: String) -> String { calloutStyle(kind) }
}

// MARK: - Visitors

struct BlockBuilder: MarkupVisitor {
    typealias Result = [MDBlock]

    mutating func defaultVisit(_ markup: Markup) -> [MDBlock] {
        markup.children.flatMap { visit($0) }
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> [MDBlock] {
        let inlines = InlineBuilder.build(paragraph)
        // A paragraph of nothing but images or videos disappears.
        return Readme.plainText(inlines).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [.paragraph(inlines)]
    }

    mutating func visitHeading(_ heading: Heading) -> [MDBlock] {
        let (tags, inlines) = osTags(InlineBuilder.build(heading))
        return [.heading(level: heading.level, tags: tags, inlines: inlines)]
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> [MDBlock] {
        var code = codeBlock.code
        if code.hasSuffix("\n") { code.removeLast() }
        return [.code(language: (codeBlock.language ?? "").lowercased(), text: code)]
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> [MDBlock] {
        var blocks = defaultVisit(blockQuote)
        var callout: String? = nil
        if case .paragraph(var inlines)? = blocks.first, case .text(let first)? = inlines.first,
           let marker = first.prefixMatch(of: /\[!([A-Za-z]+)\][ \t]*/) {
            callout = marker.1.lowercased()
            let rest = String(first[marker.range.upperBound...])
            inlines.removeFirst()
            if !rest.isEmpty {
                inlines.insert(.text(rest), at: 0)
            } else if let next = inlines.first, next == .softBreak || next == .lineBreak {
                inlines.removeFirst()
            }
            if Readme.plainText(inlines).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.removeFirst()
            } else {
                blocks[0] = .paragraph(inlines)
            }
        }
        return [.quote(callout: callout, blocks: blocks)]
    }

    mutating func visitOrderedList(_ list: OrderedList) -> [MDBlock] {
        let items = Array(list.listItems.map { BlockBuilder.item($0) })
        return [.list(ordered: true, start: Int(list.startIndex), tight: isTight(items), items: items)]
    }

    mutating func visitUnorderedList(_ list: UnorderedList) -> [MDBlock] {
        let items = Array(list.listItems.map { BlockBuilder.item($0) })
        return [.list(ordered: false, start: 1, tight: isTight(items), items: items)]
    }

    static func item(_ listItem: ListItem) -> MDListItem {
        let task: Bool? = switch listItem.checkbox {
        case .checked?: true
        case .unchecked?: false
        case nil: nil
        }
        var builder = BlockBuilder()
        return MDListItem(task: task, blocks: builder.defaultVisit(listItem))
    }

    /// Without cmark's own flag at hand: a list is tight when no item holds more than one
    /// paragraph.
    func isTight(_ items: [MDListItem]) -> Bool {
        items.allSatisfy { item in item.blocks.filter { if case .paragraph = $0 { true } else { false } }.count <= 1 }
    }

    mutating func visitTable(_ table: Table) -> [MDBlock] {
        let alignments: [MDAlignment] = table.columnAlignments.map {
            switch $0 {
            case .left?: .left
            case .center?: .center
            case .right?: .right
            case nil: .none
            }
        }
        let header: [[MDInline]] = Array(table.head.cells.map { InlineBuilder.build($0) })
        let rows: [[[MDInline]]] = Array(table.body.rows.map { row in Array(row.cells.map { InlineBuilder.build($0) }) })
        let width = max(header.count, rows.map(\.count).max() ?? 0)
        func pad(_ cells: [[MDInline]]) -> [[MDInline]] { cells + Array(repeating: [], count: max(0, width - cells.count)) }
        return [.table(alignments: alignments + Array(repeating: .none, count: max(0, width - alignments.count)),
                       header: pad(header), rows: rows.map(pad))]
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> [MDBlock] { [.rule] }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> [MDBlock] {
        let lines = htmlText(html.rawHTML)
        return lines.isEmpty ? [] : [.html(lines)]
    }

    /// OS-tagged headings: [!windows]-style markers before a heading's text name the systems
    /// the steps below it are for.
    func osTags(_ inlines: [MDInline]) -> ([String], [MDInline]) {
        guard case .text(var text)? = inlines.first else { return ([], inlines) }
        var tags: [String] = []
        let names = ["windows": "Windows", "linux": "Linux", "macos": "macOS", "mac": "macOS", "wsl": "WSL"]
        while let m = text.prefixMatch(of: /\[!([A-Za-z]+)\][ \t]*/) {
            tags.append(names[m.1.lowercased()] ?? String(m.1))
            text = String(text[m.range.upperBound...])
        }
        guard !tags.isEmpty else { return ([], inlines) }
        var rest = inlines
        rest.removeFirst()
        if !text.isEmpty { rest.insert(.text(text), at: 0) }
        return (tags, rest)
    }
}

struct InlineBuilder: MarkupVisitor {
    typealias Result = [MDInline]

    static func build(_ markup: Markup) -> [MDInline] {
        var b = InlineBuilder()
        return superscripts(linkify(merge(b.defaultVisit(markup))))
    }

    /// `^text^` in prose becomes superscript: no spaces inside, and a caret without its pair
    /// stays a caret. Code is never touched. "(m^e^)^d^" is (m to the e) to the d.
    static func superscripts(_ inlines: [MDInline]) -> [MDInline] {
        inlines.flatMap { inline -> [MDInline] in
            switch inline {
            case .text(let s):
                guard s.contains("^") else { return [inline] }
                var out: [MDInline] = []
                var rest = Substring(s)
                while let m = rest.firstMatch(of: /\^([^\s^]+)\^/) {
                    if m.range.lowerBound > rest.startIndex { out.append(.text(String(rest[..<m.range.lowerBound]))) }
                    out.append(.superscript([.text(String(m.1))]))
                    rest = rest[m.range.upperBound...]
                }
                if !rest.isEmpty { out.append(.text(String(rest))) }
                return out
            case .emphasis(let c): return [.emphasis(superscripts(c))]
            case .strong(let c): return [.strong(superscripts(c))]
            case .strike(let c): return [.strike(superscripts(c))]
            case .link(let d, let t, let c): return [.link(destination: d, title: t, children: superscripts(c))]
            default: return [inline]
            }
        }
    }

    /// Bare web addresses in text become links, as on GitHub; a trailing period or bracket
    /// stays text. Text inside a link is left alone.
    static func linkify(_ inlines: [MDInline]) -> [MDInline] {
        inlines.flatMap { inline -> [MDInline] in
            switch inline {
            case .text(let s):
                guard s.contains("http") else { return [inline] }
                var out: [MDInline] = []
                var rest = Substring(s)
                while let m = rest.firstMatch(of: /https?:\/\/[^\s<]*[^\s<.,:;"')\]!?*_~]/) {
                    if m.range.lowerBound > rest.startIndex { out.append(.text(String(rest[..<m.range.lowerBound]))) }
                    out.append(.link(destination: String(m.0), title: nil, children: [.text(String(m.0))]))
                    rest = rest[m.range.upperBound...]
                }
                if !rest.isEmpty { out.append(.text(String(rest))) }
                return out
            case .emphasis(let c): return [.emphasis(linkify(c))]
            case .strong(let c): return [.strong(linkify(c))]
            case .strike(let c): return [.strike(linkify(c))]
            default: return [inline]
            }
        }
    }

    /// Joins neighbouring text runs, which cmark splits at brackets and other punctuation.
    static func merge(_ inlines: [MDInline]) -> [MDInline] {
        var out: [MDInline] = []
        for i in inlines {
            if case .text(let s) = i, case .text(let prev)? = out.last {
                out[out.count - 1] = .text(prev + s)
            } else {
                out.append(i)
            }
        }
        return out
    }

    mutating func defaultVisit(_ markup: Markup) -> [MDInline] {
        markup.children.flatMap { visit($0) }
    }

    mutating func visitText(_ text: Markdown.Text) -> [MDInline] { [.text(text.string)] }
    mutating func visitInlineCode(_ code: InlineCode) -> [MDInline] { [.code(code.code)] }
    mutating func visitEmphasis(_ e: Emphasis) -> [MDInline] { [.emphasis(InlineBuilder.merge(defaultVisit(e)))] }
    mutating func visitStrong(_ s: Strong) -> [MDInline] { [.strong(InlineBuilder.merge(defaultVisit(s)))] }
    mutating func visitStrikethrough(_ s: Strikethrough) -> [MDInline] { [.strike(InlineBuilder.merge(defaultVisit(s)))] }
    mutating func visitSoftBreak(_ b: SoftBreak) -> [MDInline] { [.softBreak] }
    mutating func visitLineBreak(_ b: LineBreak) -> [MDInline] { [.lineBreak] }
    mutating func visitImage(_ image: Image) -> [MDInline] { [.image(alt: image.plainText)] }
    mutating func visitSymbolLink(_ s: SymbolLink) -> [MDInline] { [.code(s.destination ?? "")] }

    mutating func visitLink(_ link: Link) -> [MDInline] {
        [.link(destination: link.destination ?? "", title: link.title, children: InlineBuilder.merge(defaultVisit(link)))]
    }

    /// <br> breaks the line; any other inline HTML is shown as it is written, as code.
    mutating func visitInlineHTML(_ html: InlineHTML) -> [MDInline] {
        html.rawHTML.wholeMatch(of: /<br\s*\/?>/.ignoresCase()) != nil ? [.lineBreak] : [.code(html.rawHTML)]
    }
}

/// The readable text of a raw HTML block: no scripts, styles, comments or media; a
/// <summary> or a closing block tag ends a line.
public func htmlText(_ html: String) -> [String] {
    var s = html
    for pattern in [#"<script\b[\s\S]*?</script\s*>"#, #"<style\b[\s\S]*?</style\s*>"#, #"<!--[\s\S]*?-->"#] {
        s = s.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
    }
    s = s.replacingOccurrences(of: #"<br\s*/?>|</(p|div|summary|li|h[1-6]|tr|details)>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
    s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    return s.components(separatedBy: "\n").compactMap { line in
        let t = decodeEntities(line).trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}

private let namedEntities: [String: String] = [
    "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "copy": "©", "reg": "®",
    "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
    "larr": "←", "rarr": "→", "times": "×", "deg": "°", "middot": "·", "bull": "•",
]

func decodeEntities(_ text: String) -> String {
    text.replacing(/&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z][a-zA-Z0-9]{1,31});/) { m in
        let body = String(m.1)
        if body.hasPrefix("#x") || body.hasPrefix("#X") {
            if let n = UInt32(body.dropFirst(2), radix: 16), let u = Unicode.Scalar(n) { return String(Character(u)) }
        } else if body.hasPrefix("#") {
            if let n = UInt32(body.dropFirst()), let u = Unicode.Scalar(n) { return String(Character(u)) }
        } else if let named = namedEntities[body] {
            return named
        }
        return String(m.0)
    }
}
