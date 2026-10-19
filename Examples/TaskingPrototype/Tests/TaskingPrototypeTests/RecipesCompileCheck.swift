import Foundation
import Observation
import Tasking
import TaskingCore

/// docs/recipes.md の表示状態・受付・所有の例をコンパイル検証する。
/// アプリケーション依存はスタブで用意し、これらの例は実行しない。

private struct Plan: Sendable {}
private struct Catalog: Sendable {}
private struct SearchResult: Sendable {}

private actor BillingService {
    func fetchPlans() async throws -> [Plan] { [] }
}

private actor CatalogService {
    func fetchCatalog() async throws -> Catalog? { nil }
}

private actor SearchService {
    func search(_ term: String) async throws -> [SearchResult] { [] }
}

private struct SettingsUseCase: Sendable {
    func sync() async throws {}
}

private struct ProfileUseCase: Sendable {
    func sync() async throws {}
}

private struct SyncUseCase: Sendable {
    func sync() async throws {}
}

@MainActor
@Observable
private final class RecipeBillingViewModel {
    enum State {
        case idle
        case loading
        case loaded([Plan])
        case failed(any Error)
    }

    private let service: BillingService
    private(set) var state: State = .idle

    init(service: BillingService) {
        self.service = service
    }

    func refresh() async {
        guard !Task.isCancelled else { return }
        if case .loading = state { return }
        let previous = state
        state = .loading
        do {
            let plans = try await service.fetchPlans()
            try Task.checkCancellation()
            state = .loaded(plans)
        } catch is CancellationError {
            state = previous
        } catch {
            state = .failed(error)
        }
    }
}

@MainActor
@Observable
private final class RecipeSearchViewModel {
    private let service: SearchService
    @ObservationIgnored private var latestSearch = UUID()
    private(set) var isSearching = false
    private(set) var results: [SearchResult] = []
    private(set) var errorMessage: String?

    init(service: SearchService) {
        self.service = service
    }

    func search(term: String) async throws {
        try Task.checkCancellation()
        let search = UUID()
        latestSearch = search
        isSearching = true
        errorMessage = nil
        defer {
            if latestSearch == search { isSearching = false }
        }
        do {
            let newResults = try await service.search(term)
            try Task.checkCancellation()
            if latestSearch == search { results = newResults }
        } catch let error as CancellationError {
            throw error
        } catch {
            if latestSearch == search { errorMessage = String(describing: error) }
        }
    }
}

@MainActor
private final class RecipeCatalogCoordinator {
    private let runner = ActionRunner()
    private let service = CatalogService()
    private(set) var catalog: Catalog?

    func refresh() async throws {
        let accepted = try await runner.run(id: "catalog.refresh") { [service] in
            try Task.checkCancellation()
            let catalog = try await service.fetchCatalog()
            try Task.checkCancellation()
            return catalog
        }
        if case .some(let value) = accepted {
            catalog = value
        }
    }
}

@MainActor
private final class RecipeSettingsViewModel {
    func save() async throws {}
}

@MainActor
private func recipeAwaitCompletion(
    store: ViewTaskStore,
    viewModel: RecipeSettingsViewModel
) async {
    let outcome = store.start(id: "settings.save") {
        try await viewModel.save()
    }
    guard case let .started(run) = outcome else { return }

    store.cancel(run)
    await store.awaitCompletion(of: run)
}

private actor RecipeSyncCoordinator {
    private let slot = TaskSlot()

    func shutDown() async {
        await slot.cancelAndWaitForIdle()
    }
}

@MainActor
private func recipeInnerConcurrency(store: ViewTaskStore) {
    let profileUseCase = ProfileUseCase()
    let settingsUseCase = SettingsUseCase()
    let viewModel = RecipeSyncViewModel()
    store.start(id: "sync") {
        do {
            try Task.checkCancellation()
            async let profile: Void = profileUseCase.sync()
            async let settings: Void = settingsUseCase.sync()
            _ = try await (profile, settings)
            try Task.checkCancellation()
        } catch is CancellationError {
            return
        } catch {
            viewModel.recordSyncFailure(error)
        }
    }
}

@MainActor
private final class RecipeSyncViewModel {
    private(set) var failure: (any Error)?

    func recordSyncFailure(_ error: any Error) {
        failure = error
    }
}

@MainActor
@Observable
private final class RecipeStoreOwningViewModel {
    let store = ViewTaskStore()
    private let syncUseCase = SyncUseCase()
    private(set) var isSynced = false
    private(set) var errorMessage: String?

    func startSync() {
        store.start(id: "sync") { [weak self, syncUseCase] in
            do {
                try Task.checkCancellation()
                try await syncUseCase.sync()
                try Task.checkCancellation()
                self?.isSynced = true
            } catch let error as CancellationError {
                throw error
            } catch {
                self?.errorMessage = String(describing: error)
            }
        }
    }
}
