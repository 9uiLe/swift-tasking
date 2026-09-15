import SwiftUI
import Tasking

/// Owns app-lifetime work and its display state independently of any screen.
@MainActor
public final class AppTaskContainer {
    public static let shared = AppTaskContainer()

    public let store: ViewTaskStore
    public let syncViewModel: SyncViewModel

    public init(store: ViewTaskStore = ViewTaskStore(), syncViewModel: SyncViewModel = SyncViewModel()) {
        self.store = store
        self.syncViewModel = syncViewModel
    }
}

enum SyncAction {
    static let fullSync = ActionID("app.fullSync")
}

@MainActor
@Observable
public final class SyncViewModel {
    public enum SyncState: Equatable, Sendable {
        case idle
        case syncing
        case finished
    }

    public private(set) var syncState: SyncState = .idle

    @ObservationIgnored private var latestSync = UUID()
    private let performSync: @MainActor @Sendable () async throws -> Void

    public init(
        performSync: @MainActor @Sendable @escaping () async throws -> Void = {
            try await Task.sleep(for: .seconds(5))
        }
    ) {
        self.performSync = performSync
    }

    public func sync(cancellation: CancellationContext) async throws {
        let sync = UUID()
        latestSync = sync
        syncState = .syncing
        do {
            try cancellation.check()
            try await performSync()
            try cancellation.check()
            guard latestSync == sync else { return }
            syncState = .finished
        } catch let error as CancellationError {
            if latestSync == sync { syncState = .idle }
            throw error
        } catch {
            guard latestSync == sync else { return }
            syncState = .idle
        }
    }
}

public struct SyncSettingsScreen: View {
    private let container: AppTaskContainer
    private var viewModel: SyncViewModel { container.syncViewModel }

    public init(container: AppTaskContainer = .shared) {
        self.container = container
    }

    public var body: some View {
        Form {
            Button("Sync now") {
                // アプリ寿命の store に登録するので、この画面を閉じても同期は続く。
                container.store.start(
                    id: SyncAction.fullSync,
                    lifetime: .appBound,
                    policy: .ignoreNew
                ) { [viewModel] cancellation in
                    try await viewModel.sync(cancellation: cancellation)
                }
            }
            .disabled(viewModel.syncState == .syncing)

            if viewModel.syncState == .syncing {
                ProgressView("Syncing…")
            }
        }
        // 注意: ここに onDisappear での cancel は「書かない」ことが仕様。
        // 画面が消えても appBound の task は生き続ける。
    }
}
