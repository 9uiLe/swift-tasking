# ADR-0005: ActionFailure はエラー型を消去する

- ステータス: 実装済み(根拠はコードと README から復元 — 作者確認待ち)
- 日付: 2026-07-03

## 文脈

`ActionRunner.run` は型付きの最終結果 `ActionOutcome<Success>` を返す。
失敗ケースに元の `any Error` をそのまま載せると、`ActionOutcome` を
`Equatable` にできず(テストでの比較が困難)、`Sendable` 保証も
`any Error & Sendable` の制約に引きずられる。

## 決定

失敗は `ActionFailure`(`typeName: String` + `message: String`)に変換して載せる。
元のエラー型は意図的に消去する。

## 根拠

- `ActionOutcome` 全体が `Equatable & Sendable` になり、テストで
  `#expect(outcome == .failed(...))` と書ける。
- エラー種別による**回復・分岐は operation 内(ViewModel 側)で完結すべき**という
  ADR-0003 と同じ規律の適用。outcome の `.failed` はログ・計測・デバッグ用の
  最終報告であり、制御フローの入力ではない。

## 代償

- outcome の受け取り側でエラー型による分岐ができない。「リトライ可能な
  ネットワークエラーだけ自動再試行」のような処理を outcome 起点では書けない
  (operation 内に書く必要がある)。
- `String(reflecting:)` / `String(describing:)` の出力はエラー型の内部表現に
  依存し、安定した機械可読性はない。

## 未解決の問い

- 「outcome は制御フローの入力ではない」という規律を docs で明文化するか
  (現状 README は switch 文の例を載せており、分岐に使えそうに見える)。
