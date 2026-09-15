# ADR-0009: キャンセル時に重複判定の対象から外す

## 前提

Swift のキャンセル要求は operation の停止時点を確定しない。
Store には、要求を受け付けるための追跡状態と、終了を待つための所有状態がある。

## 決定

Store の `cancel(run)` / `cancel(id:)` / `cancel(lifetime:)` は対象 run の追跡を即座に解除し、
task にキャンセルを要求する。`cancelAll()` は追跡を空にし、所有中のすべての task をキャンセルする。
ハンドルは各 task の終了まで所有する。

重複方針と `isRunning` / `runningCount` は追跡状態だけを見る。
`.ignoreNew` は追跡中の同じ ActionID があると新しい要求を拒否する。

## 理由と制約

キャンセルした run を新しい要求の受付判断から外せる。
キャンセル済み run を終了まで重複扱いにする設計では、協調しない operation が次の要求を
無期限に妨げる。Tasking は終了確認を明示的な完了待ち API に分ける。

手動キャンセル直後の `.ignoreNew` は、古い operation が残っていても新しい要求を受け付ける。
`.cancelExisting` も古い operation の終了前に開始できるため、直列実行や副作用の順序は保証しない。
結果の選択と後始末は利用側が世代 ID や domain の規則で制御する。

追跡解除後の完了待ちは [ADR-0012](0012-store-tracking-and-ownership.md)、
内部の索引と台帳は [ADR-0013](0013-ownership-and-tracking-registries.md) に定める。
