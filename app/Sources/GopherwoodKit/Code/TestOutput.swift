import Foundation

/// The cases in `go test` output. Lesson tests often print each case between dashed lines
/// and end it with a verdict (Pass or Fail, PASS or FAIL), either with fmt (on its own lines)
/// or with t.Errorf (behind a "main_test.go:40:" prefix and indented), and finish with a
/// summary such as "0 passed, 5 failed, 2 skipped"; this finds them either way. What is not a
/// case stays as text before or after the cases.
public struct TestOutput: Sendable, Equatable {
    public struct Case: Sendable, Equatable {
        public var lines: [String]
        public var passed: Bool
        public var body: String { lines.joined(separator: "\n") }
        /// The case's first line, such as its inputs.
        public var summary: String { lines.first { !TestOutput.isVerdict($0) } ?? "" }
    }

    /// A summary line's counts.
    public struct Summary: Sendable, Equatable {
        public var passed: Int
        public var failed: Int
        public var skipped: Int
    }

    public private(set) var before = ""
    public private(set) var cases: [Case] = []
    public private(set) var after = ""
    /// The last "N passed, M failed" line, if the tests print one.
    public private(set) var summary: Summary?

    /// Whether the tests report a failure of their own. Some lesson tests print a Fail
    /// verdict and a summary but never call t.Error, so go test exits 0 and says PASS.
    public var reportsFailure: Bool {
        cases.contains { !$0.passed } || (summary?.failed ?? 0) > 0
    }

    static func isVerdict(_ line: String) -> Bool {
        ["Pass", "Fail", "PASS", "FAIL"].contains(line.trimmingCharacters(in: .whitespaces))
    }

    static func summary(in line: String) -> Summary? {
        guard let m = line.firstMatch(of: /(\d+) passed, (\d+) failed(?:, (\d+) skipped)?/),
              let passed = Int(m.1), let failed = Int(m.2) else { return nil }
        return Summary(passed: passed, failed: failed, skipped: m.3.flatMap { Int($0) } ?? 0)
    }

    public init(_ output: String) {
        var lines: [String] = []
        for raw in output.components(separatedBy: "\n") {
            var line = raw
            if let m = raw.firstMatch(of: /^\s*\S+_test\.go:\d+:\s?(.*)$/) {
                line = String(m.1)
            } else if raw.hasPrefix("        ") {
                line = String(raw.dropFirst(8))
            }
            lines.append(line)
            if let s = TestOutput.summary(in: line) { summary = s }
        }
        let isSeparator = { (l: String) in l.trimmingCharacters(in: .whitespaces).wholeMatch(of: /-{10,}/) != nil }
        guard lines.contains(where: isSeparator) else { return }
        var current: [String] = []
        var head: [String] = []
        var tail: [String] = []
        var sawSeparator = false
        for line in lines {
            if isSeparator(line) {
                if sawSeparator { flush(&current, into: &tail) }
                sawSeparator = true
                continue
            }
            if sawSeparator { current.append(line) } else { head.append(line) }
        }
        flush(&current, into: &tail)
        before = head.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        after = tail.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A block between separators is a case when lines come first and a verdict after them;
    /// the case ends at its verdict, and what follows (go test's own FAIL, exit and ok lines
    /// after the last case) is not part of it. The summary block is never a case.
    private mutating func flush(_ current: inout [String], into tail: inout [String]) {
        defer { current = [] }
        let trimmed = current.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = trimmed.first(where: { !$0.isEmpty }), TestOutput.summary(in: first) == nil,
              let end = trimmed.firstIndex(where: TestOutput.isVerdict),
              trimmed[..<end].contains(where: { !$0.isEmpty }) else {
            tail.append(contentsOf: current)
            return
        }
        let lines = current[...end].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        cases.append(Case(lines: Array(lines), passed: trimmed[end].lowercased() == "pass"))
        tail.append(contentsOf: current[(end + 1)...])
    }
}
