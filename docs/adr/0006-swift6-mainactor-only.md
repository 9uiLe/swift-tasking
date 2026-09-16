# ADR-0006: Swift 6 と明示的な actor 隔離を使う

## 前提

受付、追跡、所有台帳は可変状態であり、更新順序を制御する必要がある。
UI の状態へ接続する処理と非 UI サービスの処理は、それぞれの実行場所で扱う。

## 決定

- Swift tools 6.0 と Swift 6 言語モードを使い、利用側の機能モジュールも Swift 6 モードをサポート条件とする。
- Store・Runner と、その処理本体は MainActor に隔離する。
- Slot は独立した actor とし、`@Sendable` な async クロージャを受け取る。
- 対応 OS は iOS 13、macOS 10.15、tvOS 13、watchOS 6、visionOS 1 以降とする。
- default actor isolation と `NonisolatedNonsendingByDefault` は有効にしない。

## 理由と制約

Store と Runner は、MainActor 上で追跡の更新と ViewModel の状態反映を行える。
Slot の所有管理は独立した actor に置き、非 UI の所有者に MainActor を要求しない。

MainActor 上の重い同期計算は UI の時間を占有する。`await` だけでは処理を別の実行場所へ移せない。
計算を担当する actor や関数の隔離と負荷を確認する。

利用側が Swift 5 モードの場合はクロージャの捕捉もその規則で検査されるため、import の成功を互換性の保証としない。
コンパイラ設定を変える場合は、Slot の処理本体の実行場所と Swift tools の対応範囲を検証する。
