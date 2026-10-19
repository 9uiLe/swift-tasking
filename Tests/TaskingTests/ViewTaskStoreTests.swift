import Tasking
import TaskingTestSupport
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ViewTaskStoreTests {
    @Test func startPublishesRunBeforeOperationAndFinishesTracking() async throws {
        let store = ViewTaskStore()
        var published: ActionRun?
        var executed = false
        let outcome = store.start(id: "load", group: "foreground") {
            let run = try #require(published)
            #expect(store.isTracked(run))
            executed = true
        }
        let run = try #require(outcome.run)
        published = run
        #expect(store.isTracked(run))
        #expect(store.isUnfinished(run))
        #expect(store.unfinishedCount == 1)
        #expect(store.unfinishedCount(for: "load") == 1)
        await store.awaitCompletion(of: run)
        #expect(executed)
        #expect(!store.isTracked(run))
        #expect(!store.isUnfinished(run))
        #expect(store.unfinishedCount == 0)
        #expect(store.unfinishedCount(for: "load") == 0)
        #expect(!store.isTracked(group: "foreground"))
    }

    @Test func duplicatePolicyUsesActionIDAcrossGroups() async {
        let store = ViewTaskStore()
        let gate = Gate()
        store.start(id: "save", group: "foreground") { await gate.wait() }
        let duplicate = store.start(id: "save", group: "background") {
            Issue.record("スキップした処理が実行されました。")
        }
        #expect(duplicate == .skipped(.unfinished))
        #expect(store.trackedCount(for: "save") == 1)
        await gate.open()
        await store.waitForIdle()
    }

    @Test func cancelExistingCancelsEveryMatchingRunAndPreservesReplacement() async throws {
        let store = ViewTaskStore()
        let old = Gate()
        let latest = Gate()
        var oldRuns: [ActionRun] = []
        for group: CancellationGroup in ["foreground", "background"] {
            let outcome = store.start(id: "sync", group: group, policy: .allowConcurrent) {
                await old.wait()
                #expect(Task.isCancelled)
            }
            oldRuns.append(try #require(outcome.run))
        }
        await old.waitForArrivals(2)
        let replacement = store.start(id: "sync", group: "foreground", policy: .cancelExisting) {
            await latest.wait()
            #expect(!Task.isCancelled)
        }
        let run = try #require(replacement.run)
        #expect(store.trackedCount(for: "sync") == 1)
        #expect(store.unfinishedCount(for: "sync") == 3)
        #expect(store.trackedCount(group: "background") == 0)
        await old.open()
        for oldRun in oldRuns { await store.awaitCompletion(of: oldRun) }
        #expect(store.isTracked(run))
        #expect(store.unfinishedCount(for: "sync") == 1)
        #expect(store.trackedCount(group: "foreground") == 1)
        await latest.open()
        await store.waitForIdle()
    }

    @Test func cancellationScopesSelectOnlyMatchingRuns() async throws {
        let store = ViewTaskStore()
        let gate = Gate()
        let first = try #require(store.start(id: "download", group: "foreground") {
            await gate.wait()
            #expect(Task.isCancelled)
        }.run)
        let second = try #require(store.start(
            id: "download", group: "background", policy: .allowConcurrent
        ) {
            await gate.wait()
            #expect(!Task.isCancelled)
        }.run)
        let third = try #require(store.start(id: "other", group: "custom") {
            await gate.wait()
            #expect(Task.isCancelled)
        }.run)

        store.cancel(first)
        store.cancel(first)
        store.cancel(group: "custom")
        #expect(!store.isTracked(first))
        #expect(store.isTracked(second))
        #expect(!store.isTracked(third))
        #expect(store.trackedCount(for: "download") == 1)
        #expect(!store.isTracked(group: "custom"))
        await gate.open()
        await store.waitForIdle()
    }

    @Test func runIdentityIncludesActionID() async throws {
        let store = ViewTaskStore()
        let gate = Gate()
        let run = try #require(store.start(id: "real", group: "foreground") {
            await gate.wait()
            #expect(!Task.isCancelled)
        }.run)
        let differentAction = ActionRun(actionID: "different", runID: run.runID)
        #expect(!store.isTracked(differentAction))
        #expect(!store.isUnfinished(differentAction))
        store.cancel(differentAction)
        await store.awaitCompletion(of: differentAction)
        #expect(store.isTracked(run))
        await gate.open()
        await store.waitForIdle()
    }

    @Test func cancelledWorkIsUntrackedButOwnedUntilTermination() async throws {
        let store = ViewTaskStore()
        let gate = Gate()
        let started = Checkpoint()
        let completed = Checkpoint()
        var operationFinished = false
        let run = try #require(store.start(id: "load", group: "foreground") {
            await gate.wait()
            #expect(Task.isCancelled)
            operationFinished = true
        }.run)
        await gate.waitForArrivals()
        store.cancel(run)
        #expect(!store.isTracked(run))
        #expect(store.isUnfinished(run))
        #expect(store.unfinishedCount == 1)
        let waiter = Task {
            started.reach()
            await store.awaitCompletion(of: run)
            #expect(operationFinished)
            completed.reach()
        }
        await started.wait()
        #expect(!completed.isReached)
        await gate.open()
        await waiter.value
        await store.awaitCompletion(of: run)
        #expect(!store.isUnfinished(run))
        #expect(store.unfinishedCount == 0)
    }

    @Test func cancelKeepsIgnoreNewClosedUntilOldOperationTerminates() async throws {
        let store = ViewTaskStore()
        let gate = Gate()
        let old = try #require(store.start(id: "save", group: "foreground") {
            await gate.wait()
        }.run)
        store.cancel(id: "save")
        let latest = store.start(id: "save", group: "foreground") { }
        #expect(latest == .skipped(.unfinished))
        #expect(store.unfinishedCount(for: "save") == 1)
        await gate.open()
        await store.awaitCompletion(of: old)
        #expect(store.start(id: "save") {}.run != nil)
        await store.waitForIdle()
    }

    @Test func cancelExistingAdmitsReplacementWhileCancelledWorkIsUnfinished() async throws {
        let store = ViewTaskStore()
        let oldGate = Gate()
        let replacementGate = Gate()
        let old = try #require(store.start(id: "search") {
            await oldGate.wait()
            #expect(Task.isCancelled)
        }.run)
        store.cancel(old)
        let replacement = try #require(store.start(id: "search", policy: .cancelExisting) {
            await replacementGate.wait()
            #expect(!Task.isCancelled)
        }.run)
        #expect(store.trackedCount(for: "search") == 1)
        #expect(store.unfinishedCount(for: "search") == 2)
        await oldGate.open()
        await store.awaitCompletion(of: old)
        #expect(store.isTracked(replacement))
        #expect(store.unfinishedCount(for: "search") == 1)
        await replacementGate.open()
        await store.waitForIdle()
        #expect(store.unfinishedCount == 0)
    }

    @Test func groupCancellationLeavesUngroupedWorkAndUnfinishedOwnershipIntact() async throws {
        let store = ViewTaskStore()
        let gate = Gate()
        let ungrouped = try #require(store.start(id: "work") {
            await gate.wait()
            #expect(!Task.isCancelled)
        }.run)
        let grouped = try #require(store.start(id: "work", group: "selection", policy: .allowConcurrent) {
            await gate.wait()
            #expect(Task.isCancelled)
        }.run)
        store.cancel(group: "selection")
        #expect(store.isTracked(ungrouped))
        #expect(!store.isTracked(grouped))
        #expect(store.unfinishedCount == 2)
        #expect(store.unfinishedCount(for: "work") == 2)
        await gate.open()
        await store.waitForIdle()
        #expect(store.unfinishedCount(for: "work") == 0)
    }

    @Test(arguments: [false, true])
    func cancellingWaiterDoesNotInterruptWaitOrCancelOwnedWork(waitForAll: Bool) async throws {
        let store = ViewTaskStore()
        let gate = Gate()
        let started = Checkpoint()
        let completed = Checkpoint()
        let run = try #require(store.start(id: "work") {
            await gate.wait()
            #expect(!Task.isCancelled)
        }.run)
        let waiter = Task {
            started.reach()
            if waitForAll {
                await store.waitForIdle()
            } else {
                await store.awaitCompletion(of: run)
            }
            completed.reach()
        }
        await started.wait()
        waiter.cancel()
        #expect(!completed.isReached)
        #expect(store.isTracked(run))
        #expect(store.isUnfinished(run))
        await gate.open()
        await waiter.value
        #expect(completed.isReached)
        #expect(!store.isUnfinished(run))
    }

    @Test func completionWaitSelectsOneRunAndSupportsMultipleWaiters() async throws {
        let store = ViewTaskStore()
        let first = Gate()
        let second = Gate()
        let run = try #require(store.start(id: "first", group: "foreground") {
            await first.wait()
        }.run)
        store.start(id: "second", group: "foreground") { await second.wait() }
        async let waiterA: Void = store.awaitCompletion(of: run)
        async let waiterB: Void = store.awaitCompletion(of: run)
        await first.open()
        _ = await (waiterA, waiterB)
        #expect(store.isTracked(id: "second"))
        await second.open()
        await store.waitForIdle()
    }

    @Test func idleWaitIncludesWorkAdmittedWhileSuspended() async throws {
        let store = ViewTaskStore()
        let first = Gate()
        let second = Gate()
        let started = Checkpoint()
        let completed = Checkpoint()
        var secondFinished = false
        let firstRun = try #require(store.start(id: "first", group: "foreground") {
            await first.wait()
        }.run)
        let waiter = Task {
            started.reach()
            await store.waitForIdle()
            #expect(secondFinished)
            completed.reach()
        }
        await started.wait()
        #expect(!completed.isReached)
        store.start(id: "second", group: "foreground") {
            await second.wait()
            secondFinished = true
        }
        await first.open()
        await store.awaitCompletion(of: firstRun)
        #expect(!completed.isReached)
        await second.open()
        await waiter.value
    }

    @Test func cancelAllUntracksEveryGroupAndStillWaitsForOperations() async {
        let store = ViewTaskStore()
        let gate = Gate()
        var completed = 0
        for group: CancellationGroup in ["foreground", "background", "custom"] {
            store.start(id: "work", group: group, policy: .allowConcurrent) {
                await gate.wait()
                #expect(Task.isCancelled)
                completed += 1
            }
        }
        store.cancelAll()
        store.cancelAll()
        #expect(store.trackedCount(for: "work") == 0)
        #expect(store.unfinishedCount(for: "work") == 3)
        #expect(store.trackedCount(group: "foreground") == 0)
        await gate.open()
        await store.waitForIdle()
        #expect(completed == 3)
        #expect(store.unfinishedCount == 0)
        #expect(store.start(id: "work", group: "foreground") { }.run != nil)
        await store.waitForIdle()
    }

    @Test func closeRejectsAllPoliciesWithoutCancellingAdmittedWork() async {
        let store = ViewTaskStore()
        let gate = Gate()
        store.start(id: "work", group: "foreground") {
            await gate.wait()
            #expect(!Task.isCancelled)
        }
        store.close()
        store.close()
        for policy in [TaskStartPolicy.ignoreNew, .cancelExisting, .allowConcurrent] {
            let rejected = store.start(id: "work", group: "background", policy: policy) {
                Issue.record("受付を閉じた Store が処理を受け付けました。")
            }
            #expect(rejected == .skipped(.closed))
        }
        #expect(store.isTracked(id: "work"))
        await gate.open()
        await store.waitForIdle()
    }

    @Test func teardownClosesBeforeSuspendingAndWaitsForCancelledWork() async {
        let store = ViewTaskStore()
        let gate = Gate()
        let started = Checkpoint()
        let completed = Checkpoint()
        var operationFinished = false
        store.start(id: "work", group: "foreground") {
            await gate.wait()
            #expect(Task.isCancelled)
            operationFinished = true
        }
        let teardown = Task {
            started.reach()
            await store.cancelAndWaitForIdle()
            #expect(operationFinished)
            completed.reach()
        }
        await started.wait()
        #expect(!completed.isReached)
        #expect(!store.isTracked(id: "work"))
        #expect(store.start(id: "new", group: "background") { }.skipReason == .closed)
        await gate.open()
        await teardown.value
        await store.cancelAndWaitForIdle()
        #expect(store.start(id: "new", group: "foreground") { }.skipReason == .closed)
    }

    @Test func foreignRunDoesNotAffectAnotherStore() async throws {
        let store = ViewTaskStore()
        let other = ViewTaskStore()
        let gate = Gate()
        let run = try #require(other.start(id: "work", group: "foreground") {
            await gate.wait()
        }.run)
        store.cancel(run)
        await store.awaitCompletion(of: run)
        #expect(!store.isUnfinished(run))
        #expect(other.isTracked(run))
        await gate.open()
        await other.waitForIdle()
    }

    @Test func failureObserverCanStartReplacementBeforeOldRunFinishes() async throws {
        let gate = Gate()
        var reported: (ActionRun, any Error)?
        let reference = StoreReference()
        let store = ViewTaskStore { run, failure in
            reported = (run, failure)
            #expect(reference.store?.isTracked(run) == true)
            reference.store?.start(id: run.actionID, group: "foreground", policy: .cancelExisting) {
                await gate.wait()
            }
        }
        reference.store = store
        let run = try #require(store.start(id: "failure", group: "foreground") {
            throw SampleError.offline
        }.run)
        await store.awaitCompletion(of: run)
        #expect(reported?.0 == run)
        #expect(reported?.1 as? SampleError == .offline)
        #expect(store.trackedCount(for: "failure") == 1)
        await gate.open()
        await store.waitForIdle()
    }

    @Test func cancelledRunCanReportAnUnhandledBusinessError() async {
        let gate = Gate()
        let reference = StoreReference()
        var reports = 0
        let store = ViewTaskStore { run, _ in
            #expect(reference.store?.isTracked(run) == false)
            reports += 1
        }
        reference.store = store
        store.start(id: "failure", group: "foreground") {
            await gate.wait()
            throw SampleError.offline
        }
        store.cancelAll()
        await gate.open()
        await store.waitForIdle()
        #expect(reports == 1)
    }

    @Test func cancellationErrorDoesNotReachFailureObserver() async {
        let store = ViewTaskStore { _, _ in Issue.record("キャンセルが失敗として報告されました。") }
        store.start(id: "cancel", group: "foreground") { throw CancellationError() }
        await store.waitForIdle()
        #expect(!store.isTracked(id: "cancel"))
    }

    @Test func deinitCancelsWorkAndReleasesObserverCapture() async {
        let gate = Gate()
        let finished = Checkpoint()
        var capture: StoreReference? = StoreReference()
        weak var weakCapture = capture
        defer { weakCapture = nil }
        var store: ViewTaskStore? = ViewTaskStore { [capture] _, _ in _ = capture }
        weak var weakStore = store
        defer { weakStore = nil }
        store?.start(id: "work", group: "foreground") {
            await gate.wait()
            #expect(Task.isCancelled)
            finished.reach()
        }
        await gate.waitForArrivals()
        store = nil
        capture = nil
        #expect(weakStore == nil)
        #expect(weakCapture == nil)
        await gate.open()
        await finished.wait()
    }

    #if !DEBUG
    @Test func selfWaitFromStructuredChildReturnsInRelease() async throws {
        let store = ViewTaskStore()
        var published: ActionRun?
        let outcome = store.start(id: "self", group: "foreground") {
            let run = try #require(published)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await store.awaitCompletion(of: run)
                    await store.waitForIdle()
                }
            }
        }
        let run = try #require(outcome.run)
        published = run
        await store.waitForIdle()
    }

    @Test func unobservedFailureStillFinishesInRelease() async {
        let store = ViewTaskStore()
        store.start(id: "failure", group: "foreground") { throw SampleError.offline }
        await store.waitForIdle()
        #expect(!store.isTracked(id: "failure"))
    }
    #endif
}

private enum SampleError: Error, Equatable { case offline }

@MainActor
private final class StoreReference {
    weak var store: ViewTaskStore?
}
