# swift-tasking / Tasking

日本語 | [English](README.en.md)

[![CI](https://github.com/9uiLe/swift-tasking/actions/workflows/ci.yml/badge.svg)](https://github.com/9uiLe/swift-tasking/actions/workflows/ci.yml)

Tasking は、**同期イベントから開始したタスクを、キャンセル後も実終了まで所有し、終了を待つ**ための
Swift Concurrency ライブラリです。UI 向けの `Tasking` と非 UI 向けの `TaskingCore` を提供し、外部依存はありません。

## 用途を選ぶ

| 処理の性質 | 使用するもの |
|---|---|
| async 関数内で並行実行し、戻る前に合流する | `async let` / task group |
| SwiftUI の表示期間や入力に連動する | `.task` / `.task(id:)` |
| 単一の async 操作の重複だけを防ぐ | 通常の async 関数と状態ガード |
| 同期 UI コールバックから開始し、個別のキャンセルや終了確認を行う | `ViewTaskStore` |
| 複数の async 入口で Action ごとの重複制御を共有する | 必要に応じて `ActionRunner` |
| 非 UI サービスが差し替え可能なタスクを所有する | `TaskSlot` |

標準の仕組みが処理の寿命に合う場合は、それを使います。Tasking は進捗・業務結果・再試行の状態を持ちません。
[用途と設計原則](docs/positioning.md) に判断基準を、[プロトタイプ](Examples/TaskingPrototype) に実装例を示します。

## 導入

公開済みの package を参照するには、次の依存を追加します。

```swift
.package(url: "https://github.com/9uiLe/swift-tasking.git", from: "0.4.0")
```

各リビジョンの文書は、そのリビジョンの API を説明します。
[変更履歴](CHANGELOG.md) の `Unreleased` にある機能を使う場合は、公開までローカルのチェックアウトを参照します。

```swift
.package(path: "../swift-tasking")
```

ターゲットには必要な product を指定します。

```swift
.product(name: "Tasking", package: "swift-tasking")
// 非 UI のタスク所有には .product(name: "TaskingCore", package: "swift-tasking")
```

Swift tools 6.0 以降と Swift 6 言語モードが必要です。利用側の機能モジュールも Swift 6 言語モードにします。
対応 OS は iOS 13+、macOS 10.15+、tvOS 13+、watchOS 6+、visionOS 1+ です。
Observation や新しい SwiftUI API を使う例には、それぞれの対応 OS が必要です。
[プロトタイプ](Examples/TaskingPrototype/Package.swift) は iOS 17+ と macOS 14+ を対象にしています。

## ViewTaskStore: 同期 UI コールバックから開始する

Store を、処理を管理したい期間の所有者に配置します。この例は画面が Store を保持し、非表示時にキャンセルします。
`SettingsViewModel.save()` はアプリケーション側の async throws メソッドで、標準の `Task.checkCancellation()` と
業務エラーの表示を扱います。完全な実装は [SettingsFeature.swift](Examples/TaskingPrototype/Sources/TaskingPrototype/SettingsFeature.swift) にあります。

```swift
import SwiftUI
import Tasking

@MainActor
struct SettingsScreen: View {
    @State private var taskStore = ViewTaskStore()
    let viewModel: SettingsViewModel

    var body: some View {
        Button("保存") {
            taskStore.start(id: "settings.save") { [viewModel] in
                try await viewModel.save()
            }
        }
        .onDisappear {
            taskStore.cancelAll()
        }
    }
}
```

`start` は MainActor 上でタスクを作成し、同期的に `.started(ActionRun)` または
`.skipped(TaskStartSkipReason)` を返します。`ActionID` は処理の種類、`ActionRun` は1回の実行を識別します。

| `TaskStartPolicy` | 同じ ActionID への扱い |
|---|---|
| `.ignoreNew`（既定値） | キャンセル済みも含む未終了の実行があれば `.skipped(.unfinished)` |
| `.cancelExisting` | 追跡中の実行にキャンセルを要求し、実終了を待たず新しい実行を開始 |
| `.allowConcurrent` | 追加の実行を開始 |

受付が閉じていれば、方針にかかわらず `.skipped(.closed)` です。拒否した要求の処理本体は呼びません。
保存などの再入を実終了まで防ぐ場合は既定値を使います。古い処理に協調的な終了を要求しながら新しい要求を
すぐ始めたい場合は `.cancelExisting` を選び、結果の世代や副作用の順序を利用側で管理します。

### 追跡と実終了

キャンセルは**追跡を直ちに解除**しますが、Store はそのタスクを**実終了まで所有**します。
`isTracked` / `trackedCount` はキャンセル対象となる追跡状態、`isUnfinished` / `unfinishedCount` は
キャンセル済みも含む未終了状態の同期照会です。どちらも SwiftUI の再描画を起こさないため、表示は ViewModel の観測可能な状態で管理します。

通常は所有者ごとに Store を分け、`cancelAll()` を使います。同じ Store 内で一部だけ一括キャンセルしたい場合は、
`group: CancellationGroup` を指定します。グループは任意の文字列による選択ラベルで、所有者の寿命を変えません。
配置と参照関係は [寿命と所有構成](docs/lifetimes.md) を参照してください。

### 終了する

| 目的 | Store / Slot の操作 |
|---|---|
| 所有者を再利用しながらキャンセルする | Store の `cancel(...)` / `cancelAll()`、Slot の `cancel()` |
| 新規受付を閉じ、受理済みの処理を完了させる | `close()` の後に `waitForIdle()` |
| 新規受付を閉じ、キャンセルを要求して実終了を待つ | `cancelAndWaitForIdle()` |
| Store の1回の実行の実終了を待つ | `awaitCompletion(of:)` |

`close()` は再開できない終端操作です。待機側のキャンセルは、所有する処理に伝播せず、待機も中断しません。
処理が終了しなければ待機も続きます。所有される処理やその構造化子タスクから自己待機を行ってはいけません。
詳しい契約と検出範囲は [アーキテクチャ](docs/architecture.md#キャンセルと終了待ち) に定めます。

Store の業務エラーは処理本体で扱います。外へ漏れた `CancellationError` は通常の終了として扱い、
その他のエラーは `onUnhandledError(ActionRun, any Error)` へ元の型のまま報告します。
通知先がない場合や Store の解放後は Debug でアサーションが発生し、Release では通知しません。

## ActionRunner: async の受付を共有する

Runner は、複数の async 入口で重複制御を共有する必要がある場合の補助です。
新しい Task を作らず、呼び出し元のタスクで処理を続けます。以下は MainActor 上の async コードで、
`billingService.fetchPlans()` はアプリケーションが用意する async throws メソッドです。

```swift
let runner = ActionRunner()
do {
    let accepted = try await runner.run(id: "billing.refresh") {
        try Task.checkCancellation()
        let plans = try await billingService.fetchPlans()
        try Task.checkCancellation()
        return plans
    }
    if let plans = accepted { print(plans) }
} catch is CancellationError {
    // キャンセル時の表示は呼び出し元で確定する。
} catch {
    // 元のエラー型を使って回復や表示を行う。
}
```

`.ignoreNew`（既定値）でスキップすると `nil`、受理して値を返すと `.some(value)` です。
成功値自体が Optional なら、外側の Optional が受付を表します。エラーと `CancellationError` はそのまま送出されます。
`.allowConcurrent` も選べます。タスクの所有・キャンセル・表示状態は呼び出し元が担当します。

## TaskSlot: 非 UI の処理を差し替える

`TaskingCore.TaskSlot` は独立した actor です。`replace` はアクティブなタスクにキャンセルを要求し、
新しいタスクを開始します。処理本体は業務エラーとキャンセルを扱い、エラーを外に投げない形で渡します。

```swift
import TaskingCore

actor RefreshCoordinator {
    private let slot = TaskSlot()
    private let refresh: @Sendable () async -> Void

    init(refresh: @escaping @Sendable () async -> Void) {
        self.refresh = refresh
    }

    @discardableResult
    func scheduleRefresh() async -> Bool {
        await slot.replace(operation: refresh)
    }

    func shutDown() async {
        await slot.cancelAndWaitForIdle()
    }
}
```

閉鎖後の `replace` は `false` を返します。差し替え済みのタスクも実終了まで所有するため、未終了処理は重なり得ます。
大量の入力は開始前にデバウンスや集約を行い、[性能特性](docs/performance.md) の条件に沿って測定します。

## 設計・開発資料

- [ドキュメントガイド](docs/README.md) — 用途別の入口
- [アーキテクチャ](docs/architecture.md) — 現行の契約、設計根拠、不変条件、テスト
- [コントリビューションガイド](CONTRIBUTING.md)（[English](CONTRIBUTING.en.md)）— 変更と検証
- [リリース設計と運用](docs/releasing.md) — 認証、準備、公開、復旧
- [セキュリティポリシー](SECURITY.md)（[English](SECURITY.en.md)）— 脆弱性の報告

日本語を正本とし、README・コントリビューションガイド・セキュリティポリシーは英語版を同時に保守します。
コードは [MIT ライセンス](LICENSE) で配布しています。
