/// 現在のタスクの協調キャンセル状態を明示的に渡すための値。
///
/// 長い処理や重要な中断点の前後で `check()` を呼ぶこと。
/// キャンセルトークンを捕捉・転送する値ではなく、アクセスするたびに実行中のタスクを参照する。
/// キャンセルを伝播させる場合は構造化子タスクで処理を行う。
/// 新しい非構造化 `Task` にこの値を渡しても、親のキャンセルには接続されない。
public struct CancellationContext: Sendable {
    public init() {}

    /// 現在実行中のタスクにキャンセルが要求されているかどうか。
    public var isCancelled: Bool {
        Task.isCancelled
    }

    /// 現在のタスクにキャンセルが要求されていれば `CancellationError` を送出する。
    public func check() throws {
        try Task.checkCancellation()
    }
}
