import Tasking
import Testing
@testable import TaskingPrototype

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct FeatureStateTests {
    @Test func cancellingSaveResetsLoadingAfterActualCompletion() async {
        let gate = OperationGate()
        let store = ViewTaskStore()
        let model = SettingsViewModel(performSave: { await gate.wait() })
        store.start(id: SettingsAction.save, lifetime: .screenBound) { c in
            try await model.save(cancellation: c)
        }
        await gate.waitForArrivals()
        #expect(model.saveState == .saving)
        store.cancelAll()
        gate.open()
        await store.waitForIdle()
        #expect(model.saveState == .idle)
    }

    @Test(arguments: [false, true])
    func oldSaveCannotOverwriteRestartedSave(fails: Bool) async throws {
        let old = OperationGate()
        let latest = OperationGate()
        let store = ViewTaskStore()
        var calls = 0
        let model = SettingsViewModel(performSave: {
            calls += 1
            if calls == 1 {
                await old.wait()
                if fails { throw ServiceError.offline }
            } else {
                await latest.wait()
            }
        })
        let oldRun = try #require(store.start(id: SettingsAction.save, lifetime: .screenBound) { c in
            try await model.save(cancellation: c)
        }.run)
        await old.waitForArrivals()
        store.cancel(oldRun)
        store.start(id: SettingsAction.save, lifetime: .screenBound) { c in
            try await model.save(cancellation: c)
        }
        await latest.waitForArrivals()
        old.open()
        await store.awaitCompletion(of: oldRun)
        #expect(model.saveState == .saving)
        latest.open()
        await store.waitForIdle()
        #expect(model.saveState == .saved)
    }

    @Test func replacementSearchKeepsLoadingUntilLatestFinishes() async throws {
        let old = OperationGate()
        let latest = OperationGate()
        let store = ViewTaskStore()
        let model = SearchViewModel(performSearch: { term in
            await (term == "old" ? old : latest).wait()
            return [term]
        })
        let oldRun = try #require(store.start(id: SearchAction.query, lifetime: .screenBound) { c in
            try await model.search(term: "old", cancellation: c)
        }.run)
        await old.waitForArrivals()
        store.start(id: SearchAction.query, lifetime: .screenBound, policy: .cancelExisting) { c in
            try await model.search(term: "latest", cancellation: c)
        }
        await latest.waitForArrivals()
        old.open()
        await store.awaitCompletion(of: oldRun)
        #expect(model.isSearching)
        #expect(model.results.isEmpty)
        latest.open()
        await store.waitForIdle()
        #expect(!model.isSearching)
        #expect(model.results == ["latest"])
    }

    @Test(arguments: [false, true])
    func olderUncancelledSearchCannotPublishResultsOrErrors(fails: Bool) async throws {
        let old = OperationGate()
        let model = SearchViewModel(performSearch: { term in
            if term == "old" {
                await old.wait()
                if fails { throw ServiceError.offline }
            }
            return [term]
        })
        async let first: Void = model.search(term: "old", cancellation: CancellationContext())
        await old.waitForArrivals()
        try await model.search(term: "latest", cancellation: CancellationContext())
        old.open()
        try await first
        #expect(model.results == ["latest"])
        #expect(model.errorMessage == nil)
        #expect(!model.isSearching)
    }

    @Test func searchHandlesBusinessFailureBeforeItReachesStore() async {
        let model = SearchViewModel(performSearch: { _ in throw ServiceError.offline })
        let store = ViewTaskStore { _, _ in Issue.record("業務上のエラーが ViewModel の外へ漏れました。") }
        store.start(id: SearchAction.query, lifetime: .screenBound) { c in
            try await model.search(term: "query", cancellation: c)
        }
        await store.waitForIdle()
        #expect(model.errorMessage == "offline")
        #expect(!model.isSearching)
    }

    @Test func cancelledDownloadCleanupCannotResetItsReplacement() async throws {
        let old = OperationGate()
        let latest = OperationGate()
        let store = ViewTaskStore()
        var calls = 0
        let model = DownloadsViewModel(performDownload: { _ in
            calls += 1
            await (calls == 1 ? old : latest).wait()
        })
        let id = DownloadAction.item("report")
        let oldRun = try #require(store.start(id: id, lifetime: .screenBound) { c in
            try await model.download(itemID: "report", cancellation: c)
        }.run)
        await old.waitForArrivals()
        store.cancel(id: id)
        store.start(id: id, lifetime: .screenBound) { c in
            try await model.download(itemID: "report", cancellation: c)
        }
        await latest.waitForArrivals()
        old.open()
        await store.awaitCompletion(of: oldRun)
        #expect(model.state(of: "report") == .downloading)
        latest.open()
        await store.waitForIdle()
        #expect(model.state(of: "report") == .done)
    }

    @Test func syncDoesNotPublishSuccessAfterCancellation() async {
        let gate = OperationGate()
        let model = SyncViewModel(performSync: { await gate.wait() })
        let store = ViewTaskStore()
        store.start(id: SyncAction.fullSync, lifetime: .appBound) { c in
            try await model.sync(cancellation: c)
        }
        await gate.waitForArrivals()
        store.cancelAll()
        gate.open()
        await store.waitForIdle()
        #expect(model.syncState == .idle)
    }
}
