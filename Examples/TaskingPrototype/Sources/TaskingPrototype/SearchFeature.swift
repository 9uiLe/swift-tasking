import SwiftUI
import Tasking

/// ユースケース 2: 逐次検索(検索語が変わるたびに前の検索をキャンセル = `.cancelExisting`)。
///
/// `.cancelExisting` では「キャンセルされた旧 run」と「新 run」が同じ ViewModel
/// state を共有するため、旧 run の後始末(defer 等)が新 run の state を
/// 上書きしうる。ここでは世代カウンタで「最新 run だけが state を確定できる」
/// ようにガードしている(検証テスト F2 参照)。
enum SearchAction {
    static let query = ActionID("search.query")
}

@MainActor
@Observable
public final class SearchViewModel {
    public private(set) var results: [String] = []
    public private(set) var isSearching = false

    private var generation = 0
    private let performSearch: @MainActor @Sendable (String) async throws -> [String]

    public init(
        performSearch: @MainActor @Sendable @escaping (String) async throws -> [String] = { term in
            try await Task.sleep(for: .milliseconds(300))
            return ["\(term) の結果 1", "\(term) の結果 2"]
        }
    ) {
        self.performSearch = performSearch
    }

    public func search(term: String, cancellation: CancellationContext) async throws {
        generation += 1
        let myGeneration = generation
        isSearching = true
        defer {
            // 自分より新しい run が始まっていたら、state の確定権は新 run にある。
            if generation == myGeneration {
                isSearching = false
            }
        }

        try cancellation.check()
        let found = try await performSearch(term)
        try cancellation.check()
        results = found
    }
}

public struct SearchScreen: View {
    @State private var taskStore = ViewTaskStore()
    @State private var viewModel: SearchViewModel
    @State private var term = ""

    public init(viewModel: SearchViewModel = SearchViewModel()) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        List {
            TextField("Search", text: $term)
                .onChange(of: term) { _, newTerm in
                    taskStore.start(
                        id: SearchAction.query,
                        lifetime: .screenBound,
                        policy: .cancelExisting
                    ) { [viewModel] cancellation in
                        try await viewModel.search(term: newTerm, cancellation: cancellation)
                    }
                }

            if viewModel.isSearching {
                ProgressView()
            }

            ForEach(viewModel.results, id: \.self) { result in
                Text(result)
            }
        }
        .onDisappear {
            taskStore.cancel(lifetime: .screenBound)
        }
    }
}
