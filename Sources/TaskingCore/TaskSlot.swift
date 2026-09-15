/// UI の分離領域の外で、アクティブな非構造化タスクを1つ所有する。
///
/// 差し替えとキャンセルでは協調キャンセルを要求する。差し替えた処理も終了まで所有するため、
/// `waitForIdle()` はその処理の終了も待つ。
/// 処理内から Slot の所有者を強参照しないこと。
public actor TaskSlot {
    private var tasks = OwnedTasks<TaskOwnership>()
    private var activeTask: TaskOwnership?
    private var isClosed = false

    public init() {}

    deinit {
        tasks.cancelAll()
    }

    /// アクティブなタスクをキャンセルして代わりのタスクを開始する。受付の閉鎖後は `false` を返す。
    ///
    /// 処理は重要な中断点でキャンセルコンテキストを確認すること。
    /// 優先度は `Task` に渡し、`nil` なら呼び出し元の優先度を継承する。
    @discardableResult
    public func replace(
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable (CancellationContext) async -> Void
    ) -> Bool {
        guard !isClosed else { return false }
        cancel()

        let ownership = TaskOwnership()
        let context = ownership.inheritingCurrent
        // ここで Slot を保持すると、deinit によるキャンセルが働かなくなる。
        let handle = Task(priority: priority) { [weak self] in
            await TaskOwnership.$current.withValue(context) {
                await operation(CancellationContext())
            }
            await self?.finish(ownership)
        }
        tasks.insert(handle, for: ownership, ownership: ownership)
        activeTask = ownership
        return true
    }

    /// 既存の処理をキャンセルせずに、差し替えの受付を終端状態へ移す。
    /// 繰り返し閉じても結果は変わらない。処理を完了させて終了するには、続けて `waitForIdle()` を使う。
    public func close() {
        isClosed = true
    }

    /// アクティブなタスクに協調キャンセルを要求する。受付は開いたままにする。
    public func cancel() {
        guard let activeTask else { return }
        tasks.cancel(activeTask)
        self.activeTask = nil
    }

    /// 受付を閉じ、キャンセルを要求して、所有するすべての処理の終了を待つ。
    /// このメソッドの中断中も差し替えを開始できない。閉鎖は終端状態である。
    public func cancelAndWaitForIdle() async {
        close()
        cancel()
        await waitForIdle()
    }

    /// 待機中に受け付けた差し替えも含め、所有するすべてのタスクを待つ。
    ///
    /// 処理は自分を所有する Slot の終了を待ってはならない。Debug ビルドではアサーションで検出する。
    /// Release ビルドでは継承された所有文脈を除き、ほかの処理を待つ。
    /// 呼び出し元をキャンセルしても、所有する処理をキャンセルしたり、この待機を中断したりしない。
    public func waitForIdle() async {
        let excluded = tasks.keysExcludedFromWait()
        while let handle = tasks.firstHandle(excluding: excluded) {
            await handle.value
        }
    }

    private func finish(_ ownership: TaskOwnership) {
        tasks.remove(ownership)
        if activeTask == ownership {
            activeTask = nil
        }
    }
}
