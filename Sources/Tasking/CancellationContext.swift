import TaskingCore

/// Source-compatible access to the cancellation contract shared with `TaskingCore`.
///
/// Each access reads the task that is currently executing; this value does not forward a
/// parent's cancellation into a new unstructured `Task`. Use structured child tasks when
/// cancellation should propagate.
public typealias CancellationContext = TaskingCore.CancellationContext
