/// A value for explicitly passing the current task's cancellation state to ViewModel async methods.
///
/// Swift cancellation is cooperative. Call `check()` before and after long-running work
/// and after important suspension points so the operation reflects cancellation requests.
public struct CancellationContext: Sendable {
    public init() {}

    /// Whether cancellation has been requested for the currently running task.
    public var isCancelled: Bool {
        Task.isCancelled
    }

    /// Throws `CancellationError` if cancellation has been requested for the currently running task.
    public func check() throws {
        try Task.checkCancellation()
    }
}
