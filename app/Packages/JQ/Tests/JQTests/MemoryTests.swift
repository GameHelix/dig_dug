import Darwin
import JQ
import Testing

extension JQTests {
    @Suite("Memory")
    struct Memory {
        /// One pass over every path that creates jq values: parsing in both modes, runs with
        /// outputs, errors, regexes and halts, compile errors, and printing.
        struct Workload {
            let log = Concurrency.log(seed: 7) + "\n" + #"{"msg":"failed to list URLs","errors":{"error_1":{"path":"data/BADENTRY1"},"error_2":{"path":"data/BADENTRY2"}},"big":100000000000000000001}"#
            let programs: [JQProgram]

            init() throws {
                programs = try [
                    #"any(.[]; .msg == "Served request" and .path == "/")"#,
                    #".[] | select(.msg == "failed to list URLs") | .errors | map(.path) | sort | join(", ")"#,
                    #"[.[] | .request_id // empty | scan("[0-9]+") | tonumber] | add"#,
                    #"map(.big) | unique | .[1:]"#,
                    #"[.[] | to_entries | from_entries | keys] | length"#,
                    #".[0].path.nope"#,
                    #"[.[] | .path // "" | test("(")]"#,
                    #"error({code: 7})"#,
                    #"1, ("bye\n" | halt_error)"#,
                    #"1, halt"#,
                    #"reduce range(300) as $i (null; [.])"#,
                ].map { try JQProgram($0) }
            }

            func run() {
                guard let input = try? JQValue(json: log, mode: .jsonl) else {
                    return
                }
                for program in programs {
                    _ = try? program.run(input)
                }
                _ = try? JQProgram(".a | ")
                _ = try? JQValue(json: #"{"a":[1,2"#)
                _ = try? JQValue(json: "1\n{x}\n", mode: .jsonl)
                _ = try? JQValue(json: String(repeating: "[", count: 200) + String(repeating: "]", count: 200))
                _ = input.jsonData(pretty: true)
                _ = input.description
            }
        }

        @Test func repeatedUseKeepsTheHeapFlat() throws {
            let workload = try Workload()
            for _ in 0..<200 {
                workload.run()
            }
            var growth: [Int] = []
            for _ in 0..<3 {
                let before = heapInUse()
                for _ in 0..<1000 {
                    workload.run()
                }
                growth.append(heapInUse() - before)
            }
            // A single leaked jv per pass would add at least 16 KB per round.
            #expect(growth.contains { $0 < 8 * 1024 }, "heap grew by \(growth) bytes per round")
        }

        @Test func repeatedCompilesKeepTheHeapFlat() throws {
            func compileAndRun() {
                _ = try? JQProgram(#"[.[] | select(test("a"))] | length"#).run(["a", "b"])
            }
            for _ in 0..<50 {
                compileAndRun()
            }
            var growth: [Int] = []
            for _ in 0..<3 {
                let before = heapInUse()
                for _ in 0..<300 {
                    compileAndRun()
                }
                growth.append(heapInUse() - before)
            }
            #expect(growth.contains { $0 < 4 * 1024 }, "heap grew by \(growth) bytes per round")
        }
    }
}

/// Bytes the process has allocated and not freed, across all malloc zones.
private func heapInUse() -> Int {
    var statistics = malloc_statistics_t()
    malloc_zone_statistics(nil, &statistics)
    return Int(statistics.size_in_use)
}
