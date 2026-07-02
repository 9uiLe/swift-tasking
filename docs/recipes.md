# レシピ集

プロトタイプ(`Examples/TaskingPrototype`)で実証した、Tasking 利用側の定型と落とし穴。
ライブラリ本体の責務は「所有権と方針を見える形にする」ことなので、UI state や業務状態の
整合は ViewModel 側で明示的に持つ。

## キャンセル時は loading state を戻してから rethrow する

`ViewTaskStore` は `CancellationError` を正常なキャンセル終了として扱う。したがって、
operation 内の ViewModel が `.saving` / `.loading` のような state を立てた場合、
キャンセル経路でも state を戻してから `CancellationError` を投げ直す。

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

## `.cancelExisting` の後始末は世代でガードする

検索の打ち直しのように `.cancelExisting` を使う場合、古い run の `defer` や `catch` が
新しい run の開始後に実行されることがある。単純な `defer { isSearching = false }` は
新しい run の loading state を折るため、世代カウンタで「自分が最新か」を確認してから
後始末する。

```swift
@MainActor
final class SearchViewModel {
    private var generation = 0
    private(set) var isSearching = false
    private(set) var results: [SearchResult] = []

    func search(term: String, cancellation: CancellationContext) async throws {
        generation += 1
        let currentGeneration = generation
        isSearching = true

        defer {
            if generation == currentGeneration {
                isSearching = false
            }
        }

        do {
            try cancellation.check()
            let newResults = try await searchUseCase.search(term)
            try cancellation.check()
            if generation == currentGeneration {
                results = newResults
            }
        } catch let error as CancellationError {
            if generation == currentGeneration {
                isSearching = false
            }
            throw error
        }
    }
}
```

## `cancel` 後の `.ignoreNew` はゾンビ run を防がない

`ViewTaskStore` の `cancel(id:)` / `cancel(lifetime:)` は、対象 task にキャンセルを要求し、
追跡から即時に外す。Swift のキャンセルは協調的なので、operation が `check()` しない、
またはキャンセル対応 API で停止しない場合、その処理は store の追跡外で実行を続ける。

そのため、手動キャンセル直後の `isRunning(id:) == false` は「追跡中ではない」という意味であり、
「処理本体が完全に終了した」という意味ではない。同じ ActionID を `.ignoreNew` で再開始すると、
古い処理が残っていても新しい run は開始され得る。

この意味論を前提に、次を守る。

- operation は長い処理の前後と重要な suspension point の後で `try cancellation.check()` を呼ぶ。
- UI の loading 表示は `isRunning` に直結せず、ViewModel の state として持つ。
- キャンセル後にも残り得る副作用がある処理では、ViewModel 側で世代 ID や domain-level token を使い、
  古い run の結果を捨てる。
- 「実処理が完全に終わるまで新規開始を禁止したい」場合は、現行 API の `.ignoreNew` だけに頼らない。

## operation 内で unstructured task を作らない

`CancellationContext` は現在実行中の task のキャンセル状態を読む。operation の中でさらに
`Task {}` を作ると、処理は別の unstructured task に逃げ、store が所有する task のキャンセルは
内側に自動伝播しない。

```swift
// Avoid this inside a Tasking operation.
viewTaskStore.start(id: "sync", lifetime: .screenBound) { cancellation in
    Task {
        try await syncUseCase.sync()
    }
}
```

operation 内で並行処理が必要な場合は、呼び出し元の task ツリーに残る `async let` や task group を使う。

```swift
viewTaskStore.start(id: "sync", lifetime: .screenBound) { cancellation in
    async let profile: Void = profileUseCase.sync()
    async let settings: Void = settingsUseCase.sync()

    try cancellation.check()
    _ = try await (profile, settings)
    try cancellation.check()
}
```

## 同じ ActionID の方針を分散させない

`ActionRunner` は `ActionDescriptor` に重複ポリシーを束ねるが、`ViewTaskStore.start` は
呼び出しごとに `TaskStartPolicy` を渡す。同じ `ActionID` に対して、ある呼び出し箇所では
`.ignoreNew`、別の箇所では `.allowConcurrent` のような矛盾した方針を書けてしまう。

同じ ActionID の方針は feature 内で 1 か所に寄せる。

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

より強く寄せたい場合は、feature 専用の小さな wrapper を作り、ActionID と policy を同時に隠蔽する。
