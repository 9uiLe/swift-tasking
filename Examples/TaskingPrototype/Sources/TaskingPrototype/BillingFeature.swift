import SwiftUI
import Tasking

/// ユースケース 5: すでに async 文脈にいる場所での重複制御(`ActionRunner`)。
///
/// `.task`(初回ロード)と `.refreshable`(pull-to-refresh)という 2 つの
/// async 入口が同じ refresh を呼ぶ。ActionRunner は task を作らないため
/// 構造化文脈(view 消滅時の自動キャンセル)はそのまま生き、重複だけが
/// 排除される。これが ActionRunner の設計思想が最も生きる形。
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
    public private(set) var lastOutcomeDescription = ""

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

    public func refresh() async {
        let outcome = await runner.run(
            ActionDescriptor(id: BillingAction.refresh, duplicatePolicy: .rejectWhileRunning)
        ) { [fetchPlans] cancellation -> [String] in
            try cancellation.check()
            let plans = try await fetchPlans()
            try cancellation.check()
            return plans
        }

        switch outcome {
        case let .succeeded(plans):
            loadState = .loaded(plans)
            lastOutcomeDescription = "succeeded"
        case .cancelled:
            // view 消滅などで囲みの構造化 task が cancel された。state は触らない。
            lastOutcomeDescription = "cancelled"
        case .skipped(.alreadyRunning):
            // すでに同じ refresh が走っている。先行 run に結果表示を任せる。
            lastOutcomeDescription = "skipped"
        case let .failed(failure):
            loadState = .failed(failure.message)
            lastOutcomeDescription = "failed: \(failure.typeName)"
        }
    }
}

public struct BillingScreen: View {
    @State private var viewModel: BillingViewModel

    public init(viewModel: BillingViewModel = BillingViewModel()) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        List {
            switch viewModel.loadState {
            case .initial, .loading:
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
