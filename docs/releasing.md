# リリース設計と運用

Tasking は公開リポジトリ `9uiLe/swift-tasking` からソースを配布する。
所有者 `9uiLe` がバージョンを選び、GitHub Actions で検証したコミットを
ローカルの GitHub CLI 認証で公開する。`Tasking` と `TaskingCore` は同じ package の
product であり、1つのタグで同時にバージョンが決まる。

## 責務と公開物

| 担当 | 責務 |
|---|---|
| 所有者 | バージョン選択、準備PRの確認・マージ、公開コマンドの実行 |
| `scripts/release.py` | 文書と準備PRの作成、公開条件の検査、タグとReleaseの作成 |
| GitHub Actions | PR と master の Swift package・prototype・リリースツールの検証 |
| GitHub の保護設定 | 書き込み主体とタグの変更を制限し、公開したソースを固定する |

バージョンは `X.Y.Z` 形式の注釈付きGitタグで表す。タグはコミットを直接指し、
GitHub Releaseにはそのコミットの日本語のCHANGELOG本文を掲載する。バイナリーは添付しない。
**SwiftPMはタグ作成時点でそのバージョンを取得できる**ため、公開条件の検査はタグ作成前に完了させる。
Releaseはドラフトで作成し、タグと本文の一致を確認してから公開する。

Actionsは `contents: read` で検証だけを行い、公開用トークンを持たない。
スクリプトは所有者の認証を検査し、GitHub Actions内での実行を拒否する。

## 準備

Python 3.10以降、Git、最新のGitHub CLIを用意し、所有者として認証する。

```sh
gh auth login --hostname github.com
```

複数アカウントがある場合は `gh auth switch --hostname github.com --user 9uiLe` で選択する。
`GH_TOKEN` / `GITHUB_TOKEN` は保存済み認証に優先するため、スクリプトはAPIの `user` で
実際に使われるアカウントを確認する。

作業ツリーをcleanにし、originを次のいずれかにする。

- `https://github.com/9uiLe/swift-tasking.git`
- `https://github.com/9uiLe/swift-tasking`
- `git@github.com:9uiLe/swift-tasking.git`

fetchと準備ブランチのpushにはGitHub CLI認証のHTTPS接続を使う。originの設定は変更しない。
すべてのコマンドがmasterとタグをfetchする。`check` と `prepare --dry-run` は作業ファイルや
ブランチを変更せず、GitHubへの書き込みも行わない。

## 操作手順

以下の `X.Y.Z` は所有者が選ぶ番号に置き換える。`v` 接頭辞、先頭ゼロ、prerelease/build suffixを
含まない安定版番号を使う。`0.x` の破壊的変更ではminorを上げる。
Swift toolsのバージョンはコンパイラ要件であり、packageのリリース番号とは別に管理する。

### 1. 文書とPRを準備する

機能や修正のPRでは、CHANGELOGの `## [Unreleased]` に利用者向けの項目を日本語で書く。
破壊的変更には `破壊的変更` と必要な対応を記す。Release本文にも同じ内容を掲載するため、
項目内のリンクには完全なURLを使う。

```sh
./scripts/release.py prepare X.Y.Z --dry-run
./scripts/release.py prepare X.Y.Z
```

準備する番号はCHANGELOGと既存安定版タグより新しく、同名のタグ・Release・準備ブランチが
存在しないことを要求する。`prepare` は取得したmasterの完全なSHAを起点に `release/X.Y.Z` を作り、
Unreleasedの項目を日付付きのリリース節へ移す。比較リンクと `README.md`・`README.en.md` 両方の依存バージョンも更新し、
文書をコミット・pushしてmaster宛てのPRを作る。

公開依存指定は、両方のREADMEに次の形式をそれぞれ1か所ずつ置く。番号はCHANGELOGの最新リリースと合わせる。
prepareは更新前にも両言語の番号を照合し、ファイルの欠落・依存指定の重複・番号の不一致があれば停止する。

```swift
.package(url: "https://github.com/9uiLe/swift-tasking.git", from: "X.Y.Z")
```

CHANGELOGは `## [X.Y.Z] - YYYY-MM-DD` と比較リンクを使う。
`[Unreleased]` とバージョン見出しは機械処理に使うため、この形式を保つ。
prepare後は `## [Unreleased]` が空になる。

### 2. 準備PRをマージする

所有者はノート・互換性・依存バージョンを確認し、`Swift package checks` と
`Release tooling checks` の成功を確認してマージする。masterへのpushで再度CIが動く。
公開の判定には、PR用コミットや手動実行ではなく、**マージ後の対象SHAに対するmaster pushの結果**を使う。

### 3. 検証して公開する

```sh
./scripts/release.py check X.Y.Z
./scripts/release.py publish X.Y.Z
```

`check` は対象SHA、CI URL、リリースノートを表示する。
`publish` はその場で条件を再検査し、公開後にRelease URLを表示する。
事前のcheck結果を公開の許可として保存・流用しない。

## 公開条件

| 対象 | 条件 |
|---|---|
| 認証 | `9uiLe` として認証し、対象リポジトリのadmin権限を持つ |
| リポジトリ | 公開の `9uiLe/swift-tasking`、既定ブランチmaster、Immutable releases有効 |
| ソース | 完全なコミットSHAで特定され、masterの履歴に含まれる |
| 文書 | 対象コミットのCHANGELOGの最新節と両言語のREADME依存が指定番号に一致し、日付・リリース項目が有効でUnreleasedが空 |
| CI実行 | 有効な `ci.yml`、対象リポジトリ、master、pushイベント、対象SHAがすべて一致する最新実行・再実行が成功 |
| CIジョブ | その実行の両ジョブが対象SHAに対して各1件あり、両方成功 |
| タグ | 注釈付きで、指定番号の名前を持ち、対象コミットを直接指す |
| Release | タグ、対象SHA、所有者、本文が一致し、prereleaseと添付ファイルがない |

新規公開の番号は他の安定版タグより新しいことを要求する。
タグがない場合は取得したmaster先端、タグがある場合はそのタグのコミットを検証する。
公開済みの一致するReleaseはimmutableであることも検査し、再作成せずURLを返す。

`--verify-tag` はリモートタグの存在を検査する。タグとコミットの一致はスクリプトがAPIで確認する。
タグ作成直前にmasterが変わった場合、検証中にタグが変わった場合や消えた場合は停止する。

## 中断からの再開

同じ番号で `publish` を実行すると、GitHub上の状態から再開位置を決める。

| 状態 | 動作 |
|---|---|
| タグ・Releaseなし | masterとCIを検証してタグから作成する |
| 対応する注釈付きタグあり | タグのコミットとCIを検証してドラフトを作る |
| 対応するドラフトあり | タグ・対象SHA・所有者・本文を照合して公開する |
| 対応する公開済みReleaseあり | 内容・タグ・immutableを確認しURLを返す |
| タグ・文書・Releaseが不一致 | 自動処理を停止する |

タグ作成後にmasterが進んでも、公開対象はタグのコミットで固定する。
タグを削除・上書き・付け替える操作は持たない。認証・API・CIの問題を解消し、同じ番号で再実行する。

`prepare` は同名ブランチがあると停止する。中断時はそのブランチの差分・コミットと
`gh pr list --head release/X.Y.Z` を確認する。未完了のコミットやpushを完了させ、PRだけがなければ
`gh pr create --base master --head release/X.Y.Z` で作成する。

## GitHub設定

| 設定 | リリースに必要な役割 |
|---|---|
| Immutable releases | 公開済みタグと添付ファイルの固定 |
| 全タグの保護 | 作成・更新・削除を制限し、所有者の管理者権限で公開する |
| masterの保護 | PRとCIによる変更確認、削除・force pushの防止 |
| Actionsの既定権限 | read-only、PR承認を許可しない |
| checkout | 完全なSHAに固定し、資格情報を保存しない |

公開ツールはmasterの保護ルールのバイパスにかかわらず両CIジョブの成功を要求する。
レビュー人数やCODEOWNERSの設定は、リポジトリのレビュー方針として管理する。
書き込み主体を増やす際はタグ操作とRelease作成の両方の権限を確認する。

Immutable releasesは公開済みタグと添付ファイルを固定するが、タイトルやノートなど一部の
メタデータは編集可能である。スクリプトは再実行時にもノートの一致を確認する。

## 検証と設計資料

```sh
python3 -m unittest discover -s scripts/tests -v
```

テストは一時GitリポジトリとGitHubの模擬応答を使い、実際のタグ・Releaseを作成しない。
Swift packageとprototypeの検査は [CONTRIBUTING.md](../CONTRIBUTING.md) を参照する。
責務を分ける理由は [ADR-0016](adr/0016-owner-authenticated-releases.md) に記録する。

- [Apple: Publishing a Swift package](https://developer.apple.com/documentation/xcode/publishing-a-swift-package-with-xcode)
- [GitHub: Immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)
- [GitHub REST: Releases](https://docs.github.com/en/rest/releases/releases)
- [GitHub CLI: Environment variables](https://cli.github.com/manual/gh_help_environment)
- [GitHub CLI: release create](https://cli.github.com/manual/gh_release_create)
