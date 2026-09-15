import SwiftUI
import Tasking

/// Search replaces previous work; the ViewModel guards result publication.
enum SearchAction {
    static let query = ActionID("search.query")
}

@MainActor
@Observable
public final class SearchViewModel {
    public private(set) var results: [String] = []
    public private(set) var isSearching = false

    @ObservationIgnored private var latestSearch = UUID()
    public private(set) var errorMessage: String?

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
        let search = UUID()
        latestSearch = search
        isSearching = true
        errorMessage = nil
        defer {
            if latestSearch == search { isSearching = false }
        }

        do {
            try cancellation.check()
            let found = try await performSearch(term)
            try cancellation.check()
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
    @State private var taskStore = ViewTaskStore()
    private let viewModel: SearchViewModel
    @State private var term = ""

    public init(viewModel: SearchViewModel) {
        self.viewModel = viewModel
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

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage).foregroundStyle(.red)
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
