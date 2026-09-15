# ADR-0010: 非 UI の置換可能な task を TaskSlot が所有する

## 前提

service actor が要求をまとめたり最新の内容を同期したりする場合、メソッドの終了後も
継続する task を所有する必要がある。UI の lifetime や MainActor はその処理の概念ではない。

## 決定

`TaskingCore` product に `TaskSlot` actor と `CancellationContext` を置く。
`Tasking` は TaskingCore に依存し、同じ CancellationContext を public typealias として公開する。

Slot は最大1つの active task を持ち、`replace` で active task にキャンセルを要求して
新しい task を開始する。置換・キャンセル済みの task も実終了まで所有する。
`waitForIdle()` はその全体を待つ。受付停止の契約は [ADR-0011](0011-task-slot-close-and-self-wait.md) に定める。

operation は non-throwing とする。priority は `Task` に転送し、`nil` では呼び出し元の優先度を継承する。
業務エラー、retry、debounce の時間、flush、結果状態は呼び出し側が管理する。

## 理由と制約

単一の active task という所有規則に限定することで、非 UI の所有者は ActionID や UI lifetime を
学ばずに利用できる。MainActor の Store を非 UI 向けに一般化する必要もない。

active task は最大1つでも、キャンセルに協調するまで複数の operation が並行し得る。
Slot は FIFO や結果の last-write-wins を保証しない。世代管理や副作用の順序は service が決める。
operation が owner を強参照すると解放を妨げるため、参照関係と明示的な終了処理を設計する。
