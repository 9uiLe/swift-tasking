# Changelog

## Unreleased

### Added

- `TaskSlot.close()` and `cancelAndWaitForIdle()` for terminal draining and teardown.
- `ViewTaskStore.awaitCompletion(of:)` and `waitForIdle()` for actual task termination.
- `ViewTaskStore(onUnhandledError:)` for release-safe contract-violation reporting.

### Changed

- `TaskSlot.replace` now returns an `@discardableResult Bool`; `false` means the slot is closed.
- `ViewTaskStore` retains cancelled task handles until their operations actually finish while
  preserving the existing immediate-untracking behavior of `isRunning` and `runningCount`.
- Both duplicate-policy types now use `.ignoreNew` for the same skip-new behavior.
- `ActionRunner.run` now declares its synchronous `onStart` callback as `@MainActor`,
  matching the isolation on which it has always executed.

### Deprecated

- `ActionDuplicatePolicy.rejectWhileRunning` is a compatibility alias for `.ignoreNew`.
  Construction sites continue to compile with a warning. Exhaustive switches must migrate to
  the real `.ignoreNew` case because a static alias does not participate in exhaustivity checks.
