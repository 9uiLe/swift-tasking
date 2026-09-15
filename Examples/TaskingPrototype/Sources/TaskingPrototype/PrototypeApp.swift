import SwiftUI

/// サンプル機能を組み合わせ、共有する表示状態を所有する。
/// `WindowGroup { PrototypeRootView() }` でアプリに組み込む。
public struct PrototypeRootView: View {
    @State private var settings = SettingsViewModel()
    @State private var search = SearchViewModel()
    @State private var downloads = DownloadsViewModel()
    @State private var billing = BillingViewModel()

    public init() {}

    public var body: some View {
        TabView {
            NavigationStack { SettingsScreen(viewModel: settings) }
                .tabItem { Label("保存", systemImage: "square.and.arrow.down") }

            NavigationStack { SearchScreen(viewModel: search) }
                .tabItem { Label("検索", systemImage: "magnifyingglass") }

            NavigationStack { DownloadsScreen(viewModel: downloads) }
                .tabItem { Label("ダウンロード", systemImage: "arrow.down.circle") }

            NavigationStack { SyncSettingsScreen() }
                .tabItem { Label("同期", systemImage: "arrow.triangle.2.circlepath") }

            NavigationStack { BillingScreen(viewModel: billing) }
                .tabItem { Label("課金", systemImage: "creditcard") }
        }
    }
}
