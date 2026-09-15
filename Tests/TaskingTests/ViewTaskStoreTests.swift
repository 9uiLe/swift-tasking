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
        let outcome = store.start(id: "load", lifetime: .screenBound) { _ in
            let run = try #require(published)
            #expect(store.isRunning(run))
            executed = true
        }
        let run = try #require(outcome.run)
        published = run
        #expect(store.isRunning(run))
        await store.awaitCompletion(of: run)
        #expect(executed)
        #expect(!store.isRunning(run))
        #expect(!store.isRunning(lifetime: .screenBound))
    }

    @Test func duplicatePolicyUsesActionIDAcrossLifetimes() async {
        let store = ViewTaskStore()
        let gate = Gate()
        store.start(id: "save", lifetime: .screenBound) { _ in await gate.wait() }
        let duplicate = store.start(id: "save", lifetime: .appBound) { _ in
            Issue.record("スキップした処理が実行されました。")
        }
        #expect(duplicate == .skipped(.alreadyRunning))
        #expect(store.runningCount(for: "save") == 1)
        await gate.open()
        await store.waitForIdle()
    }

    @Test func cancelExistingCancelsEveryMatchingRunAndPreservesReplacement() async throws {
        let store = ViewTaskStore()
        let old = Gate()
        let latest = Gate()
        var oldRuns: [ActionRun] = []
        for lifetime: ActionLifetime in [.screenBound, .appBound] {
            let outcome = store.start(id: "sync", lifetime: lifetime, policy: .allowConcurrent) { c in
                await old.wait()
                #expect(c.isCancelled)
            }
            oldRuns.append(try #require(outcome.run))
        }
        await old.waitForArrivals(2)
        let replacement = store.start(id: "sync", lifetime: .screenBound, policy: .cancelExisting) { c in
            await latest.wait()
            #expect(!c.isCancelled)
        }
        let run = try #require(replacement.run)
        #expect(store.runningCount(for: "sync") == 1)
        #expect(store.runningCount(lifetime: .appBound) == 0)
        await old.open()
        for oldRun in oldRuns { await store.awaitCompletion(of: oldRun) }
        #expect(store.isRunning(run))
        #expect(store.runningCount(lifetime: .screenBound) == 1)
        await latest.open()
        await store.waitForIdle()
    }

    @Test func cancellationScopesSelectOnlyMatchingRuns() async throws {
        let store = ViewTaskStore()
        let gate = Gate()
        let first = try #require(store.start(id: "download", lifetime: .screenBound) { c in
            await gate.wait()
            #expect(c.isCancelled)
        }.run)
        let second = try #require(store.start(
            id: "download", lifetime: .appBound, policy: .allowConcurrent
        ) { c in
            await gate.wait()
            #expect(!c.isCancelled)
        }.run)
        let third = try #require(store.start(id: "other", lifetime: "custom") { c in
            await gate.wait()
            #expect(c.isCancelled)
        }.run)

        store.cancel(first)
        store.cancel(first)
        store.cancel(lifetime: "custom")
        #expect(!store.isRunning(first))
        #expect(store.isRunning(second))
        #expect(!store.isRunning(third))
        #expect(store.runningCount(for: "download") == 1)
        #expect(!store.isRunning(lifetime: "custom"))
        await gate.open()
        await store.waitForIdle()
    }

    @Test func runIdentityIncludesActionID() async throws {
        let store = ViewTaskStore()
        let gate = Gate()
        let run = try #require(store.start(id: "real", lifetime: .screenBound) { c in
            await gate.wait()
            #expect(!c.isCancelled)
        }.run)
        let differentAction = ActionRun(actionID: "different", runID: run.runID)
        #expect(!store.isRunning(differentAction))
        store.cancel(differentAction)
        await store.awaitCompletion(of: differentAction)
        #expect(store.isRunning(run))
        await gate.open()
        await store.waitForIdle()
    }

    @Test func cancelledWorkIsUntrackedButOwnedUntilTermination() async throws {
        let store = ViewTaskStore()
        let gate = Gate()
        let started = Checkpoint()
        let completed = Checkpoint()
        var operationFinished = false
        let run = try #require(store.start(id: "load", lifetime: .screenBound) { c in
            await gate.wait()
            #expect(c.isCancelled)
            operationFinished = true
        }.run)
        await gate.waitForArrivals()
        store.cancel(run)
        #expect(!store.isRunning(run))
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
    }

    @Test func cancelAllowsNewWorkBeforeOldOperationTerminates() async throws {
        let store = ViewTaskStore()
        let gate = Gate()
        let old = try #require(store.start(id: "save", lifetime: .screenBound) { _ in
            await gate.wait()
        }.run)
        store.cancel(id: "save")
        let latest = store.start(id: "save", lifetime: .screenBound) { _ in }
        #expect(latest.run != nil)
        await gate.open()
        await store.awaitCompletion(of: old)
        await store.waitForIdle()
    }

    @Test func completionWaitSelectsOneRunAndSupportsMultipleWaiters() async throws {
        let store = ViewTaskStore()
        let first = Gate()
        let second = Gate()
        let run = try #require(store.start(id: "first", lifetime: .screenBound) { _ in
            await first.wait()
        }.run)
        store.start(id: "second", lifetime: .screenBound) { _ in await second.wait() }
        async let waiterA: Void = store.awaitCompletion(of: run)
        async let waiterB: Void = store.awaitCompletion(of: run)
        await first.open()
        _ = await (waiterA, waiterB)
        #expect(store.isRunning(id: "second"))
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
        let firstRun = try #require(store.start(id: "first", lifetime: .screenBound) { _ in
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
        store.start(id: "second", lifetime: .screenBound) { _ in
            await second.wait()
            secondFinished = true
        }
        await first.open()
        await store.awaitCompletion(of: firstRun)
        #expect(!completed.isReached)
        await second.open()
        await waiter.value
    }

    @Test func cancelAllUntracksEveryLifetimeAndStillWaitsForOperations() async {
        let store = ViewTaskStore()
        let gate = Gate()
        var completed = 0
        for lifetime: ActionLifetime in [.screenBound, .appBound, "custom"] {
            store.start(id: "work", lifetime: lifetime, policy: .allowConcurrent) { c in
                await gate.wait()
                #expect(c.isCancelled)
                completed += 1
            }
        }
        store.cancelAll()
        store.cancelAll()
        #expect(store.runningCount(for: "work") == 0)
        #expect(store.runningCount(lifetime: .screenBound) == 0)
        await gate.open()
        await store.waitForIdle()
        #expect(completed == 3)
        #expect(store.start(id: "work", lifetime: .screenBound) { _ in }.run != nil)
        await store.waitForIdle()
    }

    @Test func closeRejectsAllPoliciesWithoutCancellingAdmittedWork() async {
        let store = ViewTaskStore()
        let gate = Gate()
        store.start(id: "work", lifetime: .screenBound) { c in
            await gate.wait()
            #expect(!c.isCancelled)
        }
        store.close()
        store.close()
        for policy in [TaskStartPolicy.ignoreNew, .cancelExisting, .allowConcurrent] {
            let rejected = store.start(id: "work", lifetime: .appBound, policy: policy) { _ in
                Issue.record("受付を閉じた Store が処理を受け付けました。")
            }
            #expect(rejected == .skipped(.closed))
        }
        #expect(store.isRunning(id: "work"))
        await gate.open()
        await store.waitForIdle()
    }

    @Test func teardownClosesBeforeSuspendingAndWaitsForCancelledWork() async {
        let store = ViewTaskStore()
        let gate = Gate()
        let started = Checkpoint()
        let completed = Checkpoint()
        var operationFinished = false
        store.start(id: "work", lifetime: .screenBound) { c in
            await gate.wait()
            #expect(c.isCancelled)
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
        #expect(!store.isRunning(id: "work"))
        #expect(store.start(id: "new", lifetime: .appBound) { _ in }.skipReason == .closed)
        await gate.open()
        await teardown.value
        await store.cancelAndWaitForIdle()
        #expect(store.start(id: "new", lifetime: .screenBound) { _ in }.skipReason == .closed)
    }

    @Test func foreignRunDoesNotAffectAnotherStore() async throws {
        let store = ViewTaskStore()
        let other = ViewTaskStore()
        let gate = Gate()
        let run = try #require(other.start(id: "work", lifetime: .screenBound) { _ in
            await gate.wait()
        }.run)
        store.cancel(run)
        await store.awaitCompletion(of: run)
        #expect(other.isRunning(run))
        await gate.open()
        await other.waitForIdle()
    }

    @Test func failureObserverCanStartReplacementBeforeOldRunFinishes() async throws {
        let gate = Gate()
        var reported: (ActionRun, ActionFailure)?
        let reference = StoreReference()
        let store = ViewTaskStore { run, failure in
            reported = (run, failure)
            #expect(reference.store?.isRunning(run) == true)
            reference.store?.start(id: run.actionID, lifetime: .screenBound, policy: .cancelExisting) { _ in
                await gate.wait()
            }
        }
        reference.store = store
        let run = try #require(store.start(id: "failure", lifetime: .screenBound) { _ in
            throw SampleError.offline
        }.run)
        await store.awaitCompletion(of: run)
        #expect(reported?.0 == run)
        #expect(reported?.1 == ActionFailure(error: SampleError.offline))
        #expect(store.runningCount(for: "failure") == 1)
        await gate.open()
        await store.waitForIdle()
    }

    @Test func cancelledRunCanReportAnUnhandledBusinessError() async {
        let gate = Gate()
        let reference = StoreReference()
        var reports = 0
        let store = ViewTaskStore { run, _ in
            #expect(reference.store?.isRunning(run) == false)
            reports += 1
        }
        reference.store = store
        store.start(id: "failure", lifetime: .screenBound) { _ in
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
        store.start(id: "cancel", lifetime: .screenBound) { _ in throw CancellationError() }
        await store.waitForIdle()
        #expect(!store.isRunning(id: "cancel"))
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
        store?.start(id: "work", lifetime: .screenBound) { c in
            await gate.wait()
            #expect(c.isCancelled)
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
        let outcome = store.start(id: "self", lifetime: .screenBound) { _ in
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
        store.start(id: "failure", lifetime: .screenBound) { _ in throw SampleError.offline }
        await store.waitForIdle()
        #expect(!store.isRunning(id: "failure"))
    }
    #endif
}

private enum SampleError: Error { case offline }

@MainActor
private final class StoreReference {
    weak var store: ViewTaskStore?
}
