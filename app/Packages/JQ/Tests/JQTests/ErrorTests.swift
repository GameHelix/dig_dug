import Foundation
import JQ
import Testing

extension JQTests {
    @Suite("Errors")
    struct Errors {
        @Test func syntaxErrorsCarryJqsMessage() {
            #expect(throws: JQError.compile("""
                jq: error: syntax error, unexpected end of file at <top-level>, line 1, column 6:
                    .foo |
                         ^
                jq: 1 compile error
                """)) {
                try JQProgram(".foo |")
            }
        }

        @Test func unknownFunctionsAreCompileErrors() {
            #expect(throws: JQError.compile("""
                jq: error: foo/1 is not defined at <top-level>, line 1, column 1:
                    foo(1)
                    ^^^
                jq: 1 compile error
                """)) {
                try JQProgram("foo(1)")
            }
        }

        @Test func everyCompileErrorIsReported() throws {
            let error = try #require(throws: JQError.self) {
                try JQProgram("nope1 | nope2")
            }
            guard case .compile(let message) = error else {
                Issue.record("not a compile error: \(error)")
                return
            }
            #expect(message.contains("nope1/0 is not defined"))
            #expect(message.contains("nope2/0 is not defined"))
            #expect(message.hasSuffix("jq: 2 compile errors"))
        }

        @Test func runtimeErrorsCarryJqsMessage() {
            #expect(throws: JQError.runtime(#"Cannot index number with string ("foo")"#)) {
                try jq(".foo", "1")
            }
            #expect(throws: JQError.runtime("Cannot index object with number (0)")) {
                try jq(".[0]", #"{"a":1}"#)
            }
            #expect(throws: JQError.runtime(#"string ("abc") cannot be parsed as a number"#)) {
                try jq("tonumber", #""abc""#)
            }
            #expect(throws: JQError.runtime("boolean (true) has no length")) {
                try jq("length", "true")
            }
            #expect(throws: JQError.runtime(#"string ("a") and number (1) cannot have their containment checked"#)) {
                try jq("contains(1)", #""a""#)
            }
            #expect(throws: JQError.runtime("Regex failure: end pattern with unmatched parenthesis")) {
                try jq(#"test("(")"#, #""x""#)
            }
            // A lesson query on a log whose error is still text rather than an object.
            #expect(throws: JQError.runtime(#"Cannot index string with string ("stack_trace")"#)) {
                try jq(#".[] | select(.msg == "error validating password") | .error.stack_trace | length"#, Fixture.linkoStackTextLog, mode: .jsonl)
            }
        }

        @Test func errorValuesAndHalts() throws {
            #expect(throws: JQError.runtime("custom")) { try jq(#"error("custom")"#) }
            #expect(throws: JQError.runtime(#"(not a string): {"code":7}"#)) { try jq("error({code: 7})") }
            #expect(throws: JQError.runtime("(not a string): null")) { try jq("error(null)") }
            #expect(throws: JQError.runtime("late")) { try jq(#"1, 2, error("late")"#) }
            #expect(throws: JQError.runtime("stopped")) { try jq("halt_error", #""stopped\n""#) }
            #expect(throws: JQError.runtime(#"{"code":7}"#)) { try jq("halt_error(3)", #"{"code":7}"#) }
            #expect(throws: JQError.runtime("The program stopped with exit code 5")) { try jq("null | halt_error") }
            #expect(try jq("1, halt, 2") == [1])
            #expect(try jq(#""quiet" | halt_error(0)"#) == [])
            #expect(try jq(#"try error("caught") catch ."#) == ["caught"])
            #expect(try jq(#"[.[] | try tonumber catch "bad"]"#, #"["1", "x"]"#) == [[1, "bad"]])
        }

        @Test func aProgramRunsAgainAfterAnError() throws {
            let program = try JQProgram(".a.b")
            #expect(throws: JQError.self) { try program.run(["a": 5]) }
            #expect(try program.run(["a": ["b": "fine"]]) == ["fine"])
            #expect(throws: JQError.self) { try program.run(["a": "text"]) }
            #expect(try program.run(.null) == [.null])
        }

        @Test func descriptionsReadLikeTheJqCommand() throws {
            #expect(JQError.runtime("custom").localizedDescription == "jq: error: custom")
            #expect(JQError.invalidJSON("Expected JSON value").localizedDescription == "jq: parse error: Expected JSON value")
            let compile = try #require(throws: JQError.self) { try JQProgram("}") }
            #expect(compile.localizedDescription == compile.message)
            #expect(compile.message.hasPrefix("jq: error: syntax error"))
        }

        @Test func programsAreSelfContained() throws {
            // No input, modules or files beyond the one value the program runs on.
            #expect(try jq("[inputs]") == [[]])
            #expect(throws: JQError.compile("""
                jq: error: module not found: lesson_helpers
                jq: 1 compile error
                """)) {
                try JQProgram(#"import "lesson_helpers" as h; ."#)
            }
            #expect(try jq("$__loc__") == [["file": "<top-level>", "line": 1]])
        }
    }
}
