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

## 非 UI target は TaskingCore だけへ依存する

Application/service actorがunstructured taskを所有する必要がある場合は、UI向けの
`Tasking`ではなく`TaskingCore` productへ依存し、`TaskSlot`を使う。TaskSlotは
debounce、retry、業務エラー、永続化flushを提供しない。それらはfeature側に残す。

同じslotのoperation内から`waitForIdle`を呼ばない。terminal shutdown では
`cancelAndWaitForIdle()` を使い、新規 admission を閉じてから協調終了を待つ。既存 work を
cancel せず自然完了させる場合は `close()` の後に `waitForIdle()` を呼ぶ。close しない
`waitForIdle()` は待機中の replacement も対象にするため、非終端の観測用途に限る。

## テストと観測性

`ViewTaskStore.awaitCompletion(of:)` は 1 run、`waitForIdle()` は store が所有する全 run の
実終了を待つ。どちらも `isRunning` の tracking 意味論とは独立しており、cancel 済みで
追跡から外れた task も対象にする。業務上の完了は引き続き ViewModel state や domain event
で検証し、これらの API は task ownership の teardown 検証に使う。

`ViewTaskStore(onUnhandledError:)` は operation から漏れた非 cancellation error を release
でも観測する。業務エラーの伝達路にはせず、analytics / logging / crash report の通知点として
使う。start / finish / cancel / skip の汎用 telemetry hook はまだ提供しない。

## Swift 6.2 以降の isolation 移行メモ

この package は tools 6.0、Swift 6 language mode で、default isolation と
`NonisolatedNonsendingByDefault` を有効にしていない。将来その upcoming feature を採用すると、
`TaskSlot` の nonisolated async operation が呼び出し元 isolation を継承する意味論へ変わる。
採用時には operation を slot actor の executor に直列化しないため、operation 型への
`@concurrent` 付与を同じ変更で評価する。現行 toolchain ではコードへ先行追加しない。

## 今後のロードマップ候補

- 観測専用 event hook: start / finish / cancel / skip を analytics や signpost に流す。
- `ActionOutcome` の便宜プロパティ: `isSucceeded` / `isCancelled` / `failure` など。
- 追跡中 run の debug listing / `CustomDebugStringConvertible`。
- task naming(SE-0469)や task-local への `ActionRun` 注入による Instruments / crash log の照合。
