import Foundation
import Testing
@testable import GopherwoodKit

/// Real `go build` and `go test` runs with the overlay, on lessons written for these tests.
@Suite(.serialized) struct RunnerTests {
    func lesson(_ id: String, _ type: LessonType, _ code: CodeExercise) -> LessonDetail { Fixtures.codeLesson(id, type, code) }

    @Test func testsLessonRunsTheRunCasesAndSubmitRunsAll() async throws {
        guard let toolchain = await Fixtures.toolchain() else { return } // no Go on this machine
        let root = try Fixtures.tempDir("work")
        defer { try? FileManager.default.removeItem(at: root) }
        let ws = Workspace(root: root)
        let code = CodeExercise(starterFiles: [
            StarterFile(name: "main.go", content: "package main\n\nfunc add(a, b int) int {\n\treturn 0\n}\n"),
            StarterFile(name: "main_test.go", content: Fixtures.addTests, isReadonly: true),
            StarterFile(name: "main_js_test.go", content: Fixtures.wasmOnly, isHidden: true, isReadonly: true),
        ])
        let l = lesson("tests-lesson", .codeTests, code)
        let prepared = try ws.prepare(l, code: code, saved: [:], goVersion: toolchain.languageVersion)
        let dir = prepared.folder
        #expect(dir.lastPathComponent == "tests-lesson")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("main_js_test.go").path)) // hidden: never written
        let perms = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("main_test.go").path)[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o444)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("README.md").path))
        #expect(prepared.files.map(\.name) == ["main.go", "main_test.go"] && prepared.files[1].readOnly)

        let runner = GoRunner(toolchain: toolchain, scratch: root.appendingPathComponent(".runs"))
        #expect(await runner.run(code, tests: true, folder: dir, submit: false).status == .failed)
        // Each run's overlay and binary live under work/.runs and go when the run ends.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".runs").path).isEmpty)

        // Right for the run cases only: a Run passes, a Submit does not.
        try ws.write(l, name: "main.go", content: "package main\n\nfunc add(a, b int) int {\n\tif a > 100 {\n\t\treturn 0\n\t}\n\treturn a + b\n}\n")
        let run = await runner.run(code, tests: true, folder: dir, submit: false)
        #expect(run.status == .passed && !run.output.contains("1000"), "\(run.output)")
        let submit = await runner.run(code, tests: true, folder: dir, submit: true)
        #expect(submit.status == .failed && submit.output.contains("add(1000, 1)"), "\(submit.output)")

        // Editing the tests on disk does not change what is checked.
        chmod(dir.appendingPathComponent("main_test.go").path, 0o644)
        try "package main\n\nvar withSubmit = true\n".write(to: dir.appendingPathComponent("main_test.go"), atomically: true, encoding: .utf8)
        #expect(await runner.run(code, tests: true, folder: dir, submit: true).status == .failed)

        try ws.write(l, name: "main.go", content: "package main\n\nfunc add(a, b int) int {\n\treturn a + b\n}\n")
        let pass = await runner.run(code, tests: true, folder: dir, submit: true)
        #expect(pass.status == .passed, "\(pass.output)")
        #expect(pass.durationMs > 0)

        try ws.write(l, name: "main.go", content: "package main\n\nfunc add(a, b int) int {\n\treturn a +\n}\n")
        #expect(await runner.run(code, tests: true, folder: dir, submit: false).status == .buildError)
        #expect(throws: WorkspaceError.self) { try ws.write(l, name: "../escape.go", content: "x") }
    }

    @Test func outputLessonComparesWhatItPrints() async throws {
        guard let toolchain = await Fixtures.toolchain() else { return }
        let root = try Fixtures.tempDir("work")
        defer { try? FileManager.default.removeItem(at: root) }
        let ws = Workspace(root: root)
        let code = CodeExercise(starterFiles: [StarterFile(name: "main.go", content: "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println(\"Hello, world\")\n}\n")],
                                expectedOutput: "Hello, gopher\n2 + 2 = 4\n")
        let l = lesson("output-lesson", .code, code)
        let dir = try ws.prepare(l, code: code, saved: [:], goVersion: toolchain.languageVersion).folder
        let runner = GoRunner(toolchain: toolchain, scratch: root.appendingPathComponent(".runs"))

        let run = await runner.run(code, tests: false, folder: dir, submit: false)
        #expect(run.status == .ran && run.output == "Hello, world\n")
        let wrong = await runner.run(code, tests: false, folder: dir, submit: true)
        #expect(wrong.status == .failed && wrong.expected == "Hello, gopher\n2 + 2 = 4\n")

        try ws.write(l, name: "main.go", content: "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println(\"Hello, gopher\")\n\tfmt.Printf(\"2 + 2 = %d  \\r\\n\", 4)\n}\n")
        #expect(await runner.run(code, tests: false, folder: dir, submit: true).status == .passed) // trailing spaces and CRLF do not matter

        try ws.write(l, name: "main.go", content: "package main\n\nfunc main() {\n\tx := \n}\n")
        let broken = await runner.run(code, tests: false, folder: dir, submit: false)
        #expect(broken.status == .buildError && broken.output.contains("main.go"))

        try ws.write(l, name: "main.go", content: "package main\n\nfunc main() {\n\tpanic(\"boom\")\n}\n")
        let panicked = await runner.run(code, tests: false, folder: dir, submit: false)
        #expect(panicked.status == .failed && panicked.output.contains("boom") && panicked.output.contains("exit status 2"))

        try ws.write(l, name: "main.go", content: "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfor {\n\t\tfmt.Println(\"again\")\n\t}\n}\n")
        let endless = await runner.run(code, tests: false, folder: dir, submit: false)
        #expect(endless.status == .timeout && endless.output.utf8.count < GoRunner.maxOutput + 1000)
        #expect(endless.duration < .seconds(30))
    }

    @Test func aRunCanBeStopped() async throws {
        guard let toolchain = await Fixtures.toolchain() else { return }
        let root = try Fixtures.tempDir("work")
        defer { try? FileManager.default.removeItem(at: root) }
        let code = CodeExercise(starterFiles: [StarterFile(name: "main.go", content: "package main\n\nimport \"time\"\n\nfunc main() {\n\ttime.Sleep(time.Minute)\n}\n")])
        let l = lesson("stop-lesson", .code, code)
        let dir = try Workspace(root: root).prepare(l, code: code, saved: [:], goVersion: toolchain.languageVersion).folder
        let task = Task { await GoRunner(toolchain: toolchain, scratch: root.appendingPathComponent(".runs")).run(code, tests: false, folder: dir, submit: false) }
        try await Task.sleep(for: .seconds(4))
        task.cancel()
        let result = await task.value
        #expect(result.status == .cancelled)
    }

    @Test func outputNamesTheLessonsFiles() {
        let folder = URL(fileURLWithPath: "/Users/me/Library/Caches/Gopherwood/work/abc")
        let raw = "/Users/me/Library/Caches/Gopherwood/work/.runs/run-VIBkng/overlay-0-main_test.go:37:7: not enough arguments\n/Users/me/Library/Caches/Gopherwood/work/abc/main.go:3:1: syntax error"
        #expect(GoRunner.readablePaths(raw, folder: folder) == "main_test.go:37:7: not enough arguments\nmain.go:3:1: syntax error")
    }

    @Test func normalizeOutput() {
        #expect(GoRunner.normalizeOutput("a  \r\nb\t\n\n") == GoRunner.normalizeOutput("a\nb"))
        #expect(GoRunner.normalizeOutput("a\n b") != GoRunner.normalizeOutput("a\nb"))
        #expect(GoRunner.declaresWithSubmit(Fixtures.addTests) == "main")
        #expect(GoRunner.declaresWithSubmit("package main\n\nfunc x() { withSubmit = true }") == nil)
    }
}

/// Your code lives in the database; the work folder is disposable and reconciled with it.
@Suite struct TestOutputTests {
    @Test func casesPrintedThroughErrorf() {
        let output = """
        ---------------------------------
        0 passed, 3 failed, 2 skipped
        --- FAIL: Test (0.00s)
            main_test.go:40: ---------------------------------
                Recipe:     pancakes
                Expecting:  3 eggs
                Actual:     0 eggs
                Fail
            main_test.go:40: ---------------------------------
                Recipe:     omelette
                Expecting:  2 eggs
                Actual:     0 eggs
                Fail
            main_test.go:40: ---------------------------------
                Recipe:     meringue
                Expecting:  4 eggs
                Actual:     0 eggs
                Fail
        FAIL
        exit status 1
        FAIL\tlesson\t0.152s
        """
        let parsed = TestOutput(output)
        #expect(parsed.cases.count == 3)
        #expect(parsed.cases.map(\.passed) == [false, false, false])
        #expect(parsed.cases[2].summary == "Recipe:     meringue" && parsed.cases[2].lines.last == "Fail")
        #expect(parsed.after.hasPrefix("0 passed, 3 failed, 2 skipped") && parsed.after.hasSuffix("FAIL\tlesson\t0.152s"))
    }

    @Test func uppercaseVerdictsAndGoTestsOwnTrailer() {
        // A failing case printed with FAIL, no t.Error, and go test's own PASS after it.
        let output = """
        ---------------------------------
        Filling 1 jar...

        jar 1 is full

        want jars: 1
        got jars:  1
        PASS
        ---------------------------------
        Filling 3 jars...

        want jars: 3
        got jars:  1
        FAIL
        ---------------------------------
        1 passed, 1 failed, 3 skipped
        PASS
        ok  \tlesson\t0.2s
        """
        let parsed = TestOutput(output)
        #expect(parsed.cases.map(\.passed) == [true, false])
        #expect(parsed.cases[1].summary == "Filling 3 jars..." && parsed.cases[1].lines.last == "FAIL")
        #expect(parsed.summary == TestOutput.Summary(passed: 1, failed: 1, skipped: 3) && parsed.reportsFailure)
        #expect(parsed.after.hasPrefix("1 passed, 1 failed, 3 skipped"))

        // All passed, and a trailer with no case before it: no failure, no extra case.
        let fine = TestOutput("---------------------------------\nInput: 1\nPass\n---------------------------------\n1 passed, 0 failed\nPASS\nok  \tlesson\t0.1s")
        #expect(fine.cases.count == 1 && !fine.reportsFailure)
        #expect(!TestOutput("---------------------------------\nPASS\nok  \tlesson\t0.1s").reportsFailure)
    }

    @Test func casesPrintedWithFmt() {
        let output = """
        ---------------------------------
        Input: "hi"
        Expecting: 2
        Actual: 2
        Pass
        ---------------------------------
        Input: "yo!"
        Expecting: 3
        Actual: 2
        Fail
        ---------------------------------
        1 passed, 1 failed
        """
        let parsed = TestOutput(output)
        #expect(parsed.cases.map(\.passed) == [true, false])
        #expect(parsed.cases[0].summary == "Input: \"hi\"")
        #expect(parsed.after == "1 passed, 1 failed")
        #expect(TestOutput("ok  \tlesson\t0.2s").cases.isEmpty)
    }
}

@Suite struct WorkspaceTests {
    let code = CodeExercise(starterFiles: [StarterFile(name: "main.go", content: "starter"),
                                           StarterFile(name: "main_test.go", content: "tests", isReadonly: true)])

    func lesson() -> LessonDetail {
        LessonDetail(summary: LessonSummary(id: "ws-lesson", chapterID: "h", title: "T", type: .codeTests, required: true),
                     courseID: "c", courseTitle: "C", chapterTitle: "H", readme: "", difficulty: 1,
                     topics: [], content: .codeTests(code))
    }

    @Test func leftoverRunsAreCleanedUp() throws {
        let root = try Fixtures.tempDir("runs")
        defer { try? FileManager.default.removeItem(at: root) }
        let ws = Workspace(root: root)
        let old = ws.runsFolder.appendingPathComponent("run-old"), fresh = ws.runsFolder.appendingPathComponent("run-new")
        for dir in [old, fresh] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path)
        #expect(ws.removeStaleRuns() == 1) // a crashed run's leftovers; a run under way stays
        #expect(!FileManager.default.fileExists(atPath: old.path) && FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test func databaseWinsUnlessTheFolderIsNewer() throws {
        let root = try Fixtures.tempDir("ws")
        defer { try? FileManager.default.removeItem(at: root) }
        let ws = Workspace(root: root)
        let l = lesson()
        let main = ws.folder(for: l).appendingPathComponent("main.go")

        // Nothing saved yet: the starter code.
        var p = try ws.prepare(l, code: code, saved: [:], goVersion: "1.27")
        #expect(p.files[0].content == "starter" && p.readBack.isEmpty)
        #expect(try String(contentsOf: main, encoding: .utf8) == "starter")

        // Saved code newer than the folder (from another Mac): written to the folder.
        let future = Clock.string(Date().addingTimeInterval(3600))
        p = try ws.prepare(l, code: code, saved: ["main.go": CodeFileRecord(name: "main.go", content: "from db", updatedAt: future)], goVersion: "1.27")
        #expect(p.files[0].content == "from db" && p.readBack.isEmpty)
        #expect(try String(contentsOf: main, encoding: .utf8) == "from db")

        // Edited in another editor after the last save: read back for the database.
        try "edited outside".write(to: main, atomically: true, encoding: .utf8)
        let past = Clock.string(Date().addingTimeInterval(-3600))
        p = try ws.prepare(l, code: code, saved: ["main.go": CodeFileRecord(name: "main.go", content: "older", updatedAt: past)], goVersion: "1.27")
        #expect(p.files[0].content == "edited outside")
        #expect(p.readBack.map(\.content) == ["edited outside"])

        // Read-only files are always the lesson's own.
        let tests = ws.folder(for: l).appendingPathComponent("main_test.go")
        chmod(tests.path, 0o644)
        try "tampered".write(to: tests, atomically: true, encoding: .utf8)
        _ = try ws.prepare(l, code: code, saved: [:], goVersion: "1.27")
        #expect(try String(contentsOf: tests, encoding: .utf8) == "tests")
        #expect(FileManager.default.fileExists(atPath: ws.folder(for: l).appendingPathComponent("go.mod").path))
    }
}

/// Lesson tests that report failures only in what they print: go test exits 0 and says PASS,
/// but a wrong solution must still fail. The test files are written for these tests in the
/// two styles such lessons use: Pass and Fail with a summary, and PASS and FAIL.
@Suite(.serialized) struct LessonVerdictTests {
    /// Prints each case and a summary, and never calls t.Error.
    static let printedVerdicts = #"""
    package main

    import (
    	"fmt"
    	"testing"
    )

    func TestVowels(t *testing.T) {
    	type testCase struct {
    		word string
    		want int
    	}
    	runCases := []testCase{{"kettle", 2}, {"saucepan", 4}, {"ladle", 2}}
    	submitCases := append(runCases, []testCase{{"whisk", 1}, {"colander", 3}}...)
    	cases := runCases
    	if withSubmit {
    		cases = submitCases
    	}
    	skipped := len(submitCases) - len(cases)
    	passed, failed := 0, 0
    	for _, c := range cases {
    		got := vowels(c.word)
    		verdict := "Pass"
    		if got != c.want {
    			verdict = "Fail"
    			failed++
    		} else {
    			passed++
    		}
    		fmt.Printf("---------------------------------\nWord:      %s\nExpecting: %d\nActual:    %d\n%s\n", c.word, c.want, got, verdict)
    	}
    	fmt.Println("---------------------------------")
    	if skipped > 0 {
    		fmt.Printf("%d passed, %d failed, %d skipped\n", passed, failed, skipped)
    	} else {
    		fmt.Printf("%d passed, %d failed\n", passed, failed)
    	}
    }

    var withSubmit = true
    """#

    /// The same, with PASS and FAIL.
    static let shoutedVerdicts = printedVerdicts.replacingOccurrences(of: #"verdict := "Pass""#, with: #"verdict := "PASS""#)
        .replacingOccurrences(of: #"verdict = "Fail""#, with: #"verdict = "FAIL""#)

    static let counting = "package main\n\nimport \"strings\"\n\nfunc vowels(word string) int {\n\tn := 0\n\tfor _, r := range word {\n\t\tif strings.ContainsRune(\"aeiou\", r) {\n\t\t\tn++\n\t\t}\n\t}\n\treturn n\n}\n"
    static let wrong = "package main\n\nfunc vowels(word string) int {\n\treturn 0\n}\n"

    func run(_ main: String, tests: String, submit: Bool) async throws -> RunResult? {
        guard let toolchain = await Fixtures.toolchain() else { return nil } // no Go on this machine
        let root = try Fixtures.tempDir("verdicts")
        defer { try? FileManager.default.removeItem(at: root) }
        let code = CodeExercise(starterFiles: [StarterFile(name: "main.go", content: main),
                                               StarterFile(name: "main_test.go", content: tests, isReadonly: true)])
        let lesson = Fixtures.codeLesson("verdict-lesson", .codeTests, code)
        let prepared = try Workspace(root: root).prepare(lesson, code: code, saved: [:], goVersion: toolchain.languageVersion)
        return await GoRunner(toolchain: toolchain, scratch: root.appendingPathComponent(".runs")).run(code, tests: true, folder: prepared.folder, submit: submit)
    }

    @Test func aWrongSolutionFailsThoughGoTestPasses() async throws {
        guard let result = try await run(Self.wrong, tests: Self.printedVerdicts, submit: true) else { return }
        #expect(result.status == .failed, "\(result.output)")
        #expect(result.output.contains("0 passed, 5 failed") && result.output.contains("PASS")) // go test itself passed it
        #expect(result.tests?.cases.count == 5 && result.tests?.cases.contains(where: \.passed) == false)
        #expect(result.tests?.summary == TestOutput.Summary(passed: 0, failed: 5, skipped: 0))

        // A Run uses the run cases only: the summary says so.
        guard let run = try await run(Self.wrong, tests: Self.printedVerdicts, submit: false) else { return }
        #expect(run.status == .failed && run.tests?.summary == TestOutput.Summary(passed: 0, failed: 3, skipped: 2))
    }

    @Test func uppercaseVerdictsFailAndPass() async throws {
        guard let wrong = try await run(Self.wrong, tests: Self.shoutedVerdicts, submit: true) else { return }
        #expect(wrong.status == .failed, "\(wrong.output)")
        guard let right = try await run(Self.counting, tests: Self.shoutedVerdicts, submit: true) else { return }
        #expect(right.status == .passed, "\(right.output)")
        #expect(right.tests?.cases.count == 5 && right.tests?.cases.allSatisfy(\.passed) == true)
    }
}
