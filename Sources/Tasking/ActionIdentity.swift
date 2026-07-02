import Foundation

/// ユーザー操作またはライフサイクル起点の処理を識別する安定した ID。
///
/// 呼び出し箇所に文字列リテラルを直接書くのではなく、機能ごとの名前空間に
/// 定数として宣言することを推奨します。
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

/// 1 回の具体的なアクション実行を識別する安定した ID。
public struct ActionRunID: Hashable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue.uuidString
    }
}

/// 1 回の具体的なアクション実行に関するメタデータ。
public struct ActionRun: Hashable, Sendable {
    public let actionID: ActionID
    public let runID: ActionRunID

    public init(actionID: ActionID, runID: ActionRunID = ActionRunID()) {
        self.actionID = actionID
        self.runID = runID
    }
}

/// 要求されたアクションが開始されなかった理由。
public enum ActionSkipReason: Equatable, Sendable {
    case alreadyRunning
}
