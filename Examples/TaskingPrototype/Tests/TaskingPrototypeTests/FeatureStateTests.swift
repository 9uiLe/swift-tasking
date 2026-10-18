import Tasking
import Testing
@testable import TaskingPrototype

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct FeatureStateTests {
    @Test(arguments: ["old", ""])
    func cancelledSearchEntryCannotReplaceLatestSearch(term: String) async throws {
        let oldEntry = OperationGate()
        let latestService = OperationGate()
        let model = SearchViewModel(performSearch: { term in
            await latestService.wait()
            return [term]
        })
        let old = Task {
            await oldEntry.wait()
            try await model.search(term: term)
        }
        await oldEntry.waitForArrivals()
        old.cancel()
        let latest = Task { try await model.search(term: "latest") }
        await latestService.waitForArrivals()

        oldEntry.open()
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(model.isSearching)
        latestService.open()
        try await latest.value
        #expect(model.results == ["latest"])
        #expect(!model.isSearching)
    }

    @Test func cancelledSaveEntryCannotReplaceLatestSave() async throws {
        let oldEntry = OperationGate()
        let latestService = OperationGate()
        let model = SettingsViewModel(performSave: { await latestService.wait() })
        let old = Task {
            await oldEntry.wait()
            try await model.save()
        }
        await oldEntry.waitForArrivals()
        old.cancel()
        let latest = Task { try await model.save() }
        await latestService.waitForArrivals()

        oldEntry.open()
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(model.saveState == .saving)
        latestService.open()
        try await latest.value
        #expect(model.saveState == .saved)
    }

    @Test func cancelledDownloadEntryCannotReplaceLatestDownload() async throws {
        let oldEntry = OperationGate()
        let latestService = OperationGate()
        let model = DownloadsViewModel(performDownload: { _ in await latestService.wait() })
        let old = Task {
            await oldEntry.wait()
            try await model.download(itemID: "report")
        }
        await oldEntry.waitForArrivals()
        old.cancel()
        let latest = Task { try await model.download(itemID: "report") }
        await latestService.waitForArrivals()

        oldEntry.open()
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(model.state(of: "report") == .downloading)
        latestService.open()
        try await latest.value
        #expect(model.state(of: "report") == .done)
    }

    @Test func cancelledSyncEntryCannotReplaceLatestSync() async throws {
        let oldEntry = OperationGate()
        let latestService = OperationGate()
        let model = SyncViewModel(performSync: { await latestService.wait() })
        let old = Task {
            await oldEntry.wait()
            try await model.sync()
        }
        await oldEntry.waitForArrivals()
        old.cancel()
        let latest = Task { try await model.sync() }
        await latestService.waitForArrivals()

        oldEntry.open()
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(model.syncState == .syncing)
        latestService.open()
        try await latest.value
        #expect(model.syncState == .finished)
    }

    @Test func cancellingSaveResetsLoadingAfterActualCompletion() async {
        let gate = OperationGate()
        let store = ViewTaskStore()
        let model = SettingsViewModel(performSave: { await gate.wait() })
        store.start(id: SettingsAction.save) {
            try await model.save()
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
        let oldRun = try #require(store.start(id: SettingsAction.save) {
            try await model.save()
        }.run)
        await old.waitForArrivals()
        store.cancel(oldRun)
        store.start(id: SettingsAction.save, policy: .cancelExisting) {
            try await model.save()
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
        let model = SearchViewModel(performSearch: { term in
            await (term == "old" ? old : latest).wait()
            return [term]
        })
        let first = Task { try await model.search(term: "old") }
        await old.waitForArrivals()
        first.cancel()
        let replacement = Task { try await model.search(term: "latest") }
        await latest.waitForArrivals()
        old.open()
        _ = await first.result
        #expect(model.isSearching)
        #expect(model.results.isEmpty)
        latest.open()
        try await replacement.value
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
        async let first: Void = model.search(term: "old")
        await old.waitForArrivals()
        try await model.search(term: "latest")
        old.open()
        try await first
        #expect(model.results == ["latest"])
        #expect(model.errorMessage == nil)
        #expect(!model.isSearching)
    }

    @Test func searchHandlesBusinessFailure() async throws {
        let model = SearchViewModel(performSearch: { _ in throw ServiceError.offline })
        try await model.search(term: "query")
        #expect(model.errorMessage == "offline")
        #expect(!model.isSearching)
    }

    @Test func cancelledDebounceDoesNotStartSearch() async throws {
        var searched: [String] = []
        let model = SearchViewModel(performSearch: { term in
            searched.append(term)
            return [term]
        })
        let pending = Task { try await model.search(term: "old", debounce: .seconds(30)) }
        while !model.isSearching { await Task.yield() }
        pending.cancel()
        _ = await pending.result
        #expect(searched.isEmpty)
        try await model.search(term: "latest")
        #expect(searched == ["latest"])
        #expect(model.results == ["latest"])
    }

    @Test func emptySearchClearsResultsAndInvalidatesOlderRequest() async throws {
        let old = OperationGate()
        var searched: [String] = []
        let model = SearchViewModel(performSearch: { term in
            searched.append(term)
            if term == "old" { await old.wait() }
            return [term]
        })
        try await model.search(term: "")
        #expect(searched.isEmpty)
        try await model.search(term: "first")
        let pending = Task { try await model.search(term: "old") }
        await old.waitForArrivals()
        try await model.search(term: "")
        old.open()
        try await pending.value
        #expect(model.results.isEmpty)
        #expect(model.errorMessage == nil)
        #expect(!model.isSearching)
    }

    @Test func actorOwnedIndexReturnsResultsToMainActorModel() async throws {
        let index = SearchIndex(entries: ["Actor", "Task", "actor isolation"])
        let model = SearchViewModel(performSearch: { term in try await index.search(term) })
        try await model.search(term: "ACTOR")
        #expect(model.results == ["Actor", "actor isolation"])
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
        let oldRun = try #require(store.start(id: id) {
            try await model.download(itemID: "report")
        }.run)
        await old.waitForArrivals()
        store.cancel(id: id)
        store.start(id: id, policy: .cancelExisting) {
            try await model.download(itemID: "report")
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
        store.start(id: SyncAction.fullSync) {
            try await model.sync()
        }
        await gate.waitForArrivals()
        store.cancelAll()
        gate.open()
        await store.waitForIdle()
        #expect(model.syncState == .idle)
    }
}
