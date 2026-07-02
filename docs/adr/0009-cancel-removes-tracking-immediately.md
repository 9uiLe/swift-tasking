# ADR-0009: cancel は追跡を即時解除し、実終了までは追跡し続けない

- ステータス: 確定(プロトタイプ検証 F4/F10 を受けて明文化)
- 日付: 2026-07-03

## 文脈

`ViewTaskStore.cancel(id:)` / `cancel(lifetime:)` は現在、対象 task にキャンセルを要求し、
内部辞書から run を即時に取り除く。したがって `isRunning` / `runningCount` は
「store が追跡中か」を答える同期クエリであり、「処理本体が完全に終了したか」を
保証しない。

プロトタイプ検証で、キャンセルに協調しない処理を `cancel(id:)` した直後に
同じ ActionID を `.ignoreNew` で再開始できることが確認された。これは「追跡中」と
「実行中」のズレであり、`.ignoreNew` が手動キャンセル後のゾンビ run を防ぐ保証には
ならないことを意味する。

代替案として、キャンセル済み run を `cancelling` として実終了まで追跡し続ける設計も
あり得る。この場合、`ignoreNew` はキャンセル済みだが未終了の run も重複として扱える。

## 決定

現行意味論を維持する。`cancel` はキャンセル要求と同時に追跡を即時解除する。
`isRunning` / `runningCount` は「追跡中」の同期クエリであり、実処理の終了判定や
UI state の根拠にはしない。

実処理の終了待ち、キャンセル後に残り得る副作用の破棄、loading state の復旧は
ViewModel 側の state / 世代管理 / domain-level token で扱う。

## 根拠

- Swift のキャンセルは協調的であり、store が task handle を持っていても処理本体を
  強制停止できない。`cancelling` を導入しても、実終了がいつ来るかは operation の
  協調に依存する。
- Tasking の公開思想は「可視化はするが、肩代わりはしない」である。キャンセル後の
  業務 state の整合は ViewModel の責務に残す方が、ADR-0003 / ADR-0007 と一貫する。
- 実終了まで追跡し続けると、`cancel(lifetime:)` 後も `isRunning` が true のまま残るため、
  `isRunning` を UI に直結したくなる誘因が強まる。これは ADR-0007 の責務配置と衝突する。
- 即時解除は API と実装を小さく保ち、`cancelExisting` の「古い run を重複判定から外して
  新 run を開始する」という現行動作と一致する。

## 結果

- `isRunning` / `runningCount` の doc コメント、README、glossary、recipes では
  「tracking query」であることを明記する。
- `.ignoreNew` は「追跡中の同一 ActionID を弾く」方針であり、手動 cancel 後にまだ実行中の
  古い処理を弾くものではない。
- operation は `CancellationContext.check()` を適切に呼び、ViewModel は世代ガードで
  古い run の結果を捨てる。

## 注意

operation が store または store を所有するオブジェクトを強参照すると、
`store -> task -> operation -> store` の一時循環ができ、store の `deinit` による
キャンセル安全網は operation 完了まで発火しない。deinit 安全網に依存する構成では、
operation から store owner を強参照しない。必要な場合は weak capture と明示 cancel を使う。
