# 変更履歴

各リリースの API に関する変更を記録します。
設計全体と利用時の契約は [ドキュメントガイド](docs/README.md) を参照してください。

## [Unreleased]

### 追加

- 所有者の認証によるリリースコマンドを追加。バージョン付き文書の準備、ソースコミットと CI の検証、
  注釈付きタグと変更不能な GitHub Release の公開に対応。
- `ViewTaskStore.close()` は、受け付け済みの処理をキャンセルせずに、受付を終端状態へ移す。
- `ViewTaskStore.cancelAndWaitForIdle()` は受付を閉じ、キャンセルを要求して、所有するすべてのタスクの終了を待つ。
- `Benchmarks/` の独立した Release ベンチマークで操作コストを測定し、分離したソースのスナップショットを比較できる。
  [性能特性](https://github.com/9uiLe/swift-tasking/blob/master/docs/performance.md) に負荷条件・ソースの識別情報・時間・メモリを記録。
- README・コントリビューションガイド・セキュリティポリシーに英語版を用意。

### 変更

- **破壊的変更:** Store の受付結果に `TaskStartSkipReason` を使い、`.alreadyRunning` と `.closed` を返す。
  `TaskStartOutcome.skipReason` に明示した `ActionSkipReason` 型は `TaskStartSkipReason` に置き換える必要がある。
  Store の結果を網羅する switch には `.closed` を追加する。Runner の結果は `ActionSkipReason.alreadyRunning` を使う。
- プロトタイプの `BillingViewModel.refresh()` は型付きの結果を返す。ViewModel は、その状態が必要なスコープで所有する。
- リポジトリの文書とコメントの第一言語を日本語に統一。リリースの準備・公開時は日本語・英語両 README の依存バージョンを照合する。

### 修正

- 個別の実行の照会・キャンセル・完了待ちは、ActionID と ActionRunID の両方の一致を要求する。
  ActionID が異なる実行の指定は影響を与えない。
- プロトタイプの結果反映と後処理は実行の世代に従う。キャンセル時は読み込み状態を復元し、
  業務上の失敗は機能ごとの処理内部で扱う。

## [0.3.0] - 2026-07-15

### 追加

- 受付の閉鎖と終了待ちのため、`TaskSlot.close()` と `cancelAndWaitForIdle()` を追加。
- タスクの実際の終了を待つ `ViewTaskStore.awaitCompletion(of:)` と `waitForIdle()` を追加。
- Release ビルドでも処理の外へ漏れたエラーを報告する `ViewTaskStore(onUnhandledError:)` を追加。

### 変更

- `TaskSlot.replace` は `@discardableResult Bool` を返す。`false` は Slot の受付が閉じていることを表す。
- `ViewTaskStore` はキャンセル済みタスクのハンドルも終了まで所有する。
  キャンセル時は `isRunning` と `runningCount` が照会する追跡から実行を直ちに除く。
- 両方の重複ポリシー型で `.ignoreNew` を使い、同じ Action ID の実行を追跡中なら要求をスキップする。
- `ActionRunner.run` の同期コールバック `onStart` を `@MainActor` として宣言。

### 非推奨

- `ActionDuplicatePolicy.rejectWhileRunning` は `.ignoreNew` の非推奨エイリアス。
  値の構築と網羅的な switch には `.ignoreNew` を使う。静的なエイリアスは enum の網羅性検査に参加しない。

[Unreleased]: https://github.com/9uiLe/swift-tasking/compare/0.3.0...HEAD
[0.3.0]: https://github.com/9uiLe/swift-tasking/releases/tag/0.3.0
