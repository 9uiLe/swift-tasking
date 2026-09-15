# ADR-0002: CancellationContext で協調の契約を明示する

## 前提

Swift のキャンセルは協調的である。要求を受けた task が終了するには、operation が
キャンセルを確認するか、キャンセルに反応する API を呼ぶ必要がある。
この責任を、メソッドの引数から読めるようにする。

## 決定

`CancellationContext` は `Task.isCancelled` と `Task.checkCancellation()` を公開する
`Sendable` な値型とする。Store・Runner・Slot は operation にこの値を渡す。
利用側の ViewModel / service メソッドも必要な箇所で受け取る。

`init()` は公開する。SwiftUI `.task` など、Tasking が task を作らない入口でも
`CancellationContext()` を明示的に渡せる。

## 理由と制約

`func save(cancellation: CancellationContext)` は、保存処理がキャンセルに協調する
契約を表す。実装では長い処理の前後や重要な suspension の後で確認する。
引数を受け取るだけではキャンセル対応は完了せず、確認箇所はレビューとテストで検証する。

この値は task の識別子やキャンセルトークンを保存しない。毎回、**現在実行している task** の
状態を読む。値を別の `Task {}` に渡しても、元の task のキャンセルは伝播しない。
operation 内での並行処理には構造化子 task を使う。

throwing なメソッドは `check()`、non-throwing なメソッドは `isCancelled` で終了を判断できる。
どちらも loading や途中状態の後始末を行う。optional な context による検査漏れを避けるため、
キャンセル協調を契約にするメソッドは non-optional な引数を受け取る。
