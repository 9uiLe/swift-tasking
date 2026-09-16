# 導入と運用

Tasking を機能へ組み込む際は、所有者・開始方針・状態更新・終了処理を一組として設計する。
パッケージの依存指定と対応 OS は [README](../README.md#導入)、各型の契約は [アーキテクチャ](architecture.md) を参照する。

## 1. 実行場所と所有者を決める

| 機能の入口 | 選ぶもの | 利用側が持つ責任 |
|---|---|---|
| 同期 UI コールバック | `Tasking.ViewTaskStore` | Store の配置、寿命ラベル、キャンセルのイベント |
| MainActor 上の async 呼び出し | `Tasking.ActionRunner` | 呼び出し元のタスクの所有とキャンセル |
| 非 UI サービスの差し替え可能な処理 | `TaskingCore.TaskSlot` | Slot の配置、結果の採用、サービス終了 |

利用側の機能モジュールも Swift 6 言語モードにする。
Swift 5 モードで import できても、クロージャの捕捉は利用側の規則で検査されるため、サポート条件を満たさない。

Store と Runner は MainActor に隔離される。重い同期計算を置くと UI の時間を占有するため、
計算を担当する actor や関数の隔離を確認する。`await` の記述だけでは実行場所は決まらない。

Slot は独立した actor で、タスクのハンドルを所有する。デバウンス、再試行、結果状態はサービスが持つ。
パッケージは default actor isolation と `NonisolatedNonsendingByDefault` を有効にしない。
コンパイラ設定や `@concurrent` などの指定を変える場合は、Swift tools の対応範囲と処理本体の実行場所を検証する。

## 2. ActionID と開始方針を宣言する

ActionID は、同じ Store または Runner 内で重複を判断する単位となる。
共有 Store に複数の機能が `"sync"` を登録すると、一方の要求がもう一方の重複として扱われる。
機能単位の名前空間と、対象ごとの識別子を使う。

```swift
import Tasking

enum BillingActions {
    static let refreshPlans: ActionID = "billing.refreshPlans"
    static let refreshPlansPolicy: TaskStartPolicy = .ignoreNew

    static func downloadInvoice(_ invoiceID: String) -> ActionID {
        ActionID("billing.downloadInvoice.\(invoiceID)")
    }
}
```

同じ Action の開始方針は機能内で共有し、呼び出し箇所ごとに分散させない。
入口が多い場合は、ID と方針を選択する同期ハンドラにまとめる。
Runner では `ActionDescriptor` を使う。

Store の開始結果は `.started(run)`、`.skipped(.alreadyRunning)`、`.skipped(.closed)` のいずれかである。
開始がスキップされた場合に必要な表示やログを、利用側で決める。

## 3. 寿命と表示状態を合わせる

Store と ViewModel は、その処理を管理・表示したい期間に合う所有者へ配置する。
共有 Store を使う場合は、ラベルによる一括キャンセルの範囲を利用する機能間で合意する。
配置例は [寿命と所有構成](lifetimes.md) を参照する。

処理本体は長い処理や重要な中断点の前後でキャンセルを確認する。
読み込み中・成功・失敗・キャンセルの状態遷移を ViewModel に定義し、実行が重なる場合は世代ガードを使う。
手動キャンセル後は、`.ignoreNew` でも前の処理が終わる前に再開始できる。

バックグラウンドでの完遂が必要な処理には、`beginBackgroundTask`、`BGTaskScheduler`、
バックグラウンド `URLSession` など、要件に合う OS API を選ぶ。
`.appBound` はその実行権限を与えない。

## 4. 終了処理と診断を接続する

同じ所有者を再利用するキャンセルと、所有者を終了する操作を分ける。
再表示する画面では `cancel(lifetime:)`、所有者の終了では `cancelAndWaitForIdle()` を使う。
受理済みの処理を完了させる場合は `close()` と `waitForIdle()` を組み合わせる。

Store の `onUnhandledError` は、処理本体から漏れた `CancellationError` 以外のエラーの通知点である。
アプリの依存を組み立てる場所でログや障害報告へ接続する。
業務エラーの回復と表示は処理本体で行い、通知先から所有者に戻る参照には弱参照を使う。
通知先がない場合は Debug でアサーションが発生し、Release では通知されない。

## 5. 機能の契約を検証する

- 同じ Action の連続呼び出しが、定めた開始方針に従う。
- キャンセルを処理本体が観測し、表示状態を復旧する。
- 古い処理の完了や後処理が、新しい状態を上書きしない。
- 所有者の終了時には新規受付を止め、キャンセル済みの処理も含めて終了を確認する。
- 画面を閉じた後や所有者を解放した後に、不要な参照が残らない。

業務結果は ViewModel の状態や業務イベントから確認し、タスクの終了は完了待ち API から確認する。
テストと CI の実行方法は [コントリビューションガイド](../CONTRIBUTING.md) に定める。
大量の開始や照会がある機能では、[性能特性](performance.md) に沿って件数・ID 分布・一致率・未終了タスク数を測る。

公開には必要な API を含む SemVer タグを使う。
配布担当者は [リリース設計と運用](releasing.md) の準備・検証・公開手順に従う。
