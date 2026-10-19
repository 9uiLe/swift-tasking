import SwiftUI

/// 同期的な絞り込みを MainActor から分離し、検索結果だけを画面へ返す。
public actor SearchIndex {
    private let entries: [String]

    public init(entries: [String] = [
        "Swift Concurrency", "Structured Concurrency", "Actor", "Task", "Cancellation"
    ]) {
        self.entries = entries
    }

    public func search(_ term: String) throws -> [String] {
        var matches: [String] = []
        for entry in entries {
            try Task.checkCancellation()
            if entry.localizedCaseInsensitiveContains(term) {
                matches.append(entry)
            }
        }
        return matches
    }
}

@MainActor
@Observable
public final class SearchViewModel {
    public private(set) var results: [String] = []
    public private(set) var isSearching = false
    public private(set) var errorMessage: String?

    @ObservationIgnored private var latestSearch = UUID()
    private let performSearch: @MainActor @Sendable (String) async throws -> [String]

    public convenience init() {
        let index = SearchIndex()
        self.init(performSearch: { term in try await index.search(term) })
    }

    public init(
        performSearch: @MainActor @Sendable @escaping (String) async throws -> [String]
    ) {
        self.performSearch = performSearch
    }

    /// 空文字では結果を消去する。待機中の要求は検索を始めずにキャンセルできる。
    /// 古い要求の完了は、最新要求の結果・エラー・処理中表示を変更しない。
    public func search(term: String, debounce: Duration = .zero) async throws {
        try Task.checkCancellation()
        let search = UUID()
        latestSearch = search
        errorMessage = nil
        guard !term.isEmpty else {
            results = []
            isSearching = false
            return
        }

        isSearching = true
        defer {
            if latestSearch == search { isSearching = false }
        }

        do {
            if debounce > .zero { try await Task.sleep(for: debounce) }
            let found = try await performSearch(term)
            try Task.checkCancellation()
            guard latestSearch == search else { return }
            results = found
        } catch let error as CancellationError {
            throw error
        } catch {
            guard latestSearch == search else { return }
            errorMessage = String(describing: error)
        }
    }
}

public struct SearchScreen: View {
    private let viewModel: SearchViewModel
    @State private var term = ""

    public init(viewModel: SearchViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        List {
            TextField("検索", text: $term)

            if viewModel.isSearching {
                ProgressView()
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }

            ForEach(viewModel.results, id: \.self) { result in
                Text(result)
            }
        }
        .task(id: term) { [term] in
            try? await viewModel.search(term: term, debounce: .milliseconds(250))
        }
    }
}
