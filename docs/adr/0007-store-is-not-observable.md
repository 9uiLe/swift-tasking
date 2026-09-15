# ADR-0007: 追跡状態と観測可能な UI 状態を分ける

## 前提

「重複判定の対象か」と「loading を表示するか」は異なる判断である。
キャンセルした task が終了前でも、追跡からは外れる。UI には進捗、直前の結果、
エラー、楽観的更新などの業務状態も必要になる。

## 決定

Store / Runner は `Observable` / `ObservableObject` にしない。
`isRunning` / `runningCount` は、その呼び出し時点の追跡状態を返す同期照会とする。
UI の表示は ViewModel の観測可能な状態から行う。

## 理由と制約

表示の判断を ViewModel に置くことで、task の追跡に依存せず状態遷移を定義できる。
Tasking 自体は Observation / Combine に依存せず、UI フレームワークから独立した実装を保つ。

SwiftUI の `body` で `isRunning` を読んでも、その値の変化による再描画は起きない。
ViewModel は開始・成功・失敗・キャンセルの各経路を扱う必要がある。
run が重なり得る場合は、古い結果や後始末による上書きを世代で制御する。
[利用レシピ](../recipes.md) に実装例を示す。
