# ADR-0012: Store の追跡と所有を独立した状態として扱う

## 前提

Store はキャンセル時に run を重複判定から外す一方、operation の実終了を待つ必要がある。
追跡と所有にはそれぞれ異なる終了時点がある。

## 決定

- 追跡索引 `ActionRuns` は ActionID・ActionRunID・lifetime を持つ。
- 所有台帳 `OwnedTasks` はすべての未終了 task のハンドルと所有 marker を持つ。
- start は両方に登録する。cancel は追跡のみ解除し、handle にキャンセルを要求する。
- 完了は該当 run を両方から除去する。キャンセル時の handle の移動は不要である。
- `awaitCompletion(of:)` は ActionID と ActionRunID が一致する1つの所有 run を待つ。
  完了済みや、その Store が所有しない run なら即座に戻る。
- `waitForIdle()` は所有中の全 task を待つ。待機中に開始された run も対象にする。

## 理由と制約

追跡索引の問い合わせに「キャンセル済みか」という分岐を持たせず、重複判定と終了待ちを
独立させる。`isRunning == false` と、完了待ちが suspend している状態は両立する。

所有台帳はキャンセルに協調しない operation も終了まで保持する。
受付を閉じるには [ADR-0014](0014-store-terminal-close.md) の API を使う。
close は新規 run を止めるが、未終了の operation を強制的に終わらせることはできない。

待機する側のキャンセルは run をキャンセルせず、待機を中断しない。
自己待機は Slot と同じく、Debug の assertion と Release の所有文脈の除外で扱う。
終了待ちは task の終了を表し、業務結果の正しさは ViewModel / domain の状態で検証する。
