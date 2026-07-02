/// task のキャンセル状態を ViewModel の async メソッドへ明示的に渡すための値。
///
/// Swift のキャンセルは協調的です。長い処理の前後や重要な suspension point の
/// 後で `check()` を呼び、キャンセル要求を処理に反映します。
public struct CancellationContext: Sendable {
    public init() {}

    /// 現在実行中の task にキャンセルが要求されているかどうか。
    public var isCancelled: Bool {
        Task.isCancelled
    }

    /// 現在実行中の task にキャンセルが要求されていれば `CancellationError` を送出します。
    public func check() throws {
        try Task.checkCancellation()
    }
}
