# swift-tasking / Tasking

日本語 | [English](README.en.md)

[![CI](https://github.com/9uiLe/swift-tasking/actions/workflows/ci.yml/badge.svg)](https://github.com/9uiLe/swift-tasking/actions/workflows/ci.yml)

Tasking は、Swift Concurrency の非構造化タスクについて、**誰が所有するか、重複した要求をどう扱うか、
いつキャンセルして終了を待つか**を明示するライブラリです。
UI 向けの `Tasking` と非 UI 向けの `TaskingCore` を提供し、外部 package への依存はありません。

## 用途を選ぶ

| 処理の性質 | 使用するもの |
|---|---|
| async 関数内で並行実行し、戻る前に合流する | `async let` / task group |
| SwiftUI の表示期間や入力に連動する | `.task` / `.task(id:)` |
| 同期 UI コールバックから開始し、タスクを所有する | `ViewTaskStore` |
| 呼び出し元のタスク内で重複制御と終了結果の取得を行う | `ActionRunner` |
| 非 UI サービスが差し替え可能なタスクを所有する | `TaskSlot` |

構造化並行処理や SwiftUI のスコープが処理の寿命に合う場合は、その仕組みを使います。
Tasking を使う場合も、進捗・結果・業務エラーの処理・再試行は ViewModel やサービスが担当します。

## 導入

公開済みの package を参照するには、次の依存を追加します。

```swift
.package(url: "https://github.com/9uiLe/swift-tasking.git", from: "0.3.0")
```

各リビジョンの文書は、そのリビジョンの API を説明します。
[変更履歴](CHANGELOG.md) の `Unreleased` にある機能を使う場合は、公開までローカルのチェックアウトを参照します。

```swift
.package(path: "../swift-tasking")
```

ターゲットの依存には、UI 向けの product を指定します。

```swift
.product(name: "Tasking", package: "swift-tasking")
```

非 UI のタスク所有を使うターゲットでは、次を指定します。

```swift
.product(name: "TaskingCore", package: "swift-tasking")
```

Swift tools 6.0 以降と Swift 6 言語モードが必要です。利用側の機能モジュールも Swift 6 言語モードにします。
対応 OS は iOS 13+、macOS 10.15+、tvOS 13+、watchOS 6+、visionOS 1+ です。
Observation や新しい SwiftUI API を使う例には、それぞれの対応 OS が必要です。
[プロトタイプ](Examples/TaskingPrototype/Package.swift) は iOS 17+ と macOS 14+ を対象にしています。

## 管理する3つの状態

- **受付**: 新しい処理を開始できるか。`close()` で恒久的に閉じます。
- **追跡**: Action の重複判定と照会の対象か。Store はキャンセル時に直ちに追跡を解除します。
- **所有**: 終了を管理するためにタスクのハンドルを保持しているか。Store と Slot は終了まで保持します。

Action は保存や更新などの処理の種類で、`ActionID` で識別します。
`ActionRun` は ActionID と UUID に基づく `ActionRunID` の組で、1回の実行を識別します。
同じ ActionID に複数の実行が存在する場合があります。

## ViewTaskStore: 同期 UI コールバックから開始する

`ViewTaskStore` は MainActor 上でタスクを作成・所有し、`start` から受付結果を同期的に返します。
次の例では、アプリケーションが保持する `SettingsViewModel` を画面に渡します。
`save(cancellation:)` はキャンセルへの協調と業務エラーの表示を担当します。
完全な実装は [SettingsFeature.swift](Examples/TaskingPrototype/Sources/TaskingPrototype/SettingsFeature.swift) を参照してください。

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

### 重複方針と受付結果

| `TaskStartPolicy` | 同じ ActionID の実行を追跡中の場合 |
|---|---|
| `.ignoreNew`（既定値） | 新しい要求をスキップする |
| `.cancelExisting` | 追跡中の実行にキャンセルを要求して追跡から外し、新しい要求を開始する |
| `.allowConcurrent` | 追加の実行を開始する |

`TaskStartOutcome` は `.started(ActionRun)` または `.skipped(TaskStartSkipReason)` です。
スキップ理由は `.alreadyRunning` と `.closed` で、拒否した要求の処理本体は呼ばれません。
受付結果は業務結果を表しません。個別の実行の照会・キャンセル・終了待ちには、返された `ActionRun` を使います。

### 寿命と表示状態

`ActionLifetime` は照会や一括キャンセルのラベルです。
`.screenBound`・`.sceneBound`・`.appBound` と独自の文字列を使えます。
処理を管理したい期間に合う場所へ Store を配置し、終了イベントをキャンセルに接続します。
ラベル自体は所有者の寿命や OS のバックグラウンド実行権限を変えません。

`isRunning` と `runningCount` は追跡状態の同期的な照会です。SwiftUI の再描画は起こさないため、
読み込み中・進捗・結果・エラーは ViewModel の観測可能な状態として持ちます。
実行が重なる場合は世代ガードで状態更新を制御します。[利用レシピ](docs/recipes.md) に実装例があります。

## ActionRunner: 呼び出し元のタスクで実行する

`ActionRunner` は MainActor 上で Action を追跡し、処理本体の終了結果を返します。
タスクの所有とキャンセルは呼び出し元が担当します。
複数の呼び出しで重複制御を共有するには、機能の所有者に Runner を保持します。

次は MainActor 上の async コードです。`billingService` はアプリケーションの依存で、
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

Runner の重複方針は `.ignoreNew` と `.allowConcurrent` です。
任意の同期コールバック `onStart` は、受理した実行の追跡を登録した後、処理本体より前に呼ばれます。
スキップした場合はどちらも呼ばれません。

`CancellationError` の送出は `.cancelled`、値の返却は `.succeeded` になります。
値を返した場合は、キャンセル要求があっても成功として扱います。
`ActionFailure` は報告用のエラー型名とメッセージです。元のエラー型に応じた回復は処理本体で行います。

## TaskSlot: 非 UI の処理を差し替える

`TaskingCore.TaskSlot` は独立した actor です。
`replace` はアクティブなタスクをキャンセルし、代わりのタスクを開始します。
処理本体が業務エラーとキャンセルを扱い、エラーを外に送出しない形で渡します。

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

受付の閉鎖後は `replace` が `false` を返します。
差し替えたタスクも終了まで所有するため、キャンセルに協調するまでは処理が重なる場合があります。
デバウンスの時間、再試行、結果の採用、副作用の順序はサービスが定義します。

## キャンセルと終了を管理する

`CancellationContext.check()` と `isCancelled` は、アクセス時に実行中のタスクを参照します。
長い処理や重要な中断点の前後で確認してください。処理内の並行実行には `async let` または task group を使います。
この値を別の非構造化タスクに渡しても、キャンセルの親子関係は作られません。

Store はキャンセル時に追跡を解除し、ハンドルは終了まで所有します。
そのため `isRunning == false` は完了を意味せず、手動キャンセル直後の `.ignoreNew` が新しい要求を受け付ける場合があります。

| 目的 | 操作 |
|---|---|
| 受付を続けながらキャンセルする | Store の `cancel(...)` / `cancelAll()`、Slot の `cancel()` |
| 受付を閉じ、受理済みの処理を完了させる | `close()` の後に `waitForIdle()` |
| 受付を閉じ、キャンセルを要求して終了を待つ | `cancelAndWaitForIdle()` |
| Store の1回の実行を待つ | `awaitCompletion(of:)` |

受付が開いたままの `waitForIdle()` は、待機中に開始した処理も待ちます。
待機側のキャンセルは、所有する処理をキャンセルせず、待機も中断しません。
終了しない処理があれば待機は続きます。

処理は、構造化子タスク経由も含めて自分自身の終了を待ってはいけません。
Debug ではアサーションで検出し、Release では継承された所有文脈を待機対象から除外します。
任意のタスク間の循環待機を検出する機能ではありません。

Store と Slot は解放時にキャンセルを要求します。処理が所有者を強参照すると解放を妨げるため、
必要な依存だけを捕捉し、所有者は弱参照で参照します。
両方とも任意の優先度を `Task` に渡し、`nil` なら呼び出し元の優先度を継承します。

## Store の未処理エラーを報告する

Store の業務エラーは処理本体で扱います。外へ漏れた `CancellationError` は通常のキャンセル、
それ以外のエラーは契約違反として扱います。通知先を設定すると、ログなどへ接続できます。

```swift
let taskStore = ViewTaskStore { run, failure in
    print("\(run.actionID): \(failure.typeName): \(failure.message)")
}
```

通知は MainActor 上で、完了による追跡解除より前に行います。キャンセルで解除済みの追跡は復元しません。
通知先がない場合や Store の解放後は、Debug でアサーションを発生させ、Release では通知しません。
Store は通知先を保持するため、通知先から所有者を参照するときも弱参照を使います。

## 設計・開発資料

- [ドキュメントガイド](docs/README.md) — 用途別の入口と設計判断
- [アーキテクチャ](docs/architecture.md) — 公開契約、内部構造、不変条件、テスト
- [寿命と所有構成](docs/lifetimes.md) — 画面・シーン・アプリへの配置
- [性能特性](docs/performance.md) — 計算量、測定条件、結果の読み方
- [コントリビューションガイド](CONTRIBUTING.md)（[English](CONTRIBUTING.en.md)）— 変更と検証の手順
- [リリース設計と運用](docs/releasing.md) — 認証、文書の準備、公開、復旧
- [セキュリティポリシー](SECURITY.md)（[English](SECURITY.en.md)）— 脆弱性の報告

日本語を正本とし、README・コントリビューションガイド・セキュリティポリシーには英語版を用意しています。
コードは [MIT ライセンス](LICENSE) で配布しています。

Swift Concurrency の参考資料:
[構造化並行処理](https://developer.apple.com/videos/play/wwdc2021/10134/)、
[構造化並行処理の応用](https://developer.apple.com/videos/play/wwdc2023/10170/)、
[Task.cancel()](https://developer.apple.com/documentation/swift/task/cancel%28%29)。
