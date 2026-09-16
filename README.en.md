# swift-tasking / Tasking

[日本語](README.md) | English

[![CI](https://github.com/9uiLe/swift-tasking/actions/workflows/ci.yml/badge.svg)](https://github.com/9uiLe/swift-tasking/actions/workflows/ci.yml)

Tasking makes **ownership, duplicate policy, cancellation, and completion** explicit
for unstructured Swift Concurrency tasks. It provides `Tasking` for UI code and
`TaskingCore` for non-UI code, with no external package dependencies.

## Choose an entry point

| Work to perform | Use |
|---|---|
| Concurrent work that joins before an async function returns | `async let` / task group |
| Work tied to SwiftUI view lifetime or input | `.task` / `.task(id:)` |
| Work started from a synchronous UI callback that needs a task owner | `ViewTaskStore` |
| Duplicate control and terminal outcomes within the caller's task | `ActionRunner` |
| Replaceable work owned by a non-UI service | `TaskSlot` |

Use structured concurrency or SwiftUI lifecycle tasks when their scopes fit the
work. With Tasking, ViewModels and services still own progress, results, business
error handling, and retry decisions.

## Installation

Add the following dependency for the published package:

```swift
.package(url: "https://github.com/9uiLe/swift-tasking.git", from: "0.4.0")
```

Documentation at each revision describes that revision's API. Features listed
under `Unreleased` in the [changelog](CHANGELOG.md) require a local checkout until
published:

```swift
.package(path: "../swift-tasking")
```

Choose the UI product in your target dependencies:

```swift
.product(name: "Tasking", package: "swift-tasking")
```

For non-UI task ownership, use:

```swift
.product(name: "TaskingCore", package: "swift-tasking")
```

Swift tools 6.0+ and Swift 6 language mode are required, including in consuming
feature modules. Deployment targets are iOS 13+, macOS 10.15+, tvOS 13+, watchOS 6+,
and visionOS 1+. Examples using Observation or newer SwiftUI APIs require their
corresponding OS versions. The [prototype](Examples/TaskingPrototype/Package.swift)
targets iOS 17+ and macOS 14+.

## Three states to distinguish

- **Admission:** whether new work can start. `close()` stops admission permanently.
- **Tracking:** whether an Action participates in duplicate checks and queries.
  Store cancellation removes tracking immediately.
- **Ownership:** whether a task handle is retained to manage completion. Store and
  Slot retain their tasks until termination.

An Action is a kind of work, such as saving or refreshing, identified by an
`ActionID`. An `ActionRun` combines that ID with a UUID-based `ActionRunID` to
identify one invocation. Multiple runs can share an Action ID.

## ViewTaskStore: start from a synchronous UI callback

`ViewTaskStore` creates and owns tasks on MainActor. Its synchronous `start` method
returns an admission result. This view receives an application-owned
`SettingsViewModel`; `save(cancellation:)` handles cooperative cancellation and
business error presentation. See
[SettingsFeature.swift](Examples/TaskingPrototype/Sources/TaskingPrototype/SettingsFeature.swift)
for the complete implementation.

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

### Duplicate policy and admission

| `TaskStartPolicy` | When the same Action ID has a tracked run |
|---|---|
| `.ignoreNew` (default) | Skip the new request |
| `.cancelExisting` | Request cancellation, untrack existing runs, and start the new request |
| `.allowConcurrent` | Start an additional run |

`TaskStartOutcome` is `.started(ActionRun)` or `.skipped(TaskStartSkipReason)`.
Skip reasons are `.alreadyRunning` and `.closed`; rejected requests do not call the
operation. Admission does not represent a business result. Use the returned
`ActionRun` to query, cancel, or await one invocation.

### Lifetime and presentation state

`ActionLifetime` is a label for queries and group cancellation. Built-in values are
`.screenBound`, `.sceneBound`, and `.appBound`; custom strings are supported. Place
the store in an owner that lives as long as the work needs management, and connect
lifecycle events to cancellation. Labels do not extend owner lifetime or grant OS
background execution time.

`isRunning` and `runningCount` are synchronous tracking queries. They do not drive
SwiftUI redraws. Keep loading, progress, results, and errors in observable ViewModel
state. Use generation guards when invocations can overlap; see the
[recipes](docs/recipes.md) for examples.

## ActionRunner: execute in the caller's task

`ActionRunner` tracks Actions on MainActor and returns their terminal outcomes.
The caller owns and cancels the task. Retain a runner in the feature owner when
multiple calls need to share duplicate control.

This MainActor async example uses an application dependency, `billingService`,
whose async throwing `fetchPlans()` method returns a Sendable value:

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

Runner supports `.ignoreNew` and `.allowConcurrent`. Its optional synchronous
`onStart` callback runs after tracking is registered and before the operation.
Skipped calls execute neither callback nor operation.

A thrown `CancellationError` maps to `.cancelled`; a returned value maps to
`.succeeded`, even if cancellation was requested. `ActionFailure` contains an error
type name and message for reporting. Handle recovery that requires the original
error type inside the operation.

## TaskSlot: replace non-UI work

`TaskingCore.TaskSlot` is an independent actor. `replace` cancels the active task
and starts a replacement. The operation handles business errors and cancellation
without throwing errors out of the closure.

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

After closure, `replace` returns `false`. Superseded tasks remain owned until
termination, so operations can overlap until they cooperate with cancellation.
The service defines debounce timing, retries, result selection, and side-effect
ordering.

## Manage cancellation and completion

`CancellationContext.check()` and `isCancelled` read the task executing at the time
of access. Check around long work and important suspension points. Use `async let`
or task groups for concurrency inside an operation. Passing the context into
another unstructured task does not create a cancellation relationship.

Store cancellation removes tracking while retaining the handle until termination.
Consequently, `isRunning == false` does not prove completion, and `.ignoreNew` may
admit a new request immediately after manual cancellation.

| Intent | Operation |
|---|---|
| Cancel while continuing to accept work | Store `cancel(...)` / `cancelAll()`, Slot `cancel()` |
| Close admission and let accepted work finish | `close()`, then `waitForIdle()` |
| Close admission, request cancellation, and wait | `cancelAndWaitForIdle()` |
| Wait for one Store invocation | `awaitCompletion(of:)` |

If admission remains open, `waitForIdle()` includes work started during the wait.
Cancelling the waiting task neither cancels owned work nor interrupts the wait.
An operation that never terminates keeps the wait suspended.

An operation must not wait for itself, including through a structured child.
Debug builds assert on self-waiting; release builds exclude the inherited ownership
context from the wait. This does not detect arbitrary cycles between tasks.

Store and Slot request cancellation on deallocation. Strongly capturing the owner
can prevent deallocation, so capture the dependencies needed for the operation and
refer back to owners weakly. Both forward an optional priority to `Task`; `nil`
inherits caller priority.

## Report unhandled Store errors

Handle Store business errors inside the operation. An escaping `CancellationError`
is normal cancellation; other escaping errors violate the operation's contract.
An observer can connect those failures to logging:

```swift
let taskStore = ViewTaskStore { run, failure in
    print("\(run.actionID): \(failure.typeName): \(failure.message)")
}
```

The observer runs on MainActor before completion removes tracking. Tracking
already removed by cancellation is not restored. Without an observer, or after
store deallocation, escaped errors trigger a debug assertion and have no release
notification. The store retains the observer, so use weak references when the
observer refers back to its owner.

## Design and development

- [Documentation guide](docs/README.md) — reading paths and design decisions
- [Architecture](docs/architecture.md) — public contracts, internals, invariants, and tests
- [Lifetimes and ownership](docs/lifetimes.md) — screen, scene, and application placement
- [Performance](docs/performance.md) — complexity, measurement conditions, and interpretation
- [Contributing](CONTRIBUTING.en.md) — implementation and validation workflow
- [Releasing](docs/releasing.md) — authentication, document preparation, publication, and recovery
- [Security policy](SECURITY.en.md) — vulnerability reporting

Japanese is the primary language. English editions are provided for this README,
the contribution guide, and the security policy; design and operations guides are
maintained in Japanese. The code is available under the [MIT License](LICENSE).

Swift concurrency references: [structured concurrency](https://developer.apple.com/videos/play/wwdc2021/10134/),
[advanced structured concurrency](https://developer.apple.com/videos/play/wwdc2023/10170/),
and [Task.cancel()](https://developer.apple.com/documentation/swift/task/cancel%28%29).
