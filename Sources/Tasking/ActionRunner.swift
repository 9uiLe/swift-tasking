/// The duplicate policy for Actions run through `ActionRunner`.
public enum ActionDuplicatePolicy: Equatable, Sendable {
    /// Reject a new run while the same `ActionID` is running.
    case rejectWhileRunning

    /// Allow multiple runs with the same `ActionID` to overlap.
    case allowConcurrent
}

/// A `Sendable` and comparable value that represents an error produced by an Action.
public struct ActionFailure: Equatable, Sendable {
    public let typeName: String
    public let message: String

    public init(typeName: String, message: String) {
        self.typeName = typeName
        self.message = message
    }

    public init(error: any Error) {
        typeName = String(reflecting: type(of: error))
        message = String(describing: error)
    }
}

/// The terminal outcome of an Action run through `ActionRunner`.
public enum ActionOutcome<Success: Sendable>: Sendable {
    case succeeded(Success)
    case cancelled
    case skipped(ActionSkipReason)
    case failed(ActionFailure)
}

extension ActionOutcome: Equatable where Success: Equatable {}

/// Static configuration for one Action.
public struct ActionDescriptor: Equatable, Sendable {
    public let id: ActionID
    public let duplicatePolicy: ActionDuplicatePolicy

    public init(
        id: ActionID,
        duplicatePolicy: ActionDuplicatePolicy = .rejectWhileRunning
    ) {
        self.id = id
        self.duplicatePolicy = duplicatePolicy
    }
}

/// Runs Actions in an existing async context and centrally manages Action state.
///
/// `ActionRunner` does not create or own tasks. Use it when you are already in an
/// async context and need duplicate control plus a typed terminal outcome.
/// Use `ViewTaskStore` for the separate responsibility of owning unstructured task handles.
@MainActor
public final class ActionRunner {
    private var runningRunsByActionID: [ActionID: Set<ActionRunID>] = [:]

    public init() {}

    public func run<Success: Sendable>(
        _ descriptor: ActionDescriptor,
        onStart: (ActionRun) -> Void = { _ in },
        operation: @MainActor @Sendable (CancellationContext) async throws -> Success
    ) async -> ActionOutcome<Success> {
        switch start(descriptor) {
        case let .started(run):
            onStart(run)
            defer {
                finish(run)
            }

            do {
                return .succeeded(try await operation(CancellationContext()))
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failed(ActionFailure(error: error))
            }

        case let .skipped(reason):
            return .skipped(reason)
        }
    }

    public func isRunning(_ id: ActionID) -> Bool {
        runningRunsByActionID[id]?.isEmpty == false
    }

    public func runningCount(for id: ActionID) -> Int {
        runningRunsByActionID[id]?.count ?? 0
    }

    private func start(_ descriptor: ActionDescriptor) -> ActionStart {
        let runningRuns = runningRunsByActionID[descriptor.id, default: []]

        switch descriptor.duplicatePolicy {
        case .rejectWhileRunning where !runningRuns.isEmpty:
            return .skipped(.alreadyRunning)

        case .rejectWhileRunning, .allowConcurrent:
            let run = ActionRun(actionID: descriptor.id)
            runningRunsByActionID[descriptor.id, default: []].insert(run.runID)
            return .started(run)
        }
    }

    private func finish(_ run: ActionRun) {
        runningRunsByActionID[run.actionID]?.remove(run.runID)
        if runningRunsByActionID[run.actionID]?.isEmpty == true {
            runningRunsByActionID[run.actionID] = nil
        }
    }
}

private enum ActionStart: Sendable {
    case started(ActionRun)
    case skipped(ActionSkipReason)
}
