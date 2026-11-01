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
