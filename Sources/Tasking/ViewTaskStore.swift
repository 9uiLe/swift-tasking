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

    public init() {}

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
    /// with a debug assertion.
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
        let handle = Task(priority: priority) { @MainActor [weak self] in
            defer {
                self?.finish(run)
            }

            do {
                try await operation(CancellationContext())
            } catch is CancellationError {
                return
            } catch {
                assertionFailure("Unhandled ViewTaskStore operation failure: \(error)")
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
        for task in tasksByRunID.values {
            task.handle.cancel()
        }
        tasksByRunID.removeAll()
        runIDsByActionID.removeAll()
    }

    public func isRunning(id: ActionID) -> Bool {
        runIDsByActionID[id]?.isEmpty == false
    }

    public func isRunning(_ run: ActionRun) -> Bool {
        tasksByRunID[run.runID] != nil
    }

    public func isRunning(lifetime: ActionLifetime) -> Bool {
        tasksByRunID.values.contains { $0.lifetime == lifetime }
    }

    public func runningCount(for id: ActionID) -> Int {
        runIDsByActionID[id]?.count ?? 0
    }

    public func runningCount(lifetime: ActionLifetime) -> Int {
        tasksByRunID.values.filter { $0.lifetime == lifetime }.count
    }

    private func cancel(runID: ActionRunID) {
        tasksByRunID[runID]?.handle.cancel()
        finish(runID: runID)
    }

    private func finish(_ run: ActionRun) {
        finish(runID: run.runID)
    }

    private func finish(runID: ActionRunID) {
        guard let task = tasksByRunID[runID] else {
            return
        }

        tasksByRunID[runID] = nil
        runIDsByActionID[task.actionID]?.remove(runID)
        if runIDsByActionID[task.actionID]?.isEmpty == true {
            runIDsByActionID[task.actionID] = nil
        }
    }
}

private struct ManagedTask {
    let actionID: ActionID
    let lifetime: ActionLifetime
    let handle: Task<Void, Never>
}
