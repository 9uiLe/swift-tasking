# コントリビューションガイド

日本語 | [English](CONTRIBUTING.en.md)

Tasking は、非構造化タスクの所有と実行方針を明示するライブラリです。
変更では、公開契約の分かりやすさ、責務の一貫性、キャンセルと終了待ちの確実さを重視します。
コードは [MIT ライセンス](LICENSE) で配布しています。

## 設計と契約を確認する

[用途と設計原則](docs/positioning.md)、[用語集](docs/glossary.md)、[アーキテクチャ](docs/architecture.md) の順に、
対象の責務と公開契約を確認してください。判断の理由は [設計判断一覧](docs/README.md#設計判断adr) から参照できます。

| 情報 | 記録する場所 |
|---|---|
| 実装方法 | コードの名前・型・制御フロー・モジュール境界 |
| 観測可能な振る舞い | 公開 API の文書コメントとテスト |
| 継続して必要な設計根拠 | `docs/adr/` |
| 個々の変更の問題・動機・経緯 | コミットメッセージ |
| コードで表せない制約や代替案を避ける理由 | 実装コメント |

契約を変更する場合は、対応する文書・テスト・設計根拠を一緒に更新します。
コメントはコードの逐語的な説明にせず、まず命名や構造で表現してください。
詳しい指針は [AGENTS.md](AGENTS.md) に定めています。

## 変更を検証する

Swift tools 6.0 との互換性を保ち、Swift 6 言語モードを使います。
リポジトリのルートで次を実行すると、ライブラリとプロトタイプの両方を検証できます。

```sh
for tasking_package in . Examples/TaskingPrototype; do
  swift build --package-path "$tasking_package" -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
  swift test --package-path "$tasking_package" -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
  swift test --package-path "$tasking_package" -c release -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
  swift test --package-path "$tasking_package" --sanitize=thread -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
done
```

iOS Simulator 向けのビルドには Xcode を使います。

```sh
xcodebuild build -quiet -scheme swift-tasking-Package \
  -destination 'generic/platform=iOS Simulator'
```

テストでは公開インターフェースを使い、処理のゲートで到達と再開を制御します。
完了は完了待ち API で確認し、追跡状態・短い sleep・内部ストレージから推測しません。
契約ごとの観測点は [テスト方針](docs/architecture.md#テスト方針) を参照してください。

性能は独立した Release [ベンチマーク](Benchmarks/README.md) で測ります。
負荷条件・ツールチェーン・ソースの識別情報・ばらつきを報告し、正しさのテストに絶対時間のしきい値を置かないでください。

## 文書と例を書く

日本語を、文書・公開 API コメント・実装コメント・コミットメッセージ・PR の第一言語とします。
コードの識別子、プロトコルのフィールド名、コマンド名、固定された CI チェック名は既存の表記を使います。
MIT ライセンスは原文を保持します。

README・このガイド・セキュリティポリシーは、日本語を正本として `.en.md` の英語版と同時に更新します。
設計資料・ADR・変更履歴・運用手順は日本語で管理します。
両 README の API・例・動作要件・導入バージョンを一致させてください。

説明は目的、前提、現在の契約から組み立てます。
例には必要な import、実行場所、対応 OS、アプリケーションが用意する依存を示します。
キャンセルとエラー処理を公開契約に合わせ、相対リンクとコード例を確認してください。

## リリースに関わる変更を記録する

利用者向けの変更は [CHANGELOG.md](CHANGELOG.md) の `## [Unreleased]` に日本語で記載します。
破壊的変更には必要な対応を含めます。項目を GitHub Release の本文にも使うため、リンクは完全な URL にします。
`[Unreleased]` とバージョン見出しは機械処理用の形式を保ってください。

リリースツールの検証には Python 3.10 以降を使います。

```sh
python3 -m unittest discover -s scripts/tests -v
```

一時 Git リポジトリと GitHub の模擬応答で、両言語の README の更新・不整合時の停止・公開・再開を検証します。
CI は PR と master への push で `Release tooling checks` と `Swift package checks` を実行します。

所有者の `prepare` コマンドがリリースノートと両 README の依存バージョンを更新し、準備 PR を作成します。
公開には、マージ後の対象コミットの両 CI ジョブの成功が必要です。
手順と復旧方法は [リリース設計と運用](docs/releasing.md) を参照してください。
