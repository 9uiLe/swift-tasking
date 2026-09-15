# swift-tasking / Tasking

[日本語](README.md) | English

[![CI](https://github.com/9uiLe/swift-tasking/actions/workflows/ci.yml/badge.svg)](https://github.com/9uiLe/swift-tasking/actions/workflows/ci.yml)

Tasking makes ownership, duplicate policy, and cooperative cancellation explicit
for unstructured Swift Concurrency tasks. It has two library products and no
external package dependencies.

## Choose an entry point

| Work to perform | Use |
|---|---|
| Concurrent work that finishes within an async scope | `async let` or a task group |
| Loading tied to a SwiftUI view's lifetime or input | `.task` or `.task(id:)` |
| Work started by a synchronous UI callback that needs an owner | `Tasking.ViewTaskStore` |
| Duplicate control and a terminal result within an async call | `Tasking.ActionRunner` |
| One replaceable task owned by a non-UI service | `TaskingCore.TaskSlot` |

Structured concurrency and SwiftUI lifecycle tasks provide ownership through their
scopes. Use them when those scopes fit the work. Store and Slot own tasks that
must continue beyond a synchronous callback or method invocation.

## Installation

For the published package, add this dependency:

```swift
.package(url: "https://github.com/9uiLe/swift-tasking.git", from: "0.3.0")
```

This documentation describes the checkout's API. Features listed under Unreleased
in the [release notes](CHANGELOG.md) require a local checkout until published.
To depend on that checkout:

```swift
.package(path: "../swift-tasking")
```

Choose the product in your target dependencies:

```swift
.product(name: "Tasking", package: "swift-tasking")
```

For a non-UI target that needs replaceable task ownership:

```swift
.product(name: "TaskingCore", package: "swift-tasking")
```

The package requires Swift tools 6.0 and Swift 6 language mode, including in
consuming feature modules.

Deployment targets: iOS 13+, macOS 10.15+, tvOS 13+, watchOS 6+, and visionOS 1+.
Examples that use Observation or newer SwiftUI APIs require their corresponding OS
versions; the [prototype](Examples/TaskingPrototype/Package.swift) targets iOS 17+
and macOS 14+.

## ViewTaskStore: own work from a synchronous UI callback

`ViewTaskStore` is a MainActor class. `start` creates and owns a task, records its
Action ID and lifetime, and returns an admission result synchronously.

The following view receives an application-owned `SettingsViewModel` whose
`save(cancellation:)` method updates UI state, handles business failures, and
cooperates with cancellation. A complete implementation is in
[SettingsFeature.swift](Examples/TaskingPrototype/Sources/TaskingPrototype/SettingsFeature.swift).

```swift
import SwiftUI
import Tasking

private enum SettingsActions {
    static let save: ActionID = "settings.save"
}

@MainActor
struct SettingsScreen: View {
    @State private var taskStore = ViewTaskStore()
    let viewModel: SettingsViewModel

    var body: some View {
        Button("Save") {
            taskStore.start(
                id: SettingsActions.save,
                lifetime: .screenBound,
                policy: .ignoreNew
            ) { [viewModel] cancellation in
                try await viewModel.save(cancellation: cancellation)
            }
        }
        .onDisappear {
            taskStore.cancel(lifetime: .screenBound)
        }
    }
}
```

### Admission and duplicate policy

An Action ID identifies a kind of work, such as `settings.save`. An `ActionRun`
identifies one invocation using both its Action ID and a UUID-based run ID.
Declare Action IDs as feature constants.

| `TaskStartPolicy` | Behavior |
|---|---|
| `.ignoreNew` (default) | Skip if the same Action ID has a tracked run |
| `.cancelExisting` | Cancel and untrack runs with that ID, then start a new run |
| `.allowConcurrent` | Start an additional run with that ID |

`TaskStartOutcome` is `.started(ActionRun)` or `.skipped(TaskStartSkipReason)`.
Skip reasons are `.alreadyRunning` and `.closed`. A closed store rejects every
start without running the operation. Admission is separate from the operation's
business result.

### Lifetime and UI state

`ActionLifetime` is a label for queries and group cancellation. Built-in values are
`.screenBound`, `.sceneBound`, and `.appBound`; custom string values are supported.
Place the store in an owner that lives as long as the work should be managed, and
connect lifecycle events to cancellation. A label does not extend the owner's
lifetime or grant background execution time.

Loading, progress, results, and errors belong to the ViewModel. Tracking queries
are synchronous snapshots and do not drive SwiftUI redraws. When invocations can
overlap, guard results and cleanup with a generation token so an older invocation
cannot overwrite a newer one. See the [recipes](docs/recipes.md).

### Errors

Handle business failures inside the operation, typically by updating ViewModel
state. A thrown `CancellationError` is normal cancellation. Other escaping errors
violate the operation's contract.

A store-level observer can report those errors:

```swift
let taskStore = ViewTaskStore { run, failure in
    print("\(run.actionID): \(failure.typeName): \(failure.message)")
}
```

The observer runs on MainActor before completion removes tracking. A run already
untracked by cancellation remains untracked. Without an observer, an escaping
error triggers a debug assertion and has no release notification. After store
deallocation, escaping errors use that same assertion behavior. The store retains
the observer; use weak captures when it refers back to the store's owner.

## ActionRunner: execute in the caller's task

`ActionRunner` is a MainActor class that tracks Action invocations and maps their
terminal results. It runs the operation in the caller's task. The caller retains
responsibility for task ownership and cancellation.

In this MainActor async example, `billingService` is an application dependency
with an async throwing `fetchPlans()` method returning a Sendable value:

```swift
let runner = ActionRunner()
let outcome = await runner.run(
    ActionDescriptor(id: "billing.refresh", duplicatePolicy: .ignoreNew)
) { cancellation in
    try cancellation.check()
    let plans = try await billingService.fetchPlans()
    try cancellation.check()
    return plans
}

switch outcome {
case let .succeeded(plans):
    print(plans)
case .cancelled:
    break
case .skipped(.alreadyRunning):
    break
case let .failed(failure):
    print("\(failure.typeName): \(failure.message)")
}
```

Keep a runner in the feature owner when multiple calls should share duplicate
control. Runner supports `.ignoreNew` and `.allowConcurrent`. Its optional
synchronous `onStart` callback runs while the admitted run is tracked; skipped
calls execute neither `onStart` nor the operation.

A thrown `CancellationError` maps to `.cancelled`. A returned value maps to
`.succeeded`, even if cancellation was requested. `ActionFailure` stores error
type and message strings for reporting. Perform error-specific recovery where the
original error type is available, inside the operation.

## TaskSlot: own replaceable work outside the UI

`TaskSlot` is an actor in `TaskingCore`. It owns at most one active task and retains
cancelled or superseded tasks until they terminate. The operation handles its own
business errors and accepts the same cancellation contract.

```swift
import TaskingCore

actor RefreshCoordinator {
    private let slot = TaskSlot()
    private let refresh: @Sendable (CancellationContext) async -> Void

    init(refresh: @escaping @Sendable (CancellationContext) async -> Void) {
        self.refresh = refresh
    }

    @discardableResult
    func scheduleRefresh() async -> Bool {
        await slot.replace(operation: refresh)
    }

    func shutDown() async {
        await slot.cancelAndWaitForIdle()
    }
}
```

`replace` cancels the active task and starts a replacement. It returns `false`
after closure. Superseded operations may overlap until they cooperate with
cancellation. Slot provides ownership; the application defines debounce timing,
retry, result selection, and ordering.

## Cancellation and completion

`CancellationContext.check()` and `isCancelled` read the task currently executing.
They do not capture a cancellation token or connect separate unstructured tasks.
Check cancellation around long work and important suspension points. Use
`async let` or task groups for concurrency inside operations.

Cancellation removes Store runs from tracking immediately. Their handles remain
owned until termination. Consequently, `isRunning == false` does not prove
completion, and `.ignoreNew` may admit work while a manually cancelled operation
is still executing.

| Intent | Store / Slot operation |
|---|---|
| Request cancellation and keep accepting work | Store `cancel(...)` / `cancelAll()`, Slot `cancel()` |
| Stop admission and let accepted work finish | `close()`, then `waitForIdle()` |
| Stop admission, request cancellation, and wait | `cancelAndWaitForIdle()` |
| Wait for one Store run, including cancelled work | `awaitCompletion(of:)` |

Close is terminal and idempotent. `waitForIdle()` includes work admitted during
the wait if admission remains open. Cancelling the waiting task does not cancel
owned work or interrupt the wait. An operation that does not terminate can keep a
wait suspended indefinitely.

An owned operation must not wait for itself, including through a structured child.
Debug builds assert on self-waiting; release builds exclude the inherited ownership
context and wait for other owned work. This protection does not detect arbitrary
cycles between tasks.

Store and Slot request cancellation on deallocation. An operation that strongly
captures its owner can prevent that deallocation. Capture only the dependencies
needed for long work and refer back to owners weakly. Both owners forward an
optional priority to Swift's `Task` initializer; `nil` inherits caller priority.

## Documentation

Japanese is the primary language of this repository. The design and operating
guides below are maintained in Japanese; this README, the contribution guide, and
the security policy also have English editions.

- [Documentation guide](docs/README.md) — reading order and design decisions
- [Architecture](docs/architecture.md) — responsibilities, invariants, and tests
- [Lifetimes](docs/lifetimes.md) — screen, scene, and application ownership
- [Recipes](docs/recipes.md) — cancellation, state updates, and shutdown
- [Adoption](docs/adoption.md) — feature boundaries, IDs, and operational checks
- [Performance](docs/performance.md) — complexity, measurements, and tradeoffs
- [Releasing](docs/releasing.md) — owner authentication, preparation, and publication
- [Contributing](CONTRIBUTING.en.md) — validation and documentation conventions
- [Security policy](SECURITY.en.md) — vulnerability reporting

Swift concurrency references: [structured concurrency](https://developer.apple.com/videos/play/wwdc2021/10134/),
[advanced structured concurrency](https://developer.apple.com/videos/play/wwdc2023/10170/),
and [Task.cancel()](https://developer.apple.com/documentation/swift/task/cancel%28%29).
