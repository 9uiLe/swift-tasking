import SwiftUI
import Tasking

/// Billing runs directly in the caller’s async context.
enum BillingAction {
    static let refresh = ActionID("billing.refresh")
}

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

    private let runner = ActionRunner()
    private let fetchPlans: @MainActor @Sendable () async throws -> [String]

    public init(
        fetchPlans: @MainActor @Sendable @escaping () async throws -> [String] = {
            try await Task.sleep(for: .milliseconds(500))
            return ["Free", "Pro", "Team"]
        }
    ) {
        self.fetchPlans = fetchPlans
    }

    @discardableResult
    public func refresh() async -> ActionOutcome<[String]> {
        let previousState = loadState
        let outcome = await runner.run(
            ActionDescriptor(id: BillingAction.refresh, duplicatePolicy: .ignoreNew),
            onStart: { _ in
                loadState = .loading
            }
        ) { [fetchPlans] cancellation -> [String] in
            try cancellation.check()
            let plans = try await fetchPlans()
            try cancellation.check()
            return plans
        }

        switch outcome {
        case let .succeeded(plans):
            loadState = .loaded(plans)
        case .cancelled:
            loadState = previousState
        case .skipped(.alreadyRunning):
            break
        case let .failed(failure):
            loadState = .failed(failure.message)
        }
        return outcome
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
                Text("Pull to refresh")
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
            // 初回ロード。view が消えればこの構造化 task ごとキャンセルされる。
            await viewModel.refresh()
        }
        .refreshable {
            // 初回ロード中に引っ張られたら .skipped(.alreadyRunning) になる。
            await viewModel.refresh()
        }
    }
}
