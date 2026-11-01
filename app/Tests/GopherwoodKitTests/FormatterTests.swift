import Foundation
import Testing
@testable import GopherwoodKit

/// Formatting through gofmt's standard input and output: with stand-ins for gofmt, and with the
/// toolchain's own gofmt, which those tests skip when Go is not installed.
@Suite struct GoFormatterTests {
    /// A formatter whose gofmt is a shell script, in a folder of its own.
    private func formatter(running script: String) throws -> (GoFormatter, URL) {
        let folder = try Fixtures.tempDir("gofmt")
        let path = folder.appendingPathComponent("gofmt").path
        try ("#!/bin/sh\n" + script + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
        let formatter = try #require(GoFormatter(toolchain: Toolchain(environment: ["PATH": "/usr/bin:/bin"], gofmt: path)))
        return (formatter, folder)
    }

    @Test func withoutGofmtThereIsNoFormatter() {
        #expect(GoFormatter(toolchain: Toolchain(environment: [:], go: "/usr/local/go/bin/go", goVersion: "go1.27.3")) == nil)
    }

    @Test func theCodeGoesInAndComesBackWhole() async throws {
        let (formatter, folder) = try formatter(running: "tr a-z A-Z")
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try await formatter.format("package main\n", fileName: "main.go") == "PACKAGE MAIN\n")
        let long = String(repeating: "x", count: 300_000)
        #expect(try await formatter.format(long, fileName: "main.go") == long.uppercased())
    }

    @Test func messagesNameTheFile() async throws {
        let (formatter, folder) = try formatter(running: "cat >/dev/null\necho '<standard input>:3:1: expected declaration, found x' >&2\nexit 2")
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect(throws: GoFormatError.syntax("main.go:3:1: expected declaration, found x")) {
            try await formatter.format("package main\n\nx\n", fileName: "main.go")
        }
    }

    @Test func aGofmtThatFailsOrIsMissingSaysSo() async throws {
        let (crashing, folder) = try formatter(running: "kill -9 $$")
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            _ = try await crashing.format("package main\n", fileName: "main.go")
            Issue.record("a gofmt that was killed gave code back")
        } catch let GoFormatError.failed(message) {
            #expect(message.hasPrefix("gofmt stopped (signal: "), "\(message)")
        }
        let missing = try #require(GoFormatter(toolchain: Toolchain(environment: [:], gofmt: folder.appendingPathComponent("none").path)))
        do {
            _ = try await missing.format("package main\n", fileName: "main.go")
            Issue.record("a missing gofmt gave code back")
        } catch let GoFormatError.failed(message) {
            #expect(message.contains("was not found"), "\(message)")
        }
    }

    @Test func cancellingStopsGofmt() async throws {
        let (formatter, folder) = try formatter(running: "sleep 55.5")
        defer { try? FileManager.default.removeItem(at: folder) }
        let started = ContinuousClock.now
        let task = Task { try await formatter.format("package main\n", fileName: "main.go") }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func formatsWithTheToolchainsGofmt() async throws {
        guard let toolchain = await Fixtures.toolchain(), let formatter = GoFormatter(toolchain: toolchain) else { return } // no Go here
        let gofmt = try #require(toolchain.gofmt)
        #expect(gofmt.hasSuffix("/bin/gofmt") && FileManager.default.isExecutableFile(atPath: gofmt))
        let messy = "package main\nimport \"fmt\"\nfunc main() {\nfmt.Println( \"hi\" )\n}\n"
        let formatted = "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println(\"hi\")\n}\n"
        #expect(try await formatter.format(messy, fileName: "main.go") == formatted)
        #expect(try await formatter.format(formatted, fileName: "main.go") == formatted)
        // Bigger than any pipe's buffer, and formatted already: it comes back as it went in.
        let big = "package main\n\n" + (1...10_000).map { "func f\($0)() int {\n\treturn \($0)\n}\n" }.joined(separator: "\n")
        #expect(try await formatter.format(big, fileName: "main.go") == big)
    }

    @Test func aSyntaxErrorNamesTheFile() async throws {
        guard let toolchain = await Fixtures.toolchain(), let formatter = GoFormatter(toolchain: toolchain) else { return } // no Go here
        await #expect(throws: GoFormatError.syntax("solution.go:5:1: expected operand, found '}'")) {
            try await formatter.format("package main\n\nfunc main() {\n\tx :=\n}\n", fileName: "solution.go")
        }
    }
}
