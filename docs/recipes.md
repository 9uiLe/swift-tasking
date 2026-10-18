# 利用レシピ

例は MainActor 上の表示状態と標準のキャンセルを使う。ViewModel の例は `Foundation` と `Observation` を import し、
iOS 17+ / macOS 14+ の Observation で表示を更新する。アプリ側のサービスは業務結果と必要なエラー型を定義する。
各 API の厳密な契約は [アーキテクチャ](architecture.md) に定める。

## 単一の async 操作は状態で受け付ける

同じ ViewModel の1操作を重複させないだけなら、その状態で受付を決められる。
以下の `BillingService` はアプリ側の依存で、`fetchPlans()` が `[Plan]` を返す async throws メソッドである。
`Plan` もアプリ側の値型である。

```swift
@MainActor
@Observable
final class BillingViewModel {
    enum State {
        case idle
        case loading
        case loaded([Plan])
        case failed(any Error)
    }

    private let service: BillingService
    private(set) var state: State = .idle

    init(service: BillingService) {
        self.service = service
    }

    func refresh() async {
        guard !Task.isCancelled else { return }
        if case .loading = state { return }
        let previous = state
        state = .loading
        do {
            try Task.checkCancellation()
            let plans = try await service.fetchPlans()
            try Task.checkCancellation()
            state = .loaded(plans)
        } catch is CancellationError {
            state = previous
        } catch {
            state = .failed(error)
        }
    }
}
```

キャンセル要求直後に `.loading` を外さず、処理本体が戻るまで維持することで旧処理と新処理を重ねない。
SwiftUI の `.task { await viewModel.refresh() }` や `.refreshable` から同じメソッドを呼べる。
[BillingFeature.swift](../Examples/TaskingPrototype/Sources/TaskingPrototype/BillingFeature.swift) に実行可能な例がある。

## 入力に連動する処理は標準 SwiftUI で始める

検索語に対応する寿命は `.task(id:)` で表す。次は `SwiftUI` を import した View の断片である。
`viewModel.search(term:debounce:)` はキャンセル協調と表示状態を扱い、入力が250ms変わらなければ検索する。

```swift
.task(id: term) { [term] in
    try? await viewModel.search(term: term, debounce: .milliseconds(250))
}
```

デバウンス中に入力が変われば旧タスクの sleep がキャンセルされ、検索を開始しない。
空の検索語では依存先を呼ばず表示をクリアする。実際の検索計算を担当する actor に入力を渡し、
MainActor では結果の採用と表示状態を更新する。

標準 `.task(id:)` でも、依存先がすぐキャンセルに協調するとは限らない。
結果と `defer` に世代ガードを使うと、古い処理の遅い完了で新しい表示を上書きしない。
[SearchFeature.swift](../Examples/TaskingPrototype/Sources/TaskingPrototype/SearchFeature.swift) は、Store を使わずこの構成を実装する。

## 複数の async 入口だけ受付を共有する

別々の呼び出し元で同じ ActionID の受付を共有する場合は、Runner を所有者に保持できる。
以下は MainActor 上の async 関数内の断片で、`runner` と `service` はその機能の依存である。

```swift
let accepted = try await runner.run(id: "catalog.refresh") {
    try Task.checkCancellation()
    let catalog = try await service.fetchCatalog()
    try Task.checkCancellation()
    return catalog
}
if let catalog = accepted {
    present(catalog)
}
```

既定の `.ignoreNew` で重複すると、処理本体は呼ばず外側の `nil` を返す。
Runner は元のエラーを送出するので、呼び出し元で `CancellationError` と業務エラーを扱う。
成功値が Optional の場合は、`if case .some(let value) = accepted` で受理を判定すれば、成功値の `nil` も維持できる。
呼び出し元の Task、TaskLocal、キャンセル状態は変わらない。

## 結果と後処理を世代で保護する

即時の差し替えや並行実行では、古い処理の `catch` や `defer` が新しい開始の後に動き得る。
キャンセル済みの古い要求が遅れて入口へ到達する場合もあるため、世代や表示状態を変更する前にキャンセルを確認する。
結果の採用、エラー表示、読み込み状態を同じ世代で保護する。
次はアプリ側の `SearchService.search(_:) async throws -> [SearchResult]` を使う ViewModel の例である。

```swift
@MainActor
@Observable
final class SearchViewModel {
    private let service: SearchService
    @ObservationIgnored private var latestSearch = UUID()
    private(set) var isSearching = false
    private(set) var results: [SearchResult] = []
    private(set) var errorMessage: String?

    init(service: SearchService) {
        self.service = service
    }

    func search(term: String) async throws {
        try Task.checkCancellation()
        let search = UUID()
        latestSearch = search
        isSearching = true
        errorMessage = nil
        defer {
            if latestSearch == search { isSearching = false }
        }
        do {
            let newResults = try await service.search(term)
            try Task.checkCancellation()
            if latestSearch == search { results = newResults }
        } catch let error as CancellationError {
            throw error
        } catch {
            if latestSearch == search { errorMessage = String(describing: error) }
        }
    }
}
```

キャンセル確認は処理を続けるか、世代ガードは結果を採用するかを決める。
外部への送信や保存の巻き戻しは行わないので、副作用には業務側の冪等性・重複排除・順序規則を設ける。

## キャンセルした実行の実終了を待つ

Store はキャンセルで追跡を解除してもハンドルを所有する。
以下は `Tasking` を import した MainActor 上の async 関数内で使う断片で、`store` と `viewModel` は機能の依存である。

```swift
let outcome = store.start(id: "settings.save") {
    try await viewModel.save()
}
guard case let .started(run) = outcome else { return }

store.cancel(run)
await store.awaitCompletion(of: run)
```

完了待ちが戻る前は、`isTracked(run) == false` と `isUnfinished(run) == true` が両立する。
既定の `.ignoreNew` は、この未終了期間の同じ ActionID の要求を `.skipped(.unfinished)` とする。
全体の実終了には `waitForIdle()` を使う。受付が開いていれば待機中に開始した処理も待つ。

## 所有者の終了時は受付を閉じる

Store / Slot の `cancelAndWaitForIdle()` は、中断前に受付を閉じ、キャンセルを要求し、所有する全処理の実終了を待つ。
受理済みを自然に完了させるなら、先に `close()` を呼んでから `waitForIdle()` を呼ぶ。
再利用する所有者では、受付を閉じず `cancelAll()` / `cancel()` を使う。

待機側のキャンセルは対象の処理に伝播せず、待機も中断しない。
対象処理やその構造化子タスクから自分の実終了を待つことは契約違反である。
Debug / Release の挙動と検出範囲は [待機の契約](architecture.md#自己待機) を参照する。

## 処理内の並行実行を構造化する

`async let` / task group の子タスクは親のキャンセルを引き継ぎ、親が終了する前に合流する。
次は MainActor 上の同期ハンドラで、アプリ側の2つの use case を並行実行し、業務エラーを ViewModel へ反映する断片である。

```swift
store.start(id: "sync") {
    do {
        try Task.checkCancellation()
        async let profile: Void = profileUseCase.sync()
        async let settings: Void = settingsUseCase.sync()
        _ = try await (profile, settings)
        try Task.checkCancellation()
    } catch is CancellationError {
        return
    } catch {
        viewModel.recordSyncFailure(error)
    }
}
```

独立した `Task {}` は別の非構造化タスクであり、Store / Slot はそれを所有しない。
子の所有も必要な処理は構造化して、実終了の保証に含める。

## 処理と所有者の参照関係を設計する

Store はタスクのハンドル、タスクは処理本体を保持する。
処理が Store の所有者を強参照すると、外部の参照を手放しても解放時キャンセルが働かない。

```text
owner → store → task → operation → owner
```

長い処理には必要な依存だけを捕捉し、所有者は結果を反映する時点で弱参照から参照する。
次は `Tasking` を import した例で、`SyncUseCase` はアプリ側の依存である。

```swift
@MainActor
@Observable
final class StoreOwningViewModel {
    let store = ViewTaskStore()
    private let syncUseCase = SyncUseCase()
    private(set) var isSynced = false
    private(set) var errorMessage: String?

    func startSync() {
        store.start(id: "sync") { [weak self, syncUseCase] in
            do {
                try Task.checkCancellation()
                try await syncUseCase.sync()
                try Task.checkCancellation()
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

`[weak self]` でも `await` 前に `guard let self` で強参照へ変えると、その中断中は所有者を保持する。
Slot を持つサービス、Store の未処理エラー通知先、Environment に渡す同期ハンドラにも同じ規則を適用する。
即時の差し替えや並行実行を加える場合は、状態更新を世代で保護する。
