# Tasking のベンチマーク

`TaskingBenchmarks` は、公開 API の操作時間を Release ビルドで測定する実行ファイルです。
正しさのテストとは独立して動き、負荷条件ごとの時間とプロセス全体のメモリを比較できます。
測定済みの結果と設計上の解釈は [性能特性](../docs/performance.md) を参照してください。

## 操作時間を測定する

macOS 13 以降と Swift 6 ツールチェーンが必要です。リポジトリのルートで実行します。

```sh
swift run --package-path Benchmarks -c release TaskingBenchmarks
```

| オプション | 既定値 | 意味 |
|---|---|---|
| `--sizes` | `100,1000,10000` | 測定する実行数（カンマ区切り） |
| `--samples` | `7` | ウォームアップ後の測定回数 |
| `--queries` | `1000` | Store の1バッチあたりの照会・重複受付試行の回数 |
| `--scenario` | `all` | `all`、`store`、`runner`、`slot` のいずれか |

シナリオごとにウォームアップを1回行い、その結果は集計から除外します。
出力は1行1件の JSON で、シナリオ、測定項目、実行数 `size`、操作数 `operations`、
サンプル番号、バッチ全体の所要時間 `milliseconds` を含みます。

## 負荷条件を理解する

| 対象 | 測定する操作 |
|---|---|
| Store | 開始、寿命の存在・件数照会、重複拒否、寿命単位のキャンセル、終了待ち |
| Runner | Action の逐次実行と終了結果 |
| Slot | 繰り返しの差し替えと終了待ち |

Store は、1種類・最大100種類・実行ごとに異なる ActionID の3通りを使います。
ID は計測前に生成し、すべての実行に `.screenBound` を指定します。
寿命の一致照会は `.screenBound`、不一致照会は `.appBound` を探します。

開始とキャンセルは、処理本体が実行機会を得る前に MainActor 上の同期バッチで行います。
終了待ちにはタスクのスケジューリングと測定用ゲートの処理も含まれます。
Slot の処理は差し替えの受付中にもゲートへ到達できます。
ネットワーク、業務ロジック、実アプリのキャンセルハンドラは、この負荷に含みません。

## 2つのソースを比較する

Python 3 と Git を使い、比較元のリビジョンと現在の作業内容を独立してビルドします。

```sh
python3 Benchmarks/compare.py --baseline-ref HEAD --output Benchmarks/results/comparison
```

`baseline` は指定した Git リビジョン、`working` は実行時の Package.swift・Sources・Tests のスナップショットです。
同じベンチマークソースを使い、別プロセスの実行順を交互にして比較します。
各プロセスでは、シナリオごとにウォームアップと本計測を1回ずつ行います。

保存済みのソースを比較元にする場合は `--baseline-path` を使います。
`--sizes`、`--samples`、`--queries` も指定できます。
両方のソースが、ベンチマークで使う公開 API に対応している必要があります。

| 出力 | 内容 |
|---|---|
| `metadata.json` | 環境、ソースハッシュ、比較元、スナップショットとバイナリの場所 |
| `samples.jsonl` | ソースのラベルとプロセスのサンプル番号を含む時間計測の生データ |
| `summary.json` | 測定項目ごとの中央値と `working / baseline` の比率 |
| `memory.json` | プロセス全体の最大常駐メモリ |
| `baseline-build.log`、`working-build.log` | ビルドの診断情報 |

スナップショットは表示された一時ディレクトリに残ります。
ソースハッシュは Package.swift と Sources のコメントを含む内容を識別します。
文書やコードの変更後も、過去の測定値とハッシュはその測定時の記録として保管してください。

## 結果を評価する

同じハードウェアとツールチェーンで測り、ビルド・テスト・プロファイリングなどの CPU 負荷が高い処理を同時に実行しないでください。
中央値だけでなく、負荷条件とばらつきも報告します。
一致照会と不一致照会では走査する量が異なるため、分けて扱います。

Apple の `/usr/bin/time -l` による最大 RSS はバイト単位です。
Swift ランタイムと測定用データを含むプロセス全体の値であり、Tasking だけの確保量ではありません。
正しさを検証する CI テストには絶対時間のしきい値を設けません。

## Instruments で呼び出しの内訳を調べる

Time Profiler の起動前にビルドします。

```sh
swift build --package-path Benchmarks -c release
xcrun xctrace record --template 'Time Profiler' --time-limit 10s \
  --output /tmp/tasking.trace --launch -- \
  Benchmarks/.build/release/TaskingBenchmarks \
  --sizes 10000 --samples 200 --queries 1
```

照会を1バッチあたり1回にすると開始・キャンセル・完了が中心になり、回数を増やすと検索が中心になります。
時間制限で実行が途中終了する場合は、保存したトレースをエクスポートできることを確認してください。

子呼び出しを含む CPU サンプル比率は重複する場合があります。
採録時間が異なる比率を高速化の倍率として使わず、プロファイラなしの実時間測定と分けて報告します。
