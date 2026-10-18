# swift-tasking / Tasking

[日本語](README.md) | English

[![CI](https://github.com/9uiLe/swift-tasking/actions/workflows/ci.yml/badge.svg)](https://github.com/9uiLe/swift-tasking/actions/workflows/ci.yml)

Tasking **owns tasks started by synchronous events until they terminate, including after cancellation, and lets you await completion**.
It provides `Tasking` for UI code and `TaskingCore` for non-UI code without external dependencies.

## Choose an entry point

| Work to perform | Use |
|---|---|
| Concurrent work that joins before an async function returns | `async let` / task group |
| Work tied to SwiftUI view lifetime or input | `.task` / `.task(id:)` |
| Prevent duplicate calls to one async operation | A regular async function and a state guard |
| Start from a synchronous UI callback, then cancel or await individual runs | `ViewTaskStore` |
| Share per-Action duplicate control across multiple async entry points | `ActionRunner` when needed |
| Replaceable tasks owned by a non-UI service | `TaskSlot` |

Use standard mechanisms when their scope fits the work. Tasking does not hold progress, business results, or retry state.
See [purpose and principles](docs/positioning.md) for the decision criteria and the [prototype](Examples/TaskingPrototype) for working examples.

## Installation

Add this dependency for the published package:

```swift
.package(url: "https://github.com/9uiLe/swift-tasking.git", from: "0.4.0")
```

Documentation at each revision describes that revision's API. Features under `Unreleased` in the [changelog](CHANGELOG.md)
require a local checkout until published:

```swift
.package(path: "../swift-tasking")
```

Choose the required product in your target dependencies:

```swift
.product(name: "Tasking", package: "swift-tasking")
// For non-UI ownership: .product(name: "TaskingCore", package: "swift-tasking")
```

Swift tools 6.0+ and Swift 6 language mode are required, including in consuming feature modules.
Deployment targets are iOS 13+, macOS 10.15+, tvOS 13+, watchOS 6+, and visionOS 1+.
Examples using Observation or newer SwiftUI APIs require their corresponding OS versions.
The [prototype](Examples/TaskingPrototype/Package.swift) targets iOS 17+ and macOS 14+.

## ViewTaskStore: start from a synchronous UI callback

Place the Store in an owner whose lifetime matches the work. This view owns a Store and requests cancellation when it disappears.
`SettingsViewModel.save()` is an application-provided async throwing method that uses standard `Task.checkCancellation()`
and handles business error presentation. The full implementation is in [SettingsFeature.swift](Examples/TaskingPrototype/Sources/TaskingPrototype/SettingsFeature.swift).

```swift
import SwiftUI
import Tasking

@MainActor
struct SettingsScreen: View {
    @State private var taskStore = ViewTaskStore()
    let viewModel: SettingsViewModel

    var body: some View {
        Button("Save") {
            taskStore.start(id: "settings.save") { [viewModel] in
                try await viewModel.save()
            }
        }
        .onDisappear {
            taskStore.cancelAll()
        }
    }
}
```

`start` creates a task on MainActor and synchronously returns `.started(ActionRun)` or `.skipped(TaskStartSkipReason)`.
`ActionID` identifies a kind of work; `ActionRun` identifies one invocation.

| `TaskStartPolicy` | Behavior for the same Action ID |
|---|---|
| `.ignoreNew` (default) | Return `.skipped(.unfinished)` while any run is unfinished, including cancelled runs |
| `.cancelExisting` | Request cancellation of tracked runs and start a new run without awaiting their termination |
| `.allowConcurrent` | Start an additional run |

A closed Store returns `.skipped(.closed)` regardless of policy. Rejected calls do not invoke the operation.
Use the default to prevent reentry until termination, for example when saving. Use `.cancelExisting` to admit a new request immediately
while asking old work to stop; the application manages result generations and side-effect ordering.

### Tracking and termination

Cancellation **removes tracking immediately**, while the Store **retains ownership until termination**.
`isTracked` / `trackedCount` synchronously query work eligible for cancellation selection; `isUnfinished` / `unfinishedCount`
query unfinished work, including cancelled runs. Neither drives SwiftUI redraws. Keep presentation in observable ViewModel state.

Usually, use a separate Store for each owner and call `cancelAll()`. If one Store needs selective group cancellation,
pass `group: CancellationGroup`. This is a string-based selection label and does not change owner lifetime.
See [lifetime and ownership](docs/lifetimes.md) for placement and references.

### Shut down

| Purpose | Store / Slot operation |
|---|---|
| Cancel while reusing the owner | Store `cancel(...)` / `cancelAll()`, Slot `cancel()` |
| Close admission and let accepted work finish | `close()`, then `waitForIdle()` |
| Close admission, request cancellation, and await termination | `cancelAndWaitForIdle()` |
| Await one Store invocation | `awaitCompletion(of:)` |

`close()` is terminal and cannot reopen. Cancelling a waiter neither cancels owned work nor interrupts the wait.
If an operation never terminates, the wait continues. Owned operations and their structured child tasks must not wait for their own completion.
The [architecture](docs/architecture.md#キャンセルと終了待ち) defines the full contract and detection limits.

Store operations handle business errors internally. An escaping `CancellationError` is a normal termination;
other errors are reported unchanged through `onUnhandledError(ActionRun, any Error)`.
Without a handler, or after Store deallocation, Debug builds assert and Release builds do not report the error.

## ActionRunner: share async admission

Runner is an optional helper for sharing duplicate control across multiple async entry points.
It creates no Task and continues in the caller's task. This example runs on MainActor;
`billingService.fetchPlans()` is an application-provided async throwing method.

```swift
let runner = ActionRunner()
do {
    let accepted = try await runner.run(id: "billing.refresh") {
        try Task.checkCancellation()
        let plans = try await billingService.fetchPlans()
        try Task.checkCancellation()
        return plans
    }
    if let plans = accepted { print(plans) }
} catch is CancellationError {
    // Finalize cancellation presentation in the caller.
} catch {
    // Recover or present using the original error type.
}
```

With `.ignoreNew` (default), skipped requests return `nil` and accepted values return `.some(value)`.
If the success value is itself Optional, the outer Optional represents admission. Errors, including `CancellationError`, are rethrown unchanged.
`.allowConcurrent` is also available. The caller owns the task, cancellation, and presentation state.

## TaskSlot: replace non-UI work

`TaskingCore.TaskSlot` is an independent actor. `replace` requests cancellation of the active task and starts a replacement.
The operation handles business errors and cancellation without throwing out of the closure.

```swift
import TaskingCore

actor RefreshCoordinator {
    private let slot = TaskSlot()
    private let refresh: @Sendable () async -> Void

    init(refresh: @escaping @Sendable () async -> Void) {
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

After closure, `replace` returns `false`. Replaced tasks remain owned until termination, so unfinished operations can overlap.
Debounce or coalesce high-volume inputs before starting tasks, and measure against the conditions in [performance characteristics](docs/performance.md).

## Design and development

- [Documentation guide](docs/README.md) — entry points by purpose
- [Architecture](docs/architecture.md) — current contracts, rationale, invariants, and tests
- [Contributing](CONTRIBUTING.en.md) ([日本語](CONTRIBUTING.md)) — changes and validation
- [Release design and operations](docs/releasing.md) — authentication, preparation, publication, and recovery
- [Security policy](SECURITY.en.md) ([日本語](SECURITY.md)) — vulnerability reporting

Japanese is the source of truth. README, contributing, and security documents have English editions maintained together.
The code is available under the [MIT License](LICENSE).
