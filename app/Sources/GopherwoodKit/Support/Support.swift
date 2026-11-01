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

/// One Gopherwood at a time: a launch while another copy of the same app runs (the same bundle
/// id, such as copies in ~/Applications and build/) hands over to it before it opens the
/// library, so two copies never compete for one library. An app with another bundle id, such as
/// a QA copy, runs alongside.
public enum SingleInstance {
    /// A running app, as NSRunningApplication tells it.
    public struct App: Equatable, Sendable {
        public let pid: Int32
        public let bundleID: String?
        public let launched: Date?
        public let isTerminated: Bool

        public init(pid: Int32, bundleID: String?, launched: Date?, isTerminated: Bool = false) {
            self.pid = pid
            self.bundleID = bundleID
            self.launched = launched
            self.isTerminated = isTerminated
        }
    }

    /// The copy this launch hands over to: of the running copies of `this` app, the one
    /// launched first (by process id when launched together), unless that is this one. So when
    /// two start at once, exactly one stays. Nil for an app without a bundle id, such as a bare
    /// binary.
    public static func handOver(from this: App, running: [App]) -> App? {
        guard let id = this.bundleID else { return nil }
        let copies = running.filter { $0.bundleID == id && $0.pid != this.pid && !$0.isTerminated } + [this]
        let first = copies.min { ($0.launched ?? .distantFuture, $0.pid) < ($1.launched ?? .distantFuture, $1.pid) }
        return first?.pid == this.pid ? nil : first
    }
}
