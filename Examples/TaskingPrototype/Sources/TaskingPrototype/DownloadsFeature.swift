import SwiftUI
import Tasking

/// 項目ごとの Action ID で、ダウンロードの受付とキャンセルを個別に制御する。
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

    @ObservationIgnored private var latestDownloads: [String: UUID] = [:]
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
        let download = UUID()
        latestDownloads[itemID] = download
        defer {
            if latestDownloads[itemID] == download { latestDownloads[itemID] = nil }
        }
        states[itemID] = .downloading
        do {
            try cancellation.check()
            try await performDownload(itemID)
            try cancellation.check()
            guard latestDownloads[itemID] == download else { return }
            states[itemID] = .done
        } catch let error as CancellationError {
            if latestDownloads[itemID] == download { states[itemID] = .idle }
            throw error
        } catch {
            guard latestDownloads[itemID] == download else { return }
            states[itemID] = .idle
        }
    }
}

public struct DownloadsScreen: View {
    @State private var taskStore = ViewTaskStore()
    private let viewModel: DownloadsViewModel

    public init(viewModel: DownloadsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        List(viewModel.items, id: \.self) { itemID in
            HStack {
                Text(itemID)
                Spacer()
                switch viewModel.state(of: itemID) {
                case .idle:
                    Button("ダウンロード") {
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
                    Button("キャンセル", role: .cancel) {
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
