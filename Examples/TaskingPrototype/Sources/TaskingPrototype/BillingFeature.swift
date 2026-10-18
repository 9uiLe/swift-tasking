import SwiftUI

@MainActor
@Observable
public final class BillingViewModel {
    public enum LoadState: Equatable, Sendable {
        case initial
        case loading
        case loaded([String])
        case failed(String)
    }

    public private(set) var loadState: LoadState = .initial
    private let fetchPlans: @MainActor @Sendable () async throws -> [String]

    public init(
        fetchPlans: @MainActor @Sendable @escaping () async throws -> [String] = {
            try await Task.sleep(for: .milliseconds(500))
            return ["Free", "Pro", "Team"]
        }
    ) {
        self.fetchPlans = fetchPlans
    }

    /// 初回表示と手動更新は同じ状態を共有し、先行する更新の終了まで重複を受け付けない。
    /// キャンセル時は、処理の実終了後に更新前の表示状態へ戻す。
    public func refresh() async {
        guard !Task.isCancelled else { return }
        guard loadState != .loading else { return }
        let previousState = loadState
        loadState = .loading
        do {
            let plans = try await fetchPlans()
            try Task.checkCancellation()
            loadState = .loaded(plans)
        } catch is CancellationError {
            loadState = previousState
        } catch {
            loadState = .failed(String(describing: error))
        }
    }
}

public struct BillingScreen: View {
    private let viewModel: BillingViewModel

    public init(viewModel: BillingViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        List {
            switch viewModel.loadState {
            case .initial:
                Text("引っ張って更新")
            case .loading:
                ProgressView()
            case let .loaded(plans):
                ForEach(plans, id: \.self) { plan in
                    Text(plan)
                }
            case let .failed(message):
                Text(message).foregroundStyle(.red)
            }
        }
        .task {
            await viewModel.refresh()
        }
        .refreshable {
            await viewModel.refresh()
        }
    }
}
