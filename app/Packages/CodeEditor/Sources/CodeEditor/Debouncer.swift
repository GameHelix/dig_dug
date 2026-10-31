import Foundation

/// Runs an action once a delay has passed without another `schedule`.
@MainActor
final class Debouncer {
    let delay: Duration
    private var task: Task<Void, Never>?
    private var action: (@MainActor () -> Void)?

    init(delay: Duration) {
        self.delay = delay
    }

    var isPending: Bool { action != nil }

    func schedule(_ action: @escaping @MainActor () -> Void) {
        task?.cancel()
        self.action = action
        let delay = delay
        task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.fire()
        }
    }

    /// Runs the pending action now, if there is one.
    func flush() {
        fire()
    }

    func cancel() {
        task?.cancel()
        task = nil
        action = nil
    }

    private func fire() {
        let action = action
        cancel()
        action?()
    }
}
