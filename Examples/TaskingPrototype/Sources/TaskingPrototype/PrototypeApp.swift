import SwiftUI

/// Composes the example features and owns their shared presentation state.
/// Embed it in an app with `WindowGroup { PrototypeRootView() }`.
public struct PrototypeRootView: View {
    @State private var settings = SettingsViewModel()
    @State private var search = SearchViewModel()
    @State private var downloads = DownloadsViewModel()
    @State private var billing = BillingViewModel()

    public init() {}

    public var body: some View {
        TabView {
            NavigationStack { SettingsScreen(viewModel: settings) }
                .tabItem { Label("Save", systemImage: "square.and.arrow.down") }

            NavigationStack { SearchScreen(viewModel: search) }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }

            NavigationStack { DownloadsScreen(viewModel: downloads) }
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }

            NavigationStack { SyncSettingsScreen() }
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }

            NavigationStack { BillingScreen(viewModel: billing) }
                .tabItem { Label("Billing", systemImage: "creditcard") }
        }
    }
}
