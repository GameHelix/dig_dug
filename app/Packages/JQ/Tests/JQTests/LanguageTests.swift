import JQ
import Testing

extension JQTests {
    /// The parts of the jq language the lessons rely on.
    @Suite("Language")
    struct Language {
        @Test("The Go version check", arguments: [
            ("go1.27.2", true), ("go1.27.3", true), ("go1.27.10", true), ("go1.28.0", true),
            ("go1.27.1", false), ("go1.27.0", false), ("go1.26.9", false),
        ])
        func goVersion(version: String, isRecentEnough: Bool) throws {
            let query = #".GOVERSION | [scan("[0-9]+") | tonumber] | .[1] > 27 or (.[1] == 27 and .[2] >= 2)"#
            #expect(try jq(query, Fixture.goEnv(version)) == [.bool(isRecentEnough)])
        }

        @Test func scanAndTestWithRegularExpressions() throws {
            #expect(try jq(#"[scan("[0-9]+")]"#, #""go1.27.3""#) == [["1", "27", "3"]])
            #expect(try jq(#"[scan("(a)(b)")]"#, #""abab""#) == [[["a", "b"], ["a", "b"]]])
            #expect(try jq(#"[scan("c"; "i")]"#, #""abcABC""#) == [["c", "C"]])
            #expect(try jq(#"[.[] | test("^go1\\.27")]"#, #"["go1.27.3", "go1.2", "xgo1.27"]"#) == [[true, false, false]])
            #expect(try jq(#"test("served"; "i")"#, #""Served request""#) == [true])
            #expect(try jq(#"[match("(?<n>[0-9]+)"; "g") | .captures[0] | {name, string}]"#, #""a1b22""#)
                == [[["name": "n", "string": "1"], ["name": "n", "string": "22"]]])
            #expect(try jq(#"sub("(?<word>[a-z]+)"; "<\(.word)>")"#, #""abc123""#) == ["<abc>123"])
            #expect(try jq(#"[splits(", *")]"#, #""a, b,c""#) == [["a", "b", "c"]])
            #expect(try jq(#"test("\\p{Lu}")"#, #""ünïcödé É""#) == [true])
        }

        @Test func tonumber() throws {
            #expect(try jq("map(tonumber)", #"["42", "1.5", "-7", "1e3", 12]"#) == [[42, 1.5, -7, 1000, 12]])
            #expect(try jq(#"[scan("[0-9]+") | tonumber] | add"#, #""go1.27.3""#) == [31])
        }

        @Test func anyAndAll() throws {
            #expect(try jq("any(.[]; . > 2)", "[1, 2, 3]") == [true])
            #expect(try jq("any(.[]; . > 3)", "[1, 2, 3]") == [false])
            #expect(try jq("any(.[]; . > 0)", "[]") == [false])
            #expect(try jq("[any, all]", "[true, false]") == [[true, false]])
            #expect(try jq("map(any(. > 1))", "[[0, 2], [0, 1]]") == [[true, false]])
            #expect(try jq("all(.[]; . > 0)", "[1, 2, 3]") == [true])
            #expect(try jq("all(.[]; . > 1)", "[1, 2, 3]") == [false])
            #expect(try jq("all(.[]; . > 0)", "[]") == [true])
            // any and all stop at the first answer, before later errors.
            #expect(try jq(#"any(1, error("unreached"); . == 1)"#) == [true])
            #expect(try jq(#"all(1, error("unreached"); . == 2)"#) == [false])
        }

        @Test func slices() throws {
            #expect(try jq(".[0:20] | length", "[\(Array(0..<30).map(String.init).joined(separator: ","))]") == [20])
            #expect(try jq(".[0:20]", "[1, 2, 3]") == [[1, 2, 3]])
            #expect(try jq("[.[1:3], .[2:], .[:-1], .[-2:]]", "[0, 1, 2, 3, 4]") == [[[1, 2], [2, 3, 4], [0, 1, 2, 3], [3, 4]]])
            #expect(try jq("[.[1:3], .[-2:]]", #""abcdef""#) == [["bc", "ef"]])
            #expect(try jq(".[20]", "[1, 2, 3]") == [.null])
            #expect(try jq(".[0:2]", "null") == [.null])
        }

        @Test func keysAndType() throws {
            #expect(try jq("keys", #"{"b": 1, "a": 2, "c": 3}"#) == [["a", "b", "c"]])
            #expect(try jq("keys_unsorted", #"{"b": 1, "a": 2, "c": 3}"#) == [["b", "a", "c"]])
            #expect(try jq("keys", "[5, 6]") == [[0, 1]])
            #expect(try jq("map(type)", #"[null, true, 1, 1.5, "s", [], {}]"#)
                == [["null", "boolean", "number", "number", "string", "array", "object"]])
        }

        @Test func contains() throws {
            #expect(try jq(#"contains("bar")"#, #""foobar""#) == [true])
            #expect(try jq(#"contains(["b", "c"])"#, #"["a", "b", "c"]"#) == [true])
            #expect(try jq(#"contains(["x"])"#, #"["a", "b"]"#) == [false])
            #expect(try jq(#"contains({"a": [1]})"#, #"{"a": [1, 2], "b": 3}"#) == [true])
            #expect(try jq(#"contains("validatePassword")"#, #""main.(*server).validatePassword""#) == [true])
        }

        @Test func joinSortMapSelect() throws {
            #expect(try jq(#"join(", ")"#, #"["a", "b", "c"]"#) == ["a, b, c"])
            #expect(try jq(#"join("-")"#, #"[1, null, true, "x"]"#) == ["1--true-x"])
            #expect(try jq("sort", #"[3, "b", null, 1, "a", true, false, [1], {"a": 1}]"#)
                == [[.null, false, true, 1, 3, "a", "b", [1], ["a": 1]]])
            #expect(try jq("sort_by(.n) | map(.id)", #"[{"id": "x", "n": 2}, {"id": "y", "n": 1}]"#) == [["y", "x"]])
            #expect(try jq("map(. * 2)", "[1, 2, 3]") == [[2, 4, 6]])
            #expect(try jq("map(.path)", #"{"error_1": {"path": "b"}, "error_2": {"path": "a"}}"#) == [["b", "a"]])
            #expect(try jq("[.[] | select(. > 1)]", "[1, 2, 3]") == [[2, 3]])
            #expect(try jq(".[] | select(.ok) | .id", #"[{"id": 1, "ok": true}, {"id": 2, "ok": false}, {"id": 3}]"#) == [1])
        }

        @Test func length() throws {
            #expect(try jq("map(length)", #"["héllo", [1, 2], {"a": 1}, null, -5]"#) == [[5, 2, 1, 0, 5]])
        }

        @Test func andOrNot() throws {
            #expect(try jq("[true and false, true or false, (true | not), (null | not), (0 | not)]") == [[false, true, false, true, false]])
            #expect(try jq(".a and .b", #"{"a": true, "b": "yes"}"#) == [true])
            #expect(try jq(".a or .b", #"{"a": null, "b": false}"#) == [false])
            #expect(try jq("(.x | not) and .y", #"{"x": false, "y": 1}"#) == [true])
        }

        @Test func nullHandling() throws {
            #expect(try jq(".missing, .missing.deeper, .a[3]", #"{"a": [1]}"#) == [.null, .null, .null])
            #expect(try jq(".user == null", #"{"msg": "Served request"}"#) == [true])
            #expect(try jq(".user != null", #"{"user": null}"#) == [false])
            #expect(try jq(#".name // "anonymous""#, #"{"name": null}"#) == ["anonymous"])
            #expect(try jq("[.[] | .a?]", #"[1, {"a": 2}]"#) == [[2]])
            #expect(try jq("null + 1, (null | length), ([null] | add)") == [1, 0, .null])
            #expect(try jq("if .error then \"failed\" else \"ok\" end", #"{"error": null}"#) == ["ok"])
            #expect(try jq("any(.[]; .hostname == null)", #"[{"hostname": "linko-dev"}, {}]"#) == [true])
        }

        @Test func firstAndPipelines() throws {
            #expect(try jq(#"first(.[] | select(.t == "b")).v"#, #"[{"t": "a", "v": 1}, {"t": "b", "v": 2}, {"t": "b", "v": 3}]"#) == [2])
            #expect(try jq("[limit(2; .[])]", "[1, 2, 3]") == [[1, 2]])
            #expect(try jq("reduce .[] as $x (0; . + $x)", "[1, 2, 3]") == [6])
            #expect(try jq(#"[.[] | "\(.a)-\(.b)"]"#, #"[{"a": 1, "b": "x"}]"#) == [["1-x"]])
            #expect(try jq(".data.groups[]?.rules[]?.name", #"{"data": {"groups": [{"rules": [{"name": "r1"}]}, {}]}}"#) == ["r1"])
            #expect(try jq("1, 2, 3") == [1, 2, 3])
            #expect(try jq("empty") == [])
        }
    }
}
