import TaskingCore

/// The cancellation contract shared by `Tasking` and `TaskingCore`.
///
/// Each access reads the task that is currently executing; this value does not forward a
/// parent's cancellation into a new unstructured `Task`. Use structured child tasks when
/// cancellation should propagate.
public typealias CancellationContext = TaskingCore.CancellationContext
