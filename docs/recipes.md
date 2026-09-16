# 利用レシピ

この文書は、Tasking が管理するタスクと、アプリケーションが持つ業務状態を組み合わせる実装例を示す。
各例は独立したコード断片である。`Tasking` を import し、UUID を使う例では `Foundation`、
Slot の例では `TaskingCore`、View の例では `SwiftUI` も import する。

| 例に登場する依存 | アプリケーションが用意するもの |
|---|---|
| `settingsUseCase` | async throws の `save()` または `sync()` |
| `searchUseCase` | `[SearchResult]` を返す async throws の `search(_:)` |
| `feedUseCase` | `[FeedItem]` を返す async throws の `fetch()` |
| `profileUseCase` / `SyncUseCase` | async throws の `sync()` |
| `SearchResult` / `FeedItem` | 業務の値型 |

クラス内の依存プロパティと初期化子は省略している。
SwiftUI の再描画には、対象 OS に合う `@Observable` または `ObservableObject` を ViewModel に適用する。
依存の宣言・初期化・UI との接続を含む例は [TaskingPrototype](../Examples/TaskingPrototype/Sources/TaskingPrototype/PrototypeApp.swift)、
その振る舞いの検証は [機能のテスト](../Examples/TaskingPrototype/Tests/TaskingPrototypeTests) を参照する。

## キャンセル時の表示状態を定義する

読み込みや保存を開始するメソッドは、成功・失敗・キャンセルのすべての経路で表示状態を確定させる。
次の例では `CancellationError` を受け取ると `.idle` に戻し、Store へ投げ直す。
Store はそのエラーを通常のキャンセルとして扱う。

この例は同時に1回だけ実行する場合を扱う。手動キャンセル直後の再開始や差し替えで実行が重なる場合は、
次節の世代ガードを合わせて使う。

```swift
@MainActor
final class SettingsViewModel {
    enum SaveState {
        case idle
        case saving
        case saved
        case failed(any Error)
    }

    private(set) var saveState: SaveState = .idle

    func save(cancellation: CancellationContext) async throws {
        saveState = .saving
        do {
            try cancellation.check()
            try await settingsUseCase.save()
            try cancellation.check()
            saveState = .saved
        } catch let error as CancellationError {
            saveState = .idle
            throw error
        } catch {
            saveState = .failed(error)
        }
    }
}
```

一覧の再読み込みなど、キャンセル時に表示を残したい場合は、開始前の状態を保存して復元する。
復元する状態はタスクの追跡状態から推測せず、ViewModel の状態として持つ。

## 結果と後処理を実行の世代で制御する

キャンセル要求から終了までは時間差がある。古い実行の `catch` や `defer` が、新しい実行の開始後に動く場合もある。
実行ごとの世代を用意し、結果・エラー・読み込み状態の更新時に、その実行が最新かを確認する。

```swift
@MainActor
final class SearchViewModel {
    private var latestSearch = UUID()
    private(set) var isSearching = false
    private(set) var results: [SearchResult] = []
    private(set) var errorMessage: String?

    func search(term: String, cancellation: CancellationContext) async throws {
        let search = UUID()
        latestSearch = search
        isSearching = true
        errorMessage = nil

        defer {
            if latestSearch == search {
                isSearching = false
            }
        }

        do {
            try cancellation.check()
            let newResults = try await searchUseCase.search(term)
            try cancellation.check()
            if latestSearch == search {
                results = newResults
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            if latestSearch == search {
                errorMessage = String(describing: error)
            }
        }
    }
}
```

キャンセル確認は処理を続けるか、世代ガードは結果を採用するかを決める。
送信済みのリクエストや保存済みのデータを巻き戻す機能ではないため、
外部への副作用には必要に応じて業務側の重複排除や順序規則を設ける。

## キャンセルした実行の終了を待つ

Store はキャンセル時に追跡を解除し、ハンドルを終了まで所有する。
1回の実行を待つには、`start` が返した `ActionRun` を保持して `awaitCompletion(of:)` に渡す。
次の断片は MainActor 上の async 関数で使い、`taskStore` と `viewModel` はその機能の依存を表す。

```swift
let outcome = taskStore.start(
    id: "settings.save",
    lifetime: .screenBound
) { cancellation in
    try await viewModel.save(cancellation: cancellation)
}
guard case let .started(run) = outcome else {
    return
}

taskStore.cancel(run)
await taskStore.awaitCompletion(of: run)
```

全体の終了には `waitForIdle()` を使う。受付が開いていれば、待機中に開始された処理も待つ。
副作用を実終了まで直列化する必要がある場合は、新規開始の入口も制御する。
`.ignoreNew` はキャンセル済みの処理を重複として扱わない。

## 所有者の終了時は受付を閉じる

`cancelAndWaitForIdle()` は、最初の中断点より前に受付を閉じ、キャンセルを要求する。
その後、所有するすべての処理の終了を待つ。Store と Slot のどちらでも同じ形で使える。

```swift
actor SyncCoordinator {
    private let slot = TaskSlot()

    func shutDown() async {
        await slot.cancelAndWaitForIdle()
    }
}
```

受理済みの処理を完了させる場合は、`close()` の後に `waitForIdle()` を呼ぶ。
同じ所有者を再利用する場合は、Store の `cancel(lifetime:)` や Slot の `cancel()` を使う。

待機側をキャンセルしても、この待機は中断せず、所有するタスクにもキャンセルを伝播しない。
終了しない処理があれば、待機も完了しない。

## 処理内の並行実行を構造化する

`async let` または task group を使うと、子タスクは親のキャンセルを引き継ぎ、親が終了する前に合流する。
次の例は MainActor 上の同期コードから開始し、`viewModel.recordSyncFailure(_:)` が業務エラーを表示状態へ変換する。

```swift
viewTaskStore.start(id: "sync", lifetime: .screenBound) { cancellation in
    do {
        try cancellation.check()
        async let profile: Void = profileUseCase.sync()
        async let settings: Void = settingsUseCase.sync()
        _ = try await (profile, settings)
        try cancellation.check()
    } catch is CancellationError {
        return
    } catch {
        viewModel.recordSyncFailure(error)
    }
}
```

処理内で別の `Task {}` を作ると、独立した非構造化タスクになる。
`CancellationContext` を渡しても、そのタスク内ではそのタスク自身のキャンセル状態を読む。
所有される処理やその構造化子タスクから、自分自身の終了を待つ API を呼んではならない。

## 処理と所有者の参照関係を設計する

Store はタスクのハンドルを保持し、タスクは処理本体のクロージャを保持する。
処理が Store の所有者を強参照すると、次の循環ができる。

```text
owner → store → task → operation → owner
```

循環が残ると、外部から所有者への参照を手放しても `deinit` のキャンセルが働かない。
長い処理には必要な依存を捕捉し、状態の反映時に所有者を弱参照で参照する。

```swift
@MainActor
final class StoreOwningViewModel {
    let store = ViewTaskStore()
    private let syncUseCase = SyncUseCase()
    private(set) var isSynced = false
    private(set) var errorMessage: String?

    func startSync() {
        store.start(id: "sync", lifetime: .screenBound) { [weak self, syncUseCase] cancellation in
            do {
                try cancellation.check()
                try await syncUseCase.sync()
                try cancellation.check()
                self?.isSynced = true
            } catch let error as CancellationError {
                throw error
            } catch {
                self?.errorMessage = String(describing: error)
            }
        }
    }
}
```

`[weak self]` を指定しても、`await` の前に `guard let self` で強参照へ変えると、中断中は所有者を保持する。
依存を直接捕捉し、結果の反映時に `self?` を使うと、その保持を避けられる。

この例は参照構成を示す。キャンセル後の再開始も許す場合は、状態更新に世代ガードを追加する。
Slot を持つサービスも同じ参照規則に従う。
アプリや Environment に渡す同期ハンドラが Store を保持する場合も、実際の参照関係を確認する。

## エラーを外へ投げないメソッドで協調する

async メソッドがエラーを外へ投げない場合は、`isCancelled` で終了を判断できる。
依存先が `CancellationError` を投げる経路も扱い、キャンセルを業務上の失敗として表示しない。
次の例は実行が重ならない場合の状態遷移を示す。

```swift
@MainActor
final class FeedViewModel {
    enum LoadState {
        case idle
        case loading
        case loaded([FeedItem])
        case failed(any Error)
    }

    private(set) var state: LoadState = .idle

    func load(cancellation: CancellationContext) async {
        if cancellation.isCancelled { return }
        state = .loading
        do {
            let items = try await feedUseCase.fetch()
            if cancellation.isCancelled {
                state = .idle
                return
            }
            state = .loaded(items)
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed(error)
        }
    }
}
```

Store と SwiftUI `.task` から同じメソッドを呼ぶ場合も、キャンセル引数を必須にする。
`.task` 内で `CancellationContext()` を渡すと、その `.task` を実行しているタスクの状態をメソッド内から参照できる。
次の断片は `viewModel` を持つ SwiftUI View の修飾子として使う。

```swift
.task {
    await viewModel.load(cancellation: CancellationContext())
}
```

## ActionID と開始方針をまとめる

共有 Store では `feature.action` の名前空間を使い、同じ Action の方針を機能内の1か所に置く。
次の宣言と呼び出しは、保存処理の ID と開始方針を共有する。
`viewTaskStore.start` の呼び出しは MainActor 上の同期ハンドラ内に置く。

```swift
private enum SettingsAction {
    static let save: ActionID = "settings.save"
    static let savePolicy: TaskStartPolicy = .ignoreNew
}

viewTaskStore.start(
    id: SettingsAction.save,
    lifetime: .screenBound,
    policy: SettingsAction.savePolicy
) { cancellation in
    try await viewModel.save(cancellation: cancellation)
}
```

呼び出し箇所が多い場合は、機能専用の同期ハンドラに開始処理をまとめる。
Runner の ID と重複方針は `ActionDescriptor` でまとめる。
