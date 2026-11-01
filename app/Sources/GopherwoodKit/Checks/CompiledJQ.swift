import Foundation
import JQ
import os

/// jq for command-line checks: jq 1.8.2 compiled into the app. Each program is compiled once
/// and kept, since lessons run the same programs again and again.
public final class CompiledJQ: Sendable {
    private let programs = OSAllocatedUnfairLock<[String: JQProgram]>(initialState: [:])

    public init() {}

    /// Runs `program` on `input`; jq's own message when it does not compile or fails.
    public func run(_ program: String, on input: JQValue) throws(JQError) -> [JQValue] {
        if let cached = programs.withLock({ $0[program] }) { return try cached.run(input) }
        let compiled = try JQProgram(program)
        programs.withLock { $0[program] = compiled }
        return try compiled.run(input)
    }
}
