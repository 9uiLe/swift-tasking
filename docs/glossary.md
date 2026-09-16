# 用語集

Tasking のコード・文書・テストで使う用語を定義する。
本文では `ViewTaskStore` を Store、`ActionRunner` を Runner、`TaskSlot` を Slot と略記する。

## 処理と識別子

| 用語 | 意味 |
|---|---|
| タスク（task） | Swift Concurrency の実行単位。`Task {}` は非構造化タスクを作る |
| 処理本体（operation） | Store・Runner・Slot に渡す async クロージャ |
| Action | 保存・更新・同期など、アプリケーションにとって意味のある処理の種類 |
| `ActionID` | Action の種類を表す安定した識別子。例: `"settings.save"` |
| 実行（run） | Action を1回呼び出したもの。同じ Action の実行は複数存在できる |
| `ActionRunID` | 1回の実行を識別する UUID に基づく値 |
| `ActionRun` | `ActionID` と `ActionRunID` の組。個別の実行の照会・キャンセル・終了待ちに使う |
| `ActionDescriptor` | Runner に渡す `ActionID` と重複方針の組 |

ActionID による重複判定は、同じ Store または Runner の中で行う。
個別の実行を指定する操作では、ActionID と ActionRunID の両方が一致する必要がある。

## 受付・追跡・所有

### 受付（admission）

新しい処理の開始を受理すること。Store の `start` と Slot の `replace` が入口となる。
`close()` は受付を恒久的に閉じ、受け付け済みの処理をそのまま継続させる。
繰り返し閉じても結果は変わらず、再開には新しいインスタンスを使う。

### 追跡（tracking）

実行を重複判定と照会の対象として登録すること。
Store はキャンセル要求または処理の終了時に、Runner は終了結果を返す際に追跡を解除する。
`isRunning` と `runningCount` は、呼び出した時点の追跡状態を返す。

### 所有（ownership）

タスクのハンドルを保持し、キャンセル要求と終了確認に責任を持つこと。
Store と Slot は作成したタスクを終了まで所有する。キャンセルや差し替えだけでは所有を解除しない。
Runner は呼び出し元のタスクを使い、そのタスクを所有しない。

### アクティブなタスク（active task）

Slot が次の `replace` または `cancel` の対象にする、最大1つのタスク。
差し替えやキャンセルでアクティブでなくなったタスクも、終了までは所有される。

### 実終了（termination）

処理本体と、そのタスク内の後処理が終わること。
キャンセル要求や追跡解除から実終了までは、処理が続く場合がある。
Store の `awaitCompletion(of:)` は指定した実行、Store と Slot の `waitForIdle()` は所有するタスクの終了を待つ。

## 寿命とキャンセル

### 寿命ラベル（`ActionLifetime`）

Store 内の実行を、照会や一括キャンセルの対象として選ぶための値。
`.screenBound`・`.sceneBound`・`.appBound` と任意の文字列を使える。
ラベルに対応する所有者の配置とライフサイクルイベントへの接続は、アプリケーションが行う。

### 協調キャンセル

要求を受けた処理自身が、キャンセル状態の確認や対応する API を通じて終了に協力する方式。
Swift の `Task.cancel()` はキャンセル状態を設定し、登録されたキャンセルハンドラを呼ぶ。
処理の強制停止や副作用の巻き戻しは行わない。

### キャンセルの契約（`CancellationContext`）

処理がキャンセルに協調する責任を、引数として明示する値。
`isCancelled` と `check()` は、アクセスした時点で実行中のタスクの状態を読む。
値の作成元のタスクを記憶せず、別の非構造化タスクへのキャンセル伝播も行わない。

### 所有文脈（ownership context）

自己待機を検出するため、内部の TaskLocal に保持する所有識別子の集合。
各識別子は `TaskOwnership` のインスタンスで、構造化子タスクにも継承される。
キャンセル状態や、任意のタスク間の依存関係を表す値ではない。

### 世代ガード

どの実行の結果や後処理を状態へ反映するかを、利用側の識別子で判定すること。
新しい検索が始まった後に古い検索が完了しても、表示を上書きしないために使う。
キャンセル要求とは独立した、アプリケーションの状態更新規則である。

## 重複方針

| 型 | 値 | 同じ ActionID の実行を追跡中の場合 |
|---|---|---|
| `TaskStartPolicy` | `.ignoreNew` | 新しい要求をスキップする（既定値） |
| | `.cancelExisting` | 追跡中の実行にキャンセルを要求して追跡から外し、新しい要求を開始する |
| | `.allowConcurrent` | 追加の実行を開始する |
| `ActionDuplicatePolicy` | `.ignoreNew` | 新しい要求をスキップする（既定値） |
| | `.allowConcurrent` | 追加の実行を開始する |

Runner はタスクを所有しないため、キャンセルによる差し替えは行わない。
Store の手動キャンセル後は、未終了の実行が残っていても `.ignoreNew` が新しい要求を受け付ける。

## 受付結果と終了結果

| 型 | 値と用途 |
|---|---|
| `TaskStartOutcome` | Store の受付結果。`.started(ActionRun)` または `.skipped(TaskStartSkipReason)` |
| `TaskStartSkipReason` | Store が開始を拒否した理由。`.alreadyRunning` または `.closed` |
| `ActionOutcome<Success>` | Runner の終了結果。`.succeeded(Success)`・`.cancelled`・`.skipped(ActionSkipReason)`・`.failed(ActionFailure)` |
| `ActionSkipReason` | Runner が実行を拒否した理由。`.alreadyRunning` |
| `ActionFailure` | エラー型名とメッセージの文字列を持つ、等価比較可能な `Sendable` の値 |

Runner は `CancellationError` の送出を `.cancelled` に変換する。
値が返された場合は、キャンセル要求の有無にかかわらず `.succeeded` になる。
`ActionFailure` は報告用の値であり、文字列を業務分岐の安定したエラーコードとして使わない。
