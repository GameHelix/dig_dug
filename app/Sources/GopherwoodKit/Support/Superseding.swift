import Foundation

/// Runs jobs one at a time where only the newest counts. Starting a job cancels the one under
/// way and begins only once that one has stopped, so two never run at once, and a superseded
/// job sees `Task.isCancelled` before it changes anything.
@MainActor
public final class Superseding {
    private var current: Task<Void, Never>?

    public init() {}

    public func run(_ job: @escaping @MainActor () async -> Void) {
        let previous = current
        previous?.cancel()
        current = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled else { return }
            await job()
        }
    }

    /// Waits for the job under way, if any.
    public func wait() async {
        await current?.value
    }
}

/// Runs a job one at a time, and never drops a request: one that comes while a job runs is
/// remembered, and the newest of those runs once the job ends. A push asked for during a push
/// so pushes again, with what was committed meanwhile.
@MainActor
public final class Coalescing {
    public private(set) var isRunning = false
    private var waiting: (@MainActor () async -> Void)?

    public init() {}

    /// Runs `job` now, or, while another runs, once that one ends; returns when the jobs it
    /// ran are done, at once when it only left `job` waiting.
    public func run(_ job: @escaping @MainActor () async -> Void) async {
        waiting = job
        guard !isRunning else { return }
        isRunning = true
        while let next = waiting {
            waiting = nil
            await next()
        }
        isRunning = false
    }
}
