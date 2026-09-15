# Changelog

Release-specific API notes. The [documentation guide](docs/README.md) describes
the complete design and usage contracts.

## Unreleased

### Added

- `ViewTaskStore.close()` permanently stops admission without cancelling accepted work.
- `ViewTaskStore.cancelAndWaitForIdle()` stops admission, requests cancellation, and waits
  for all owned tasks to terminate.
- The standalone Release benchmark in `Benchmarks/` measures operation costs and compares
  isolated source snapshots. [Performance characteristics](docs/performance.md) documents
  workloads, source identities, timing, and memory.

### Changed

- **Breaking:** Store outcomes use `TaskStartSkipReason` with `.alreadyRunning` and `.closed`.
  Explicit `ActionSkipReason` annotations on `TaskStartOutcome.skipReason` must use
  `TaskStartSkipReason`; exhaustive Store outcome switches must handle `.closed`.
  Runner outcomes use `ActionSkipReason.alreadyRunning`.
- Prototype `BillingViewModel.refresh()` returns its typed outcome. Prototype ViewModels
  are owned at the scope where their state must be available.

### Fixed

- Concrete run queries, cancellation, and completion waits require matching ActionID and
  ActionRunID. A run with a mismatched ActionID has no effect.
- Prototype result publication and cleanup respect invocation generations. Cancellation
  restores loading state, and business failures are handled within feature operations.

## 0.3.0 - 2026-07-15

### Added

- `TaskSlot.close()` and `cancelAndWaitForIdle()` for admission closure and termination waits.
- `ViewTaskStore.awaitCompletion(of:)` and `waitForIdle()` for actual task termination.
- `ViewTaskStore(onUnhandledError:)` for reporting escaped operation errors in release builds.

### Changed

- `TaskSlot.replace` returns an `@discardableResult Bool`; `false` means the slot is closed.
- `ViewTaskStore` owns cancelled task handles until termination. Cancellation immediately
  removes runs from the tracking queried by `isRunning` and `runningCount`.
- Both duplicate-policy types use `.ignoreNew` to skip a request when the same Action ID
  has a tracked run.
- `ActionRunner.run` declares its synchronous `onStart` callback as `@MainActor`.

### Deprecated

- `ActionDuplicatePolicy.rejectWhileRunning` is a deprecated alias for `.ignoreNew`.
  Use `.ignoreNew` for construction and exhaustive switches; static aliases do not
  participate in enum exhaustivity checks.
