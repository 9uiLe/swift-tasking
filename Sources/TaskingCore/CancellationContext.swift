/// A value for explicitly passing the current task's cooperative cancellation state.
///
/// Call `check()` before and after long-running work and important suspension points.
public struct CancellationContext: Sendable {
    public init() {}

    /// Whether cancellation has been requested for the currently running task.
    public var isCancelled: Bool {
        Task.isCancelled
    }

    /// Throws `CancellationError` if cancellation has been requested for the current task.
    public func check() throws {
        try Task.checkCancellation()
    }
}
