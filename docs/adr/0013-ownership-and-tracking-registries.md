# ADR-0013: 追跡索引と所有台帳に内部の更新責務を集約する

## 前提

Store と Runner は Action ごとの追跡を共有し、Store と Slot は task を終了まで所有する。
登録・キャンセル・完了の規則を、責務ごとに1か所で保守できる構造にする。

## 決定

- `ActionRuns<Metadata>` は Tasking 内部の追跡索引とする。
  `[ActionID: [ActionRunID: Metadata]]` に登録し、Store は lifetime、Runner は `Void` を格納する。
- `OwnedTasks<Key>` は TaskingCore の package 内部の所有台帳とする。
  handle と ownership marker を保持し、cancel で除去せず完了時に除去する。
- Store は `ActionRun` 全体、Slot は所有 marker を所有台帳のキーにする。
- actor 隔離、task 作成、受付方針、待機ループは各所有者が担当する。
  台帳への可変アクセスを suspension をまたいで保持しない。

## 不変条件

- Store の追跡中 run は必ず所有中である。
- 古い run の完了は、その run だけを索引と台帳から除去する。
- run の照会・cancel・完了待ちは ActionID と ActionRunID の組を使う。
- task の終了処理が所有者の actor で動く前に、所有台帳への登録を完了する。
- 内部 task は所有者を弱参照し、所有者の解放による cancel を妨げない。

## 理由と制約

追跡索引は重複とラベルの選択、所有台帳は handle の保持と cancel に集中する。
終了待ち専用の台帳への移動や、複数の追跡索引を同期する責務を持たせずに契約を実装できる。

自己待機の検出には、所有台帳と TaskLocal が保持する独立した参照 marker を使う。
参照の寿命と性能上の判断は [ADR-0015](0015-measured-ownership-overhead.md) に定める。
内部の型を公開 protocol にせず、利用者は Store・Runner・Slot の契約を通じて操作する。
