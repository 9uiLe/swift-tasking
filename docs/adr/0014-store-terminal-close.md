# ADR-0014: Store の終了処理で新規開始を先に停止する

## 前提

MainActor は `waitForIdle()` の suspension 中に他の callback を実行できる。
終了処理で新しい task を受け付けないためには、待機前に Store の受付状態を変える必要がある。

## 決定

- `close()` は受付を恒久的に閉じる。冪等であり、所有中の task をキャンセルしない。
- `cancelAndWaitForIdle()` は close と cancelAll を最初の suspension より前に行い、実終了を待つ。
- `cancel` / `cancelAll` は受付を閉じない。
- close 後の start は重複方針の判定前に `.skipped(.closed)` を返し、operation を実行しない。
- Store の拒否理由は `TaskStartSkipReason` の `.alreadyRunning` / `.closed` とする。
  Runner の `ActionSkipReason` は `.alreadyRunning` のみとする。

## 理由と制約

受付状態を Store 自身が持つことで、利用側が各 callback に終了フラグを配る必要がなくなる。
close と cancel を分け、自然完了を待つ `close()` + `waitForIdle()` も表現する。

close 後は再 open しない。再利用には新しい Store を作る。
同じ画面を再表示する場合の `onDisappear` では、対象の lifetime を cancel する。

受付停止は終了対象を確定するための操作であり、operation の強制停止を保証しない。
キャンセルに協調しない operation が残れば、終了待ちも続く。
