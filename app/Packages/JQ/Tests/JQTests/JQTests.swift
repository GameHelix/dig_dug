import JQ
import Testing

/// Every suite nests here and runs one test at a time, so the leak test can read the heap
/// without other tests allocating at the same moment. Tests that need concurrency start
/// their own tasks.
@Suite(.serialized)
enum JQTests {}

/// Runs `program` on JSON text.
func jq(_ program: String, _ input: String = "null", mode: JQInputMode = .json) throws -> [JQValue] {
    try JQProgram(program).run(JQValue(json: input, mode: mode))
}
