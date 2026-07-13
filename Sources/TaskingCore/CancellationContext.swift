/// A value for explicitly passing the current task's cooperative cancellation state.
///
/// Call `check()` before and after long-running work and important suspension points.
/// The value does not capture or forward a cancellation token: every access reads the
/// task that is currently executing. Keep work in structured child tasks when cancellation
/// should propagate. Passing this value into a new unstructured `Task` does not connect that
/// task to its parent's cancellation.
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
