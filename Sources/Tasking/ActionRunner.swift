/// Tracks Actions while running in the caller’s existing async context.
///
/// `ActionRunner` does not create or own tasks. Use it when you are already in an
/// async context and need duplicate control plus a typed terminal outcome.
/// Use `ViewTaskStore` for the separate responsibility of owning unstructured task handles.
@MainActor
public final class ActionRunner {
    private var runs = ActionRuns<Void>()

    public init() {}

    /// Admits a run, calls `onStart` while it is tracked, and awaits the operation.
    /// Skipped runs call neither closure. Every terminal outcome removes tracking.
    /// Cancellation is cooperative: only a thrown `CancellationError` maps to `.cancelled`;
    /// a returned value still maps to `.succeeded` even if cancellation was requested.
    public func run<Success: Sendable>(
        _ descriptor: ActionDescriptor,
        onStart: @MainActor (ActionRun) -> Void = { _ in },
        operation: @MainActor @Sendable (CancellationContext) async throws -> Success
    ) async -> ActionOutcome<Success> {
        if descriptor.duplicatePolicy == .ignoreNew, isRunning(id: descriptor.id) {
            return .skipped(.alreadyRunning)
        }

        let run = ActionRun(actionID: descriptor.id)
        runs.insert(run, metadata: ())
        defer { runs.remove(run) }
        onStart(run)

        do {
            return .succeeded(try await operation(CancellationContext()))
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(ActionFailure(error: error))
        }
    }

    /// Returns whether any run with the given Action ID is currently tracked.
    ///
    /// This is a synchronous query. It does not drive SwiftUI redraws because
    /// `ActionRunner` is not Observable. UI state such as loading indicators
    /// should be owned by the ViewModel as its own state.
    public func isRunning(id: ActionID) -> Bool {
        runningCount(for: id) > 0
    }

    /// Returns the number of currently tracked runs with the given Action ID.
    ///
    /// This is a synchronous query. It does not drive SwiftUI redraws because
    /// `ActionRunner` is not Observable. UI state such as loading indicators
    /// should be owned by the ViewModel as its own state.
    public func runningCount(for id: ActionID) -> Int {
        runs.count(for: id)
    }
}
