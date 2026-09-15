# 導入と運用

Tasking を複数の feature やチームで使う場合は、所有者の配置、ActionID、キャンセル後の
状態更新を共通ルールにする。基本的な用途は [用途と設計原則](positioning.md) を参照する。

## Swift 6 と actor 隔離

パッケージは Swift tools 6.0、Swift 6 言語モードを使用する。
Tasking を呼び出す feature module も Swift 6 言語モードをサポート条件とする。

Swift 5 言語モードの target から import できる場合でも、closure の capture は呼び出し側の
言語モードで検査される。import の成功だけでは strict concurrency の保証にならない。

UI の同期 callback と ViewModel には `Tasking` を使い、Store / Runner の MainActor 隔離に従う。
非 UI の service actor が置換可能な task を所有する場合は `TaskingCore` に依存する。
Slot は task 所有を担当し、debounce の時間、retry、flush、業務状態は service が持つ。

## 所有者を配置する

- Store は feature、画面、またはアプリ全体の共通処理を単位として配置する。
- 共有 Store は、同じ寿命とキャンセル方針を持つ Action に限定する。
- UI に進捗を表示する ViewModel は、その処理を観測できる期間だけ所有する。
- operation が Store / Slot の所有者を強参照しないかを確認する。

[ライフタイムと所有構成](lifetimes.md) に画面・シーン・アプリの例を示す。
`.appBound` は OS の background execution 権限を与えない。background での完遂には
`beginBackgroundTask`、`BGTaskScheduler`、background `URLSession` など、用途に合う OS API を使う。

## ActionID と重複方針

ActionID の衝突は同じ Store / Runner 内で重複判定に影響する。
たとえば共有 Store に別々の feature が `"sync"` を登録すると、一方の `.ignoreNew` が
他方を拒否する可能性がある。

- 定数は `feature.action`、entity ごとは `feature.action.<entity-id>` を使う。
- 同じ ActionID の方針は feature 内の1か所に置く。
- 同じ ID の異なる operation を混在させる場合は、重複扱いが意図どおりかを確認する。

```swift
enum BillingActions {
    static let refreshPlans: ActionID = "billing.refreshPlans"
    static let refreshPlansPolicy: TaskStartPolicy = .ignoreNew

    static func downloadInvoice(_ invoiceID: String) -> ActionID {
        ActionID("billing.downloadInvoice.\(invoiceID)")
    }
}
```

## 終了処理

画面の再表示などで同じ Store を再利用するときは `cancel(lifetime:)` を使う。
所有者を終了するときは `cancelAndWaitForIdle()`、受け付け済みの処理を自然完了させるときは
`close()` の後に `waitForIdle()` を呼ぶ。Slot も同じ受付停止の契約を持つ。

Store の開始結果は `TaskStartOutcome` で確認する。

| 結果 | 意味 |
|---|---|
| `.started(run)` | task を受け付けた。業務結果は operation / ViewModel が扱う |
| `.skipped(.alreadyRunning)` | 同じ ActionID の追跡中 run があり、`.ignoreNew` が拒否した |
| `.skipped(.closed)` | Store の受付が閉じている |

Runner の拒否理由は `ActionSkipReason.alreadyRunning` である。
Runner は task の所有者ではなく、受付を閉じる状態を持たない。

キャンセル要求と実終了は分かれているため、`.ignoreNew` は手動キャンセル後の重なりを防がない。
表示の loading・結果・エラーには必要に応じて世代ガードを設ける。[利用レシピ](recipes.md) を参照する。

## 観測と検証

Store の `onUnhandledError` observer は、operation から漏れた `CancellationError` 以外の
エラーを報告する。composition root でログや crash reporting に接続する。
業務エラーの回復と表示は operation 内で完結させる。
observer がない場合は Debug で assertion が発生し、Release では通知しない。

テストでは ViewModel の状態や domain event により業務結果を確認する。
`awaitCompletion(of:)` / `waitForIdle()` は、キャンセル済みの task も含む実終了の確認に使う。
CI は root package と prototype の Debug・Release・Thread Sanitizer、strict concurrency、
iOS Simulator 向けビルドを検査する。

大量の開始や照会は [性能特性](performance.md) の測定方法で確認する。
処理件数、ActionID の分布、キャンセル後に残る operation の数を実アプリに合わせる。

## ツールチェーンと配布

公開依存には必要な API を含む SemVer tag を指定する。開発中の checkout を使う方法は
[README](../README.md#導入) を参照する。
公開担当者は [リリース設計と運用](releasing.md) のprepare・check・publish手順を使う。

パッケージは default actor isolation と `NonisolatedNonsendingByDefault` を有効にしていない。
コンパイラ設定を変える際には、Slot の nonisolated async operation がどの executor で動くかを
検証する。呼び出し元の隔離を継承する設定は、Slot への意図しない直列化につながり得る。
`@concurrent` などの指定は Swift tools の対応範囲と合わせて評価する。
