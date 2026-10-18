# 用語集

本文では `ViewTaskStore` を Store、`ActionRunner` を Runner、`TaskSlot` を Slot と略記する。

## 処理と識別子

| 用語 | 意味 |
|---|---|
| タスク（task） | Swift Concurrency の実行単位。`Task {}` は非構造化タスクを作る |
| 処理本体（operation） | Store・Runner・Slot に渡す async クロージャ |
| Action | 保存・更新・同期など、意味のある処理の種類 |
| `ActionID` | Action の種類を表す安定した文字列の識別子。例: `"settings.save"` |
| 実行（run） | Action の1回の呼び出し。同じ Action に複数の実行が存在できる |
| `ActionRunID` | Store の1回の実行を識別する UUID に基づく値 |
| `ActionRun` | `ActionID` と `ActionRunID` の組。Store の個別実行の照会・キャンセル・終了待ちに使う |

ActionID の受付単位は、同じ Store または Runner の中で共有される。
個別の実行を指定する操作は ActionID と ActionRunID の両方の一致を要求する。
Runner は個別の ActionRun を作らず、ID ごとの実行数を保持する。

## 管理する状態

| 用語 | 意味 |
|---|---|
| 受付（admission） | 新しい処理を開始できること。Store の `start` と Slot の `replace` が入口 |
| 追跡（tracking） | Store では選択キャンセルと照会の対象として登録された状態。キャンセル時に直ちに解除される |
| 所有（ownership） | タスクのハンドルを保持し、キャンセル要求と実終了の確認に責任を持つこと |
| 未終了（unfinished） | Store / Slot が所有を続けている状態。キャンセル済みの処理も含む |
| アクティブなタスク（active task） | Slot が次の差し替えやキャンセルの対象にする最大1つのタスク |
| 実終了（termination） | 処理本体と、そのタスク内の後処理が終わること |

Store と Slot は作成したタスクを実終了まで所有する。キャンセル要求や追跡解除だけでは実終了しない。
Runner は呼び出し元のタスクを使い、タスクのハンドルを所有しない。Runner の追跡は、処理本体を実行している件数を表す。
`close()` は受付を恒久的に閉じる。既存の処理は継続し、再開には新しい Store / Slot を用意する。

## キャンセルと状態更新

| 用語 | 意味 |
|---|---|
| キャンセルグループ（`CancellationGroup`） | 同じ Store 内の追跡中の実行を一括選択する任意の文字列ラベル。寿命を制御しない |
| 協調キャンセル | 要求を受けた処理自身がキャンセル状態の確認や対応 API を通じて終了する方式 |
| 所有文脈（ownership context） | 自己待機の検出に使う内部 TaskLocal の所有識別子。構造化子タスクにも継承される |
| 世代ガード | 利用側の識別子で、どの実行の結果・エラー・後処理を状態に採用するか決める規則 |
| デバウンス | 入力が一定時間変わらない場合に処理を始めることで、途中の要求をまとめる方法 |

標準の `Task.checkCancellation()` / `Task.isCancelled` は、呼び出した時点で実行中のタスクの状態を読む。
キャンセルは強制停止や副作用の巻き戻しではない。別の非構造化 Task を作ってもキャンセルの親子関係は生まれない。
所有文脈は、任意のタスク間の依存関係を表すものではない。

## 方針と結果

| 型 | 値と契約 |
|---|---|
| `TaskStartPolicy` | `.ignoreNew`（同じ ID の未終了処理があれば拒否）、`.cancelExisting`（追跡中をキャンセルして即開始）、`.allowConcurrent`（追加開始） |
| `TaskStartOutcome` | Store の受付結果。`.started(ActionRun)` または `.skipped(TaskStartSkipReason)` |
| `TaskStartSkipReason` | `.unfinished`（同じ ID に未終了処理あり）、`.closed`（受付閉鎖済み） |
| `ActionDuplicatePolicy` | Runner の `.ignoreNew`（同じ ID を追跡中なら拒否）と `.allowConcurrent` |
| Runner の `Success?` | 外側の `nil` は拒否、`.some(value)` は受理後の戻り値。成功値自体の `nil` は `.some(nil)` |

Runner は業務エラーも `CancellationError` も変換せず送出する。
返却値・キャンセル・業務状態の契約は [アーキテクチャ](architecture.md) に定める。
