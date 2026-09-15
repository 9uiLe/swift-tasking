# ADR-0003: Store の業務結果とエラー表示を ViewModel に置く

## 前提

同期 UI コールバックから始める処理では、結果や失敗を UI の状態へ反映する必要がある。
状態の反映と、task 所有の終了処理を別々の責務として定義する。

## 決定

Store の operation は `async throws -> Void` とする。

| operation の終了 | Store の扱い |
|---|---|
| 正常 return | run の追跡と所有を解除する |
| `CancellationError` | 正常なキャンセル終了として解除する |
| その他の error | 契約違反を報告して解除する |

業務エラーの回復・表示は operation 内で行う。漏れたエラーは、生存中の Store に設定された
`onUnhandledError` observer へ `(ActionRun, ActionFailure)` として通知する。
observer がなければ Debug で assertion を発生させ、Release では通知しない。
Store 解放後に漏れたエラーも、observer がない場合と同じ扱いにする。

## 理由と制約

保存失敗のアラートや retry の可否は業務状態である。ViewModel に判断を集めることで、
利用者は表示と回復の経路を1か所で把握できる。observer はログ・計測・crash report の通知点とする。

observer は完了による追跡解除の前に MainActor で同期実行する。
キャンセルにより追跡解除済みの run は、通知時にも追跡外である。
Store は observer を保持するため、observer が Store の所有者に戻る場合は弱参照を使う。
