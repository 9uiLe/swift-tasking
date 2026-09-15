/// 呼び出し元の既存の async コンテキストで実行しながら Action を追跡する。
///
/// `ActionRunner` はタスクを作成・所有しない。async コンテキスト内で、
/// 重複制御と型付きの終了結果が必要な場合に使う。
/// 非構造化タスクのハンドルの所有には `ViewTaskStore` を使う。
@MainActor
public final class ActionRunner {
    private var runs = ActionRuns<Void>()

    public init() {}

    /// 実行を受け付け、追跡中に `onStart` を呼び、処理の終了を待つ。
    /// スキップした場合はどちらのクロージャも呼ばない。すべての終了結果で追跡を除く。
    /// キャンセルは協調的に行われ、送出された `CancellationError` だけを `.cancelled` に変換する。
    /// 値が返された場合は、キャンセルが要求されていても `.succeeded` になる。
    public func run<Success: Sendable>(
        _ descriptor: ActionDescriptor,
        onStart: @MainActor (ActionRun) -> Void = { _ in },
        operation: @MainActor @Sendable (CancellationContext) async throws -> Success
    ) async -> ActionOutcome<Success> {
        if descriptor.duplicatePolicy == .ignoreNew, isRunning(id: descriptor.id) {
            return .skipped(.alreadyRunning)
        }

        let run = ActionRun(actionID: descriptor.id)
        runs.insert(run, metadata: ())
        defer { runs.remove(run) }
        onStart(run)

        do {
            return .succeeded(try await operation(CancellationContext()))
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(ActionFailure(error: error))
        }
    }

    /// 指定した Action ID の実行を追跡しているかどうかを返す。
    ///
    /// 同期的な照会であり、`ActionRunner` は Observable ではないため SwiftUI の再描画を起こさない。
    /// 読み込み表示などの UI 状態は ViewModel 自身の状態として所有する。
    public func isRunning(id: ActionID) -> Bool {
        runningCount(for: id) > 0
    }

    /// 指定した Action ID の追跡中の実行数を返す。
    ///
    /// 同期的な照会であり、`ActionRunner` は Observable ではないため SwiftUI の再描画を起こさない。
    /// 読み込み表示などの UI 状態は ViewModel 自身の状態として所有する。
    public func runningCount(for id: ActionID) -> Int {
        runs.count(for: id)
    }
}
