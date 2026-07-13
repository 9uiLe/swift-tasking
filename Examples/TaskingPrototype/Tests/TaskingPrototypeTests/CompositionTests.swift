import Testing
import Tasking
@testable import TaskingPrototype

/// ActionRunner の合成と、CancellationContext の伝播境界の検証。
@MainActor
@Suite struct CompositionTests {
    @Test func billingPublishesLoadingForAnAcceptedRefresh() async throws {
        let gate = Signal()
        let viewModel = BillingViewModel(fetchPlans: {
            await gate.wait()
            return ["Pro"]
        })

        async let refresh: Void = viewModel.refresh()
        try await waitUntil { viewModel.loadState == .loading }
        await gate.signal()
        await refresh

        #expect(viewModel.loadState == .loaded(["Pro"]))
    }

    /// BillingViewModel: 2 つの async 入口(.task と .refreshable 相当)からの
    /// 同時 refresh は片方が skipped になる。
    @Test func runnerDeduplicatesAcrossTwoAsyncEntryPoints() async throws {
        let gate = Signal()
        let viewModel = BillingViewModel(fetchPlans: {
            await gate.wait()
            return ["Free", "Pro"]
        })

        async let firstEntry: Void = viewModel.refresh()  // .task 相当
        async let secondEntry: Void = viewModel.refresh() // .refreshable 相当

        try await waitUntil { viewModel.lastOutcomeDescription == "skipped" }
        await gate.signal()
        await gate.signal() // 先行 run 分(片方は skip なので 1 回で足りるが冪等)
        _ = await (firstEntry, secondEntry)

        #expect(viewModel.loadState == .loaded(["Free", "Pro"]))
    }

    /// 合成: ViewTaskStore が所有する task の中で ActionRunner を使うと、
    /// store のキャンセルが CancellationContext 経由で runner の outcome に
    /// .cancelled として現れる(キャンセル所有権は store 側に残る)。
    @Test func runnerInsideStoreObservesStoreCancellation() async throws {
        let gate = Signal()
        let store = ViewTaskStore()
        let runner = ActionRunner()
        let recorder = Recorder()

        store.start(id: "composite", lifetime: .screenBound) { _ in
            let outcome = await runner.run(ActionDescriptor(id: "composite.inner")) { cancellation in
                await gate.wait()
                try cancellation.check()
            }
            if case .cancelled = outcome {
                recorder.record("inner-cancelled")
            }
        }
        try await waitUntil { runner.isRunning(id: "composite.inner") }

        store.cancel(id: "composite")
        await gate.signal()
        try await waitUntil { recorder.count(of: "inner-cancelled") == 1 }
        #expect(!runner.isRunning(id: "composite.inner"))
    }

    /// F7: CancellationContext は task 境界を越えない。operation 内で新たな
    /// unstructured Task に処理を逃がすと、store のキャンセルは内側に届かず、
    /// 内側の check() も素通りする(教育すべき制約)。
    @Test func f7_nestedUnstructuredTaskEscapesCancellation() async throws {
        let gate = Signal()
        let store = ViewTaskStore()
        let recorder = Recorder()

        store.start(id: "leaky", lifetime: .screenBound) { _ in
            // アンチパターン: operation 内でさらに Task {} を作る
            let inner = Task { @MainActor in
                await gate.wait()
                if Task.isCancelled {
                    recorder.record("inner-saw-cancel")
                } else {
                    recorder.record("inner-completed")
                }
            }
            _ = await inner.value
        }
        try await waitUntil { store.isRunning(id: "leaky") }

        store.cancel(id: "leaky") // 外側の task はキャンセルされるが…
        await gate.signal()
        try await waitUntil { recorder.events.count == 1 }

        // 内側の Task にはキャンセルが伝播しない
        #expect(recorder.count(of: "inner-completed") == 1)
    }

    /// F3: 重複ポリシーは呼び出し箇所ごとに指定できるため、同じ ActionID に
    /// 矛盾するポリシーを与えてもコンパイルも実行も通る(宣言の一貫性は
    /// 利用者の規約頼み)。
    @Test func f3_conflictingPoliciesForSameActionIDAreNotRejected() async throws {
        let gateA = Signal()
        let gateB = Signal()
        let store = ViewTaskStore()

        // 呼び出し箇所 A: 「実行中は無視」のつもり
        store.start(id: "export", lifetime: .screenBound, policy: .ignoreNew) { _ in
            await gateA.wait()
        }
        try await waitUntil { store.runningCount(for: "export") == 1 }

        // 呼び出し箇所 B: 同じ ID に allowConcurrent を指定 → 並行実行が成立
        let outcome = store.start(id: "export", lifetime: .screenBound, policy: .allowConcurrent) { _ in
            await gateB.wait()
        }
        #expect(outcome.run != nil)
        #expect(store.runningCount(for: "export") == 2)

        await gateA.signal()
        await gateB.signal()
        try await waitUntil { !store.isRunning(id: "export") }
    }

    /// 動的 ActionID(エンティティ単位)は独立して重複制御される。
    @Test func perItemActionIDsAreIndependent() async throws {
        let gate = Signal()
        let store = ViewTaskStore()
        let viewModel = DownloadsViewModel(performDownload: { _ in await gate.wait() })

        for itemID in ["a", "b"] {
            store.start(id: DownloadAction.item(itemID), lifetime: .screenBound, policy: .ignoreNew) { c in
                try await viewModel.download(itemID: itemID, cancellation: c)
            }
        }
        try await waitUntil {
            viewModel.state(of: "a") == .downloading && viewModel.state(of: "b") == .downloading
        }

        // 同じアイテムの二度押しだけが弾かれる
        let duplicate = store.start(
            id: DownloadAction.item("a"), lifetime: .screenBound, policy: .ignoreNew
        ) { c in
            try await viewModel.download(itemID: "a", cancellation: c)
        }
        #expect(duplicate.skipReason == .alreadyRunning)

        // アイテム a のみ個別キャンセル。b は継続。
        store.cancel(id: DownloadAction.item("a"))
        await gate.signal() // a の滞留を解放(キャンセル済みなので idle へ)
        try await waitUntil { viewModel.state(of: "a") == .idle }
        #expect(viewModel.state(of: "b") == .downloading)

        await gate.signal()
        try await waitUntil { viewModel.state(of: "b") == .done }
    }
}
