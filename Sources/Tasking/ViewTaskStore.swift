import TaskingCore

/// MainActor 上の同期 UI コールバックから開始する非構造化タスクを所有する。
///
/// 寿命ラベルと重複ポリシーは追跡中の実行に適用する。キャンセルすると直ちに追跡から外すが、
/// タスクのハンドルは実際に終了するまで所有する。
/// 実行状態の照会は同期的なスナップショットであり、監視可能な UI 状態ではない。
/// 読み込み状態や結果は ViewModel が所有する。処理から Store やその所有者を強参照してはならない。
@MainActor
public final class ViewTaskStore {
    private var runs = ActionRuns<ActionLifetime>()
    private var tasks = OwnedTasks<ActionRun>()
    private var isClosed = false
    private let onUnhandledError: (@MainActor (ActionRun, ActionFailure) -> Void)?

    /// 処理の契約違反を受け取る任意の通知先を指定して Store を作成する。
    ///
    /// 業務上のエラーは処理の外に漏らさず、ViewModel の状態に変換する。
    /// 通知先は、完了による追跡の除去より前に呼ばれる。キャンセル済みの実行は既に追跡対象外である。
    /// 通知先がなければ、漏れたエラーは Debug のアサーション対象になる。
    /// Store の解放後のエラーにも同じアサーションの扱いを適用する。
    /// Store は通知先を保持するため、Store の所有者は弱参照で捕捉する。
    public init(
        onUnhandledError: (@MainActor (ActionRun, ActionFailure) -> Void)? = nil
    ) {
        self.onUnhandledError = onUnhandledError
    }

    deinit {
        tasks.cancelAll()
    }

    /// 重複ポリシーまたは受付の終端状態により拒否されなければ、処理を開始する。
    ///
    /// 処理を開始する前に実行を追跡に追加する。重要な中断点で `cancellation.check()` を呼び、
    /// キャンセル要求に協調すること。`CancellationError` は通常の終了として扱う。
    /// 業務上のエラーは ViewModel で処理する。それ以外の漏れたエラーは通知先に報告するか、
    /// Debug のアサーション対象になる。
    @discardableResult
    public func start(
        id: ActionID,
        lifetime: ActionLifetime,
        policy: TaskStartPolicy = .ignoreNew,
        priority: TaskPriority? = nil,
        operation: @escaping @MainActor @Sendable (CancellationContext) async throws -> Void
    ) -> TaskStartOutcome {
        guard !isClosed else { return .skipped(.closed) }

        switch policy {
        case .ignoreNew where isRunning(id: id):
            return .skipped(.alreadyRunning)
        case .cancelExisting:
            cancel(id: id)
        case .ignoreNew, .allowConcurrent:
            break
        }

        let run = ActionRun(actionID: id)
        let ownership = TaskOwnership()
        let context = ownership.inheritingCurrent
        // Store や通知先を強参照すると、deinit によるキャンセルが働かなくなるか、
        // Store の解放後も通知先の依存を保持してしまう。
        let handle = Task(priority: priority) { @MainActor [weak self] in
            await TaskOwnership.$current.withValue(context) {
                defer { self?.finish(run) }
                do {
                    try await operation(CancellationContext())
                } catch is CancellationError {
                    return
                } catch {
                    let failure = ActionFailure(error: error)
                    if let observer = self?.onUnhandledError {
                        observer(run, failure)
                    } else {
                        assertionFailure(
                            "ViewTaskStore の処理で未処理のエラーが発生しました: "
                                + "\(failure.typeName): \(failure.message)"
                        )
                    }
                }
            }
        }

        tasks.insert(handle, for: run, ownership: ownership)
        runs.insert(run, metadata: lifetime)
        return .started(run)
    }

    /// この Action ID の実行にキャンセルを要求し、直ちに追跡から外す。
    public func cancel(id: ActionID) {
        for run in runs.runs(for: id) { cancel(run) }
    }

    /// 指定した1回の実行にキャンセルを要求し、直ちに追跡から外す。
    /// 終了済み・キャンセル済み・この Store に属さない実行には影響しない。
    public func cancel(_ run: ActionRun) {
        guard runs.remove(run) != nil else { return }
        tasks.cancel(run)
    }

    /// この寿命ラベルの実行にキャンセルを要求し、直ちに追跡から外す。
    public func cancel(lifetime: ActionLifetime) {
        for run in runs.runs(matching: { $0 == lifetime }) { cancel(run) }
    }

    /// 所有するすべてのタスクにキャンセルを要求し、追跡を空にする。受付は開いたままにする。
    public func cancelAll() {
        runs.removeAll()
        tasks.cancelAll()
    }

    /// 既存の処理をキャンセルせずに、新しい開始要求の受付を終端状態へ移す。
    /// 繰り返し閉じても結果は変わらない。処理を完了させて終了するには、続けて `waitForIdle()` を使う。
    public func close() {
        isClosed = true
    }

    /// 受付を閉じ、所有するすべての処理にキャンセルを要求して、実際の終了を待つ。
    /// このメソッドの中断中も新しい実行は開始できない。閉鎖は終端状態である。
    public func cancelAndWaitForIdle() async {
        close()
        cancelAll()
        await waitForIdle()
    }

    /// キャンセル済みや待機中に受け付けた実行も含め、所有するすべてのタスクを待つ。
    ///
    /// 処理は自分を所有する Store の終了を待ってはならない。Debug ビルドではアサーションで検出する。
    /// Release ビルドでは継承された所有文脈を除き、ほかの処理を待つ。
    /// 呼び出し元をキャンセルしても、所有する処理をキャンセルしたり、この待機を中断したりしない。
    public func waitForIdle() async {
        let excluded = tasks.keysExcludedFromWait()
        while let handle = tasks.firstHandle(excluding: excluded) {
            await handle.value
        }
    }

    /// 指定した1回の実行を待つ。キャンセル済みでも終了まで所有している実行を含む。
    /// 終了済みか、この Store に属さない実行なら直ちに戻る。自己待機は構造化子タスク経由も含め、
    /// Debug ビルドではアサーションで検出し、Release ビルドでは直ちに戻る。
    /// 呼び出し元をキャンセルしても、対象の実行をキャンセルしたり、この待機を中断したりしない。
    public func awaitCompletion(of run: ActionRun) async {
        await tasks.handleToWait(for: run)?.value
    }

    /// この Action ID の実行を追跡しているかどうか。
    public func isRunning(id: ActionID) -> Bool {
        runningCount(for: id) > 0
    }

    /// 指定した1回の実行を追跡しているかどうか。
    public func isRunning(_ run: ActionRun) -> Bool {
        runs.contains(run)
    }

    /// この寿命ラベルの実行を追跡しているかどうか。
    public func isRunning(lifetime: ActionLifetime) -> Bool {
        runs.contains(matching: { $0 == lifetime })
    }

    /// この Action ID の追跡中の実行数。
    public func runningCount(for id: ActionID) -> Int {
        runs.count(for: id)
    }

    /// この寿命ラベルの追跡中の実行数。
    public func runningCount(lifetime: ActionLifetime) -> Int {
        runs.count(matching: { $0 == lifetime })
    }

    private func finish(_ run: ActionRun) {
        runs.remove(run)
        tasks.remove(run)
    }
}
