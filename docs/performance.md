# 性能特性

Tasking の開始・追跡・キャンセルは、所有中の task 数と ActionID の分布に影響される。
Store の同期操作は MainActor の時間を使うため、処理件数を含めて設計する。
この文書は計算量、測定したコスト、実装上のトレードオフを示す。

## 計算量とメモリ

`n` を追跡中 run 数、`m` を所有中 task 数、`k` を同じ ActionID の追跡中 run 数とする。

| 操作・状態 | 計算量の目安 |
|---|---|
| ActionID / concrete run の照会 | ハッシュ辞書による平均 O(1) |
| start / allowConcurrent / Runner の登録・解除 | 平均・償却 O(1)。task 作成などの固定費を伴う |
| cancel(id:) | O(k) |
| lifetime の存在確認 | 最初の一致まで。最良 O(1)、最悪 O(n) |
| lifetime の件数照会・対象選択 | O(n) |
| cancelAll / deinit の cancel | O(m) |
| TaskLocal の所有文脈が空の場合の自己待機確認 | O(1) |
| 追跡索引と所有台帳 | O(n + m) |

辞書の走査は確保容量や疎密にも影響される。キャンセルだけでは task の所有を解除しないため、
未終了の operation が残ればその handle と capture も残る。
`waitForIdle()` の時間は operation の終了と、待機中に受け付ける work に依存する。

## 測定条件

- 測定日: 2026-09-16（日本時間）
- 環境: Apple M1 Pro、16 GB、macOS 26.2、Swift 6.3.2
- 実行: 独立した Release executable。時間測定には sanitizer / profiler を付けない
- 集計: 7回の別プロセス測定の中央値。各シナリオの最初の1回を warmup として除外
- 規模: 100 / 1,000 / 10,000 run、1 / 最大100 / run ごとに異なる ActionID

[測定データ](performance-results.json) の `working` は、参照 identity の所有 marker、
存在確認の早期終了、空の所有文脈での走査省略を使う実装の測定用スナップショットである。
`source_hashes` は測定時の Package.swift と Sources の内容を識別する。
ソースコメントもハッシュの対象であり、測定の識別情報を後から書き換えない。

Store の全 run に `.screenBound` を指定する。一致あり照会は `.screenBound`、一致なし照会は
`.appBound` を探す。start / cancel は operation が動く前の同期的な一括呼び出しである。
終了待ちは Swift の task scheduling と benchmark の gate を含む。
Slot では置換を受け付けている間にも operation が gate に到達できる。

## 操作ごとの測定値

Store は **10,000 run / 100 ActionID**、Slot は10,000回の置換を測定する。
各行は表に示す回数全体の時間である。

| 操作 | 中央値 |
|---|---:|
| Store の start × 10,000 | 16.94 ms |
| Slot の replace × 10,000 | 10.80 ms |
| lifetime の存在確認・一致あり × 1,000 | 0.034 ms |
| lifetime の存在確認・一致なし × 1,000 | 51.64 ms |
| lifetime の件数照会 × 1,000 | 17.42 ms |
| Store の cancel(lifetime:)、対象10,000 run | 7.84 ms |
| Store の全 run 終了待ち | 17.67 ms |
| 一括処理終了後の idle wait × 1,000 | 0.569 ms |
| ignoreNew の重複拒否 × 1,000 | 0.167 ms |

100 run / 100 ActionID の start は合計0.199 ms、ActionRunner の10,000回実行は約10 msである。
これらは runtime と測定用の処理を含む壁時計時間であり、ライブラリ内部だけの CPU 時間ではない。

### lifetime 照会

存在確認は最初の一致で終わる。すべてが screen lifetime の測定では、1,000回の一致あり照会は
約0.034 msとなる。10,000 run がすべて異なる ActionID の条件でも約0.033 msである。

一致なし照会は全件を走査する。100 ActionID の条件では1,000回で51.64 ms、1回では約52 µsとなる。
件数を数える17.42 msより高いため、早期終了が常に有利とは限らない。

lifetime の別索引を持てば照会を定数時間にできるが、登録・キャンセル・完了の更新責務が増える。
追跡情報は単一索引に置き、実アプリの CPU プロファイルで照会が支配的な場合に再評価する。

### MainActor の占有

10,000回の同期 start は約17 msかかる。この量を一度に受け付けると描画へ影響し得る。
大量処理には task group や利用側での件数制限を検討する。
Store / Runner の operation に重い同期計算を置く場合も、実際の actor 隔離と占有時間を確認する。

### メモリ

測定プロセス全体の最大 resident set size の中央値は **43.75 MiB**、範囲は43.59〜44.33 MiBである。
Swift runtime と benchmark のデータを含む高水位の値であり、Tasking だけの live allocation や
リーク量を表さない。メモリの残留を調べる場合は、operation が実際に終了しているかも確認する。

## 実装選択の比較

比較用実装 `baseline` は、所有 marker に UUID を使い、lifetime の存在確認を件数照会で行い、
所有文脈が空でも自己待機候補を走査する。追跡索引と所有台帳の分離は両実装で共通である。
同じ benchmark を別ディレクトリでビルドし、両実装の実行順を交互にした7回の中央値を比較する。

| 操作 | 比較用実装 `baseline` | 参照 identity 等を使う実装 `working` |
|---|---:|---:|
| Store の start × 10,000 | 21.26 ms | 16.94 ms |
| Slot の replace × 10,000 | 19.97 ms | 10.80 ms |
| lifetime 存在確認・一致あり × 1,000 | 17.55 ms | 0.034 ms |
| lifetime 存在確認・一致なし × 1,000 | 33.51 ms | 51.64 ms |
| 一括処理終了後の idle wait × 1,000 | 1.003 ms | 0.569 ms |
| プロセス全体の最大RSS | 43.67 MiB | 43.75 MiB |

RSS の範囲は baseline が42.75〜43.92 MiB、working が43.59〜44.33 MiBで重なる。
この測定からメモリの明確な差は主張しない。

公開版0.3.0（commit `4a3eeeedf37e291a7effeba08cad0cd24224d50c`）の別途5回の測定では、
同じ10,000 run / 100 ActionID の start が約14.81 ms、lifetime 件数照会1,000回が約857 ms、
Slot の10,000回置換が約10.2 msだった。表の working は開始に約2.1 ms多くかかる一方、
件数照会は約17 msである。公開版の数値は7回の比較と別の測定であり、小差から優劣を断定しない。

### CPU プロファイル

Time Profiler では照会を1回にし、start / cancel / completion の多い workload を使う。
UUID.init を含むスタックの inclusive な CPU サンプル比率は baseline が約8.2%、working が約4.6%である。
`OwnedTasks.keysExcludedFromWait` の走査は baseline で約2.7%、working ではサンプルが観測されていない。

採録時間と反復数が異なるため、これらの比率をそのまま速度改善率にしない。
inclusive な値は重複を含み得るため足し合わせない。
通常の壁時計時間と分け、所有識別や走査のコストを判断する補助資料とする。

`@inlinable` / `@usableFromInline` は別の11回比較で明確な利益を示していない。
内部表現を公開する保守負担との判断は [ADR-0015](adr/0015-measured-ownership-overhead.md) に記録する。

## 再計測

[Benchmarks](../Benchmarks/README.md) に実行・比較・プロファイルの手順を示す。
利用者の端末と workload で測り、件数、ID の分布、照会の一致率、キャンセルへの協調を合わせる。
固定の性能閾値を通常テストに置かず、公開契約の検証と測定を分離する。
