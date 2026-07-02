# 大規模導入ガイド

大規模・複数チームのアプリへ Tasking を導入するときの運用ルール。
Tasking は小さなライブラリだが、ActionID と store の所有位置はアプリ全体の
運用規律に触れるため、チーム横断の合意を先に置く。

## リリースと CI

- public release は SemVer tag を必ず切る。README の
  `.package(url: ..., from: "0.1.0")` は `0.1.0` tag が存在して初めて動く。
- CI は root package と `Examples/TaskingPrototype` の debug / release / Thread Sanitizer
  テストを通す。README の「strict data-race checking は public quality bar」という宣言は、
  CI が守る。
- Swift Package Index 掲載は GitHub 上の repository rename と `0.1.0` tag 作成後に確認する。

## Swift 5 言語モードの消費側はサポート境界外

Tasking 自体は Swift 6 language mode でビルドする。ただし、SwiftPM の依存として
Swift 5 language mode の feature module から import できる場合がある。

その場合でも、operation クロージャ内の capture は**消費側 target の言語モード**で検査される。
Swift 5 target では非 Sendable object を捕捉しても警告なしに通ることがあり、Tasking が
期待する strict concurrency の規律は静かに弱まる。

導入ルール:

- Tasking を使う feature module は Swift 6 language mode に上げる。
- 移行中で Swift 5 module から使う場合は、strict concurrency の compile-time 保証はないものとして扱う。
- Swift 5 module では、ViewModel / service capture の Sendable 性をレビューで明示確認する。

## ActionID ガバナンス

ActionID は文字列なので、複数チームで共有 store を使うと衝突をコンパイラが防げない。
たとえば 2 チームが同じ app-bound store に `"sync"` を登録すると、片方の `.ignoreNew` が
もう片方の処理を黙って skip し得る。

導入ルール:

- 原則として store は feature / screen / app-level concern ごとに分ける。
- app-bound 共有 store は、アプリ横断で本当に同じ寿命とキャンセル方針を持つ Action だけに使う。
- 共有 store の ActionID は `feature.action` 形式を必須にする。
- entity ごとの ActionID は `feature.action.<entity-id>` の形にする。
- ActionID と duplicate policy は feature 内の 1 か所へ寄せる。

例:

```swift
enum BillingAction {
    static let refreshPlans: ActionID = "billing.refreshPlans"
    static let refreshPlansPolicy: TaskStartPolicy = .ignoreNew

    static func downloadInvoice(_ id: Invoice.ID) -> ActionID {
        ActionID("billing.downloadInvoice.\(id)")
    }
}
```

## `.appBound` は background execution を保証しない

`.appBound` は「store をアプリ寿命のコンテナが所有する」という Tasking 内の寿命宣言であり、
iOS / watchOS / tvOS の background execution 権限を得るものではない。

アプリが background suspend されれば、`.appBound` の task も進行できない。画面を閉じても
継続したいだけなら `.appBound` でよいが、background でも完遂が必要な処理はアプリ側で
適切な OS API を使う。

- 短時間の猶予: `beginBackgroundTask`
- スケジュール実行: `BGTaskScheduler` / `BGProcessingTask`
- 転送継続: background `URLSession`

Tasking はそれらの代替ではない。使う場合も、Tasking は「どの Action か」「どの lifetime か」
「どの duplicate policy か」を見えるようにする役割に留める。

## テストと観測性の現状

0.1.0 の `ViewTaskStore.start` は完了待ち API を持たない。利用側テストで完了の事実を待つ場合は、
ViewModel state、明示的な test gate、または domain event を待つ。`isRunning` のポーリングは
tracking query に過ぎず、UI state や business completion の代用にしない。

横断的な analytics / `os_signpost` / telemetry hook も 0.1.0 にはない。必要な場合は feature 側で
operation をラップする。

## 0.2 系ロードマップ候補

- `ViewTaskStore` の完了待ち API: `awaitCompletion(of:)` / `settle()` など。
- 観測専用 event hook: start / finish / cancel / skip を analytics や signpost に流す。
- release build の未処理エラー観測: ADR-0003 の `onUnhandledError` 系。
- `ActionOutcome` の便宜プロパティ: `isSucceeded` / `isCancelled` / `failure` など。
- 追跡中 run の debug listing / `CustomDebugStringConvertible`。
- task naming(SE-0469)や task-local への `ActionRun` 注入による Instruments / crash log の照合。
