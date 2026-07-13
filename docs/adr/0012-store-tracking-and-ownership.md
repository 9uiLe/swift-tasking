# ADR-0012: ViewTaskStore は tracking と task ownership を別状態で持つ

- ステータス: 実装済み
- 日付: 2026-07-14

## 文脈

ADR-0009 は cancel と同時に run を tracking から外す意味論を確定した。以前の実装は同時に
task handle も破棄していたため、キャンセルに協調しない operation の実終了を store から
観測できず、正しい完了待ち API を構築できなかった。

## 決定

- tracking 中の `tasksByRunID` と、キャンセル済みで実終了待ちの
  `terminatingByRunID` を分ける。
- cancel は suspension のない MainActor 区間で handle を cancel し、tracking index から
  外して terminating ownership へ移す。
- `isRunning`、`runningCount`、duplicate policy は tracking 状態だけを参照する。
- `awaitCompletion(of:)` は 1 run、`waitForIdle()` は tracking と terminating の全 owned run を
  待つ。`waitForIdle()` の待機中に開始された run も対象にする。
- operation の ownership context は TaskLocal で識別し、自己待機は ADR-0011 と同じく
  debug assertion と release の自己除外で有限にする。

## 根拠

同じ辞書へ cancellation flag 付きで残すと、既存の `isRunning(_:)` と lifetime query が
キャンセル済み run を再び「追跡中」と報告し、ADR-0009 を破る。別辞書への move なら公開
tracking 意味論を一切変えず、TaskSlot と同じ「handle は実終了まで所有する」原則を適用できる。

ActionID / lifetime 単位の completion API は、待機中に同じ分類の run が増えた場合の契約を
さらに増やす。0.2 では全体と具体的な ActionRun の 2 粒度に限定する。

## 結果

- `cancel` 直後の `isRunning == false` と、`awaitCompletion` がまだ suspend する状態は両立する。
- terminating entry の上限は、実際に終了していない cancellation-uncooperative operation 数になる。
  これは handle leak を隠すのではなく、所有中の work を可視化する。
- `waitForIdle()` は新規 start が続く限り復帰しない。teardown の admission 停止は利用側 owner が担う。
- business state、結果の世代管理、キャンセル後の副作用破棄は ViewModel / domain の責務に残る。
