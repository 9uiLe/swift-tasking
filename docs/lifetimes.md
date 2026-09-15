# ライフタイムと所有構成

`ActionLifetime` は、どの run を一括で照会・キャンセルするかを決めるラベルである。
処理を継続したい期間に合わせて Store の所有者を配置し、その期間の終わりにキャンセルを要求する。
ラベルを指定するだけでは、画面イベントや OS のバックグラウンド実行には接続されない。

## 配置の原則

| ラベル | Store の所有者 | 利用側が接続するイベントの例 |
|---|---|---|
| `.screenBound` | 画面の View または画面のコンテナ | `onDisappear` で対象を cancel |
| `.sceneBound` | シーンごとのルート View またはコンテナ | シーンの終了方針に応じて cancel / close |
| `.appBound` | アプリ全体のコンテナ | ログアウトやアプリ側のサービス終了で cancel / close |
| カスタムラベル | 同じ所有者の中の処理群 | その機能の終了イベントで cancel |

Store は解放時に所有中の全 task にキャンセルを要求する。ただし解放時点は参照関係で決まり、
キャンセル要求後も operation が終了するまで処理は続き得る。
表示終了とキャンセル要求を対応させたい場合は、ライフサイクルイベントで明示的に呼び出す。

Store を共有する場合は、同じラベルへの `cancel(lifetime:)` が全該当 run に及ぶ。
画面単位でキャンセルしたい処理は Store を分けるか、機能固有のラベルや `ActionRun` で選択する。

## 画面で所有する

次の断片では、`viewModel.save(cancellation:)` が業務エラーを表示状態に変換し、
キャンセル時の後始末を行う。ViewModel の実装は [利用レシピ](recipes.md) を参照する。
SwiftUI の例で使う型は `@MainActor` とする。

```swift
@MainActor
struct EditorView: View {
    @State private var taskStore = ViewTaskStore()
    let viewModel: SettingsViewModel

    var body: some View {
        Button("Save") {
            taskStore.start(id: EditorActions.save, lifetime: .screenBound) { cancellation in
                try await viewModel.save(cancellation: cancellation)
            }
        }
        .onDisappear {
            taskStore.cancel(lifetime: .screenBound)
        }
    }
}

private enum EditorActions {
    static let save: ActionID = "editor.save"
}
```

再表示時に同じ Store を使うため、ここでは受付を開いたまま cancel する。
`close()` は終端的な操作であり、一度閉じた Store では start を受け付けない。

## シーンで所有する

`WindowGroup` 内のルート View に Store を置くと、ウィンドウごとに異なる所有者を持てる。
子画面にはその Store または同期の操作ハンドラを渡す。

```swift
@MainActor
struct SceneRoot: View {
    @State private var taskStore = ViewTaskStore()

    var body: some View {
        SceneContent(taskStore: taskStore)
    }
}
```

`SceneContent` はアプリ側の View であり、必要な処理を `.sceneBound` で開始する。
シーンの inactive 化でキャンセルするかは処理ごとに決める。システムダイアログや
一時的なフォーカス喪失も inactive を起こすため、inactive とシーンの終了を同一視しない。

## アプリで所有する

画面を閉じても継続する同期処理は、Store と表示用の ViewModel をアプリ寿命の
コンテナに配置する。Store だけが長生きし、ViewModel を画面ごとに作り直す構成では、
画面へ戻ったときに進行中の処理と表示状態が食い違う。

コンテナは `App` の `@State` などで保持し、必要な画面へ渡す。
次は iOS 17 / macOS 14 以降の `onChange(of:initial:)` を使う例である。
`RootView` はアプリ側の View、`prepareServices()` はエラーを内部処理する準備操作を表す。

```swift
@main
@MainActor
struct MyApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var taskStore = ViewTaskStore()
    @State private var didRequestPreparation = false

    var body: some Scene {
        WindowGroup {
            RootView()
                .onChange(of: scenePhase, initial: true) { _, phase in
                    guard phase == .active, !didRequestPreparation else { return }
                    didRequestPreparation = true
                    taskStore.start(
                        id: AppActions.prepare,
                        lifetime: .appBound,
                        policy: .ignoreNew
                    ) { _ in
                        await prepareServices()
                    }
                }
        }
    }
}

private enum AppActions {
    static let prepare: ActionID = "app.prepare"
}
```

`didRequestPreparation` はアプリ寿命で1度だけ要求する方針を表す。
`.ignoreNew` 単独は追跡中の重複を拒否するだけで、完了後の再要求は受け付ける。
失敗後に再試行したい処理では、準備状態と再試行条件をアプリ側で管理する。

システムダイアログを出す準備処理は、表示によって `scenePhase` が変わることがある。
`.task(id: scenePhase)` に処理を結び付けると、その変化で自分の処理がキャンセルされ得る。
シーンの状態変化と独立して継続したい場合は、上のようにアプリ側の Store が所有する。

## 所有者を終了する

- 再利用する所有者: 必要な対象を `cancel` する。
- 受け付け済みの work を自然完了させる: `close()` → `waitForIdle()`。
- 受付停止してキャンセルを要求し、終了を確認する: `cancelAndWaitForIdle()`。

operation が Store 自身やその所有者を強参照すると、解放によるキャンセルを妨げる。
[利用レシピ](recipes.md) の参照関係と世代管理を確認する。

`.appBound` は background execution の保証ではない。アプリが suspend されると task も進行できず、
プロセス終了時の完遂も保証しない。必要な処理には OS の background task や転送 API を組み合わせる。
