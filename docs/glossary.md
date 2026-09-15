# 用語集

コード・設計資料・レビューで共有する語彙を定義する。
利用場面から型を選ぶ場合は [用途と設計原則](positioning.md) を参照する。

## 処理と識別子

| 用語 | 定義 |
|---|---|
| task | Swift Concurrency の実行単位。`Task {}` が作る task は unstructured task である |
| operation | Store / Runner / Slot に渡す、実際の処理を記述した async closure |
| Action | 保存・更新・同期など、アプリにとって意味のある処理の種類 |
| `ActionID` | Action の安定した識別子。例: `"settings.save"`。同じ Store / Runner 内の重複判定単位 |
| `ActionRunID` | 1回の実行を識別する UUID ベースの値 |
| `ActionRun` | ActionID と ActionRunID の組で表す、1回の具体的な実行 |
| `ActionDescriptor` | Runner に渡す ActionID と重複方針の組 |

同じ ActionID の複数の run は並行し得る。具体的な run の照会・キャンセル・終了待ちには
ActionID と ActionRunID の両方が一致する `ActionRun` を使う。

## 追跡・所有・終了

### 追跡（tracking）

Action を重複判定と照会の対象として登録すること。
`isRunning` / `runningCount` は、その呼び出し時点の追跡状態を返す。
Store は cancel 時に追跡を即座に解除する。Runner は run の最終結果が決まるまで追跡する。
追跡状態は SwiftUI の再描画を駆動する観測可能な状態ではない。

### 所有（ownership）

unstructured task のハンドルを保持し、キャンセル要求と終了確認の責任を持つこと。
Store / Slot は作成した task を終了まで所有する。キャンセルや置換だけでは所有を解除しない。
Runner は呼び出し元の task を使い、その task を所有しない。

### 実終了（termination）

operation と、その task 内の後始末が終わること。
キャンセル要求は実終了を保証せず、追跡から外れた operation も実行を続け得る。
Store の `awaitCompletion(of:)` は1 run、Store / Slot の `waitForIdle()` は所有中の全 task を待つ。

### active task

Slot が次の `replace` / `cancel` の対象にする最大1つの task。
active でなくなった task も、終了するまでは所有中である。

### 受付（admission）と close

受付は、新しい start / replace を受理すること。`close()` は受付を恒久的に停止する。
close は冪等であり、所有中の task はキャンセルしない。
`cancelAndWaitForIdle()` は受付停止とキャンセルを最初の suspension より前に行う。

## 寿命とキャンセル

### `ActionLifetime`

Store における論理的な寿命のラベル。`.screenBound` / `.sceneBound` / `.appBound` と
任意の文字列を使える。照会と一括キャンセルの選択に使い、Store の寿命や OS の実行権限を変えない。
ライフサイクルへの接続と Store の配置は利用側が行う。

### 協調的キャンセル

キャンセル要求を受けた operation 自身が終了に協力する方式。
Swift の `cancel()` はキャンセル状態を設定し、キャンセルハンドラを呼ぶ。
operation の強制停止や副作用の巻き戻しは行わない。

### `CancellationContext`

キャンセルに協調する契約を引数として表す値。
`isCancelled` / `check()` は、アクセスした時点で実行中の task のキャンセル状態を読む。
元の task の状態を保存するトークンではなく、別の unstructured task へキャンセルを伝播しない。

### 所有文脈（ownership context）

内部の TaskLocal に保持する `TaskOwnership` marker の集合。
構造化子 task へも継承され、自分の終了を待つ誤用の検出に使う。
キャンセル状態とは別の情報であり、任意の task 間の依存関係を表すものではない。

## 重複方針

| 型 | 値 | 同じ ActionID の追跡中 run があるときの動作 |
|---|---|---|
| `TaskStartPolicy` | `.ignoreNew` | 新規要求を拒否する（既定） |
| | `.cancelExisting` | 追跡中 run をキャンセルし、新規要求を開始する |
| | `.allowConcurrent` | 新規要求も受け付ける |
| `ActionDuplicatePolicy` | `.ignoreNew` | 新規要求を拒否する（既定） |
| | `.allowConcurrent` | 新規要求も受け付ける |

Runner は task を所有しないため、キャンセルによる置換方針を持たない。
Store の `.ignoreNew` は、手動キャンセルで追跡から外れた run を重複として扱わない。

## 返り値

| 型 | 内容 |
|---|---|
| `TaskStartOutcome` | Store の受付結果。`.started(ActionRun)` または `.skipped(TaskStartSkipReason)` |
| `TaskStartSkipReason` | `.alreadyRunning` / `.closed` |
| `ActionOutcome<Success>` | Runner の最終結果。`.succeeded(Success)` / `.cancelled` / `.skipped(ActionSkipReason)` / `.failed(ActionFailure)` |
| `ActionSkipReason` | `.alreadyRunning` |
| `ActionFailure` | エラーの型名とメッセージを文字列で保持する比較可能な値 |

Runner の `.cancelled` は operation が `CancellationError` を投げたことを表す。
キャンセル要求の有無だけでは outcome は決まらず、operation が値を返せば `.succeeded` になる。
`ActionFailure` の文字列はログ・計測向けであり、業務分岐用の安定したエラーコードではない。
