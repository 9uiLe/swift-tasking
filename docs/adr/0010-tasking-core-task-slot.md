# ADR-0010: 非 UI task 所有を TaskingCore / TaskSlot に分離する

- ステータス: 実装済み
- 日付: 2026-07-11

## 文脈

`ViewTaskStore` と `ActionRunner` は UI 境界を明確にするため `@MainActor` 固定である。
一方、actor がアプリ寿命の debounce や coalescing を所有する場合も、同期メソッドの
終了後まで work を生かすため unstructured task の明示所有が必要になる。

`ViewTaskStore` を非 UI actor から使うと MainActor hop と UI lifetime 語彙が漏れる。
各アプリが直接 `Task {}` と例外規則を持つと、所有・cancel・終了待ちの意味が分散する。

## 決定

- 非 UI 向けの独立 product / target `TaskingCore` を追加する。
- `CancellationContext` の実体を TaskingCore に置き、既存 Tasking product は
  public typealias で source compatibility を保つ。
- `TaskSlot` actor は1つのactive taskを所有し、基本操作として `replace`、`cancel`、
  `waitForIdle`を公開する。terminal close と race のない teardown は ADR-0011 で追加する。
- `replace`のoptional priorityはSwift Taskへそのまま渡し、nilでは呼び出し元を継承する。
  TaskingCore自身はpriority方針を判断しない。
- replace/cancel済みtaskも実終了まではslotが所有する。`waitForIdle`は置換中に
  生じたtaskを含め、所有taskが0になるまで待つ。
- operationはnon-throwingとし、業務エラー、retry、debounce、flush、結果状態を
  TaskSlotへ持ち込まない。

## 根拠

- UIのTasking契約を一般化せず、Application actorへMainActorを漏らさない。
- task handleをライブラリ内へ隔離し、利用側は所有者をTaskSlotとして読める。
- cooperative cancellationを隠さず、cancel後も動くoperationを終了待ちできる。
- 単一slotに限定することで、ActionID、lifetime、queueなど別の概念を増やさない。

## 代償

- packageに2つ目のproductが増え、非 UI targetはTaskingCoreへ依存する。
- `waitForIdle`はcancelを無視するoperationがあると完了しない。強制停止は提供しない。
- 同じslotが所有するoperation内から`waitForIdle`を呼ぶことは禁止する。ADR-0011 の
  runtime guard は永久待機を防ぐ安全網であり、通常の制御フローには使わない。
- TaskSlotはlast-write-winsの業務結果を保証しない。operationがcancelを検査し、
  feature側が必要なら世代やpending stateを管理する。

## 不採用案

- `ViewTaskStore`の転用: MainActorとUI lifetime語彙が非 UI層へ漏れる。
- actor版ActionRunner: task所有だけでなく重複結果管理まで表面積が広がる。
- `TaskDebouncer`: clock・待機時間・flushをライブラリが肩代わりし、domain固有契約を
  汎用APIへ押し込む。

## Swift 6.2 以降

`NonisolatedNonsendingByDefault` を採用すると nonisolated async operation の実行 isolation が
呼び出し元継承へ変わる。採用時は slot actor への不要な直列化を避けるため、operation 型への
`@concurrent` 付与を同じ変更で評価する。tools 6.0 の現状では先行追加しない。
