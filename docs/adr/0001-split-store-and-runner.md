# ADR-0001: タスクの所有と実行制御を分ける

## 前提

同期 UI コールバックから始めた非同期処理には、コールバックの外でタスクを管理する所有者が必要になる。
async 関数には既に呼び出し元のタスクがあり、その中で処理を続けられる。
どちらの入口にも、保存や更新といった Action 単位の重複制御が必要になる。

## 決定

| 型 | タスクの扱い | 返すもの |
|---|---|---|
| `ViewTaskStore` | MainActor 上で作成し、ハンドルを所有する | 同期の受付結果 `TaskStartOutcome` |
| `ActionRunner` | MainActor 上で、呼び出し元のタスクを使う | 終了結果 `ActionOutcome<Success>` |
| `TaskSlot` | 非 UI 向けの actor として作成・所有する | 差し替えの受付結果 `Bool` |

Store と Runner は Action を追跡し、Store と Slot はタスクを所有する。
Slot の役割は [ADR-0010](0010-tasking-core-task-slot.md) に定める。

## 理由と制約

入口ごとに所有者と結果の受け取り方が明確になる。
Runner は新しいタスクを作らず、呼び出し元のキャンセル状態と TaskLocal を使って処理を実行できる。
その重複方針は `.ignoreNew` と `.allowConcurrent` とする。

Store はタスクへキャンセルを要求できるため、`.cancelExisting` による差し替えも提供する。
受付結果は業務結果を含まず、処理の結果や表示は ViewModel が管理する。
