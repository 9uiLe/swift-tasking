# ADR-0011: TaskSlot の受付停止・終了待ち・自己待機の契約を定める

## 前提

actor は suspension 中に再入できる。`cancel()` と `waitForIdle()` だけでは、待機中の
`replace` が新しい work を受け付ける。所有者の終了には、新規受付を止める操作が必要になる。
また、operation が自分自身の終了を待つと循環待機になる。

## 決定

- `close()` は新規 `replace` を恒久的に拒否する。冪等であり、実行中の task はキャンセルしない。
- 閉じた Slot の `replace` は `false` を返し、operation を実行しない。
- `cancelAndWaitForIdle()` は suspension 前に close と active task の cancel を行い、全所有 task を待つ。
- `waitForIdle()` は置換済みの task と、受付が開いていれば待機中に受け付けた task も待つ。
- 各 operation の TaskLocal に所有 marker の集合を置く。自己待機は Debug で assertion、
  Release では継承した所有文脈に属する task の除外で扱う。

## 理由と制約

受付停止とキャンセルを同じ actor の suspension を含まない区間で行い、終了処理中の新規受付を防ぐ。
`close()` と cancel を分けることで、自然完了を待つ drain も表現できる。
再利用可能なキャンセルには `cancel()`、終端的な終了には `cancelAndWaitForIdle()` を使う。

自己待機はプログラミング上の契約違反であり、通常の制御フローには使わない。
構造化子 task も TaskLocal を継承するため検出対象になる。
検出は任意の task 間の循環待機を解決せず、他の operation の終了も保証しない。

待機する側のキャンセルは所有中の task に伝播せず、待機を中断しない。
operation 内の並行処理には、キャンセルが伝播する `async let` / task group を使う。
`Task {}` は TaskLocal をコピーしてもキャンセルの親子関係を作らないため、operation 内では使用しない。
