# Tasking ドキュメント

Tasking は Swift Concurrency の unstructured task に、所有者・寿命・重複方針・
キャンセルへの協調を明示するためのライブラリである。

## 読む順序

1. [用途と設計原則](positioning.md) — 解決する問題と、構造化並行性との使い分け
2. [用語集](glossary.md) — Action、追跡、所有、完了の定義
3. [アーキテクチャ](architecture.md) — 公開契約、内部構造、不変条件、テスト方針
4. [ライフタイムと所有構成](lifetimes.md) — 画面・シーン・アプリに store を配置する方法
5. [利用レシピ](recipes.md) — キャンセル、状態更新、終了待ちの実装例
6. [導入と運用](adoption.md) — Swift 6、ActionID、監視、終了処理の運用ルール
7. [性能特性](performance.md) — 計算量、測定結果、負荷に応じた判断
8. [リリース設計と運用](releasing.md) — 所有者の認証、準備PR、公開条件、中断からの再開

インストールと基本的な呼び出し方は [README](../README.md)、実行可能な利用例は
[TaskingPrototype](../Examples/TaskingPrototype/Sources/TaskingPrototype/PrototypeApp.swift) を参照する。

## Architecture Decision Records

各 ADR は、設計上の判断を前提・決定・理由・制約に分けて説明する。
番号は参照用の識別子であり、読む順序や機能の依存順序を表さない。

| ADR | 判断 |
|---|---|
| [0001](adr/0001-split-store-and-runner.md) | task の所有と、呼び出し元 task 内の実行制御を分ける |
| [0002](adr/0002-cancellation-context-as-contract.md) | CancellationContext で協調の契約を明示する |
| [0003](adr/0003-viewtaskstore-does-not-carry-errors.md) | Store の業務結果とエラー表示を ViewModel に置く |
| [0004](adr/0004-lifetime-is-declared-not-enforced.md) | lifetime を選択用のラベルとして扱う |
| [0005](adr/0005-actionfailure-erases-error-types.md) | 失敗の最終報告を文字列で表現する |
| [0006](adr/0006-swift6-mainactor-only.md) | Swift 6 と明示的な actor 隔離を前提にする |
| [0007](adr/0007-store-is-not-observable.md) | 追跡状態と観測可能な UI 状態を分ける |
| [0008](adr/0008-publication-naming-license-language.md) | 名称・ライセンス・文書言語を定める |
| [0009](adr/0009-cancel-removes-tracking-immediately.md) | キャンセル時に重複判定の対象から外す |
| [0010](adr/0010-tasking-core-task-slot.md) | 非 UI の置換可能な task を TaskSlot が所有する |
| [0011](adr/0011-task-slot-close-and-self-wait.md) | TaskSlot の受付停止・終了待ち・自己待機の契約を定める |
| [0012](adr/0012-store-tracking-and-ownership.md) | Store の追跡と所有を独立した状態として扱う |
| [0013](adr/0013-ownership-and-tracking-registries.md) | 追跡索引と所有台帳に内部の更新責務を集約する |
| [0014](adr/0014-store-terminal-close.md) | Store の終了処理で新規開始を先に停止する |
| [0015](adr/0015-measured-ownership-overhead.md) | 所有識別と照会のコストを抑える |
| [0016](adr/0016-owner-authenticated-releases.md) | 所有者の認証とコミット単位のCI検証で公開する |
