import Foundation
import Tasking
import TaskingCore

/// docs/recipes.md の throws を使う ViewModel・所有・ポリシーの例をコンパイル検証する。
/// アプリケーション依存はスタブで用意し、これらの例は実行しない。

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

// キャンセル時に表示状態を復元する。

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

// 世代で結果反映と後処理を選択する。

@MainActor
private final class RecipeSearchViewModel {
    private var latestSearch = UUID()
    private(set) var isSearching = false
    private(set) var results: [SearchResult] = []
    private(set) var errorMessage: String?
    private let searchUseCase = SearchUseCaseStub()

    func search(term: String, cancellation: CancellationContext) async throws {
        let search = UUID()
        latestSearch = search
        isSearching = true
        errorMessage = nil

        defer {
            if latestSearch == search {
                isSearching = false
            }
        }

        do {
            try cancellation.check()
            let newResults = try await searchUseCase.search(term)
            try cancellation.check()
            if latestSearch == search {
                results = newResults
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            if latestSearch == search { errorMessage = String(describing: error) }
        }
    }
}

// 完了待ちはキャンセル済みの実行も含む。

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

// 終了処理は待機前に受付を閉じる。

private actor RecipeSyncCoordinator {
    private let slot = TaskSlot()

    func shutDown() async {
        await slot.cancelAndWaitForIdle()
    }
}

// 構造化子タスクは処理の寿命を共有する。

@MainActor
private func recipeInnerConcurrency(viewTaskStore: ViewTaskStore) {
    let profileUseCase = ProfileUseCaseStub()
    let settingsUseCase = SettingsUseCaseStub()

    let viewModel = RecipeSyncViewModel()
    viewTaskStore.start(id: "sync", lifetime: .screenBound) { cancellation in
        do {
            try cancellation.check()
            async let profile: Void = profileUseCase.sync()
            async let settings: Void = settingsUseCase.sync()
            _ = try await (profile, settings)
            try cancellation.check()
        } catch is CancellationError {
            return
        } catch {
            viewModel.recordSyncFailure(error)
        }
    }
}

@MainActor
private final class RecipeSyncViewModel {
    private(set) var failure: ActionFailure?

    func recordSyncFailure(_ error: any Error) {
        failure = ActionFailure(error: error)
    }
}

// 処理は所有者を弱参照で保持する。

@MainActor
private final class RecipeStoreOwningViewModel {
    let store = ViewTaskStore()
    private let syncUseCase = SyncUseCaseStub()
    private(set) var isSynced = false
    private(set) var errorMessage: String?

    func startSync() {
        store.start(id: "sync", lifetime: .screenBound) { [weak self, syncUseCase] cancellation in
            do {
                try cancellation.check()
                try await syncUseCase.sync()
                try cancellation.check()
                self?.isSynced = true
            } catch let error as CancellationError {
                throw error
            } catch {
                self?.errorMessage = String(describing: error)
            }
        }
    }
}

// Action の識別子とポリシーをまとめて宣言する。

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
