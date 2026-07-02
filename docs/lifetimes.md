# ライフタイムの推奨構成 — store をどこに所有させるか

> ADR-0004 の帰結: `ActionLifetime` は宣言であって強制ではない。
> したがって **宣言の実効上限 = store を所有しているオブジェクトの寿命** である。
> このドキュメントは各 lifetime に対する store の推奨所有位置を示す。

## 黄金律

1. **store は所有スコープごとに 1 つ**作る(画面ごと・シーンごと・アプリに 1 つ)。
2. **task の lifetime 宣言は、その store の所有スコープ以下のときだけ実効性がある**。
   画面所有の store に `.appBound` と書いても、task は画面と共に(`deinit` で)
   キャンセルされる。
3. 複数の画面が**共有 store に同じ lifetime タグ**を入れると、
   `cancel(lifetime:)` が他画面の task まで巻き込む。共有 store では
   機能固有のカスタムタグ(`"accountSettings"` など)か `ActionRun` 単位の
   キャンセルを使う。

| 宣言 | store の推奨所有位置 | 解放・キャンセルの実際 |
|---|---|---|
| `.screenBound` | 画面 view の `@State` | view の identity 消滅 → store `deinit` が全 task をキャンセル。明示配線で早めることも可(下記) |
| `.sceneBound` | シーン(`WindowGroup` 等)のルート view の `@State` | シーン破棄と共にキャンセル |
| `.appBound` | アプリ寿命のコンテナ(下記例) | プロセス生存中は生存。`ScenePhase` 等での明示キャンセルは利用者判断 |
| カスタム(`"accountSettings"` 等) | 上記いずれかの共有 store 内の一括キャンセル単位 | `cancel(lifetime: "accountSettings")` |

## screenBound — 画面所有(基本形)

```swift
struct EditorView: View {
    @State private var taskStore = ViewTaskStore() // 画面と同じ寿命

    var body: some View {
        Button("Save") {
            taskStore.start(id: .editorSave, lifetime: .screenBound) { cancellation in
                // ...
            }
        }
        // 任意: deinit を待たず、非表示になった時点で確実に止めたい場合の明示配線
        .onDisappear {
            taskStore.cancel(lifetime: .screenBound)
        }
    }
}

extension ActionID {
    static let editorSave = ActionID("editor.save")
}
```

`@State` 所有の store は view の identity が消えた時点で `deinit` が走り、
全 task がキャンセルされる。`onDisappear` の配線は「非表示 = 即キャンセル」を
明示したい場合の追加であり、安全網は `deinit` が担う。

## appBound — アプリ寿命のコンテナ所有

「画面を閉じても完遂すべき処理」(設定の同期、送信キューのフラッシュ等)は、
**store 自体をアプリ寿命のオブジェクトに所有させる**。

```swift
@MainActor
final class AppTaskContainer {
    static let shared = AppTaskContainer()
    let store = ViewTaskStore() // アプリと同じ寿命
}

struct SettingsView: View {
    var body: some View {
        Button("Sync") {
            AppTaskContainer.shared.store.start(
                id: .settingsSync,
                lifetime: .appBound
            ) { cancellation in
                // 画面が閉じてもこの task は生き続ける
            }
        }
    }
}

extension ActionID {
    static let settingsSync = ActionID("settings.sync")
}
```

シングルトンを避けたい場合は、`App` 構造体の `@State` で所有して
ルート view にイニシャライザ注入しても同じ寿命が得られる。
要点は「何が store を所有しているか」であって、注入手段ではない。

## sceneBound — シーンのルート view 所有

```swift
@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            RootView() // RootView の @State が store を所有 = シーン寿命
        }
    }
}
```

マルチウィンドウ(iPad / macOS / visionOS)ではシーンごとにルート view の
identity が分かれるため、store も自然にシーン単位になる。

## アンチパターン

- **画面所有の store に `.appBound`** — 宣言はレビュー上「アプリ寿命の意図」を
  主張するのに、実際は画面と共に死ぬ。意図があるなら store の所有位置を変える。
- **アプリ所有の共有 store に複数画面が `.screenBound` を入れる** —
  `cancel(lifetime: .screenBound)` が全画面分を巻き込む。共有 store では
  機能固有のカスタムタグを使う。
