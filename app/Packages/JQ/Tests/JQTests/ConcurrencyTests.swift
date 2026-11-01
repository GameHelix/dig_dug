import JQ
import Testing

extension JQTests {
    @Suite("Concurrency")
    struct Concurrency {
        /// A small access log whose numbers depend on `seed`, so each run has its own answer.
        static func log(seed: Int) -> String {
            (0..<5).map { line in
                #"{"msg":"Served request","path":"\#(line.isMultiple(of: 2) ? "/api/login" : "/")","response_status":\#(200 + (seed + line) % 300),"request_id":"req-\#(seed)-\#(line)"}"#
            }.joined(separator: "\n")
        }

        @Test func concurrentRunsEachGetTheirOwnAnswer() async throws {
            // One program shared by every task, and one compiled by each task while the others run.
            let shared = try JQProgram(#"[.[] | select(.msg == "Served request" and (.path | test("^/api/"))) | .response_status] | add"#)
            let tasks = 16
            let rounds = 150
            let checked = try await withThrowingTaskGroup(of: Int.self) { group in
                for task in 0..<tasks {
                    group.addTask {
                        let own = try JQProgram(#"[.[] | .request_id | scan("[0-9]+") | tonumber] | add + \#(task)"#)
                        for round in 0..<rounds {
                            let seed = task * 1000 + round
                            let input = try JQValue(json: Self.log(seed: seed), mode: .jsonl)
                            let statuses = [0, 2, 4].map { 200 + (seed + $0) % 300 }.reduce(0, +)
                            #expect(try shared.run(input) == [.number(JQNumber(statuses))])
                            #expect(try own.run(input) == [.number(JQNumber(5 * seed + 10 + task))])
                            #expect(input.jsonString().contains("req-\(seed)-4"))
                        }
                        return rounds
                    }
                }
                return try await group.reduce(0, +)
            }
            #expect(checked == tasks * rounds)
        }

        @Test func concurrentCompilesAndErrors() async throws {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for task in 0..<16 {
                    group.addTask {
                        for round in 0..<20 {
                            #expect(throws: JQError.self) { try JQProgram(".[\(task) |") }
                            #expect(throws: JQError.runtime("bad \(task)")) { try JQProgram(#"error("bad \#(task)")"#).run(.null) }
                            let program = try JQProgram(#"[splits(",")] | map(select(test("^[a-z]+$"))) | length + \#(round)"#)
                            #expect(try program.run("a,b,1,c") == [.number(JQNumber(3 + round))])
                        }
                    }
                }
                try await group.waitForAll()
            }
        }
    }
}
