import SwiftUI
import Tasking

/// ユースケース 3: アイテムごとの並行ダウンロードと個別キャンセル。
///
/// 「エンティティ単位のアクション」のモデリングは 2 通りある:
/// (a) 動的 ActionID(`download.item.<id>`)+ `.ignoreNew` — 本実装
/// (b) 共有 ActionID + `.allowConcurrent` + `ActionRun` ハンドル保持
/// (a) は「同一アイテムの重複ダウンロード禁止」を ID 空間で表現でき、
/// 行単位のキャンセルも `cancel(id:)` で済む。docs にはこの指針がまだない
/// (レビュー所見 F3 参照)。
enum DownloadAction {
    static func item(_ itemID: String) -> ActionID {
        ActionID("download.item.\(itemID)")
    }
}

@MainActor
@Observable
public final class DownloadsViewModel {
    public enum ItemState: Equatable, Sendable {
        case idle
        case downloading
        case done
    }

    public let items: [String]
    public private(set) var states: [String: ItemState] = [:]

    private let performDownload: @MainActor @Sendable (String) async throws -> Void

    public init(
        items: [String] = ["report.pdf", "assets.zip", "backup.tar"],
        performDownload: @MainActor @Sendable @escaping (String) async throws -> Void = { _ in
            try await Task.sleep(for: .seconds(2))
        }
    ) {
        self.items = items
        self.performDownload = performDownload
    }

    public func state(of itemID: String) -> ItemState {
        states[itemID] ?? .idle
    }

    public func download(itemID: String, cancellation: CancellationContext) async throws {
        states[itemID] = .downloading
        do {
            try cancellation.check()
            try await performDownload(itemID)
            try cancellation.check()
            states[itemID] = .done
        } catch let error as CancellationError {
            states[itemID] = .idle
            throw error
        } catch {
            states[itemID] = .idle
        }
    }
}

public struct DownloadsScreen: View {
    @State private var taskStore = ViewTaskStore()
    @State private var viewModel: DownloadsViewModel

    public init(viewModel: DownloadsViewModel = DownloadsViewModel()) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        List(viewModel.items, id: \.self) { itemID in
            HStack {
                Text(itemID)
                Spacer()
                switch viewModel.state(of: itemID) {
                case .idle:
                    Button("Download") {
                        taskStore.start(
                            id: DownloadAction.item(itemID),
                            lifetime: .screenBound,
                            policy: .ignoreNew
                        ) { [viewModel] cancellation in
                            try await viewModel.download(itemID: itemID, cancellation: cancellation)
                        }
                    }
                case .downloading:
                    ProgressView()
                    Button("Cancel", role: .cancel) {
                        taskStore.cancel(id: DownloadAction.item(itemID))
                    }
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .onDisappear {
            taskStore.cancel(lifetime: .screenBound)
        }
    }
}
