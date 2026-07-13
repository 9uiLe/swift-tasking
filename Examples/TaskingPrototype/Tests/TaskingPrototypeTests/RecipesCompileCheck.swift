import Tasking
import TaskingCore

/// docs/recipes.md のコード断片が(依存のスタブ化以外)そのままコンパイル
/// できることの検証。実行はしない。スニペットに構文・型エラーがあれば
/// このファイルがビルドを落とす。

// --- スタブ依存(スニペット外の前提) ---

private struct SearchResult: Sendable {}

private struct SettingsUseCaseStub: Sendable {
    func save() async throws {}
    func sync() async throws {}
}

private struct SyncUseCaseStub: Sendable {
    func sync() async throws {}
}

private struct SearchUseCaseStub: Sendable {
    func search(_ term: String) async throws -> [SearchResult] { [] }
}

private struct ProfileUseCaseStub: Sendable {
    func sync() async throws {}
}

// --- レシピ 1: キャンセル時は loading state を戻してから rethrow ---

@MainActor
private final class RecipeSettingsViewModel {
    enum SaveState {
        case idle
        case saving
        case saved
        case failed(any Error)
    }

    private(set) var saveState: SaveState = .idle
    private let settingsUseCase = SettingsUseCaseStub()

    func save(cancellation: CancellationContext) async throws {
        saveState = .saving
        do {
            try cancellation.check()
            try await settingsUseCase.save()
            try cancellation.check()
            saveState = .saved
        } catch let error as CancellationError {
            saveState = .idle
            throw error
        } catch {
            saveState = .failed(error)
        }
    }
}

// --- レシピ 2: .cancelExisting の後始末は世代でガードする ---

@MainActor
private final class RecipeSearchViewModel {
    private var generation = 0
    private(set) var isSearching = false
    private(set) var results: [SearchResult] = []
    private let searchUseCase = SearchUseCaseStub()

    func search(term: String, cancellation: CancellationContext) async throws {
        generation += 1
        let currentGeneration = generation
        isSearching = true

        defer {
            if generation == currentGeneration {
                isSearching = false
            }
        }

        do {
            try cancellation.check()
            let newResults = try await searchUseCase.search(term)
            try cancellation.check()
            if generation == currentGeneration {
                results = newResults
            }
        } catch let error as CancellationError {
            throw error
        }
    }
}

// --- レシピ 3: tracking 解除後の実終了は run handle 経由で待つ ---

@MainActor
private func recipeAwaitCompletion(
    taskStore: ViewTaskStore,
    viewModel: RecipeSettingsViewModel
) async {
    let outcome = taskStore.start(
        id: "settings.save",
        lifetime: .screenBound
    ) { cancellation in
        try await viewModel.save(cancellation: cancellation)
    }
    guard case let .started(run) = outcome else {
        return
    }

    taskStore.cancel(run)
    await taskStore.awaitCompletion(of: run)
}

// --- レシピ 4: TaskSlot の teardown は admission を閉じてから待つ ---

private actor RecipeSyncCoordinator {
    private let slot = TaskSlot()

    func shutDown() async {
        await slot.cancelAndWaitForIdle()
    }
}

// --- レシピ 5: operation 内で unstructured task を作らない(推奨形) ---

@MainActor
private func recipeInnerConcurrency(viewTaskStore: ViewTaskStore) {
    let profileUseCase = ProfileUseCaseStub()
    let settingsUseCase = SettingsUseCaseStub()

    viewTaskStore.start(id: "sync", lifetime: .screenBound) { cancellation in
        async let profile: Void = profileUseCase.sync()
        async let settings: Void = settingsUseCase.sync()

        try cancellation.check()
        _ = try await (profile, settings)
        try cancellation.check()
    }
}

// --- レシピ 6: operation から store owner を強参照しない ---

@MainActor
private final class RecipeStoreOwningViewModel {
    let store = ViewTaskStore()
    private let syncUseCase = SyncUseCaseStub()

    func startSync() {
        store.start(id: "sync", lifetime: .screenBound) { [weak self] cancellation in
            guard let self else { return }
            try cancellation.check()
            try await syncUseCase.sync()
            try cancellation.check()
        }
    }
}

// --- レシピ 7: 同じ ActionID の方針を分散させない ---

private enum RecipeSettingsAction {
    static let save: ActionID = "settings.save"
    static let savePolicy: TaskStartPolicy = .ignoreNew
}

@MainActor
private func recipeCentralizedPolicy(
    viewTaskStore: ViewTaskStore,
    viewModel: RecipeSettingsViewModel
) {
    viewTaskStore.start(
        id: RecipeSettingsAction.save,
        lifetime: .screenBound,
        policy: RecipeSettingsAction.savePolicy
    ) { cancellation in
        try await viewModel.save(cancellation: cancellation)
    }
}
