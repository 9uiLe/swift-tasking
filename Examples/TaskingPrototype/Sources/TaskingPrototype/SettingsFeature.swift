import SwiftUI
import Tasking

/// 保存操作では重複抑制と明示的なキャンセルを使う。
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

    @ObservationIgnored private var latestSave = UUID()
    private let performSave: @MainActor @Sendable () async throws -> Void

    public init(
        performSave: @MainActor @Sendable @escaping () async throws -> Void = {
            try await Task.sleep(for: .seconds(1))
        }
    ) {
        self.performSave = performSave
    }

    public func save(cancellation: CancellationContext) async throws {
        let save = UUID()
        latestSave = save
        saveState = .saving
        do {
            try cancellation.check()
            try await performSave()
            try cancellation.check()
            guard latestSave == save else { return }
            saveState = .saved
        } catch let error as CancellationError {
            if latestSave == save { saveState = .idle }
            throw error
        } catch {
            guard latestSave == save else { return }
            saveState = .failed("\(error)")
        }
    }
}

public struct SettingsScreen: View {
    @State private var taskStore = ViewTaskStore()
    private let viewModel: SettingsViewModel

    public init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Form {
            Button("保存") {
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
                    Button("キャンセル", role: .cancel) {
                        taskStore.cancel(id: SettingsAction.save)
                    }
                }
            }

            switch viewModel.saveState {
            case .saved:
                Text("保存しました").foregroundStyle(.green)
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
