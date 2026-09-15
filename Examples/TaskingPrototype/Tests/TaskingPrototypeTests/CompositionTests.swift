import Tasking
import Testing
@testable import TaskingPrototype

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CompositionTests {
    @Test func billingDeduplicatesAsyncEntryPointsWithoutChangingLoadingState() async {
        let gate = OperationGate()
        let model = BillingViewModel(fetchPlans: {
            await gate.wait()
            return ["Pro"]
        })
        async let first = model.refresh()
        await gate.waitForArrivals()
        #expect(model.loadState == .loading)
        #expect(await model.refresh() == .skipped(.alreadyRunning))
        #expect(model.loadState == .loading)
        gate.open()
        #expect(await first == .succeeded(["Pro"]))
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
        gate.open()
        #expect(await refresh.value == .cancelled)
        #expect(model.loadState == (previouslyLoaded ? .loaded(["Pro"]) : .initial))
    }

    @Test func billingPublishesBusinessFailure() async {
        let model = BillingViewModel(fetchPlans: { throw ServiceError.offline })
        #expect(await model.refresh() == .failed(ActionFailure(error: ServiceError.offline)))
        #expect(model.loadState == .failed("offline"))
    }

    @Test func runnerInsideStoreKeepsStoreCancellationContext() async {
        let gate = OperationGate()
        let store = ViewTaskStore()
        let runner = ActionRunner()
        var outcome: ActionOutcome<String>?
        store.start(id: "composite", lifetime: .screenBound) { _ in
            outcome = await runner.run(ActionDescriptor(id: "inner")) { c in
                await gate.wait()
                try c.check()
                return "finished"
            }
        }
        await gate.waitForArrivals()
        store.cancelAll()
        gate.open()
        await store.waitForIdle()
        #expect(outcome == .cancelled)
        #expect(!runner.isRunning(id: "inner"))
    }

    @Test func itemDownloadsHaveIndependentAdmissionAndCancellation() async throws {
        let first = OperationGate()
        let second = OperationGate()
        let model = DownloadsViewModel(performDownload: { item in
            await (item == "a" ? first : second).wait()
        })
        let store = ViewTaskStore()
        let runA = try #require(store.start(id: DownloadAction.item("a"), lifetime: .screenBound) { c in
            try await model.download(itemID: "a", cancellation: c)
        }.run)
        store.start(id: DownloadAction.item("b"), lifetime: .screenBound) { c in
            try await model.download(itemID: "b", cancellation: c)
        }
        await first.waitForArrivals()
        await second.waitForArrivals()
        let duplicate = store.start(id: DownloadAction.item("a"), lifetime: .screenBound) { _ in
            Issue.record("Duplicate download executed.")
        }
        #expect(duplicate.skipReason == .alreadyRunning)
        store.cancel(runA)
        first.open()
        await store.awaitCompletion(of: runA)
        #expect(model.state(of: "a") == .idle)
        #expect(model.state(of: "b") == .downloading)
        second.open()
        await store.waitForIdle()
        #expect(model.state(of: "b") == .done)
    }

    @Test func appOwnedSyncSurvivesScreenLifetimeCancellation() async {
        let gate = OperationGate()
        let container = AppTaskContainer(syncViewModel: SyncViewModel(performSync: { await gate.wait() }))
        let model = container.syncViewModel
        container.store.start(id: SyncAction.fullSync, lifetime: .appBound) { c in
            try await model.sync(cancellation: c)
        }
        await gate.waitForArrivals()
        container.store.cancel(lifetime: .screenBound)
        #expect(container.store.isRunning(id: SyncAction.fullSync))
        #expect(model.syncState == .syncing)
        gate.open()
        await container.store.waitForIdle()
        #expect(model.syncState == .finished)
    }
}
