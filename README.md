# swift-tasking / Tasking

[![CI](https://github.com/9uiLe/swift-tasking/actions/workflows/ci.yml/badge.svg)](https://github.com/9uiLe/swift-tasking/actions/workflows/ci.yml)

`Tasking` is a small Swift package for making unstructured task ownership
explicit at UI and application boundaries.

It provides two deliberately separate types:

- `ViewTaskStore`: owns task handles started from synchronous UI callbacks such as
  `Button` actions, and makes lifetime plus duplicate policy visible.
- `ActionRunner`: runs work in an existing async context, tracks action state,
  and returns a typed outcome without creating a task.

The package is intentionally not a replacement for structured concurrency. Use
`async let`, task groups, and SwiftUI `.task` whenever their scope matches the
work. Use `ViewTaskStore` only when work must outlive a synchronous callback and
therefore needs explicit ownership.

## Why this exists

Apple's Swift concurrency guidance draws a strong line between structured tasks
and unstructured tasks:

- Structured tasks (`async let` and task groups) live inside a scope and get
  automatic cancellation/error bookkeeping from the task tree.
- `Task {}` and `Task.detached {}` are unstructured. They are useful at
  non-async boundaries, but cancellation, errors, results, and lifetime must be
  managed explicitly.
- Cancellation is cooperative. Calling `cancel()` requests cancellation; the
  running operation must check cancellation or call APIs that react to it.
- SwiftUI `.task` is already view-lifetime-bound and automatically cancelled
  when the view disappears, so it should remain the preferred tool for lifecycle
  loading.

Primary references:

- [WWDC21: Explore structured concurrency in Swift](https://developer.apple.com/videos/play/wwdc2021/10134/)
- [WWDC23: Beyond the basics of structured concurrency](https://developer.apple.com/videos/play/wwdc2023/10170/)
- [WWDC21: What's new in SwiftUI](https://developer.apple.com/videos/play/wwdc2021/10018/)
- [Task.cancel() documentation](https://developer.apple.com/documentation/swift/task/cancel%28%29)
- [SwiftUI View.task documentation](https://developer.apple.com/documentation/swiftui/view/task%28name%3Apriority%3Afile%3Aline%3A_%3A%29)

## Documentation

Design rationale and vocabulary live in [`docs/`](docs/README.md):

- [Glossary](docs/glossary.md) — domain vocabulary and a quick "which tool when" table
- [Positioning](docs/positioning.md) — problem statement, design principles, comparison
  with alternatives (SwiftUI `.task(id:)`, VergeGroup TaskManager, TCA, async-task),
  and an honest strengths/weaknesses assessment
- [Adoption Guide](docs/adoption.md) — large-app adoption policy, ActionID governance,
  Swift 5 language-mode caveat, and 0.2 roadmap
- [Architecture Decision Records](docs/README.md#architecture-decision-records) —
  why the API is shaped the way it is

## Installation

```swift
// Add to Package.swift
.package(url: "https://github.com/9uiLe/swift-tasking.git", from: "0.1.0")
```

```swift
.product(name: "Tasking", package: "swift-tasking")
```

```swift
import Tasking
```

## Support Policy

Tasking requires the Swift 6 toolchain and compiles in Swift 6 language mode.
The package manifest uses Swift tools version 6.0 so clients do not need a newer
SwiftPM just to load the package.

Supported Apple deployment targets:

- iOS 13+
- macOS 10.15+
- tvOS 13+
- watchOS 6+
- visionOS 1+

Swift 5 language mode is intentionally not supported. This package is about
making Swift Concurrency task ownership explicit, so strict data-race checking
is part of the public quality bar.

Swift 5 language-mode targets may be able to import the package, but their
closure captures are checked under the consuming target's language mode. In
practice, non-Sendable captures that Swift 6 would reject can compile silently
from Swift 5 targets. Treat Swift 6 language mode in consuming feature modules
as part of the support boundary.

## ViewTaskStore

Use `ViewTaskStore` at synchronous UI boundaries where `await` is not available.

```swift
import SwiftUI
import Tasking

private enum SettingsActions {
    static let save: ActionID = "settings.save"
}

struct SettingsScreen: View {
    @State private var viewTaskStore = ViewTaskStore()
    @State private var viewModel = SettingsViewModel()

    var body: some View {
        Button("Save") {
            viewTaskStore.start(
                id: SettingsActions.save,
                lifetime: .screenBound,
                policy: .ignoreNew
            ) { cancellation in
                try await viewModel.save(cancellation: cancellation)
            }
        }
        .onDisappear {
            viewTaskStore.cancel(lifetime: .screenBound)
        }
    }
}
```

`TaskStartPolicy` makes duplicate behavior local and reviewable:

- `.ignoreNew`: keep the current run and skip the new request.
- `.cancelExisting`: request cancellation for current runs, then start a new
  run. The cancelled operation may continue until it cooperates with
  cancellation.
- `.allowConcurrent`: track multiple overlapping runs for the same action ID.

`ViewTaskStore.start` passes a `CancellationContext` into the operation. Pass it
to the ViewModel method and call `try cancellation.check()` in long-running work
so cancellation requests are handled deliberately.

```swift
@MainActor
final class SettingsViewModel {
    func save(cancellation: CancellationContext) async throws {
        do {
            try cancellation.check()
            try await settingsUseCase.save()
            try cancellation.check()
            state = .saved
        } catch let error as CancellationError {
            throw error
        } catch {
            state = .failed(error)
        }
    }
}
```

Business errors should be converted to ViewModel state before they leave the
operation. `ViewTaskStore` treats `CancellationError` as a normal cancellation;
other uncaught errors are considered programming mistakes and trigger a debug
assertion.

`ActionLifetime` has built-in `.screenBound`, `.sceneBound`, and `.appBound`
values, and it can be extended with string literals:

```swift
let lifetime: ActionLifetime = "accountSettings"
viewTaskStore.cancel(lifetime: lifetime)
```

## Operational notes

- Running queries are tracking queries. `isRunning` and `runningCount` report
  what Tasking is currently tracking; they do not prove that no cancelled work
  is still executing. `cancel(id:)` and `cancel(lifetime:)` request cancellation
  and remove runs from tracking immediately, so `.ignoreNew` does not guard
  against old work that ignores cancellation after a manual cancel.
- UI state belongs to the ViewModel. If a ViewModel sets loading state before
  work begins, reset that state before rethrowing `CancellationError`.
- With `.cancelExisting`, cleanup from the old run can arrive after the new run
  has started. Guard cleanup with a generation token when both runs mutate the
  same ViewModel state.
- Do not let an operation strongly capture its `ViewTaskStore` or an object that
  owns that store. The cycle `store -> task -> operation -> store` prevents the
  store's deinit cancellation safety net from running until the operation
  finishes. Use explicit `cancel(...)` and weak captures when the operation
  needs to call back into an owner.
- Do not create nested unstructured tasks inside an operation. `CancellationContext`
  reflects the current task; escaping work into `Task {}` creates a new ownership
  and cancellation boundary. Prefer `async let` or task groups for inner
  concurrency.

See [Recipes](docs/recipes.md) for the concrete patterns validated by the
prototype tests.

## ActionRunner

Use `ActionRunner` when you are already in an async context and want duplicate
handling plus a typed terminal result.

```swift
let runner = ActionRunner()

let outcome = await runner.run(ActionDescriptor(id: "billing.refresh")) { cancellation in
    try cancellation.check()
    try await billingUseCase.refresh()
    try cancellation.check()
}

switch outcome {
case .succeeded:
    break
case .cancelled:
    break
case .skipped(.alreadyRunning):
    break
case let .failed(error):
    logger.error("\(error.typeName): \(error.message)")
}
```

`ActionRunner` also passes `CancellationContext` to the operation, but it does
not own or cancel a task. It only lets the current task's cancellation state be
checked explicitly while it manages duplicate policy and outcome mapping. Keep
cancellation ownership in `ViewTaskStore`, SwiftUI `.task`, task groups, or the
caller's existing structured task.

## Design rules

- Prefer structured concurrency first.
- Use SwiftUI `.task` for view lifecycle work.
- Use `ViewTaskStore.start(...)` for synchronous user-action callbacks.
- Keep `Task.detached` out of feature code unless the work intentionally should
  not inherit actor, priority, task-local values, or cancellation context.
- Keep nested `Task {}` out of Tasking operations; use structured child work.
- Make action IDs constants, not scattered string literals.
- Treat cancellation as a request. Long-running ViewModel methods should accept
  `CancellationContext` and call `try cancellation.check()` before expensive
  work and after important suspension points.
