import Foundation

/// A stable ID for identifying an Action that starts from a user operation or lifecycle event.
///
/// Declare these as constants in a feature-specific namespace instead of writing string
/// literals directly at call sites.
public struct ActionID: Hashable, Sendable, RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible {
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

/// A stable ID for one concrete Action run.
public struct ActionRunID: Hashable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue.uuidString
    }
}

/// Metadata for one concrete Action run.
public struct ActionRun: Hashable, Sendable {
    public let actionID: ActionID
    public let runID: ActionRunID

    public init(actionID: ActionID, runID: ActionRunID = ActionRunID()) {
        self.actionID = actionID
        self.runID = runID
    }
}

/// The reason a requested Action did not start.
public enum ActionSkipReason: Equatable, Sendable {
    case alreadyRunning
}
