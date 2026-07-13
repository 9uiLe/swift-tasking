/// A logical lifetime for tasks owned by `ViewTaskStore`.
///
/// Built-in values represent common UI ownership scopes.
/// You can also define feature-specific scopes such as `"accountSettings"`.
public struct ActionLifetime: Hashable, Sendable, RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible {
    public static let screenBound = ActionLifetime("screenBound")
    public static let sceneBound = ActionLifetime("sceneBound")
    public static let appBound = ActionLifetime("appBound")

    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: StringLiteralType) {
        rawValue = value
    }

    public var description: String {
        rawValue
    }
}

/// The start policy used when a task with the same `ActionID` is already being tracked.
public enum TaskStartPolicy: Equatable, Sendable {
    /// Keep the existing task and skip the new request.
    case ignoreNew

    /// Cancel tasks tracked as the same Action, then start the new request.
    ///
    /// Cancellation is cooperative. If old work ignores cancellation, it may continue
    /// after the store has stopped treating it as running for duplicate-policy decisions.
    case cancelExisting

    /// Start an additional task with the same Action ID.
    case allowConcurrent
}

public enum TaskStartOutcome: Equatable, Sendable {
    case started(ActionRun)
    case skipped(ActionSkipReason)

    public var run: ActionRun? {
        guard case let .started(run) = self else {
            return nil
        }
        return run
    }

    public var skipReason: ActionSkipReason? {
        guard case let .skipped(reason) = self else {
            return nil
        }
        return reason
    }
}

/// Owns handles for unstructured tasks created from synchronous UI callbacks on a View.
///
/// `ViewTaskStore` is `@MainActor` because it is primarily intended to be owned by
/// SwiftUI views.
/// It makes the task owner, lifetime, and duplicate policy explicit at the call site.
@MainActor
public final class ViewTaskStore {
    private var tasksByRunID: [ActionRunID: ManagedTask] = [:]
    private var runIDsByActionID: [ActionID: Set<ActionRunID>] = [:]
    private var terminatingByRunID: [ActionRunID: ManagedTask] = [:]
    private let onUnhandledError: (@MainActor (ActionRun, ActionFailure) -> Void)?

    /// Creates a store with an optional observer for operation contract violations.
    ///
    /// Business errors should still be converted into ViewModel state before escaping the
    /// operation. The handler is a release-safe notification point for errors that do escape;
    /// it runs before the failed run is removed from tracking. When no handler is installed,
    /// escaped errors continue to trigger a debug assertion. The handler is invoked only while
    /// the store is alive; an error that escapes after deallocation uses the same debug assertion
    /// fallback. The store retains the handler, so a handler that calls its store-owning object
    /// should capture that owner weakly.
    public init(
        onUnhandledError: (@MainActor (ActionRun, ActionFailure) -> Void)? = nil
    ) {
        self.onUnhandledError = onUnhandledError
    }

    deinit {
        for task in tasksByRunID.values {
            task.handle.cancel()
        }
    }

    /// Starts a ViewModel async method as an unstructured task.
    ///
    /// The operation receives a `CancellationContext`. In long-running work, call
    /// `try cancellation.check()` to cooperate with cancellation requests.
    /// `CancellationError` is treated as normal termination. Other errors are expected
    /// to be converted into ViewModel state before escaping; escaped errors are detected
    /// by the configured unhandled-error observer, or by a debug assertion when no observer
    /// is installed.
    @discardableResult
    public func start(
        id: ActionID,
        lifetime: ActionLifetime,
        policy: TaskStartPolicy = .ignoreNew,
        priority: TaskPriority? = nil,
        operation: @escaping @MainActor @Sendable (CancellationContext) async throws -> Void
    ) -> TaskStartOutcome {
        let runningRunIDs = runIDsByActionID[id, default: []]

        switch policy {
        case .ignoreNew where !runningRunIDs.isEmpty:
            return .skipped(.alreadyRunning)

        case .cancelExisting:
            cancel(id: id)

        case .ignoreNew, .allowConcurrent:
            break
        }

        let run = ActionRun(actionID: id)
        let ownedRun = ViewTaskStoreOwnedRun(
            storeID: ObjectIdentifier(self),
            runID: run.runID
        )
        let ownership = ViewTaskStoreOwnership.current.union([ownedRun])
        // Keep this weak capture. A strong capture would make the task retain the store,
        // which disables the deinit cancellation safety net until the operation finishes.
        // Resolve the error handler through the same weak reference at failure time; capturing
        // it in the task would extend the lifetime of everything the handler captures.
        let handle = Task(priority: priority) { @MainActor [weak self] in
            await ViewTaskStoreOwnership.$current.withValue(ownership) {
                defer {
                    self?.finish(run)
                }

                do {
                    try await operation(CancellationContext())
                } catch is CancellationError {
                    return
                } catch {
                    let failure = ActionFailure(error: error)
                    if let onUnhandledError = self?.onUnhandledError {
                        onUnhandledError(run, failure)
                    } else {
                        assertionFailure(
                            "Unhandled ViewTaskStore operation failure: "
                                + "\(failure.typeName): \(failure.message)"
                        )
                    }
                }
            }
        }

        tasksByRunID[run.runID] = ManagedTask(
            actionID: id,
            lifetime: lifetime,
            handle: handle
        )
        runIDsByActionID[id, default: []].insert(run.runID)
        return .started(run)
    }

    public func cancel(id: ActionID) {
        let runIDs = runIDsByActionID[id, default: []]
        for runID in runIDs {
            cancel(runID: runID)
        }
    }

    public func cancel(_ run: ActionRun) {
        cancel(runID: run.runID)
    }

    public func cancel(lifetime: ActionLifetime) {
        let runIDs = tasksByRunID.compactMap { runID, task in
            task.lifetime == lifetime ? runID : nil
        }
        for runID in runIDs {
            cancel(runID: runID)
        }
    }

    public func cancelAll() {
        for (runID, task) in tasksByRunID {
            task.handle.cancel()
            terminatingByRunID[runID] = task
        }
        tasksByRunID.removeAll()
        runIDsByActionID.removeAll()
    }

    /// Suspends until every task currently owned by the store has actually finished.
    ///
    /// This includes cancelled tasks that are no longer reported by `isRunning`, plus
    /// runs started while this method is suspended. If called from a run owned by this
    /// store, the current ownership context is excluded to avoid self-waiting; a debug
    /// assertion reports the contract violation.
    public func waitForIdle() async {
        let storeID = ObjectIdentifier(self)
        let excludedRunIDs = Set(
            ViewTaskStoreOwnership.current.lazy
                .filter { $0.storeID == storeID }
                .map(\.runID)
        )

        if !excludedRunIDs.isEmpty {
            assertionFailure(
                "ViewTaskStore.waitForIdle() cannot wait for a run owned by the same "
                    + "operation context; that context was excluded."
            )
        }

        while let handle = firstOwnedHandle(excluding: excludedRunIDs) {
            await handle.value
        }
    }

    /// Suspends until one concrete run has actually finished.
    ///
    /// Unlike `isRunning(_:)`, this also observes a cancelled run retained for termination.
    /// An already-finished run or a run created by another store returns immediately.
    public func awaitCompletion(of run: ActionRun) async {
        let ownedRun = ViewTaskStoreOwnedRun(
            storeID: ObjectIdentifier(self),
            runID: run.runID
        )
        guard !ViewTaskStoreOwnership.current.contains(ownedRun) else {
            assertionFailure(
                "ViewTaskStore.awaitCompletion(of:) cannot wait for the current run."
            )
            return
        }

        guard let handle = tasksByRunID[run.runID]?.handle
            ?? terminatingByRunID[run.runID]?.handle
        else {
            return
        }
        await handle.value
    }

    /// Returns whether any run with the given Action ID is currently tracked.
    ///
    /// This is a synchronous query. It does not drive SwiftUI redraws because
    /// `ViewTaskStore` is not Observable. UI state such as loading indicators
    /// should be owned by the ViewModel as its own state.
    public func isRunning(id: ActionID) -> Bool {
        runIDsByActionID[id]?.isEmpty == false
    }

    /// Returns whether the given Action run is currently tracked.
    ///
    /// This is a synchronous query. It does not drive SwiftUI redraws because
    /// `ViewTaskStore` is not Observable. UI state such as loading indicators
    /// should be owned by the ViewModel as its own state.
    public func isRunning(_ run: ActionRun) -> Bool {
        tasksByRunID[run.runID] != nil
    }

    /// Returns whether any run with the given lifetime is currently tracked.
    ///
    /// This is a synchronous query. It does not drive SwiftUI redraws because
    /// `ViewTaskStore` is not Observable. UI state such as loading indicators
    /// should be owned by the ViewModel as its own state.
    public func isRunning(lifetime: ActionLifetime) -> Bool {
        tasksByRunID.values.contains { $0.lifetime == lifetime }
    }

    /// Returns the number of currently tracked runs with the given Action ID.
    ///
    /// This is a synchronous query. It does not drive SwiftUI redraws because
    /// `ViewTaskStore` is not Observable. UI state such as loading indicators
    /// should be owned by the ViewModel as its own state.
    public func runningCount(for id: ActionID) -> Int {
        runIDsByActionID[id]?.count ?? 0
    }

    /// Returns the number of currently tracked runs with the given lifetime.
    ///
    /// This is a synchronous query. It does not drive SwiftUI redraws because
    /// `ViewTaskStore` is not Observable. UI state such as loading indicators
    /// should be owned by the ViewModel as its own state.
    public func runningCount(lifetime: ActionLifetime) -> Int {
        tasksByRunID.values.count { $0.lifetime == lifetime }
    }

    private func cancel(runID: ActionRunID) {
        guard let task = tasksByRunID.removeValue(forKey: runID) else {
            return
        }

        task.handle.cancel()
        removeTrackedRun(runID, actionID: task.actionID)
        terminatingByRunID[runID] = task
    }

    private func finish(_ run: ActionRun) {
        finish(runID: run.runID)
    }

    private func finish(runID: ActionRunID) {
        if let task = tasksByRunID.removeValue(forKey: runID) {
            removeTrackedRun(runID, actionID: task.actionID)
        }
        terminatingByRunID[runID] = nil
    }

    private func removeTrackedRun(_ runID: ActionRunID, actionID: ActionID) {
        runIDsByActionID[actionID]?.remove(runID)
        if runIDsByActionID[actionID]?.isEmpty == true {
            runIDsByActionID[actionID] = nil
        }
    }

    private func firstOwnedHandle(
        excluding excludedRunIDs: Set<ActionRunID>
    ) -> Task<Void, Never>? {
        if let task = tasksByRunID.first(where: { !excludedRunIDs.contains($0.key) })?.value {
            return task.handle
        }
        return terminatingByRunID.first(where: { !excludedRunIDs.contains($0.key) })?.value.handle
    }
}

private struct ManagedTask {
    let actionID: ActionID
    let lifetime: ActionLifetime
    let handle: Task<Void, Never>
}

private struct ViewTaskStoreOwnedRun: Hashable, Sendable {
    let storeID: ObjectIdentifier
    let runID: ActionRunID
}

private enum ViewTaskStoreOwnership {
    @TaskLocal static var current: Set<ViewTaskStoreOwnedRun> = []
}
