/// The duplicate policy for Actions run through `ActionRunner`.
public enum ActionDuplicatePolicy: Equatable, Sendable {
    /// Keep the existing run and skip a new run with the same `ActionID`.
    case ignoreNew

    /// Allow multiple runs with the same `ActionID` to overlap.
    case allowConcurrent

    /// A deprecated alias for `ignoreNew`; use `.ignoreNew` in exhaustive switches.
    @available(*, deprecated, renamed: "ignoreNew")
    public static var rejectWhileRunning: ActionDuplicatePolicy {
        .ignoreNew
    }
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

    /// The operation threw `CancellationError`.
    ///
    /// This reflects the thrown error type. It does not require that the current
    /// task was externally cancelled before the operation threw.
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
        duplicatePolicy: ActionDuplicatePolicy = .ignoreNew
    ) {
        self.id = id
        self.duplicatePolicy = duplicatePolicy
    }
}
