# ポジショニング — 何を解決し、なぜ存在するか

> ステータス: 主要論点は 2026-07-03 のグリリングで作者確認済み。
> 残る未解決事項は末尾参照。

## 1. 解決する問題

**一文で**(作者確認済み — 「所有者不在」を根に置く): 同期 UI コールバックの中で作られる `Task {}` は所有者不在になり、
寿命・重複・キャンセルの方針がコードのどこにも現れない。Tasking はその方針を
**呼び出し箇所で宣言・レビュー可能にする**。

SwiftUI の `Button` action は同期クロージャなので、非同期処理を始めるには
`Task {}` を書くしかない。素の `Task {}` には 3 つの症状が伴う:

1. **所有者不在** — ハンドルを誰も保持せず、画面が消えても走り続け、
   キャンセルする手段も生死を確認する手段もない。
2. **重複実行** — 二度押し・連打で同じ処理が多重に走る。対策は各画面に散らばる
   `isLoading` フラグの手管理になりがち。
3. **キャンセル無視** — Swift のキャンセルは協調的なので、ViewModel 側が
   チェックしなければ `cancel()` は何もしない。この「協調する責任」が
   どのメソッドにあるのかシグネチャから読み取れない。

この 3 症状の根は 1 つ:**unstructured task の所有権と方針が暗黙**であること。
Tasking は方針(誰が所有するか・いつまで生きるか・重複時どうするか・
キャンセルに誰が協調するか)を型と引数で強制的に言語化させる。

## 2. 設計思想

### 原則: 可視化はするが、肩代わりはしない

Tasking は「見えなくなっているものを見えるようにする」ことだけを引き受け、
アプリ側の責務を奪わない。この原則から各判断が導かれる:

| 判断 | 内容 | ADR |
|---|---|---|
| 責務分離 | task を「所有する」型(ViewTaskStore)と「実行を制御する」型(ActionRunner)を分ける。ActionRunner は task を作らない | [0001](adr/0001-split-store-and-runner.md) |
| 契約の可視化 | CancellationContext は能力ではなく、キャンセル協調の責任をシグネチャに現す装置 | [0002](adr/0002-cancellation-context-as-contract.md) |
| エラーの居場所 | 業務エラーは ViewModel state に変換してから operation を出る。store はエラーを運ばない | [0003](adr/0003-viewtaskstore-does-not-carry-errors.md) |
| 宣言と強制 | ActionLifetime は宣言(レビュー・一括キャンセルの単位)であって、強制機構ではない | [0004](adr/0004-lifetime-is-declared-not-enforced.md) |
| 結果の型 | ActionFailure はエラー型を消去する。回復は operation 内、outcome はログ・計測用 | [0005](adr/0005-actionfailure-erases-error-types.md) |
| 品質の下限 | Swift 6 言語モード専用・@MainActor 固定。UI 境界のツールであることを型で明示 | [0006](adr/0006-swift6-mainactor-only.md) |
| UI 状態の責務 | store は Observable にしない。ローディング表示は ViewModel state の仕事 | [0007](adr/0007-store-is-not-observable.md) |

### 原則: 構造化並行性が第一、本ライブラリは残余ケース専用

`async let`・task group・SwiftUI `.task` で表現できる処理には Tasking を使わない。
これは README に明記された公式の立場であり、「まず純正、表現できない残余だけ
Tasking」という住み分けが成立しない場面では採用しないことを推奨する。

## 3. なぜ必要か — 「純正で書けるのでは?」への回答

最も強い反論は「`@State var request: SaveRequest?` + `.task(id: request)` で
ボタン起点の処理も構造化でき、画面消滅時の自動キャンセルまで付く」というもの。
これに対する回答:

1. **画面より長い寿命が表現できない** — `.task` は view 寿命に縛られる。
   「画面を閉じても完遂したい保存」「シーン単位で生かすアップロード」は
   `.task` では書けず、結局 `Task {}` に戻ることになる。
2. **重複ポリシーが 1 種類しかない** — `.task(id:)` は「id が変われば前をキャンセル
   して再実行」(= `cancelExisting` 相当)固定。保存ボタンに欲しいのは大抵
   「実行中は新規を無視」(`ignoreNew`)であり、これはトリガー state 方式では
   別途フラグ管理が必要になる。`allowConcurrent` も表現できない。
3. **トリガー state は意図を隠す** — nil に戻すタイミング、連打時の挙動などが
   暗黙になり、レビューで「二度押しの方針はどれか」を確認できない。

逆に言えば、**上記 3 点に当てはまらない処理は `.task(id:)` で書くべき**であり、
Tasking はそれを推奨する側に立つ。

## 4. 競合と優位性

### 直接競合

| | Tasking | [VergeGroup/swift-concurrency-task-manager](https://github.com/VergeGroup/swift-concurrency-task-manager) | [swiftuiux/async-task](https://github.com/swiftuiux/async-task) |
|---|---|---|---|
| 主眼 | 所有権・方針の可視化 | キーによる直列化/切替(キュー機能) | 単一タスクの状態観測 VM |
| 重複ポリシー | ignoreNew / cancelExisting / allowConcurrent | dropCurrent / waitInCurrent(README 上、「実行中は無視」相当は見当たらない) | なし(SingleTask 前提、view 側で防止) |
| ライフタイム宣言 | あり(screen/scene/app + 拡張) | なし(@LocalTask は view 寿命) | なし |
| task を作らない実行制御 | あり(ActionRunner) | なし(常に manager が task を所有) | なし |
| ローディング状態の提供 | なし(ViewModel の責務と定義) | isRunning binding あり | あり(@Published / @Observable) |
| キュー・順序保証 | なし(スコープ外) | あり(waitInCurrent、pause/resume) | なし |
| 対応 OS | iOS 13+ | iOS 14+ | iOS 17+(@Observable 版) |
| 依存 | ゼロ | — | — |

- **vs Verge TaskManager**: 機能量では Verge が上(キュー、pause/resume、binding)。
  Tasking の優位は (a) 保存ボタンに最適な `ignoreNew` を第一級で持つこと、
  (b) ライフタイム宣言と `cancel(lifetime:)`、(c) ActionRunner という
  「構造化文脈を壊さない重複制御」、(d) 表面積の小ささと思想の一貫性。
- **vs async-task**: 解いている問題が逆。async-task はローディング状態の提供が主で、
  Tasking はそれを意図的に提供しない(ADR-0007)。状態観測が欲しいだけなら
  async-task の方が向く。

### 隣接(競合しない)

- **[mattmassicotte/Queue](https://github.com/mattmassicotte/Queue) / [dfed/swift-async-queue](https://github.com/dfed/swift-async-queue)**:
  unstructured task 間の**順序保証**が主題。Tasking は順序を扱わない。相互補完。
- **TCA(The Composable Architecture)**: `.cancellable(id:)` / `.cancel(id:)` は
  ActionID キーのキャンセルという同じ着想の先行例。ただしアーキテクチャ全体の
  採用が前提。Tasking は「TCA を入れずに、その規律の一片だけ MVVM に持ち込む」
  位置づけ。
- **SwiftUI `.task(id:)`**: 競合ではなく第一選択。§3 の残余ケースのみ Tasking。
- **Combine の `Set<AnyCancellable>`**: 概念上の祖先。「購読ハンドルの所有を
  view/VM に明示させる」慣習の async/await 版が ViewTaskStore と言える。

### ポジショニング一文

> **Combine の cancellables bag に相当する規律を、アーキテクチャ移行なしで
> Swift Concurrency の unstructured task に持ち込む、最小のライブラリ。**

## 5. 良い点・悪い点(正直な評価)

### 良い点

- 表面積が小さい(公開型 ~10、依存ゼロ、~400 行)。読み切れる。
- Swift 6 言語モード + strict concurrency を公開時点から品質下限にしている。
- 「何をしないか」が明確(構造化並行性の代替ではない、と README が自ら言う)。
- Action という業務語彙で API が組まれ、Task という機構語彙が漏れていない。
- 重複ポリシーの語彙(ignoreNew / cancelExisting / allowConcurrent)が
  レビューの共通言語になる。
- 15 本のテストが方針(ポリシー・キャンセル・ライフタイム)を仕様として固定している。

### 悪い点・リスク

- **ライフタイムは名前ほど強くない**: `.appBound` と書いても store が `@State`
  所有なら画面と共に死ぬ。名前と実態の乖離は誤解の温床で、ドキュメントで
  補い続ける必要がある(ADR-0004 の代償)。推奨所有構成は
  [lifetimes.md](lifetimes.md) に集約した。
- **release ビルドで業務エラーが無音になる**: ViewTaskStore の未処理エラーは
  `assertionFailure` 頼みのため、release では黙って握り潰される。
  グリリングの結果これは**見落としと認定**され、観測用フック
  (`onUnhandledError` 系)の追加が検討中(ADR-0003 追記)。それまでは既知の制限。
- **ローディング UI を自前で持てない**: `isRunning` は観測可能でないため、
  スピナー表示には結局 ViewModel の状態管理が要る。競合はここを無料で提供して
  おり、採用時の第一印象で不利(ADR-0007 の代償)。
- **CancellationContext は慣習でしか守られない**: 誰でも `CancellationContext()`
  を作れるため、契約の実効性はチーム規律に依存する(ADR-0002 の代償)。
- **順序保証がない**: `allowConcurrent` の並行実行間の順序・整合はアプリ側の責任。
- **運用面の未整備(公開ブロッカー)**: LICENSE ファイルなし、CI なし、
  パッケージ名 `TaskRunner`・プロダクト名 `Tasking`・リポジトリ名 `task-runner` の
  三重名称、doc コメント(日本語)と README(英語)の言語不一致。

## 6. 公開・運用方針(2026-07-03 グリリングで確定)

公開のゴールは**設計思想の提示(リファレンス実装)**である。

- 「unstructured task に所有権と方針の語彙を」という考え方を示すことが主目的。
  コードをコピーして各自のコードベースに取り込まれることも歓迎する。
- 採用数・star は成功指標にしない。機能要望への対応よりも思想の一貫性
  (「可視化はするが、肩代わりはしない」)を優先する。
- したがって第一級のドキュメントは ADR と設計解説(本書)であり、
  チュートリアルの網羅性は二の次でよい。

## 未解決の問い(グリリング継続事項)

2026-07-03 のグリリングで、核心の一文(§1 = 所有者不在を根に)、release 無音
エラーの扱い(ADR-0003 追記)、appBound の推奨構成([lifetimes.md](lifetimes.md))、
公開ゴール(§6)、名称・ライセンス・言語方針(ADR-0008: swift-tasking / MIT /
二層言語構造)は確定した。残る事項:

1. ADR-0008 の実装(リポジトリ・パッケージのリネーム、doc コメントの英訳)—
   実装変更を伴うため別作業として委譲予定。
2. 各 ADR 末尾の細かい「未解決の問い」(ActionRunner の追加例、CancellationContext
   の拡張構想、outcome を制御フローに使わない規律の明文化、非 UI 版への態度)。
