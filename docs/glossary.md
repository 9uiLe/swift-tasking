# 用語集(Glossary)

Tasking のドメイン語彙。コード・ドキュメント・レビューコメントでは、ここで定義した
意味でのみ各語を使う(ユビキタス言語)。

## 中核概念

### Action(アクション)
ユーザー操作またはライフサイクルを起点とする、アプリにとって意味のある 1 つの処理。
「保存」「更新」「同期」など。**Task は実装機構であり、Action は業務語彙である**。
このライブラリの API はすべて Task ではなく Action を主語に設計されている。

### ActionID
Action の安定した識別子(`"settings.save"` など)。重複実行の判定単位。
呼び出し箇所に文字列リテラルを書かず、機能ごとの名前空間に定数として宣言する。

### ActionRun / ActionRunID
Action の「1 回の具体的な実行」。同じ ActionID の実行が複数並行し得るため
(`allowConcurrent`)、実行ごとに UUID ベースの ActionRunID で区別する。
ActionID が「何をするか」、ActionRunID が「どの実行か」。

### 追跡中(Tracked) / 実行中(Executing)
Tasking の `isRunning` / `runningCount` が答えるのは「追跡中かどうか」であり、
処理本体が実行中かどうかを OS レベルで保証するものではない。`cancel(id:)` や
`cancel(lifetime:)` はキャンセルを要求したうえで追跡を即時解除するため、
協調しない処理は `isRunning == false` の後も実行を続け得る。

この区別は `.ignoreNew` の理解に重要である(ADR-0009)。手動キャンセル後は追跡が消えるため、
古い処理がまだ実行中でも同じ ActionID の新しい `start(..., policy: .ignoreNew)` は
開始され得る。表示状態や「実処理が残っているか」の判断は ViewModel 側の state /
世代管理で扱う。

### 所有(Ownership)
unstructured task のハンドル(`Task` 値)への参照を保持し、キャンセル・生存確認・
破棄時の後始末に責任を持つこと。構造化並行性では task tree が自動で行うが、
`Task {}` では誰かが明示的に引き受けなければ**所有者不在(fire-and-forget)**になる。
ViewTaskStore はこの所有を引き受ける型。ActionRunner は意図的に所有しない。
非 UI 文脈では TaskingCore の TaskSlot が単一taskの所有を引き受ける。

### ActionLifetime(ライフタイム)
ViewTaskStore が所有する task の「論理的な」生存スコープの宣言。
`.screenBound` / `.sceneBound` / `.appBound` と文字列リテラル拡張。
**宣言であって強制ではない**(ADR-0004)。実際の生存上限は store 自体の寿命で決まる。
`cancel(lifetime:)` の一括キャンセル単位として機能する。

### 重複ポリシー(Duplicate Policy)
同じ ActionID の実行が既に進行中のときに新しい要求をどう扱うかの、呼び出し箇所で
宣言する方針。

| 型 | 値 | 意味 |
|---|---|---|
| `TaskStartPolicy`(ViewTaskStore) | `.ignoreNew` | 既存を維持し新規をスキップ(保存ボタンの二度押し対策の既定) |
| | `.cancelExisting` | 既存にキャンセルを要求してから新規を開始(検索の打ち直し) |
| | `.allowConcurrent` | 同一 ActionID の並行実行を許可・追跡 |
| `ActionDuplicatePolicy`(ActionRunner) | `.rejectWhileRunning` | 実行中は新規を拒否 |
| | `.allowConcurrent` | 並行実行を許可 |

ActionRunner に `cancelExisting` 相当が**存在しない**のは設計による:
task を所有しない型はキャンセルできない(ADR-0001)。

### 協調的キャンセル(Cooperative Cancellation)
Swift のキャンセルは要求であって強制ではない。`cancel()` はフラグを立てるだけで、
実行中の処理が `check()` するか、キャンセル対応 API を呼ばない限り止まらない。
Tasking の全 API ドキュメントはこの前提の上に書かれている。

### CancellationContext
キャンセル協調の責任を ViewModel メソッドの**シグネチャに現す**ための値
(ADR-0002)。機能的には `Task.isCancelled` / `Task.checkCancellation()` の
薄いラッパーであり、能力(capability)を付与するものではない。

### ActionOutcome / ActionFailure / ActionSkipReason
ActionRunner が返す型付きの最終結果。`succeeded / cancelled / skipped / failed`。
ActionFailure はエラーの型名とメッセージの文字列表現で、**元のエラー型を意図的に
消去している**(ADR-0005)。ログ・計測向けであり、エラー種別による分岐・回復は
operation 内(ViewModel 側)で行う。

## 3 つの中核型

### TaskSlot
非 UI actorから起動する置換可能なunstructured taskを所有するTaskingCoreのactor。
replace/cancel済みtaskも実終了までは所有し、`waitForIdle`で全終了を待てる。
ActionID、UI lifetime、業務エラー、キューは扱わない。

### ViewTaskStore
同期 UI コールバック(`Button` action など、`await` できない場所)から作られる
unstructured task のハンドルを所有する `@MainActor` クラス。
ライフタイム・重複ポリシーを呼び出し箇所で宣言させ、`deinit` で全 task を
キャンセルする。結果は返さない(業務エラーは ViewModel state に変換する契約。
ADR-0003)。

### ActionRunner
すでに async 文脈にいるときに、重複制御と型付き結果だけを提供する `@MainActor`
クラス。**task を作らず・所有せず・キャンセルしない**。キャンセルの所有権は
呼び出し側の構造化文脈(SwiftUI `.task`、task group、ViewTaskStore)に残す。

## 使い分けの早見表

| 状況 | 使うもの |
|---|---|
| view の表示に紐づくロード | SwiftUI `.task` / `.task(id:)`(純正を優先) |
| スコープ内で並行処理 | `async let` / task group(構造化を優先) |
| 同期コールバックから起動し、寿命・重複方針を明示したい | `ViewTaskStore.start` |
| async 文脈内で重複制御と型付き結果が欲しい | `ActionRunner.run` |
| 非 UI ownerが同期scope外まで単一taskを所有・置換したい | `TaskingCore.TaskSlot` |
| 実行順序の保証(FIFO) | **スコープ外** — mattmassicotte/Queue 等を検討 |
