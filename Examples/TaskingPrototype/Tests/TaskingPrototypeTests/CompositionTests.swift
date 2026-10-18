import Tasking
import Testing
@testable import TaskingPrototype

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CompositionTests {
    @Test func billingDeduplicatesAsyncEntryPointsWithoutChangingLoadingState() async {
        let gate = OperationGate()
        var calls = 0
        let model = BillingViewModel(fetchPlans: {
            calls += 1
            await gate.wait()
            return ["Pro"]
        })
        async let first: Void = model.refresh()
        await gate.waitForArrivals()
        #expect(model.loadState == .loading)
        await model.refresh()
        #expect(calls == 1)
        #expect(model.loadState == .loading)
        gate.open()
        await first
        #expect(model.loadState == .loaded(["Pro"]))
    }

    @Test(arguments: [false, true])
    func billingCancellationRestoresPreviousState(previouslyLoaded: Bool) async {
        let gate = OperationGate()
        var calls = 0
        let model = BillingViewModel(fetchPlans: {
            calls += 1
            if !previouslyLoaded || calls > 1 { await gate.wait() }
            return ["Pro"]
        })
        if previouslyLoaded { await model.refresh() }
        let refresh = Task { await model.refresh() }
        await gate.waitForArrivals()
        refresh.cancel()
        await model.refresh()
        #expect(calls == (previouslyLoaded ? 2 : 1))
        #expect(model.loadState == .loading)
        gate.open()
        await refresh.value
        #expect(model.loadState == (previouslyLoaded ? .loaded(["Pro"]) : .initial))
    }

    @Test func billingPublishesBusinessFailure() async {
        let model = BillingViewModel(fetchPlans: { throw ServiceError.offline })
        await model.refresh()
        #expect(model.loadState == .failed("offline"))
    }

    @Test func runnerInsideStoreKeepsTaskCancellation() async {
        let gate = OperationGate()
        let store = ViewTaskStore()
        let runner = ActionRunner()
        var cancelled = false
        store.start(id: "composite") {
            do {
                _ = try await runner.run(id: "inner") {
                    await gate.wait()
                    try Task.checkCancellation()
                    return "finished"
                }
            } catch is CancellationError {
                cancelled = true
            }
        }
        await gate.waitForArrivals()
        store.cancelAll()
        gate.open()
        await store.waitForIdle()
        #expect(cancelled)
        #expect(!runner.isTracked(id: "inner"))
    }

    @Test func itemDownloadsHaveIndependentAdmissionAndCancellation() async throws {
        let first = OperationGate()
        let second = OperationGate()
        let model = DownloadsViewModel(performDownload: { item in
            await (item == "a" ? first : second).wait()
        })
        let store = ViewTaskStore()
        let runA = try #require(store.start(id: DownloadAction.item("a")) {
            try await model.download(itemID: "a")
        }.run)
        store.start(id: DownloadAction.item("b")) {
            try await model.download(itemID: "b")
        }
        await first.waitForArrivals()
        await second.waitForArrivals()
        let duplicate = store.start(id: DownloadAction.item("a")) {
            Issue.record("重複したダウンロードが実行されました。")
        }
        #expect(duplicate.skipReason == .unfinished)
        store.cancel(runA)
        first.open()
        await store.awaitCompletion(of: runA)
        #expect(model.state(of: "a") == .idle)
        #expect(model.state(of: "b") == .downloading)
        second.open()
        await store.waitForIdle()
        #expect(model.state(of: "b") == .done)
    }

    @Test func appOwnedSyncSurvivesScreenOwnedStoreCancellation() async {
        let gate = OperationGate()
        let container = AppTaskContainer(syncViewModel: SyncViewModel(performSync: { await gate.wait() }))
        let screenStore = ViewTaskStore()
        let model = container.syncViewModel
        container.store.start(id: SyncAction.fullSync) {
            try await model.sync()
        }
        await gate.waitForArrivals()
        screenStore.cancelAll()
        #expect(container.store.isTracked(id: SyncAction.fullSync))
        #expect(model.syncState == .syncing)
        gate.open()
        await container.store.waitForIdle()
        #expect(model.syncState == .finished)
    }
}
