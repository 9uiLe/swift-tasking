# Tasking のベンチマーク

`TaskingBenchmarks` は公開 API と標準 Swift で書いた対照を Release で実行する。
正しさのテストとは分離し、操作時間、受付から開始までの遅延、キャンセル後の未終了件数を測る。
計算量と測定済みの結果は [性能特性](../docs/performance.md) を参照する。

## 実行する

macOS 13 以降、Swift tools 6.0 以降を使い、リポジトリのルートで実行する。

```sh
swift run --package-path Benchmarks -c release TaskingBenchmarks
```

| オプション | 既定値 | 意味 |
|---|---|---|
| `--sizes` | `1,8,32,128,1000,10000` | 1バッチの実行数 |
| `--samples` | `7` | ウォームアップ後の測定回数 |
| `--queries` | `1000` | Store の1バッチあたりの照会・受付拒否の試行数 |
| `--scenario` | `all` | `all` / `store` / `runner` / `slot` / `ownership` |
| `--order` | `tasking-first` | 対照との順序。`native-first` も選べる |

各条件のウォームアップを1回除外する。単独実行の測定回数は同じプロセス内の反復であり、
独立プロセスの測定回数とは区別する。出力は1行1件の JSON である。

| フィールド | 内容 |
|---|---|
| `scenario` / `metric` | 負荷と測定対象 |
| `size` / `operations` | バッチの実行数と測定する操作数 |
| `sample` | ウォームアップ後のサンプル番号 |
| `unit` / `value` | `ms` または `count` と、その値 |

## 同じ範囲を対照と比較する

| シナリオ | 負荷と比較範囲 |
|---|---|
| `store.*-actions` | 1種類・最大100種類・実行ごとに異なる ActionID。グループ照会とキャンセル。標準対照との直接比較はしない |
| `runner` / `native.async-gate` | 同じ ID の逐次 async 呼び出しと値の受け渡し。標準対照は1操作の状態ガード |
| `slot` / `native.slot` | actor 上で繰り返し差し替え、キャンセル済みも含め全処理を終了まで所有する |
| `ownership.store` / `ownership.native` | 同期 MainActor バッチから開始し、ゲートで全処理を止め、キャンセル後も保持し、受付を閉じて実終了を待つ |

標準対照はこの負荷に必要な契約を手書きする。キャンセルで単一ハンドルを上書きするだけの対照は使わない。
ただし対照は Tasking の API 全体を再実装せず、グループ選択、複数 ActionID の管理、自己待機の検出は比較範囲外である。
結果は限定した処理に払う費用を示し、ライブラリ全体の代替可能性や他アプリの速度は示さない。

`ownership` はタスクごとの受付時刻と処理本体の開始・終了時刻を記録する。
`admission-to-start.p50/p95/p99` と `cancel-to-body-end.p50/p95/p99` は、バッチ内の時刻差を昇順に並べ、
位置 `ceil((件数 - 1) * p)` の値を選ぶ。1件なら同じ値になる。全バッチ時間を1件あたりの遅延に割り算しない。

`uninterrupted-admission` は中断点のない同期受付バッチの時間、`main-actor-probe-delay` はその直前に投入した
MainActor タスクが実行機会を得るまでの時間である。描画や実アプリのフレーム落ちを測る指標ではない。
時計・配列への記録費用は両対照に含め、これらの区間内では JSON を出力しない。

ゲートはキャンセルに協調しない。`unfinished-after-cancel` は、全処理がゲートに到達してからキャンセルし、
ゲートを開く前の保持件数である。`cancel-to-idle` はキャンセル要求からゲートの明示開放、実終了の待機までを含む。
実ネットワークの中断応答時間ではなく、即時に解放したゲートとスケジューラを含む負荷の時間である。

Store のグループ照会シナリオでは、処理本体が実行機会を得る前に開始・照会・キャンセルする。
Slot の処理は差し替え受付中にも動ける。開始前キャンセルと開始後キャンセルを混同しない。

## 独立プロセスの結果を保存する

Python 3 と Apple の `/usr/bin/time -l` を使う。
既存の保存先は上書きしないので、新しいディレクトリを指定する。

```sh
python3 Benchmarks/record.py --output Benchmarks/results/current
```

`--samples`、`--sizes`、`--queries`、`--scenario` も指定できる。
先にビルドを完了し、独立したプロセスでウォームアップ1回と測定1回を行う。
Tasking と標準対照の順序をプロセスごとに反転する。

| 出力 | 内容 |
|---|---|
| `report.json` | 環境、ソースハッシュ、各条件のサンプル数・中央値・最小/最大・p95/p99、プロセス最大 RSS |
| `samples.jsonl` | 独立プロセスの番号と実行順を含む生の測定値 |
| `build.log` | Release ビルドの診断 |

`report.json` の p95/p99 はプロセスごとの値に対する線形補間 `p * (サンプル数 - 1)` で、
バッチ内のタスク遅延 percentile とは別の集計である。少数のプロセスから母集団の tail latency を推定しない。

ソースハッシュはルートと Benchmarks の `Package.swift`、両 `Sources` の相対パスと内容を対象にする。
コメントも含み、ビルド・測定中の変更は拒否する。測定後の編集でハッシュを更新せず、再測定で別の記録を作る。
最大 RSS はバイト単位のプロセス全体の高水位であり、Tasking 単体の確保量でも、対照間のメモリ差でもない。

## 2つの実装を比較する

同じ公開 API に対応するソース間では、同一ハーネスを使う `compare.py` で比較できる。
`CancellationContext` / `ActionLifetime` を使う旧 API のソースは、このハーネスではビルドできない。
対応した比較元の Git リビジョン、または保存したソースを指定する。

```sh
python3 Benchmarks/compare.py --baseline-path /path/to/source-snapshot --output Benchmarks/results/comparison
```

`--baseline-ref` なら Git リビジョンを指定する。比較元を省略した場合の既定値は `HEAD` である。
両ソースを別ディレクトリでビルドし、プロセスの実行順を交互に入れ替える。
`metadata.json`、`samples.jsonl`、`memory.json`、`summary.json` とビルドログを保存する。
`summary.json` は `unit` を保持し、`baseline` / `working` の中央値と比率を出す。比較元が0なら比率は `null` となる。

## 解釈とプロファイリング

ビルド・テスト・プロファイラなど CPU 負荷の高い処理を測定と同時に動かさない。
一致率、ID 分布、グループ、キャンセル対応、所有者の再利用、入力頻度を実際の負荷に合わせる。
絶対時間のしきい値を正しさの CI テストに入れない。

Time Profiler を使うときは先にビルドする。

```sh
swift build --package-path Benchmarks -c release
xcrun xctrace record --template 'Time Profiler' --time-limit 10s \
  --output /tmp/tasking.trace --launch -- \
  Benchmarks/.build/release/TaskingBenchmarks \
  --scenario ownership --sizes 10000 --samples 200 --queries 1
```

採録が完了してトレースをエクスポートできることを確認する。
CPU サンプル比率を実時間の高速化率に換算せず、プロファイラなしの測定と分ける。
