import Foundation
import JQ
import Testing

extension JQTests {
    @Suite("Values and input")
    struct Values {
        @Test func jsonRoundTripKeepsKeyOrder() throws {
            let text = #"{"zeta":1,"alpha":{"y":[true,false,null],"x":"é \"quoted\" \\ \n"},"mid":[],"empty":{}}"#
            let value = try JQValue(json: text)
            #expect(value.jsonString() == text)
            #expect(String(decoding: value.jsonData(), as: UTF8.self) == text)
            #expect(try JQValue(json: value.jsonData()) == value)
            guard case .object(let object) = value else {
                Issue.record("not an object")
                return
            }
            #expect(object.keys == ["zeta", "alpha", "mid", "empty"])
            #expect(object.map { $0.key } == ["zeta", "alpha", "mid", "empty"])
            #expect(try JQProgram("keys_unsorted").run(value) == [["zeta", "alpha", "mid", "empty"]])
            #expect(try JQProgram(".").run(value) == [value])
            #expect(try JQProgram(".").run(value).first?.jsonString() == text)
        }

        @Test func valuesBuiltInSwiftKeepTheirOrder() throws {
            var object: JQObject = ["b": 1, "a": [true, .null, 2.5, "x"]]
            object["c"] = ["nested": "yes"]
            object["b"] = 10
            #expect(object.keys == ["b", "a", "c"])
            #expect(JQValue.object(object).jsonString() == #"{"b":10,"a":[true,null,2.5,"x"],"c":{"nested":"yes"}}"#)
            object["a"] = nil
            #expect(object.keys == ["b", "c"])
            #expect(object.count == 2)
            #expect(JQValue.object(object) == ["c": ["nested": "yes"], "b": 10])
        }

        @Test func duplicateKeysKeepTheFirstPlaceAndLastValue() throws {
            #expect(try JQValue(json: #"{"b":1,"a":2,"b":3}"#).jsonString() == #"{"b":3,"a":2}"#)
        }

        @Test func prettyPrintingMatchesJq() throws {
            let value = try JQValue(json: #"{"b":[1,{"c":null}],"a":"x","e":[],"f":{}}"#)
            #expect(value.jsonString(pretty: true) == """
                {
                  "b": [
                    1,
                    {
                      "c": null
                    }
                  ],
                  "a": "x",
                  "e": [],
                  "f": {}
                }
                """)
        }

        @Test func integersStayExact() throws {
            let big = try JQValue(json: "[12345678901234567890, 9007199254740993, -9223372036854775808, 100000000000000000000000000001]")
            #expect(big.jsonString() == "[12345678901234567890,9007199254740993,-9223372036854775808,100000000000000000000000000001]")
            #expect(try JQProgram(".").run(big).first?.jsonString() == big.jsonString())
            #expect(try JQProgram("map(tostring)").run(big) == [["12345678901234567890", "9007199254740993", "-9223372036854775808", "100000000000000000000000000001"]])
            guard case .array(let numbers) = big, case .number(let beyondDouble) = numbers[1] else {
                Issue.record("not numbers")
                return
            }
            #expect(beyondDouble.intValue == 9_007_199_254_740_993)
            #expect(beyondDouble.doubleValue == 9_007_199_254_740_992)

            let fromSwift = JQValue.number(JQNumber(Int.max))
            let output = try JQProgram(".").run(fromSwift)
            #expect(output == [fromSwift])
            if case .number(let number)? = output.first {
                #expect(number.intValue == Int.max)
                #expect(number.description == "9223372036854775807")
            }
            // Arithmetic is in doubles, as in jq.
            #expect(try jq(". + 0", "9007199254740993") == [.number(JQNumber(9_007_199_254_740_992.0))])
        }

        @Test func numbersCompareByValue() throws {
            #expect(try JQValue(json: "1.000") == 1)
            #expect(try JQValue(json: "1E+2") == 100)
            #expect(try JQValue(json: "-0") == 0)
            #expect(try JQValue(json: "0.1") == 0.1)
            #expect(try JQValue(json: "1.5") != 1)
            #expect(try JQValue(json: "12345678901234567890") != JQValue(json: "12345678901234567891"))
            let thousandths = try JQValue(json: "1.000")
            #expect(Set<JQValue>([1, 1.0, thousandths, 2]).count == 2)
            #expect(try JQValue(json: "1.000").description == "1.000")
            #expect(JQNumber(3.0).description == "3")
            #expect(JQNumber(0.1 + 0.2).description == "0.30000000000000004")
            #expect(JQNumber(2.5).intValue == nil)
            #expect(JQNumber(-4.0).intValue == -4)
            #expect(try jq("[.[] | . * 1]", "[1.5, 2]") == [[1.5, 2]])
        }

        @Test func stringsKeepEveryCharacter() throws {
            let text = "plain, \u{0}nul, tab\t, émoji 🧸, \"quotes\", back\\slash, \u{2028}"
            let output = try JQProgram(".").run(.string(text))
            #expect(output == [.string(text)])
            #expect(try JQProgram("length").run(.string("🧸é")) == [2])
            #expect(try JQValue(json: JQValue.string(text).jsonData()) == .string(text))
        }

        @Test func jsonModeReadsOneValue() throws {
            #expect(try JQValue(json: "  \n {\"a\": 1}\n\n") == ["a": 1])
            #expect(try JQValue(json: "\u{FEFF}[1]") == [1])
            #expect(throws: JQError.invalidJSON("Expected JSON value")) { try JQValue(json: "  \n") }
            #expect(throws: JQError.invalidJSON("Unexpected extra JSON values")) { try JQValue(json: #"{"a":1} {"b":2}"#) }
            #expect(throws: JQError.invalidJSON("Unfinished JSON term at EOF at line 1, column 4")) { try JQValue(json: "[1,2") }
            #expect(throws: JQError.self) { try JQValue(json: "{'a': 1}") }
        }

        @Test func jsonLinesBecomeOneArray() throws {
            let log = "{\"msg\":\"a\",\"n\":1}\n\n   \n{\"msg\":\"b\",\"n\":2}\r\n[3]\n"
            let value = try JQValue(json: log, mode: .jsonl)
            #expect(value == [["msg": "a", "n": 1], ["msg": "b", "n": 2], [3]])
            #expect(try JQValue(json: "{\"msg\":\"a\"}", mode: .jsonl) == [["msg": "a"]])
            #expect(try JQValue(json: "", mode: .jsonl) == [])
            #expect(try JQValue(json: "\n\n", mode: .jsonl) == [])
            #expect(try JQValue(json: Data(log.utf8), mode: .jsonl) == value)
            #expect(try jq(#".[] | objects | select(.n > 1) | .msg"#, log, mode: .jsonl) == ["b"])
        }

        @Test func jsonLinesErrorsNameTheLine() throws {
            #expect(throws: JQError.invalidJSON("Unfinished JSON term at EOF at line 2, column 5")) {
                try JQValue(json: "{\"a\":1}\n{\"a\":\n", mode: .jsonl)
            }
            #expect(throws: JQError.invalidJSON("Unexpected extra JSON values at line 3")) {
                try JQValue(json: "1\n\n2 3\n", mode: .jsonl)
            }
            #expect(throws: JQError.invalidJSON("Invalid numeric literal at line 2, column 9")) {
                try JQValue(json: "{}\nStarting server on :8080\n", mode: .jsonl)
            }
        }

        @Test func deepValuesAreRejectedNotCrashed() throws {
            let deep = { (depth: Int) in String(repeating: "[", count: depth) + String(repeating: "]", count: depth) }
            #expect(try JQValue(json: deep(128)).jsonString() == deep(128))
            #expect(throws: JQError.invalidJSON("Exceeds depth limit for parsing (128 levels)")) { try JQValue(json: deep(129)) }
            #expect(throws: JQError.invalidJSON("Exceeds depth limit for parsing (128 levels)")) { try JQValue(json: deep(9_999)) }
            #expect(throws: JQError.invalidJSON("Exceeds depth limit for parsing at line 1, column 10001")) { try JQValue(json: deep(10_001)) }
            #expect(throws: JQError.runtime("Output exceeds depth limit (128 levels)")) {
                try JQProgram("reduce range(5000) as $i (null; [.])").run(.null)
            }
            #expect(try JQProgram("reduce range(5000) as $i (null; [.]) | flatten | length").run(.null) == [1])
        }
    }
}
