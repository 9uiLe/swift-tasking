import Foundation

/// ユーザー操作やライフサイクルイベントから始まる Action の種類を識別する安定した ID。
///
/// 呼び出し箇所に文字列リテラルを直接書かず、機能ごとの名前空間に定数として宣言する。
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

/// Action の1回の実行を識別する安定した ID。
public struct ActionRunID: Hashable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue.uuidString
    }
}

/// Action の1回の実行に関するメタデータ。
public struct ActionRun: Hashable, Sendable {
    public let actionID: ActionID
    public let runID: ActionRunID

    public init(actionID: ActionID, runID: ActionRunID = ActionRunID()) {
        self.actionID = actionID
        self.runID = runID
    }
}

/// `ActionRunner` が Action の実行を受け付けなかった理由。
public enum ActionSkipReason: Equatable, Sendable {
    case alreadyRunning
}
