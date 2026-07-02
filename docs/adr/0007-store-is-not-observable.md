# ADR-0007: ViewTaskStore / ActionRunner は Observable にしない

- ステータス: 実装済み(根拠はコードから復元 — 作者確認待ち)
- 日付: 2026-07-03

## 文脈

`isRunning(id:)` / `runningCount(for:)` は存在するが、両クラスは `@Observable`
でも `ObservableObject` でもないため、SwiftUI view の body でこれらを読んでも
値の変化で再描画は起きない。つまり「実行中はスピナーを出す」という定番 UI を
store 直結では書けない。競合(Verge の isRunning binding、async-task の
@Published state)はここを主要機能として提供している。

## 決定

観測可能にしない。ローディング・進捗・結果・エラーの表示状態は ViewModel が
自身の state として持つ(ADR-0003 と同じ責務配置)。`isRunning` 系 API は
ポリシー判定・テスト・デバッグ用の同期クエリと位置づける。

## 根拠

- 「実行中かどうか」と「スピナーを出すべきか」は一致しない(楽観的 UI、
  最短表示時間、多段階の進捗など)。表示状態は業務判断を含むため ViewModel の
  責務であり、store が isRunning を公開して view が直結すると、その判断の
  置き場が失われる。
- Observation を持ち込むと iOS 17+(@Observable)か Combine 依存
  (ObservableObject)の二択になり、iOS 13+ ゼロ依存という支持基盤と衝突する。

## 代償

- 採用時の第一印象で不利。「スピナーすら自分で書くのか」は正当な不満で、
  競合はここを無料にしている。
- `isRunning` API の存在自体が「view から使えそう」に見えるため、
  再描画されない罠として機能しうる。docs での注意喚起が必須。

## 未解決の問い

- `isRunning` 系の doc コメントに「SwiftUI の再描画は駆動しない」と明記するか
  (実装変更なしで足せる最小の緩和策)。
- ViewModel 側の定番実装(state enum + start/finish で遷移)を README の
  例に含め、「スピナーはこう書く」への公式回答を用意するか。
