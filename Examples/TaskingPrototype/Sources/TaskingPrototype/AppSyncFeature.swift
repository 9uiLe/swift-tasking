import SwiftUI
import Tasking

/// ユースケース 4: 画面を閉じても完遂すべき同期処理(`.appBound`)。
///
/// docs/lifetimes.md の推奨どおり、store をアプリ寿命のコンテナに所有させる。
/// 画面所有の store に `.appBound` と書いても実効性がない(宣言の実効上限 =
/// store の所有スコープ)ため、所有位置がこのユースケースの本体である。
@MainActor
public final class AppTaskContainer {
    public static let shared = AppTaskContainer()

    public let store = ViewTaskStore()

    public init() {}
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

    private let performSync: @MainActor @Sendable () async throws -> Void

    public init(
        performSync: @MainActor @Sendable @escaping () async throws -> Void = {
            try await Task.sleep(for: .seconds(5))
        }
    ) {
        self.performSync = performSync
    }

    public func sync(cancellation: CancellationContext) async throws {
        syncState = .syncing
        do {
            try cancellation.check()
            try await performSync()
            syncState = .finished
        } catch let error as CancellationError {
            syncState = .idle
            throw error
        } catch {
            syncState = .idle
        }
    }
}

public struct SyncSettingsScreen: View {
    private let container: AppTaskContainer
    @State private var viewModel: SyncViewModel

    public init(
        container: AppTaskContainer = .shared,
        viewModel: SyncViewModel = SyncViewModel()
    ) {
        self.container = container
        _viewModel = State(initialValue: viewModel)
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
