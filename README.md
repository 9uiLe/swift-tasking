# swift-tasking / Tasking

日本語 | [English](README.en.md)

[![CI](https://github.com/9uiLe/swift-tasking/actions/workflows/ci.yml/badge.svg)](https://github.com/9uiLe/swift-tasking/actions/workflows/ci.yml)

Tasking は、Swift Concurrency の非構造化タスクについて、所有・重複制御・協調キャンセルを
明示するライブラリです。2つのライブラリ product を提供し、外部 package への依存はありません。

## 用途に合う入口を選ぶ

| 実行したい処理 | 使用するもの |
|---|---|
| async スコープ内で完了する並行処理 | `async let` または task group |
| SwiftUI の画面寿命や入力に連動する読み込み | `.task` または `.task(id:)` |
| 同期 UI コールバックから開始し、所有者が必要な処理 | `Tasking.ViewTaskStore` |
| async 呼び出し内での重複制御と終了結果の取得 | `Tasking.ActionRunner` |
| 非 UI サービスが所有する、差し替え可能な1つのタスク | `TaskingCore.TaskSlot` |

構造化並行処理と SwiftUI のライフサイクルタスクは、スコープを通じて所有を表します。
処理の寿命に合う場合は、それらを使います。Store と Slot は、同期コールバックや
メソッドの呼び出しを越えて継続する必要があるタスクを所有します。

## 導入

公開済み package には、次の依存を追加します。

```swift
.package(url: "https://github.com/9uiLe/swift-tasking.git", from: "0.3.0")
```

この文書はチェックアウト内の API を説明します。[変更履歴](CHANGELOG.md) の Unreleased に
記載された機能は、公開されるまでローカルのチェックアウトを参照してください。

```swift
.package(path: "../swift-tasking")
```

ターゲットの依存には、使用する product を指定します。

```swift
.product(name: "Tasking", package: "swift-tasking")
```

非 UI ターゲットで差し替え可能なタスクを所有する場合は、次を指定します。

```swift
.product(name: "TaskingCore", package: "swift-tasking")
```

Swift tools 6.0 以降と Swift 6 言語モードが必要です。利用する機能モジュールにも
Swift 6 言語モードを指定してください。

対応 OS は iOS 13+、macOS 10.15+、tvOS 13+、watchOS 6+、visionOS 1+ です。
Observation や新しい SwiftUI API を使う例には、それぞれの対応 OS が必要です。
[プロトタイプ](Examples/TaskingPrototype/Package.swift) は iOS 17+ と macOS 14+ を対象にしています。

## ViewTaskStore: 同期 UI コールバックから始まる処理を所有する

`ViewTaskStore` は MainActor 上のクラスです。`start` はタスクを作成・所有し、
Action ID と寿命ラベルを記録して、受付結果を同期的に返します。

次の画面は、アプリケーションが所有する `SettingsViewModel` を受け取ります。
その `save(cancellation:)` メソッドが UI 状態の更新、業務上の失敗の処理、
キャンセルへの協調を担当します。完全な実装は
[SettingsFeature.swift](Examples/TaskingPrototype/Sources/TaskingPrototype/SettingsFeature.swift) を参照してください。

```swift
import SwiftUI
import Tasking

private enum SettingsActions {
    static let save: ActionID = "settings.save"
}

@MainActor
struct SettingsScreen: View {
    @State private var taskStore = ViewTaskStore()
    let viewModel: SettingsViewModel

    var body: some View {
        Button("保存") {
            taskStore.start(
                id: SettingsActions.save,
                lifetime: .screenBound,
                policy: .ignoreNew
            ) { [viewModel] cancellation in
                try await viewModel.save(cancellation: cancellation)
            }
        }
        .onDisappear {
            taskStore.cancel(lifetime: .screenBound)
        }
    }
}
```

### 受付と重複制御

Action ID は `settings.save` のように処理の種類を識別します。`ActionRun` は、
Action ID と UUID に基づく run ID の組み合わせで1回の実行を識別します。
Action ID は機能ごとの定数として宣言します。

| `TaskStartPolicy` | 振る舞い |
|---|---|
| `.ignoreNew`（既定値） | 同じ Action ID の実行を追跡中なら、新しい要求をスキップする |
| `.cancelExisting` | 同じ ID の実行をキャンセルして追跡から外し、新しい実行を開始する |
| `.allowConcurrent` | 同じ ID の実行を追加で開始する |

`TaskStartOutcome` は `.started(ActionRun)` または `.skipped(TaskStartSkipReason)` です。
スキップ理由には `.alreadyRunning` と `.closed` があります。受付を閉じた Store は、
処理を実行せずにすべての開始要求を拒否します。受付結果と処理の業務結果は別のものです。

### 寿命と UI 状態

`ActionLifetime` は、照会や一括キャンセルに使うラベルです。組み込み値は
`.screenBound`、`.sceneBound`、`.appBound` で、独自の文字列も使えます。
処理を管理したい期間に合う所有者へ Store を配置し、ライフサイクルイベントをキャンセルに接続します。
ラベル自体が所有者の寿命を延ばしたり、バックグラウンド実行時間を確保したりすることはありません。

読み込み中・進捗・結果・エラーは ViewModel の状態として管理します。追跡の照会は同期的な
スナップショットであり、SwiftUI の再描画を起こしません。実行が重なる場合は世代トークンで
結果反映と後処理を保護し、古い実行が新しい状態を上書きしないようにします。
[レシピ](docs/recipes.md) に実装例があります。

### エラー

業務上の失敗は処理の内部で扱い、通常は ViewModel の状態に反映します。
送出された `CancellationError` は通常のキャンセルとして扱います。
それ以外のエラーが外へ漏れることは、処理の契約違反です。

Store に通知先を設定すると、漏れたエラーを報告できます。

```swift
let taskStore = ViewTaskStore { run, failure in
    print("\(run.actionID): \(failure.typeName): \(failure.message)")
}
```

通知先は MainActor 上で、完了による追跡の除去より前に呼ばれます。キャンセルで追跡から
外れた実行は、そのまま追跡対象外です。通知先がなければ、漏れたエラーは Debug の
アサーション対象となり、Release では通知されません。Store の解放後も同じアサーションの
扱いになります。Store は通知先を保持するため、通知先から Store の所有者を参照する場合は
弱参照にしてください。

## ActionRunner: 呼び出し元のタスク内で実行する

`ActionRunner` は、Action の実行を追跡して終了結果に変換する MainActor 上のクラスです。
処理は呼び出し元のタスク内で実行します。タスクの所有とキャンセルは呼び出し元が担当します。

次は MainActor 上の async コードです。`billingService` はアプリケーションが用意する依存で、
`Sendable` な値を返す async throws メソッド `fetchPlans()` を持ちます。

```swift
let runner = ActionRunner()
let outcome = await runner.run(
    ActionDescriptor(id: "billing.refresh", duplicatePolicy: .ignoreNew)
) { cancellation in
    try cancellation.check()
    let plans = try await billingService.fetchPlans()
    try cancellation.check()
    return plans
}

switch outcome {
case let .succeeded(plans):
    print(plans)
case .cancelled:
    break
case .skipped(.alreadyRunning):
    break
case let .failed(failure):
    print("\(failure.typeName): \(failure.message)")
}
```

複数の呼び出しで重複制御を共有するには、機能の所有者に Runner を保持します。
Runner は `.ignoreNew` と `.allowConcurrent` に対応します。任意の同期コールバック
`onStart` は、受け付けた実行を追跡している間に呼ばれます。スキップした呼び出しでは
`onStart` も処理本体も実行しません。

送出された `CancellationError` は `.cancelled` に変換します。値が返された場合は、
キャンセルが要求されていても `.succeeded` になります。`ActionFailure` は報告用に
エラー型名とメッセージの文字列を保持します。エラー型に応じた復旧は、元の型を扱える
処理本体の内部で行ってください。

## TaskSlot: UI の外で差し替え可能な処理を所有する

`TaskSlot` は `TaskingCore` の actor です。アクティブなタスクを最大1つ所有し、
キャンセル済み・差し替え済みのタスクも終了まで保持します。処理本体が業務上のエラーを扱い、
共通のキャンセル契約に従います。

```swift
import TaskingCore

actor RefreshCoordinator {
    private let slot = TaskSlot()
    private let refresh: @Sendable (CancellationContext) async -> Void

    init(refresh: @escaping @Sendable (CancellationContext) async -> Void) {
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

`replace` はアクティブなタスクをキャンセルし、代わりのタスクを開始します。
受付を閉じた後は `false` を返します。差し替えられた処理がキャンセルに協調するまでは、
新旧の処理が重なることがあります。Slot は所有を担当し、デバウンスの時間・再試行・
結果の選択・順序はアプリケーションが定義します。

## キャンセルと完了

`CancellationContext.check()` と `isCancelled` は、その時点で実行中のタスクを参照します。
キャンセルトークンを捕捉したり、別の非構造化タスク同士を接続したりする値ではありません。
長い処理や重要な中断点の前後でキャンセルを確認してください。処理内の並行実行には
`async let` または task group を使います。

キャンセルすると、Store の実行は直ちに追跡から外れます。ハンドルの所有は終了まで続くため、
`isRunning == false` は完了を意味しません。手動でキャンセルした処理がまだ実行中でも、
`.ignoreNew` が新しい要求を受け付けることがあります。

| 目的 | Store / Slot の操作 |
|---|---|
| 受付を続けながらキャンセルを要求する | Store の `cancel(...)` / `cancelAll()`、Slot の `cancel()` |
| 受付を閉じ、受け付け済みの処理を完了させる | `close()` の後に `waitForIdle()` |
| 受付を閉じ、キャンセルを要求して終了を待つ | `cancelAndWaitForIdle()` |
| キャンセル済みを含む Store の1回の実行を待つ | `awaitCompletion(of:)` |

受付の閉鎖は終端状態で、繰り返しても結果は変わりません。受付が開いている場合、
`waitForIdle()` は待機中に受け付けた処理も待ちます。待機側のタスクをキャンセルしても、
所有する処理はキャンセルされず、待機も中断しません。終了しない処理があれば、待機も続きます。

所有される処理は、構造化子タスクを経由する場合も含めて、自分自身の終了を待ってはいけません。
Debug ビルドでは自己待機をアサーションで検出します。Release ビルドでは継承された所有文脈を
待機対象から除き、ほかの処理を待ちます。タスク間の任意の循環待機を検出する機能ではありません。

Store と Slot は解放時にキャンセルを要求します。処理が所有者を強参照すると、解放できなくなる
場合があります。長い処理では必要な依存だけを捕捉し、所有者は弱参照で参照してください。
どちらも任意の優先度を Swift の `Task` 初期化子に渡し、`nil` なら呼び出し元の優先度を継承します。

## ドキュメント

日本語を正本とし、利用・貢献・脆弱性報告の入口には英語版も用意しています。
設計資料と運用手順は日本語で管理します。

- [ドキュメントガイド](docs/README.md) — 読む順序と設計判断
- [アーキテクチャ](docs/architecture.md) — 責務・不変条件・テスト
- [寿命と所有](docs/lifetimes.md) — 画面・シーン・アプリケーションの所有
- [レシピ](docs/recipes.md) — キャンセル・状態更新・終了処理
- [導入ガイド](docs/adoption.md) — 機能の境界・ID・運用確認
- [性能特性](docs/performance.md) — 計算量・測定・トレードオフ
- [リリース設計と運用](docs/releasing.md) — 所有者認証・準備・公開
- [コントリビューションガイド](CONTRIBUTING.md)（[English](CONTRIBUTING.en.md)）— 検証と文書の規約
- [セキュリティポリシー](SECURITY.md)（[English](SECURITY.en.md)）— 脆弱性の報告

Swift Concurrency の参考資料:
[構造化並行処理](https://developer.apple.com/videos/play/wwdc2021/10134/)、
[構造化並行処理の応用](https://developer.apple.com/videos/play/wwdc2023/10170/)、
[Task.cancel()](https://developer.apple.com/documentation/swift/task/cancel%28%29)。
