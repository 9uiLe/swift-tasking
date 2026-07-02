import SwiftUI
import Tasking

/// ユースケース 1: 保存ボタンの二度押し防止(`.ignoreNew`)+ 手動キャンセル。
///
/// ADR-0007 の公式回答どおり、ローディング状態は ViewModel の state として持つ。
/// 注意: キャンセル経路でも state を確実に戻すため、`CancellationError` を
/// 捕捉して `saveState` をリセットしてから rethrow している。README の例には
/// このリセットがなく、キャンセル時に `.saving` が残留する(検証テスト F1 参照)。
enum SettingsAction {
    static let save = ActionID("settings.save")
}

@MainActor
@Observable
public final class SettingsViewModel {
    public enum SaveState: Equatable, Sendable {
        case idle
        case saving
        case saved
        case failed(String)
    }

    public private(set) var saveState: SaveState = .idle

    private let performSave: @MainActor @Sendable () async throws -> Void

    public init(
        performSave: @MainActor @Sendable @escaping () async throws -> Void = {
            try await Task.sleep(for: .seconds(1))
        }
    ) {
        self.performSave = performSave
    }

    public func save(cancellation: CancellationContext) async throws {
        saveState = .saving
        do {
            try cancellation.check()
            try await performSave()
            try cancellation.check()
            saveState = .saved
        } catch let error as CancellationError {
            // キャンセルは正常終了だが、画面が生きている場合に .saving を
            // 残さないよう、境界を出る前に必ず state を戻す。
            saveState = .idle
            throw error
        } catch {
            saveState = .failed("\(error)")
        }
    }
}

public struct SettingsScreen: View {
    @State private var taskStore = ViewTaskStore()
    @State private var viewModel: SettingsViewModel

    public init(viewModel: SettingsViewModel = SettingsViewModel()) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        Form {
            Button("Save") {
                taskStore.start(
                    id: SettingsAction.save,
                    lifetime: .screenBound,
                    policy: .ignoreNew
                ) { [viewModel] cancellation in
                    try await viewModel.save(cancellation: cancellation)
                }
            }
            .disabled(viewModel.saveState == .saving)

            if viewModel.saveState == .saving {
                HStack {
                    ProgressView()
                    Button("Cancel", role: .cancel) {
                        taskStore.cancel(id: SettingsAction.save)
                    }
                }
            }

            switch viewModel.saveState {
            case .saved:
                Text("Saved").foregroundStyle(.green)
            case let .failed(message):
                Text(message).foregroundStyle(.red)
            case .idle, .saving:
                EmptyView()
            }
        }
        .onDisappear {
            taskStore.cancel(lifetime: .screenBound)
        }
    }
}
