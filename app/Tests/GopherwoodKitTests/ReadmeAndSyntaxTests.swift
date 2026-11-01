import Foundation
import SyntaxCore
import Testing
@testable import GopherwoodKit

@Suite struct ReadmeTests {
    func one(_ md: String) -> MDBlock? { Readme.parse(md).first }

    /// Excerpts come from the readme as it is shown, so Markdown, callout and system markers
    /// never leak in, brackets stay paired and underscores stay put; a callout's title and a
    /// heading's system label are drawn, so they are in.
    @Test func searchExcerptsShowTheReadmeAsRendered() {
        let readme = """
        # Pantry Maps

        > [!WARNING]
        > Keys of a `map[string]interface{}` come back in no fixed order.

        ## [!windows] For Windows Cooks

        Run the pantry tests in `pantry_test.go` with **care**.
        """
        let text = ReadmeTexts.text(readme, title: "Pantry Maps")
        #expect(!text.contains("[!") && !text.contains("**") && !text.contains("`") && !text.contains("#"))

        let order = Snippet.make(text, query: "order")
        #expect(order.map(\.text).joined() == "…back in no fixed order. Windows For Windows Cooks Run the pantry tests in pantry_test…")
        #expect(Snippet.make(text, query: "keys").map(\.text).joined().hasPrefix("Warning Keys of a map[string]interface{} come back"))
        #expect(Snippet.make(text, query: "warn").filter(\.matched).map(\.text) == ["Warning"])
        #expect(order.filter(\.matched).map(\.text) == ["order"])

        let pantry = Snippet.make(text, query: "pantry")
        #expect(pantry.filter(\.matched).map(\.text) == ["pantry", "pantry"]) // pantry_test splits as the index does
        #expect(pantry.map(\.text).joined().contains("pantry_test.go"))

        // Nothing matched in the text (the title did): the excerpt starts at the beginning.
        #expect(Snippet.make("Salt draws water out.", query: "zzz").map(\.text).joined() == "Salt draws water out.")
    }

    /// The title heading goes even when it quotes or marks code differently from the title.
    @Test func titleHeadingThatDiffersInQuotesOrCode() {
        #expect(Readme.parse("# Why is it called a \"kettle\"?\n\nBecause.", droppingTitle: "Why Is It Called a 'kettle'?") == [.paragraph([.text("Because.")])])
        #expect(Readme.parse("# Sandboxing `teacup` Elements\n\nCarefully.", droppingTitle: "Sandboxing 'teacup' Elements") == [.paragraph([.text("Carefully.")])])
        #expect(Readme.parse("# Another Title\n\nText", droppingTitle: "Pantry Maps").count == 2)
        // A readme that is only its title leaves nothing to show.
        #expect(Readme.parse("# Pantry Maps\n", droppingTitle: "Pantry Maps").isEmpty)
    }

    @Test func inlineHTMLShowsAsCode() {
        #expect(Readme.parseInline("use the <blink> tag") == [.text("use the "), .code("<blink>"), .text(" tag")])
        #expect(Readme.parseInline("one<br>two") == [.text("one"), .lineBreak, .text("two")])
    }

    @Test func superscript() {
        #expect(Readme.parseInline("m^e^ mod n") == [.text("m"), .superscript([.text("e")]), .text(" mod n")])
        #expect(Readme.parseInline("x^-1^") == [.text("x"), .superscript([.text("-1")])])
        // Nested in parentheses and adjacent to another.
        #expect(Readme.parseInline("(m^e^)^d^ (mod n)") == [.text("(m"), .superscript([.text("e")]), .text(")"), .superscript([.text("d")]), .text(" (mod n)")])
        #expect(Readme.parseInline("2^3^^2^") == [.text("2"), .superscript([.text("3")]), .superscript([.text("2")])])
        #expect(Readme.parseInline("**c^2^**") == [.strong([.text("c"), .superscript([.text("2")])])])
        // Never in code, and a caret without its pair is a caret.
        #expect(Readme.parseInline("`a^b^` and x ^ y") == [.code("a^b^"), .text(" and x ^ y")])
        #expect(Readme.plainText([.text("m"), .superscript([.text("e")])]) == "m^e")
    }

    @Test func calloutKinds() {
        #expect(Readme.calloutTitle("info") == "Note" && Readme.calloutKind("info") == "note")
        #expect(Readme.calloutTitle("danger") == "Caution" && Readme.calloutSymbol("danger") == "exclamationmark.octagon")
        #expect(Readme.calloutTitle("mentor") == "Mentor" && Readme.calloutKind("mentor") == "note" && Readme.calloutSymbol("mentor") == "info.circle")
        #expect(Readme.calloutTitle("TIP") != "" && Readme.calloutKind("tip") == "tip")
    }

    @Test func headingsParagraphsAndBreaks() {
        #expect(Readme.parse("# Connections\n\nText") == [.heading(level: 1, tags: [], inlines: [.text("Connections")]), .paragraph([.text("Text")])])
        #expect(Readme.parse("# Hello Gopher\n\nText", droppingTitle: "hello gopher") == [.paragraph([.text("Text")])])
        #expect(Readme.parse("# Other\n\nText", droppingTitle: "Hello").count == 2)
        #expect(one("Title\n=====") == .heading(level: 1, tags: [], inlines: [.text("Title")]))
        // A sentence ending in a year on its own line is not an ordered list.
        #expect(one("It was released in\n2012. Since then") == .paragraph([.text("It was released in"), .softBreak, .text("2012. Since then")]))
        #expect(one("line one  \nline two") == .paragraph([.text("line one"), .lineBreak, .text("line two")]))
        #expect(Readme.parse("a\n\n---\n\nb")[1] == .rule)
    }

    @Test func inlines() {
        #expect(one("Use `x := 1` and **bold** and *it* and ~~old~~.") == .paragraph([
            .text("Use "), .code("x := 1"), .text(" and "), .strong([.text("bold")]), .text(" and "),
            .emphasis([.text("it")]), .text(" and "), .strike([.text("old")]), .text("."),
        ]))
        #expect(one("call snake_case_name now") == .paragraph([.text("call snake_case_name now")]))
        #expect(one("a *int and *string") == .paragraph([.text("a *int and *string")]))
        #expect(one("[Go](https://go.dev) and https://pkg.go.dev.") == .paragraph([
            .link(destination: "https://go.dev", title: nil, children: [.text("Go")]), .text(" and "),
            .link(destination: "https://pkg.go.dev", title: nil, children: [.text("https://pkg.go.dev")]), .text("."),
        ]))
        #expect(one("5 \\* 3 &amp; x") == .paragraph([.text("5 * 3 & x")]))
        #expect(one("Press<br>Enter") == .paragraph([.text("Press"), .lineBreak, .text("Enter")]))
        #expect(Readme.parseInline("`func`") == [.code("func")])
    }

    @Test func codeBlocks() {
        #expect(one("```go\nfunc main() {\n\tfmt.Println(\"<hi>\")\n}\n```") == .code(language: "go", text: "func main() {\n\tfmt.Println(\"<hi>\")\n}"))
        #expect(one("~~~\nplain\n~~~") == .code(language: "", text: "plain"))
    }

    @Test func imagesAndVideosShowNothing() {
        #expect(Readme.parse("![gopher](https://go.dev/g.png)\n\nText") == [.paragraph([.text("Text")])])
        #expect(Readme.parse("![](https://storage.googleapis.com/x/lesson_videos/Intro-1920x1080.mp4)").isEmpty)
        #expect(one("Look: ![g](https://go.dev/g.png) here") == .paragraph([.text("Look: "), .image(alt: "g"), .text(" here")]))
        #expect(Readme.parse("<img src=\"https://cdn/j.png\">\n\nAfter") == [.paragraph([.text("After")])])
        #expect(Readme.parse("<iframe src=\"https://youtube.com/embed/x\"></iframe>").isEmpty)
    }

    @Test func lists() {
        #expect(one("- one\n- two\n  - nested\n- three") == .list(ordered: false, start: 1, tight: true, items: [
            MDListItem(task: nil, blocks: [.paragraph([.text("one")])]),
            MDListItem(task: nil, blocks: [.paragraph([.text("two")]), .list(ordered: false, start: 1, tight: true, items: [
                MDListItem(task: nil, blocks: [.paragraph([.text("nested")])]),
            ])]),
            MDListItem(task: nil, blocks: [.paragraph([.text("three")])]),
        ]))
        if case .list(true, 3, _, let items)? = one("3. c\n4. d") { #expect(items.count == 2) } else { Issue.record("ordered start") }
        if case .list(_, _, _, let items)? = one("1. [ ] Install Go\n2. [x] Log in") {
            #expect(items.map(\.task) == [false, true])
            #expect(items[0].blocks == [.paragraph([.text("Install Go")])])
        } else { Issue.record("task list") }
        #expect(one("1. Run:\n\n   ```bash\n   go run .\n   ```\n2. Done") == .list(ordered: true, start: 1, tight: true, items: [
            MDListItem(task: nil, blocks: [.paragraph([.text("Run:")]), .code(language: "bash", text: "go run .")]),
            MDListItem(task: nil, blocks: [.paragraph([.text("Done")])]),
        ]))
    }

    /// Callouts like > [!NOTE] and OS-tagged headings.
    @Test func calloutsAndOSTags() {
        #expect(one("> [!TIP]\n> Use tabs.") == .quote(callout: "tip", blocks: [.paragraph([.text("Use tabs.")])]))
        #expect(one("> [!warning]\n>\n> The Top 10 is a start.") == .quote(callout: "warning", blocks: [.paragraph([.text("The Top 10 is a start.")])]))
        #expect(one("> [!NOTE] Same line.") == .quote(callout: "note", blocks: [.paragraph([.text("Same line.")])]))
        #expect(one("> [!mentor]\n> Keep it **simple**.") == .quote(callout: "mentor", blocks: [.paragraph([.text("Keep it "), .strong([.text("simple")]), .text(".")])]))
        #expect(one("> quoted *text*\nlazy") == .quote(callout: nil, blocks: [.paragraph([.text("quoted "), .emphasis([.text("text")]), .softBreak, .text("lazy")])]))
        #expect(one("## [!windows] for Windows Users") == .heading(level: 2, tags: ["Windows"], inlines: [.text("for Windows Users")]))
        #expect(one("### [!linux][!windows] Ubuntu (WSL) / Linux") == .heading(level: 3, tags: ["Linux", "Windows"], inlines: [.text("Ubuntu (WSL) / Linux")]))
        #expect(one("## Not [!tagged]") == .heading(level: 2, tags: [], inlines: [.text("Not [!tagged]")]))
        #expect(Readme.calloutTitle("mentor") == "Mentor" && Readme.calloutTitle("caution") == "Caution" && Readme.calloutTitle("warning") == "Warning")
        #expect(Readme.calloutSymbol("warning") == "exclamationmark.triangle")
    }

    @Test func tablesAndHTML() {
        #expect(one("| a | b |\n|:--|--:|\n| `x` | 2 |") == .table(alignments: [.left, .right], header: [[.text("a")], [.text("b")]],
                                                                   rows: [[[.code("x")], [.text("2")]]]))
        #expect(htmlText("<details>\n<summary>Hint</summary>\n<script>alert(1)</script>Use &amp; enjoy</details>") == ["Hint", "Use & enjoy"])
        #expect(one("<details>\n<summary>Hint</summary>\nText\n</details>") == .html(["Hint", "Text"]))
    }

    @Test func oddInputNeverCrashes() {
        for md in ["", "#", "* ", "> ", "```", "[", "![", "**", "| a |\n|---|", "1. \n2. ", "<!--", "&#xFFFFFFF;", "`a``b`", "_a_b_", "~~~~", "[a](<b", "> [!", "## [!"] {
            _ = Readme.parse(md)
        }
    }
}

@Suite struct GoLexerTests {
    func kinds(_ code: String) -> [(String, SyntaxKind)] {
        let ns = code as NSString
        return GoLexer.tokens(code).map { (ns.substring(with: $0.range), $0.kind) }
    }

    @Test func keywordsTypesConstantsAndCalls() {
        let t = kinds("package main\n\n// hi\nfunc add(a int) string { return fmt.Sprint(a + len(x), \"s\", nil, true) }")
        let map = Dictionary(t, uniquingKeysWith: { a, _ in a })
        #expect(map["package"] == .keyword && map["func"] == .keyword && map["return"] == .keyword)
        #expect(map["// hi"] == .comment && map["\"s\""] == .string)
        #expect(map["int"] == .typeName && map["string"] == .typeName && map["nil"] == .builtin && map["true"] == .builtin)
        #expect(map["add"] == .function && map["Sprint"] == .function && map["len"] == .builtin)
        #expect(map["main"] == nil && map["fmt"] == nil && map["a"] == nil)
    }

    @Test func literalsFollowTheSpec() {
        let numbers = ["42", "4_2", "0600", "0o600", "0O600", "0xBadFace", "0x_67_7a_2f_cc_40_c6", "0b1011", "0.", "72.40", "072.40",
                       "2.71828", "1.e+0", "6.67428e-11", "1E6", ".25", ".12345E+5", "1_5.", "0.15e+0_2", "0x1p-2", "0x2.p10", "0x1.Fp+0",
                       "0X.8p-0", "0x15e", "0i", "0123i", "0o123i", "0xabci", "1e3i", "0x1p-2i"]
        for n in numbers {
            #expect(kinds(n).map(\.0) == [n] && kinds(n).first?.1 == .number, "\(n)")
        }
        #expect(kinds("'a' '\\n' '\\x07' '\\u12e4'").map(\.1) == [.string, .string, .string, .string])
        #expect(kinds("`raw\nstring` \"esc\\\"aped\"").map(\.0) == ["`raw\nstring`", "\"esc\\\"aped\""])
        #expect(kinds("/* a\nb */ x").first?.0 == "/* a\nb */")
        // Unterminated literals stop at the end of their line, so typing stays cheap.
        #expect(kinds("x := \"open\nfunc").map(\.0) == ["\"open", "func"])
    }

    @Test func declarationsAndUnicode() {
        let t = kinds("type Server struct{}\nfunc (s *Server) handle(w int) {}\nvar größe = 1")
        #expect(t.contains { $0.0 == "Server" && $0.1 == .typeName })
        #expect(t.contains { $0.0 == "handle" && $0.1 == .function })
        #expect(!t.contains { $0.0 == "s" })
        #expect(t.contains { $0.0 == "1" && $0.1 == .number })
        // Ranges are UTF-16 offsets.
        let code = "// é\nx"
        #expect(GoLexer.tokens(code).first?.range == NSRange(location: 0, length: 4))
    }

    @Test func highlighterByLanguageAndFile() {
        #expect(Highlighting.forLanguage("Go") is GoLexer && Highlighting.forLanguage("golang") is GoLexer)
        #expect(Highlighting.forLanguage("sh") is PlainTextHighlighter && Highlighting.forLanguage("") is PlainTextHighlighter)
        #expect(Highlighting.forFile("main_test.go") is GoLexer && Highlighting.forFile("go.mod") is PlainTextHighlighter)
        // The protocol entry point the editor calls gives the same tokens, sorted and apart.
        let code = "func f() int { return len(\"é\") + 'x' }"
        let tokens = GoLexer().tokens(in: code)
        #expect(tokens == GoLexer.tokens(code))
        #expect(zip(tokens, tokens.dropFirst()).allSatisfy { NSMaxRange($0.range) <= $1.range.location })
    }
}

@Suite struct ProcessRunnerTests {
    let env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]

    @Test func readsBothStreamsAtOnce() async {
        // 200 KB on each stream: a runner reading one pipe at a time would stall here.
        let out = await ProcessRunner.run(ProcessRequest(executable: "/bin/sh", arguments: ["-c", "head -c 200000 /dev/zero | tr '\\0' o; head -c 200000 /dev/zero | tr '\\0' e >&2"],
                                                         directory: "/tmp", environment: env, timeout: .seconds(20), outputLimit: 1 << 20))
        #expect(out.exitCode == 0 && out.stdout.count == 200_000 && out.stderr.count == 200_000 && out.combined.count == 400_000)
    }

    @Test func resolvesExecutablesAndReportsLaunchErrors() async {
        #expect(ProcessRunner.resolve("ls", environment: env) == "/bin/ls")
        let missing = await ProcessRunner.run(ProcessRequest(executable: "no-such-program-xyz", arguments: [], directory: "/tmp", environment: env))
        #expect(missing.launchError != nil && !missing.succeeded)
        let failing = await ProcessRunner.run(ProcessRequest(executable: "/bin/sh", arguments: ["-c", "exit 3"], directory: "/tmp", environment: env))
        #expect(failing.exitCode == 3)
        let pwd = await ProcessRunner.run(ProcessRequest(executable: "/bin/pwd", arguments: [], directory: "/usr", environment: env))
        #expect(pwd.stdout == "/usr\n")
    }

    @Test func capsOutput() async {
        let out = await ProcessRunner.run(ProcessRequest(executable: "/usr/bin/yes", arguments: [], directory: "/tmp", environment: env,
                                                         timeout: .seconds(1), outputLimit: 4096))
        #expect(out.timedOut && out.truncated && out.combined.utf8.count == 4096)
    }

    /// A timeout kills the whole process group, children included.
    @Test func timeoutKillsTheGroup() async throws {
        let out = await ProcessRunner.run(ProcessRequest(executable: "/bin/sh", arguments: ["-c", "sleep 33.25 & sleep 33.5"],
                                                         directory: "/tmp", environment: env, timeout: .milliseconds(500)))
        #expect(out.timedOut)
        #expect(out.duration < .seconds(5))
        try await Task.sleep(for: .milliseconds(200))
        let left = await ProcessRunner.run(ProcessRequest(executable: "/usr/bin/pgrep", arguments: ["-f", "sleep 33.25"], directory: "/tmp", environment: env))
        #expect(left.exitCode == 1) // nothing left: the background sleep went with its group
    }

    @Test func cancellingTheTaskKillsTheGroup() async throws {
        let task = Task {
            await ProcessRunner.run(ProcessRequest(executable: "/bin/sh", arguments: ["-c", "sleep 44.25 & sleep 44.5"], directory: "/tmp",
                                                   environment: env, timeout: .seconds(60)))
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let out = await task.value
        #expect(out.cancelled && !out.succeeded)
        #expect(out.duration < .seconds(5))
        try await Task.sleep(for: .milliseconds(200))
        let left = await ProcessRunner.run(ProcessRequest(executable: "/usr/bin/pgrep", arguments: ["-f", "sleep 44"], directory: "/tmp", environment: env))
        #expect(left.exitCode == 1)
    }
}
