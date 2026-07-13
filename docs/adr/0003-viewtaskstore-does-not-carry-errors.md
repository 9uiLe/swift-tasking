# ADR-0003: ViewTaskStore は業務エラーを運ばない

- ステータス: 確定。release-safe な観測フックを実装済み
- 日付: 2026-07-03

## 文脈

同期 UI コールバックから起動した処理の結果・エラーは、呼び出し側で await
できない。エラーの通知経路が「store 経由のコールバック」「ViewModel state」の
二重になると、どちらを見ればよいか曖昧になる。

## 決定

`ViewTaskStore.start` の operation は `Void` を返し、エラーの扱いを次で固定する:

- `CancellationError` → 正常なキャンセル終了として黙って終わる。
- それ以外の throw → **契約違反(プログラミングミス)**として
  扱う。業務エラーは operation を出る前に ViewModel state へ変換されて
  いなければならない。
- `ViewTaskStore(onUnhandledError:)` が設定されていれば、契約違反を
  `(ActionRun, ActionFailure)` として通知する。通知はログ・telemetry・crash report
  用であり、業務エラーの回復経路ではない。
- handler 未設定時は従来どおり debug assertion を発火する。

## 根拠

- エラー提示(アラート、リトライ導線、インライン表示)は本質的に UI 状態であり、
  ViewModel の責務。store がエラーを運ぶ API を持つと、状態の置き場が二重化する。
- 「業務エラーは state に変換してから境界を出る」という規律を、API 形状
  (Void 戻り + assertion)で教育する。

## 代償

- handler は opt-in のため、未設定の release ビルドでは契約違反を通知できない。
  production の composition root で logging / crash reporting handler を設定する必要がある。
- 「とりあえず throw を投げっぱなしにして store 側で拾う」という段階的導入が
  できず、採用ハードルが上がる。

## 観測タイミング

handler は operation の catch 節で、tracking 解除より前に同期実行する。そのため handler は
受け取った `ActionRun` を `isRunning(_:)` で照合できる。handler が設定されている場合は
観測経路をテスト可能にするため assertion を代替し、未設定時だけ従来の assertion を使う。
