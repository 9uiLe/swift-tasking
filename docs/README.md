# Tasking ドキュメント

Tasking は、Swift Concurrency の非構造化タスクを誰が所有し、重複した要求をどう扱い、
いつキャンセルして終了を確認するかを明示するライブラリである。
このガイドは、利用・設計・保守に必要な資料の入口となる。

## 利用を始める

| 知りたいこと | 読む資料 |
|---|---|
| 動作要件、導入方法、基本的な呼び出し | [README](../README.md)（[English](../README.en.md)） |
| Swift 標準の仕組みとの使い分け | [用途と設計原則](positioning.md) |
| Action、追跡、所有、実終了の意味 | [用語集](glossary.md) |
| 画面・シーン・アプリへの所有者の配置 | [寿命と所有構成](lifetimes.md) |
| キャンセル、表示状態、結果の世代管理 | [利用レシピ](recipes.md) |
| 機能へ組み込む際の設計と確認事項 | [導入と運用](adoption.md) |

[TaskingPrototype](../Examples/TaskingPrototype/Sources/TaskingPrototype/PrototypeApp.swift) は、
保存・検索・ダウンロード・同期・課金を題材にした実行可能なサンプルである。

## 設計と保守を理解する

[アーキテクチャ](architecture.md) は、公開する型の責務、状態遷移、不変条件、内部構造、
テストの観測点を説明する。[性能特性](performance.md) は計算量と測定条件を示す。

変更を検証する手順は [コントリビューションガイド](../CONTRIBUTING.md)、
配布するソースを確定する手順は [リリース設計と運用](releasing.md) を参照する。
公開済みの版と未公開の変更は [変更履歴](../CHANGELOG.md) に記録する。

日本語を正本とする。README・コントリビューションガイド・セキュリティポリシーには英語版を用意し、
対応する日本語版と同時に保守する。設計資料・ADR・変更履歴・運用手順は日本語で管理する。

## 設計判断（ADR）

ADR（Architecture Decision Record）は、設計上の判断と、その前提・理由・制約を記述する。
以下は責務ごとの参照先である。

| 領域 | 設計判断 |
|---|---|
| 公開する型 | [0001: 所有と実行制御](adr/0001-split-store-and-runner.md)、[0010: 非 UI のタスク所有](adr/0010-tasking-core-task-slot.md) |
| キャンセル | [0002: 協調の契約](adr/0002-cancellation-context-as-contract.md)、[0009: キャンセル時の追跡解除](adr/0009-cancel-removes-tracking-immediately.md) |
| 所有と終了 | [0012: Store の追跡と所有](adr/0012-store-tracking-and-ownership.md)、[0014: Store の受付停止](adr/0014-store-terminal-close.md)、[0011: Slot の受付停止と自己待機](adr/0011-task-slot-close-and-self-wait.md) |
| アプリの状態 | [0003: 業務結果とエラー](adr/0003-viewtaskstore-does-not-carry-errors.md)、[0005: 失敗の報告形式](adr/0005-actionfailure-erases-error-types.md)、[0007: UI の観測可能な状態](adr/0007-store-is-not-observable.md) |
| 寿命と実行場所 | [0004: 寿命ラベル](adr/0004-lifetime-is-declared-not-enforced.md)、[0006: Swift と actor 隔離](adr/0006-swift6-mainactor-only.md) |
| 内部構造と性能 | [0013: 追跡索引と所有台帳](adr/0013-ownership-and-tracking-registries.md)、[0015: 識別と照会のコスト](adr/0015-measured-ownership-overhead.md) |
| 公開と運用 | [0008: 名称・ライセンス・言語](adr/0008-publication-naming-license-language.md)、[0016: リリースの認証と検証](adr/0016-owner-authenticated-releases.md) |
