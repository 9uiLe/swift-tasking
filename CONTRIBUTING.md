# コントリビューションガイド

日本語 | [English](CONTRIBUTING.en.md)

Tasking は、Swift Concurrency の非構造化タスクの所有を明示するリファレンス実装です。
設計の一貫性、読み取れる契約、確実なキャンセル・完了の振る舞いを重視します。
[MIT ライセンス](LICENSE) で公開しており、ほかのコードベースへの取り込みも可能です。

## 設計を理解する

[ドキュメントガイド](docs/README.md) と [アーキテクチャ](docs/architecture.md) から
読み始めてください。設計判断は `docs/adr/` に記録します。文書化された契約を変更する場合は、
その根拠と公開された振る舞いのテストを一緒に更新します。

実装方法はコード、観測できる振る舞いはテストに置きます。継続して必要な設計根拠は ADR、
個々の変更に固有の動機はコミットメッセージに記録します。実装コメントは、コードで表せない
制約や、一見自然な代替案が安全でない理由を残すために使います。[リポジトリ指針](AGENTS.md) を参照してください。

## 変更を検証する

Swift tools 6.0 との互換性を保ち、Swift 6 言語モードを使います。
厳密な並行性チェックの警告を残さないでください。CI はルート package と
`Examples/TaskingPrototype` の両方で次を実行します。

```sh
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
swift test -c release -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
swift test --sanitize=thread -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

ルート package は iOS Simulator 向けにもビルドします。

```sh
xcodebuild build -quiet -scheme swift-tasking-Package \
  -destination 'generic/platform=iOS Simulator'
```

公開インターフェースを通じてテストしてください。処理のゲートと完了 API で順序を制御し、
追跡の照会・スケジューラの遅延・内部ストレージから完了を推測しないでください。
観測点は [テスト方針](docs/architecture.md#テスト方針) に定めています。

性能は独立した Release [ベンチマーク package](Benchmarks/README.md) で測定します。
負荷条件・ツールチェーン・ソースの識別情報・ばらつきを報告してください。
正しさのテストに絶対時間のしきい値を持ち込まないでください。

## 文書と例

文書、公開 API コメント、実装コメント、コミットメッセージ、PR は日本語を第一言語とします。
用語は [用語集](docs/glossary.md) に揃えます。コードの識別子、プロトコルのフィールド名、
コマンド名、固定された CI チェック名は既存の表記を使います。MIT ライセンスは原文を保持します。

英語版は README、このガイド、セキュリティポリシーに用意します。内容を変更するときは
対応する日本語版と英語版を同時に更新し、すべての設計文書を二重管理することは避けます。
両 README の API・例・動作要件・導入バージョンを一致させてください。
会話の経緯を知らない読者にも契約全体が伝わるように書きます。

相対リンクと Swift スニペットの対応 OS を確認してください。例ではアプリケーションが用意する
依存を明示し、公開契約に沿ったキャンセルとエラー処理を示します。
リリースに含める API の変更は [CHANGELOG.md](CHANGELOG.md) に記録してください。

## リリースツール

Python 3.10 以降で、一時 Git リポジトリと GitHub の模擬応答を使い、準備・検証・公開をテストします。

```sh
python3 -m unittest discover -s scripts/tests -v
```

CI は PR と master への push で `Release tooling checks` と `Swift package checks` を実行します。
公開には、対象となる master のコミットで両ジョブが成功している必要があります。
Actions の権限は読み取り専用とし、所有者がローカルの GitHub CLI 認証で公開します。

CHANGELOG.md の `## [Unreleased]` に、利用者向けの項目を日本語で書いてください。
`[Unreleased]` とバージョン見出しは機械処理用の形式を保ちます。項目は GitHub Release の
本文になるため、リンクには完全な URL を使います。所有者の `prepare` コマンドが項目を
日付付きのリリース節へ移し、日本語・英語両 README の依存バージョンと比較リンクを更新して
準備 PR を作成します。コマンドと復旧手順は [リリースガイド](docs/releasing.md) を参照してください。
