import Foundation

/// The library open now and the ones opened lately, as state: the stored setting (or a launch
/// argument) names the first library only, and every later open changes the state, which the
/// app then stores.
public struct OpenLibraries: Equatable, Sendable {
    public static let recentLimit = 10

    public private(set) var current: URL?
    /// Newest first, without repeats.
    public private(set) var recent: [URL]

    public init(launch: URL?, recent: [URL]) {
        current = launch
        self.recent = Array(recent.prefix(OpenLibraries.recentLimit))
    }

    /// A library opened: it is the current one and first among the recent ones.
    public mutating func opened(_ url: URL) {
        current = url
        recent = Array(([url] + recent.filter { $0.standardizedFileURL != url.standardizedFileURL }).prefix(OpenLibraries.recentLimit))
    }

    public mutating func clearRecent() {
        recent = []
    }
}
