/// `ViewTaskStore` が所有するタスクの論理的な寿命。
///
/// 組み込み値は一般的な UI の所有スコープを表す。
/// `"accountSettings"` のような機能固有のスコープも定義できる。
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

/// 同じ `ActionID` のタスクを追跡している場合の開始ポリシー。
public enum TaskStartPolicy: Equatable, Sendable {
    /// 既存のタスクを継続し、新しい要求をスキップする。
    case ignoreNew

    /// 同じ Action として追跡中のタスクをキャンセルし、新しい要求を開始する。
    ///
    /// キャンセルは協調的に行われる。古い処理がキャンセルを無視した場合、
    /// Store が重複判定の対象から外した後も実行が続くことがある。
    case cancelExisting

    /// 同じ Action ID のタスクを追加で開始する。
    case allowConcurrent
}

/// Store が処理の開始を受け付けなかった理由。
public enum TaskStartSkipReason: Equatable, Sendable {
    case alreadyRunning
    case closed
}

/// Store が1回の実行を受け付けたかどうかを表す。
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
