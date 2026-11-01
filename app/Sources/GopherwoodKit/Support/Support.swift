import Foundation
import os

/// Loggers for the app's subsystems.
public enum Log {
    public static let subsystem = "io.github.jobloom.Gopherwood"
    public static let git = Logger(subsystem: subsystem, category: "git")
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let github = Logger(subsystem: subsystem, category: "github")
}

/// ISO 8601 timestamps in UTC with a trailing Z, the only form the schema's CHECKs accept,
/// such as 2026-10-31T12:00:00Z.
public enum Clock {
    public static func now() -> String { string(Date()) }

    public static func string(_ date: Date) -> String {
        date.ISO8601Format() // UTC, whole seconds, trailing Z
    }

    public static func date(_ text: String) -> Date? {
        if let d = try? Date(text, strategy: .iso8601) { return d }
        return try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}

/// Paths of the system programs the app relies on.
public enum SystemTools {
    public static let zsh = "/bin/zsh"
    public static let git = "/usr/bin/git"
}

/// Which errors reach the person. Work is cancelled when something newer replaces it: another
/// lesson, the next keystroke of a search, another library. That work ends silently, whatever
/// it threw on the way out; the newer work meets any real problem again.
public enum Reporting {
    /// Whether `error` stays unsaid: a cancellation, or anything thrown in a cancelled task.
    public static func isSilent(_ error: any Error) -> Bool {
        error is CancellationError || Task.isCancelled
    }
}
