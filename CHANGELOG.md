# 変更履歴

各リリースの API に関する変更を記録します。
設計全体と利用時の契約は [ドキュメントガイド](docs/README.md) を参照してください。

## [Unreleased]

### 変更

- **破壊的変更:** `CancellationContext` を削除。Store・Runner・Slot の処理本体は引数なしにし、
  標準の `Task.checkCancellation()` / `Task.isCancelled` を使う。利用側の async メソッドからキャンセル引数を除く。
- **破壊的変更:** `ActionLifetime` と組込みの寿命ラベルを削除し、任意の文字列を持つ `CancellationGroup` へ変更。
  通常は寿命の所有者ごとに Store を保持し、終了イベントから `cancelAll()` を呼ぶ。
  部分集合のキャンセルが必要な場合だけ `lifetime:` を `group:` に移し、独自のグループを宣言する。
- **破壊的変更:** Store の既定 `.ignoreNew` はキャンセル済みも含む同じ ActionID の未終了処理を拒否する。
  拒否理由の `.alreadyRunning` は `.unfinished` へ変更。旧処理の実終了を待たず差し替える必要があれば `.cancelExisting` を明示する。
- **破壊的変更:** 追跡照会の `isRunning` / `runningCount` を `isTracked` / `trackedCount` へ変更。
  Runner の照会は `isTracked(id:)` を使う。Store にはキャンセル済みも含む `unfinishedCount`、
  `unfinishedCount(for:)`、`isUnfinished(_:)` を追加し、追跡解除と実終了を区別する。
- **破壊的変更:** `ActionRunner.run(id:policy:operation:)` は呼び出し元のタスクで実行する `async rethrows -> Success?` に変更。
  スキップは外側の `nil`、受理した戻り値は `.some(value)`、エラーと `CancellationError` は元の型のまま送出する。
  `ActionDescriptor`・`ActionOutcome`・`ActionSkipReason`・`ActionFailure`・`onStart` を削除。
  Runner の結果 switch を Optional の受付判定と通常の `do` / `catch` へ置き換える。成功値の `Sendable` 制約は不要となる。
  非推奨だった `ActionDuplicatePolicy.rejectWhileRunning` も削除したため、`.ignoreNew` を使う。
- **破壊的変更:** Store の `onUnhandledError` は `ActionFailure` の代わりに元の `any Error` を渡す。
  診断側は必要に応じて元のエラー型や `String(describing:)` を使う。
- 検索例は標準 `.task(id:)` と入力のデバウンスを使い、検索計算を専用 actor に分離。
  課金情報の例は通常の async と状態ガードを使う。画面を越える同期と同期イベントの所有で Store の用途を示す。
- 標準の手書き所有器・状態ガードとの Release 比較、受付から開始までの遅延、キャンセル後の未終了件数、
  MainActor の同期受付時間を測定する。`Benchmarks/record.py` で独立プロセスの結果と最大 RSS を保存できる。
- 現行の契約・設計根拠・運用を正式文書へ統合し、個別の設計判断記録を削除。
  変更固有の経緯は Git 履歴、現在の設計はアーキテクチャと各責務の文書で確認できる。

## [0.4.0] - 2026-09-16

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

[Unreleased]: https://github.com/9uiLe/swift-tasking/compare/0.4.0...HEAD
[0.4.0]: https://github.com/9uiLe/swift-tasking/compare/0.3.0...0.4.0
[0.3.0]: https://github.com/9uiLe/swift-tasking/releases/tag/0.3.0
