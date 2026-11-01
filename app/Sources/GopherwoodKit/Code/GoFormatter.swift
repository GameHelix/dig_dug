import Foundation

/// Why gofmt gave back no code.
public enum GoFormatError: LocalizedError, Equatable, Sendable {
    /// The code does not parse: gofmt's messages, which name the file.
    case syntax(String)
    /// gofmt could not run, or did not finish.
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .syntax(let messages), .failed(let messages): messages
        }
    }
}

/// Lays out Go code with the gofmt of the Go that runs it. The code goes in on standard input
/// and comes back on standard output, so nothing is written to the lesson folder.
public struct GoFormatter: Sendable {
    /// gofmt takes milliseconds; one that takes this long is stuck.
    public static let timeout: Duration = .seconds(10)

    public let gofmt: String
    private let environment: [String: String]

    /// The formatter for the toolchain's gofmt, or nil when it has none.
    public init?(toolchain: Toolchain) {
        guard let gofmt = toolchain.gofmt else { return nil }
        self.gofmt = gofmt
        environment = toolchain.environment
    }

    /// The code as gofmt lays it out: the same text when it is formatted already. Code that
    /// does not parse throws `GoFormatError.syntax` with gofmt's messages, `fileName` in place
    /// of "<standard input>". A cancelled task stops gofmt and throws CancellationError.
    @concurrent
    public func format(_ source: String, fileName: String) async throws -> String {
        let input = Data(source.utf8)
        let out = await ProcessRunner.run(ProcessRequest(
            executable: gofmt, arguments: [], directory: NSTemporaryDirectory(), environment: environment,
            timeout: GoFormatter.timeout, outputLimit: max(input.count * 2, 1 << 20), input: input))
        if out.cancelled { throw CancellationError() }
        if let launch = out.launchError { throw GoFormatError.failed(launch) }
        if out.timedOut { throw GoFormatError.failed("gofmt did not finish in \(GoFormatter.timeout.components.seconds) seconds.") }
        if out.truncated { throw GoFormatError.failed("gofmt's output was too long to take in.") }
        guard out.exitCode == 0 else {
            let messages = out.stderr.replacingOccurrences(of: "<standard input>", with: fileName)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if out.exitCode == 2 && !messages.isEmpty { throw GoFormatError.syntax(messages) }
            let why = out.signal != 0 ? "signal: \(String(cString: strsignal(out.signal)))" : "exit status \(out.exitCode)"
            throw GoFormatError.failed(messages.isEmpty ? "gofmt stopped (\(why))." : messages)
        }
        return out.stdout
    }
}
