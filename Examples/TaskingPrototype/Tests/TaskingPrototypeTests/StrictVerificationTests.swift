import Testing
import Tasking
@testable import TaskingPrototype

/// 2 回目レビュー(厳格版)で追加した検証。
@MainActor
@Suite struct StrictVerificationTests {
    /// F10: operation クロージャが store 自身(または store を持つ ViewModel)を
    /// 強参照すると、store → task → closure → store の一時循環ができる。
    /// 画面破棄で @State の参照が切れても store は解放されず、
    /// **deinit の安全網(全 task キャンセル)が発火しない**。
    @Test func f10_operationCapturingStoreDefeatsDeinitSafetyNet() async throws {
        let gate = Signal()
        let recorder = Recorder()
        var store: ViewTaskStore? = ViewTaskStore()
        // weak let は Swift 6.2+ のため、旧ツールチェーン(CI の Xcode 16.4)互換で
        // var + 形式的 mutation にする。
        weak var weakStore = store
        defer { weakStore = nil }

        // ありがちな書き方: operation の中で store(や store を持つ VM)を触る
        store!.start(id: "cyclic", lifetime: .screenBound) { [store] _ in
            await gate.wait()
            // ここで store に触る(強参照キャプチャ)
            recorder.record(store?.isRunning(id: "cyclic") == true ? "tracked" : "untracked")
        }

        store = nil // 画面破棄相当。しかし…
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(10))

        // 循環参照により store は生きたまま = deinit のキャンセルは走らない
        #expect(weakStore != nil)
        #expect(weakStore?.isRunning(id: "cyclic") == true)

        await gate.signal()
        try await waitUntil { weakStore == nil } // task 完了で循環が解けて解放
        #expect(recorder.count(of: "tracked") == 1)
    }

    /// operation 内から自分自身の ActionID を cancel しても
    /// ブックキーピングが壊れないこと(再入の最悪ケース)。
    @Test func selfCancelInsideOwnOperationStaysConsistent() async throws {
        let store = ViewTaskStore()
        let recorder = Recorder()

        let selfCancellingStore = store
        store.start(id: "selfCancel", lifetime: .screenBound) { cancellation in
            selfCancellingStore.cancel(id: "selfCancel") // 自分をキャンセル
            recorder.record(selfCancellingStore.isRunning(id: "selfCancel") ? "still" : "untracked")
            await Task.yield()
            recorder.record(cancellation.isCancelled ? "saw-cancel" : "no-cancel")
        }

        try await waitUntil { recorder.count(of: "saw-cancel") == 1 }
        #expect(recorder.count(of: "untracked") == 1)
        #expect(store.runningCount(for: "selfCancel") == 0)
        #expect(internalEntryCounts(of: store) == (0, 0))
    }

    /// `.cancelExisting` を 50 連打しても追跡は常に最新 1 件で、
    /// 全完了後に内部辞書が完全に空へ戻ること。
    @Test func cancelExistingStormLeavesCleanBookkeeping() async throws {
        let store = ViewTaskStore()
        let recorder = Recorder()

        for _ in 0..<50 {
            store.start(id: "storm", lifetime: .screenBound, policy: .cancelExisting) { c in
                try? await Task.sleep(for: .milliseconds(5))
                if !c.isCancelled {
                    recorder.record("survivor")
                }
            }
            #expect(store.runningCount(for: "storm") == 1)
        }

        try await waitUntil { !store.isRunning(id: "storm") }
        try await waitUntil { internalEntryCounts(of: store) == (0, 0) }
        #expect(recorder.count(of: "survivor") <= 1) // 生き残りは最後の 1 run だけ
    }

    /// 動的 ActionID(エンティティ単位)を大量に使い捨てても
    /// 内部辞書にエントリが残らないこと(per-ID リーク検査)。
    @Test func massDistinctActionIDsLeaveNoDictionaryEntries() async throws {
        let store = ViewTaskStore()
        for index in 0..<500 {
            store.start(id: DownloadAction.item("item-\(index)"), lifetime: .screenBound) { _ in }
        }
        try await waitUntil { internalEntryCounts(of: store) == (0, 0) }
    }

    /// ActionRunner: operation が実際のキャンセルなしに CancellationError を
    /// 投げた場合も outcome は `.cancelled` に写像される(意味論の footnote)。
    @Test func spontaneousCancellationErrorMapsToCancelledOutcome() async throws {
        let runner = ActionRunner()
        let outcome: ActionOutcome<Void> = await runner.run(ActionDescriptor(id: "spontaneous")) { _ in
            throw CancellationError() // 誰もキャンセルしていない
        }
        // 補足: ActionOutcome<Void> は Void が Equatable でないため == 比較できず、
        // パターンマッチが必要(API 摩擦として本体レビューに記載)。
        var isCancelled = false
        if case .cancelled = outcome {
            isCancelled = true
        }
        #expect(isCancelled)
    }

    /// F9 追検証: @MainActor クラスは Sendable なので最終参照の解放が
    /// main 外で起き得る。deinit と MainActor 上の finish が競合しないかを
    /// ストレス実行する(--sanitize=thread での検出用。素の実行では生存確認)。
    ///
    /// 理論分析: operation は self を weak 捕捉しており、deinit 開始時点で
    /// weak 参照は nil を返すため、deinit 中に辞書へ触れる経路は存在しない
    /// はず(weak-zeroing が排他を担保)。これを実測で裏取りする。
    @Test func f9_offMainDeinitStressDoesNotRace() async throws {
        final class LastReferenceBox: @unchecked Sendable {
            nonisolated(unsafe) var store: ViewTaskStore?
            init(_ store: ViewTaskStore) { self.store = store }
        }

        for _ in 0..<300 {
            var store: ViewTaskStore? = ViewTaskStore()
            for _ in 0..<4 {
                store!.start(id: "noise", lifetime: .screenBound, policy: .allowConcurrent) { _ in
                    await Task.yield() // すぐ終わる → finish が main で走る
                }
            }
            let box = LastReferenceBox(store!)
            store = nil
            Task.detached(priority: .high) {
                box.store = nil // 最終参照を main 外で解放 → deinit は main 外
            }
            await Task.yield() // main 側では finish 群が流れる
        }
        try? await Task.sleep(for: .milliseconds(50))
    }

    #if !DEBUG
    /// ADR-0003 の既知の制限の実証(release 構成専用):
    /// 未処理の業務エラーは assertionFailure が no-op になるため、
    /// 何のフィードバックもなく握り潰される。
    /// 実行方法: swift test -c release --filter releaseBuildSilentlySwallows
    @Test func releaseBuildSilentlySwallowsUncaughtErrors() async throws {
        struct BusinessError: Error {}
        let store = ViewTaskStore()
        let recorder = Recorder()

        store.start(id: "swallow", lifetime: .screenBound) { _ in
            recorder.record("begin")
            throw BusinessError() // 契約違反。release では無音で消える
        }

        try await waitUntil { !store.isRunning(id: "swallow") }
        #expect(recorder.count(of: "begin") == 1)
        // クラッシュも通知も起きずここに到達する = 無音の握り潰しを実証
    }
    #endif
}

/// Mirror でライブラリ内部の追跡辞書のエントリ数を覗く(リーク検査専用)。
@MainActor
private func internalEntryCounts(of store: ViewTaskStore) -> (tasks: Int, runIDs: Int) {
    var tasks = -1
    var runIDs = -1
    for child in Mirror(reflecting: store).children {
        if child.label == "tasksByRunID" {
            tasks = Mirror(reflecting: child.value).children.count
        }
        if child.label == "runIDsByActionID" {
            runIDs = Mirror(reflecting: child.value).children.count
        }
    }
    return (tasks, runIDs)
}
