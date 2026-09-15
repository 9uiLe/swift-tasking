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

/// Why a store declined to start an operation.
public enum TaskStartSkipReason: Equatable, Sendable {
    case alreadyRunning
    case closed
}

/// Whether the store admitted one concrete run.
public enum TaskStartOutcome: Equatable, Sendable {
    case started(ActionRun)
    case skipped(TaskStartSkipReason)

    public var run: ActionRun? {
        guard case let .started(run) = self else {
            return nil
        }
        return run
    }

    public var skipReason: TaskStartSkipReason? {
        guard case let .skipped(reason) = self else {
            return nil
        }
        return reason
    }
}
