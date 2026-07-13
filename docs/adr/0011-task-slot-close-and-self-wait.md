# ADR-0011: TaskSlot は terminal close と自己待機除外を持つ

- ステータス: 実装済み
- 日付: 2026-07-14

## 文脈

owner actor が `TaskSlot.cancel()` の後に `waitForIdle()` を呼んでも、最初の `await` で
owner と slot の両 actor は再入可能になる。待機中に届いた `replace` は従来 API の仕様上
受理されるため、teardown 後の新規 operation が未キャンセルで実行され得る。

また、slot が所有する operation から同じ slot の `waitForIdle()` を呼ぶと、自分自身の
終了を内側から待つため永久に復帰しない。文書上の禁止だけでは release の停止性を守れない。

## 決定

- `close()` は slot を terminal 状態へ移し、以後の `replace` を拒否する。実行中 task は
  cancel しないため、`close()` → `waitForIdle()` で graceful drain を表現できる。
- `replace` は `@discardableResult Bool` を返す。`false` のとき operation は作成も実行も
  されない。
- `cancelAndWaitForIdle()` は suspension のない actor 隔離区間で close と active task の
  cancel を行い、その後に全 owned task の実終了を待つ。
- 各 owned operation の `(slot identity, task ID)` を TaskLocal に記録する。
  `waitForIdle()` が同じ ownership context から呼ばれた場合、debug assertion で契約違反を
  報告し、release では該当 task だけを待機対象から外して他の owned task を待つ。

## 根拠

単に `cancelAndWaitForIdle()` を追加しても、新規 admission を止めなければ method の suspension
中に replace が入る。closed state と replace の guard を同じ actor に置くことで、teardown の
有限性を利用側の二 actor protocol に依存せず保証できる。

close が暗黙に cancel する案は graceful drain を失う。close 後に operation を開始して即 cancel
する案は、拒否された work の副作用と観測ノイズを生む。TaskingCore は Action 語彙を持たないため、
専用 outcome 型ではなく Bool で admission だけを返す。

自己待機を throws にすると既存呼び出しを壊し、完全な no-op にすると他の superseded task まで
待たない。TaskLocal で現在の ownership context だけを除く形なら、通常時の意味論を変えずに
誤用時も有限にできる。

## 結果

- close は冪等で再 open しない。close 後の slot を再利用する場合は新しい instance を作る。
- structured child は TaskLocal を継承するため同じ自己待機保護を受ける。
- `Task {}` も TaskLocal は継承するが cancellation ownership は継承しない。operation 内の
  nested unstructured task は引き続きサポート外とする。
- TaskLocal の ownership 集合は継承先で累積する。サポート外の operation 内 `replace` を
  行うと、子 operation の自己待機除外には親 marker も含まれる。この過剰近似は契約違反の
  経路に限られ、サポート対象の呼び出しには影響しない。
- cancel を無視する operation の実終了は保証できない。強制停止は提供しない。
