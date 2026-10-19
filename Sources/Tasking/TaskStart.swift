/// `ViewTaskStore` の追跡中の実行から、キャンセル対象を選ぶ任意のラベル。
///
/// ラベルは寿命を制御しない。所有者が Store を保持し、終了時にキャンセルする。
public struct CancellationGroup: Hashable, Sendable, RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible {
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

/// 同じ `ActionID` の未終了タスクがある場合の受付方針。
public enum TaskStartPolicy: Equatable, Sendable {
    /// キャンセル済みも含め、先に受け付けた処理が終了するまで新しい要求を受け付けない。
    case ignoreNew

    /// 同じ Action として追跡中のタスクをキャンセルし、新しい要求を開始する。
    ///
    /// キャンセルは協調的に行われる。古い処理がキャンセルを無視した場合、
    /// Store が追跡から外した後も実行が続き、未終了件数には残る。
    case cancelExisting

    /// 同じ Action ID のタスクを追加で開始する。
    case allowConcurrent
}

/// Store が処理の開始を受け付けなかった理由。
public enum TaskStartSkipReason: Equatable, Sendable {
    /// 同じ Action ID に、キャンセル済みも含む未終了の処理がある。
    case unfinished
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
