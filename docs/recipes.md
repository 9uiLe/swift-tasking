# 利用レシピ

Tasking は task の所有と重複方針を管理する。業務結果、表示状態、古い処理の結果を採用するかは
ViewModel / service が決める。以下はその実装パターンである。

Swift の断片では `import Tasking`、UUID を使う箇所では `import Foundation`、Slot の例では
`import TaskingCore` を前提とする。`settingsUseCase`、`searchUseCase` などの依存と domain の値型は
アプリが用意する。クラスの断片では依存の宣言と initializer を省略する。
実行可能な例は [TaskingPrototype](../Examples/TaskingPrototype/Sources/TaskingPrototype/PrototypeApp.swift) を参照する。

## キャンセル時の表示状態を定義する

Store は `CancellationError` を正常な終了として扱う。ViewModel が `.saving` / `.loading` を
設定した場合は、キャンセル経路で表示を復旧してから投げ直す。

次の例は同じメソッドの実行が重ならない場合の状態遷移を示す。
手動キャンセル後の再開始や `.cancelExisting` で重なる場合は、次節の世代ガードも使う。

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

ロード前の表示を残したい場合は、開始前の状態を保存してキャンセル時に戻す。
たとえば一覧の再読込をキャンセルしたら、ロード済みの一覧を表示し続ける。

## 結果と後始末を実行の世代で制御する

キャンセルは協調的であり、古い run の `catch` や `defer` が新しい run の開始後に動くことがある。
結果・エラー・loading の更新を、その実行が最新かで判断する。

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

キャンセル確認は処理の継続を判断し、世代ガードは結果の採用を判断する。
両方を使っても、送信済みのリクエストや保存済みのデータを巻き戻すことはできない。
外部への副作用には、必要に応じて domain 側の重複排除や順序規則を設ける。

## キャンセルと実終了を区別する

Store の cancel は run を追跡から即座に外す。したがって `isRunning == false` は実終了を表さず、
`.ignoreNew` はキャンセル済みで未終了の run を重複として扱わない。

1回の具体的な実行が終わるまで待つ場合は、start が返した `ActionRun` を使う。
次の断片は MainActor の async 関数内で実行する。

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

Store が所有する全 run の終了確認には `waitForIdle()` を使う。
受付が開いていれば、待機中に開始された run も対象にする。
特定の処理同士を実終了まで直列化したい場合は、新規開始の入口も制御する。
`.ignoreNew` だけで副作用の直列化を保証しない。

## 所有者の終了時は受付を閉じてから待つ

`cancelAndWaitForIdle()` は、最初の suspension より前に受付を閉じ、キャンセルを要求する。
Store / Slot ともに、終了処理中の新しい start / replace を拒否できる。

```swift
actor SyncCoordinator {
    private let slot = TaskSlot()

    func shutDown() async {
        await slot.cancelAndWaitForIdle()
    }
}
```

自然完了を待つ場合は `close()` の後に `waitForIdle()` を呼ぶ。
close は終端であるため、再表示する画面の `onDisappear` では `cancel(lifetime:)` を使う。
同じ Slot を再利用する場合も `cancel()` を使う。

待機する側のキャンセルは、所有する task をキャンセルせず、待機を中断しない。
operation が終了しなければ待機も終わらない。

## operation 内の並行処理を構造化する

operation 内で `Task {}` を作ると独立した task になり、外側のキャンセルは自動伝播しない。
`CancellationContext` を渡しても、内側で読むのは内側の task の状態である。
並行処理には `async let` / task group を使う。

次の断片では `viewModel.recordSyncFailure(_:)` が同期の MainActor メソッドとして
業務エラーを表示状態に変換する。

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

構造化子 task は親の終了前に合流する。所有中の operation またはその構造化子 task から、
同じ Store / Slot の自分の終了を待つ操作は呼ばない。

## operation と所有者の参照関係を設計する

Store は task handle を保持し、task は operation closure を保持する。
operation が Store や Store を所有するオブジェクトを強参照すると、次の循環ができる。

```text
owner → store → task → operation → owner
```

外部から owner を解放しても、この循環中は `deinit` のキャンセルが働かない。
長い処理に必要な依存だけを捕捉し、所有者への反映には弱参照を使う。

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

この例は `.ignoreNew` で追跡中の重複を拒否する。キャンセル後の再開始を許す利用側では、
この参照構成に加えて世代ガードを設ける。

`[weak self]` でも、await の前に `guard let self` で強参照へ変えると suspension 中は所有者を保持する。
依存を先に捕捉し、結果反映時に `self?` で参照する形を使う。

アプリや Environment が持つ同期ハンドラが Store を保持する構成は、この循環とは別である。
その場合も実際の所有関係を確認し、operation の捕捉を小さく保つ。
Slot を所有する service も同じ参照規則に従う。

## non-throwing メソッドで協調する

non-throwing の ViewModel メソッドは `isCancelled` で早期に return できる。
呼び出し先が `CancellationError` を投げる経路も扱い、キャンセルで業務失敗を表示しない。
次の例も、実行が重ならない場合の状態遷移を示す。

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

Store と SwiftUI `.task` から同じメソッドを呼ぶ場合も、context は non-optional で受け取る。
`.task` の中では `CancellationContext()` を渡す。値の構築時点ではなく、アクセス時点の
実行中 task を読むため、その `.task` の中で呼び出すメソッドは同じキャンセル状態を確認できる。

```swift
.task {
    await viewModel.load(cancellation: CancellationContext())
}
```

## ActionID と方針をまとめる

同じ ActionID の重複方針は feature 内の1か所で宣言する。
共有 Store では `feature.action` の名前空間を使い、別 feature の処理との衝突を防ぐ。

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

呼び出し箇所が多い場合は feature 専用の同期ハンドラにまとめ、ID と方針をそこで選択する。
Runner では `ActionDescriptor` が ID と方針をまとめる。
