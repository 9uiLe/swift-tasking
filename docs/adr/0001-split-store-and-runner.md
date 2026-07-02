# ADR-0001: task を所有する型と実行を制御する型を分離する

- ステータス: 実装済み(根拠はコードと README から復元 — 作者確認待ち)
- 日付: 2026-07-03

## 文脈

「重複実行の制御」と「unstructured task のハンドル所有」は一緒に語られがちだが、
必要になる場所が違う。同期 UI コールバックでは task を作らざるを得ないが、
すでに async 文脈にいる場所(SwiftUI `.task` の中、task group の中)で新たに
unstructured task を作ると、せっかくの構造化文脈(キャンセル伝播・エラー伝播)を
自ら壊すことになる。

## 決定

2 つの型に分離する。

- **ViewTaskStore**: 同期コールバック専用。task を作り、ハンドルを所有し、
  ライフタイムと重複ポリシーを管理する。結果は返さない。
- **ActionRunner**: async 文脈専用。task を**作らない・所有しない・キャンセルしない**。
  重複制御と型付きの最終結果(`ActionOutcome`)だけを提供する。

## 根拠

- ActionRunner が task を作らないことで、呼び出し側の構造化文脈が保たれる。
  周囲の task がキャンセルされれば `CancellationContext.check()` がそれを拾う。
- この分離は API の非対称に現れている:
  - ActionRunner の重複ポリシーに `cancelExisting` 相当が**ない**。
    所有していない task はキャンセルできないから。
  - ViewTaskStore は結果を返さない。同期コールバックは outcome を await
    できないから(結果の伝達路は ViewModel state)。
- 1 つの型に統合すると「task を作るときと作らないときがある store」になり、
  キャンセル所有権がどこにあるか呼び出し箇所から読めなくなる。

## 代償

- 利用者は 2 つの型と使い分けを学ぶ必要がある(早見表を glossary に置いて緩和)。
- 「ボタンから起動して outcome も欲しい」という要求には直接応えられない
  (公式回答: outcome は ViewModel state で表現する)。

## 未解決の問い

- ActionRunner の実用シーンの代表例をもう 1 つ README に足せるか
  (現状 billing.refresh のみ。`.task` 内での pull-to-refresh 重複制御など)。
