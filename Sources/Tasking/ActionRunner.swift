/// 呼び出し元の既存の async コンテキストで、Action ID ごとの重複受付を制御する。
///
/// タスクは作成・所有せず、キャンセル状態と送出されたエラーをそのまま処理へ渡す。
/// UI の読み込み状態や結果は呼び出し側が所有する。
@MainActor
public final class ActionRunner {
    private var counts: [ActionID: Int] = [:]

    public init() {}

    /// 受け付けた処理の結果を `.some` で返し、重複で拒否した場合は `nil` を返す。
    ///
    /// 処理の戻り値が Optional でも、成功した `nil` は `.some(nil)` となり、受付拒否と区別できる。
    /// 処理が送出したエラーは、`CancellationError` を含め変換せず再送出する。
    /// 追跡は処理の呼び出し前に開始し、成功・失敗・キャンセルのいずれでも終了時に除去する。
    public func run<Success>(
        id: ActionID,
        policy: ActionDuplicatePolicy = .ignoreNew,
        operation: @MainActor () async throws -> Success
    ) async rethrows -> Success? {
        if policy == .ignoreNew, isTracked(id: id) {
            return nil
        }

        counts[id, default: 0] += 1
        defer {
            let remaining = counts[id, default: 0] - 1
            counts[id] = remaining == 0 ? nil : remaining
        }
        return .some(try await operation())
    }

    /// この Action ID で受け付けた処理が終了していないかどうか。平均 O(1) で照会する。
    /// 同期的なスナップショットであり、SwiftUI の再描画は起こさない。
    public func isTracked(id: ActionID) -> Bool {
        trackedCount(for: id) > 0
    }

    /// この Action ID で受け付けた未終了の処理数。平均 O(1) で照会する。
    /// 同期的なスナップショットであり、SwiftUI の再描画は起こさない。
    public func trackedCount(for id: ActionID) -> Int {
        counts[id] ?? 0
    }
}
