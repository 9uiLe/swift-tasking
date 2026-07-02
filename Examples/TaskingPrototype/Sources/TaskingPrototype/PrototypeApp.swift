import SwiftUI

/// プロトタイプ全体のルート。実アプリに組み込む場合は
/// `WindowGroup { PrototypeRootView() }` を App に置く。
public struct PrototypeRootView: View {
    public init() {}

    public var body: some View {
        TabView {
            NavigationStack { SettingsScreen() }
                .tabItem { Label("Save", systemImage: "square.and.arrow.down") }

            NavigationStack { SearchScreen() }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }

            NavigationStack { DownloadsScreen() }
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }

            NavigationStack { SyncSettingsScreen() }
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }

            NavigationStack { BillingScreen() }
                .tabItem { Label("Billing", systemImage: "creditcard") }
        }
    }
}
