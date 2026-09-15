# ADR-0001: task の所有と実行制御を分ける

## 前提

同期 UI コールバックは非同期処理の終了を await できないため、コールバックの外まで生きる
task の所有者が必要になる。async 関数では呼び出し元の task をそのまま使える。
どちらの入口にも Action 単位の重複制御が必要になり得る。

## 決定

- `ViewTaskStore` は task を作成・所有し、lifetime と重複方針を管理する。
  同期の `start` は受付結果の `TaskStartOutcome` を返す。
- `ActionRunner` は呼び出し元の task 内で operation を実行する。
  重複を制御し、最終結果の `ActionOutcome<Success>` を返す。
- 非 UI の task 所有は `TaskSlot` が担当する。[ADR-0010](0010-tasking-core-task-slot.md) を参照する。

## 理由と制約

Runner が task を作らなければ、呼び出し元のキャンセル状態と task-local 値を保って
operation を実行できる。Runner に task をキャンセルする責務はなく、重複方針は
`.ignoreNew` と `.allowConcurrent` に限る。

Store は所有中の task にキャンセルを要求できるため `.cancelExisting` も持つ。
Store の開始結果は業務結果ではなく、完了した業務結果は ViewModel の状態に反映する。
呼び出し箇所で task の所有者と結果の受け取り方を選択できる形にする。
