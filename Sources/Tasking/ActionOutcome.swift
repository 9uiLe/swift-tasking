/// `ActionRunner` で実行する Action の重複ポリシー。
public enum ActionDuplicatePolicy: Equatable, Sendable {
    /// 既存の実行を継続し、同じ `ActionID` の新しい実行をスキップする。
    case ignoreNew

    /// 同じ `ActionID` の複数の実行が重なることを許可する。
    case allowConcurrent

    /// `ignoreNew` の非推奨エイリアス。網羅的な switch には `.ignoreNew` を使う。
    @available(*, deprecated, renamed: "ignoreNew")
    public static var rejectWhileRunning: ActionDuplicatePolicy {
        .ignoreNew
    }
}

/// Action で発生したエラーを表す、`Sendable` で等価比較可能な値。
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

/// `ActionRunner` で実行した Action の終了結果。
public enum ActionOutcome<Success: Sendable>: Sendable {
    case succeeded(Success)

    /// 処理が `CancellationError` を送出したことを表す。
    ///
    /// 送出されたエラー型によって決まり、送出前に現在のタスクが
    /// 外部からキャンセルされている必要はない。
    case cancelled

    case skipped(ActionSkipReason)
    case failed(ActionFailure)
}

extension ActionOutcome: Equatable where Success: Equatable {}

/// 1つの Action の静的な設定。
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
