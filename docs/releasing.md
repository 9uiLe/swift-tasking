# リリース設計と運用

Tasking は `9uiLe/swift-tasking` の Git タグからソースを配布する。
`Tasking` と `TaskingCore` は同じ package の product であり、1つのタグでバージョンが決まる。
所有者 `9uiLe` が番号を選び、CI で検証したコミットをローカルの GitHub CLI 認証で公開する。

## 公開物と責務

バージョンは `X.Y.Z` 形式の注釈付きタグで表し、コミットを直接指す。
GitHub Release の本文には、そのコミットの日本語の CHANGELOG を使う。バイナリは添付しない。
SwiftPM はタグ作成時点からソースを取得できるため、公開条件はタグの作成前に検査する。

| 担当 | 責務 |
|---|---|
| 所有者 | バージョン選択、準備 PR の確認・マージ、公開コマンドの実行 |
| `scripts/release.py` | 文書と PR の準備、公開条件の検証、タグと Release の作成 |
| GitHub Actions | PR と master の Swift package・プロトタイプ・リリースツールの検証 |
| GitHub の保護設定 | 書き込み主体の制限、公開済みソースの固定 |

Actions の権限は `contents: read` とし、公開資格情報を持たせない。
スクリプトは GitHub Actions 内での実行を拒否する。
設計の根拠は [ADR-0016](adr/0016-owner-authenticated-releases.md) に定める。

## 実行環境を用意する

Python 3.10 以降、Git、最新の GitHub CLI を用意する。
リポジトリのルートで作業し、作業ツリーの変更をコミットまたは退避してから実行する。

```sh
gh auth login --hostname github.com
```

複数のアカウントがある場合は、`gh auth switch --hostname github.com --user 9uiLe` で選択する。
`GH_TOKEN` と `GITHUB_TOKEN` は保存済みの認証より優先される。
スクリプトは API の `user` を使い、実際の認証アカウントが所有者であることを確認する。

`origin` は次のいずれかとする。

- `https://github.com/9uiLe/swift-tasking.git`
- `https://github.com/9uiLe/swift-tasking`
- `git@github.com:9uiLe/swift-tasking.git`

全コマンドが master とタグを取得する。取得と準備ブランチの push には GitHub CLI 認証の HTTPS 接続を使う。
`check` と `prepare --dry-run` は作業ファイルやブランチを変更せず、GitHub への書き込みも行わない。

## 1. バージョンと文書を準備する

以下の `X.Y.Z` は所有者が選ぶ番号に置き換える。
`v` 接頭辞、先頭ゼロ、プレリリース・ビルド接尾辞を含まない安定版の番号を使う。
`0.x` の破壊的変更では minor を上げる。Swift tools の番号はコンパイラ要件として別に管理する。

### 文書の形式

機能や修正の PR では、CHANGELOG の `## [Unreleased]` に利用者向けの項目を日本語で記載する。
破壊的変更にはその旨と必要な対応を記す。Release 本文にも使うため、項目内のリンクは完全な URL にする。

両 README の公開依存指定は、次の形式をそれぞれ1か所に置く。
準備前の番号は CHANGELOG の最新リリースに揃える。

```swift
.package(url: "https://github.com/9uiLe/swift-tasking.git", from: "X.Y.Z")
```

CHANGELOG のリリース見出しは `## [X.Y.Z] - YYYY-MM-DD` とする。
`[Unreleased]` の比較リンクは最新リリースから HEAD への比較を指す。
これらの見出しとリンクはツールが読み取る形式なので、表記を保つ。

### 準備コマンド

```sh
./scripts/release.py prepare X.Y.Z --dry-run
./scripts/release.py prepare X.Y.Z
```

番号は CHANGELOG と既存の安定版タグより新しく、同名のタグ・Release・準備ブランチがないことを要求する。
README の欠落、依存指定の重複、バージョンの不一致も準備前に検出する。

`prepare` は取得した master の完全な SHA から `release/X.Y.Z` ブランチを作る。
Unreleased の項目を日付付きのリリース節へ移し、両 README の依存バージョンと比較リンクを更新する。
文書をコミット・push して、master 宛ての準備 PR を作成する。準備後の Unreleased は空になる。

## 2. 準備 PR を確認してマージする

所有者はリリースノート、互換性、両言語の導入手順を確認する。
`Swift package checks` と `Release tooling checks` の成功を確認してマージする。

マージによる master への push で CI が再実行される。
公開判定には、公開対象の SHA に対する master push の結果を使う。
PR 用のコミットや手動実行の成功だけでは公開条件を満たさない。

## 3. 検証して公開する

```sh
./scripts/release.py check X.Y.Z
./scripts/release.py publish X.Y.Z
```

`check` は対象 SHA、CI の URL、リリースノートを表示する。
`publish` は条件を再検証し、注釈付きタグ、ドラフトの Release、公開済みの Release の順に進める。
ドラフトの照合後に公開し、公開済みの内容とタグを確認して URL を表示する。

### 公開条件

| 対象 | 条件 |
|---|---|
| 認証 | `9uiLe` で認証し、対象リポジトリの管理者権限を持つ |
| リポジトリ | 公開の `9uiLe/swift-tasking`、既定ブランチ master、Immutable releases が有効 |
| ソース | 完全な SHA で特定され、master の履歴に含まれる |
| 文書 | 対象コミットの CHANGELOG と両 README が指定番号に一致し、日付と項目が有効で Unreleased が空 |
| CI 実行 | 有効な `ci.yml` で、対象リポジトリ・master・push イベント・対象 SHA が一致する実行のうち、最新の実行・試行が成功 |
| CI ジョブ | その実行の両ジョブが対象 SHA に対して各1件あり、両方成功 |
| タグ | 指定番号の注釈付きタグで、対象コミットを直接指す |
| Release | タグ・SHA・所有者・本文が一致し、プレリリース指定と添付ファイルがない |

タグがなければ取得した master の先端、タグがあればそのタグのコミットを対象にする。
新規公開の番号はほかの安定版タグより新しいことを要求する。
既に公開済みで内容が一致する場合は、immutable であることを確認して URL を返す。

タグの作成直前に master が変わった場合や、検証中にタグが変更・削除された場合は停止する。
`--verify-tag` はリモートタグの存在を検査し、コミットとの一致はスクリプトが API で確認する。

## 中断した操作を再開する

`publish` は同じ番号で再実行し、GitHub 上の状態に応じて続行する。

| 状態 | 動作 |
|---|---|
| タグ・Release がない | master と CI を検証してタグを作る |
| 対応する注釈付きタグがある | そのコミットと CI を検証してドラフトを作る |
| 対応するドラフトがある | タグ・SHA・所有者・本文を照合して公開する |
| 対応する公開済み Release がある | 内容・タグ・immutable を確認して URL を返す |
| タグ・文書・Release が一致しない | 自動処理を停止する |

タグ作成後は master が進んでも公開対象を変更しない。
タグを削除・上書き・付け替える操作は持たない。認証・API・CI の問題を解消し、同じ番号で再実行する。

`prepare` は同名の準備ブランチがあると停止する。
中断時はブランチの差分とコミット、`gh pr list --head release/X.Y.Z` を確認する。
不足しているコミットや push を完了させ、PR だけがなければ
`gh pr create --base master --head release/X.Y.Z` で作成する。

## GitHub の保護設定

| 設定 | 役割 |
|---|---|
| Immutable releases | 公開済みタグと添付ファイルを固定する |
| 全タグの保護 | 作成・更新・削除を制限し、所有者の管理者権限で公開する |
| master の保護 | PR と CI を要求し、削除と force push を防ぐ |
| Actions の既定権限 | 読み取り専用とし、PR 承認を許可しない |
| checkout | 完全な SHA に固定し、資格情報を保存しない |

スクリプトは、保護ルールをバイパスできる権限があっても両 CI ジョブの成功を要求する。
レビュー人数と CODEOWNERS はリポジトリのレビュー方針として管理する。
書き込み主体を増やす場合は、タグと Release の両方の操作権限を確認する。

Immutable releases でもタイトルやノートなどの一部のメタデータは編集できるため、再実行時も本文の一致を検証する。

## ツールを検証する

```sh
python3 -m unittest discover -s scripts/tests -v
```

テストは一時 Git リポジトリと GitHub の模擬応答で、文書の準備、公開前の拒否、中断からの再開を検証する。
Swift package とプロトタイプの検査は [コントリビューションガイド](../CONTRIBUTING.md) を参照する。

- [Apple: Publishing a Swift package](https://developer.apple.com/documentation/xcode/publishing-a-swift-package-with-xcode)
- [GitHub: Immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)
- [GitHub REST: Releases](https://docs.github.com/en/rest/releases/releases)
- [GitHub CLI: Environment variables](https://cli.github.com/manual/gh_help_environment)
- [GitHub CLI: release create](https://cli.github.com/manual/gh_release_create)
