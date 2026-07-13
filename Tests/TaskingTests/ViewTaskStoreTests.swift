import Tasking
import Testing

@MainActor
struct ViewTaskStoreTests {
    @Test func startRunsOperationAndRemovesCompletedTask() async {
        let store = ViewTaskStore()
        let gate = AsyncGate()

        let outcome = store.start(id: "load", lifetime: .screenBound) { _ in
            await gate.markCompleted()
        }

        guard case let .started(run) = outcome else {
            Issue.record("Expected task to start.")
            return
        }

        await gate.waitUntilCompleted()
        await store.awaitCompletion(of: run)
        #expect(!store.isRunning(id: "load"))
    }

    @Test func ignoreNewSkipsWhenSameActionIsRunning() async {
        let store = ViewTaskStore()
        let gate = AsyncGate()

        let first = store.start(id: "save", lifetime: .screenBound) { _ in
            await gate.waitUntilOpened()
        }

        let outcome = store.start(id: "save", lifetime: .screenBound, policy: .ignoreNew) { _ in }

        #expect(outcome == .skipped(.alreadyRunning))

        await gate.open()
        if let run = first.run {
            await store.awaitCompletion(of: run)
        }
    }

    @Test func cancelExistingStartsReplacement() async {
        let store = ViewTaskStore()
        let gate = AsyncGate()
        var replacementRan = false

        store.start(id: "sync", lifetime: .screenBound) { _ in
            await gate.waitUntilOpened()
        }

        let outcome = store.start(id: "sync", lifetime: .screenBound, policy: .cancelExisting) { _ in
            replacementRan = true
        }

        guard case let .started(run) = outcome else {
            Issue.record("Expected replacement task to start.")
            return
        }

        await store.awaitCompletion(of: run)
        #expect(replacementRan)
        await gate.open()
        await store.waitForIdle()
    }

    @Test func allowConcurrentTracksMultipleRuns() async {
        let store = ViewTaskStore()
        let gate = AsyncGate()

        store.start(id: "download", lifetime: .screenBound, policy: .allowConcurrent) { _ in
            await gate.waitUntilOpened()
        }
        store.start(id: "download", lifetime: .screenBound, policy: .allowConcurrent) { _ in
            await gate.waitUntilOpened()
        }

        #expect(store.runningCount(for: "download") == 2)

        await gate.open()
        await store.waitForIdle()
    }

    @Test func cancelRunCancelsOnlyMatchingRun() async {
        let store = ViewTaskStore()
        let gate = AsyncGate()

        let first = store.start(id: "upload", lifetime: .screenBound, policy: .allowConcurrent) { _ in
            await gate.waitUntilOpened()
        }
        let second = store.start(id: "upload", lifetime: .screenBound, policy: .allowConcurrent) { _ in
            await gate.waitUntilOpened()
        }

        guard let firstRun = first.run, let secondRun = second.run else {
            Issue.record("Expected both tasks to start.")
            return
        }

        store.cancel(firstRun)

        #expect(!store.isRunning(firstRun))
        #expect(store.isRunning(secondRun))
        #expect(store.runningCount(for: "upload") == 1)

        await gate.open()
        await store.waitForIdle()
    }

    @Test func cancelLifetimeCancelsMatchingTasks() async {
        let store = ViewTaskStore()
        let screenGate = AsyncGate()
        let appGate = AsyncGate()

        store.start(id: "screen", lifetime: .screenBound) { _ in
            await screenGate.waitUntilOpened()
        }
        store.start(id: "app", lifetime: .appBound) { _ in
            await appGate.waitUntilOpened()
        }

        store.cancel(lifetime: .screenBound)

        #expect(!store.isRunning(id: "screen"))
        #expect(store.isRunning(id: "app"))

        await appGate.open()
        await screenGate.open()
        await store.waitForIdle()
    }

    @Test func customLifetimeCanBeCancelled() async {
        let store = ViewTaskStore()
        let lifetime: ActionLifetime = "accountSettings"
        let gate = AsyncGate()

        store.start(id: "refresh", lifetime: lifetime) { _ in
            await gate.waitUntilOpened()
        }

        #expect(store.isRunning(lifetime: lifetime))

        store.cancel(lifetime: lifetime)

        #expect(!store.isRunning(id: "refresh"))
        #expect(!store.isRunning(lifetime: lifetime))
        await gate.open()
        await store.waitForIdle()
    }

    @Test func cancellationContextThrowsAfterStoreCancellation() async {
        let store = ViewTaskStore()
        let release = AsyncGate()
        let observedCancellation = AsyncGate()

        let outcome = store.start(id: "cancel", lifetime: .screenBound) { cancellation in
            await release.waitUntilOpened()

            do {
                try cancellation.check()
            } catch is CancellationError {
                await observedCancellation.markCompleted()
            }
        }

        store.cancel(id: "cancel")
        await release.open()
        await observedCancellation.waitUntilCompleted()
        if let run = outcome.run {
            await store.awaitCompletion(of: run)
        }
    }

    @Test func cancelledRunIsUntrackedButAwaitCompletionWaitsForTermination() async {
        let store = ViewTaskStore()
        let operationStarted = AsyncGate()
        let release = AsyncGate()
        let waiterStarted = AsyncGate()
        let waiterCompleted = AsyncGate()

        let outcome = store.start(id: "zombie", lifetime: .screenBound) { _ in
            await operationStarted.markCompleted()
            await release.waitUntilOpened()
        }
        guard let run = outcome.run else {
            Issue.record("Expected task to start.")
            return
        }
        await operationStarted.waitUntilCompleted()

        store.cancel(run)
        #expect(!store.isRunning(run))

        let waiter = Task { @MainActor in
            await waiterStarted.markCompleted()
            await store.awaitCompletion(of: run)
            await waiterCompleted.markCompleted()
        }
        await waiterStarted.waitUntilCompleted()
        try? await Task.sleep(for: .milliseconds(10))
        let completedBeforeTermination = await waiterCompleted.hasCompleted
        #expect(!completedBeforeTermination)

        await release.open()
        await waiterCompleted.waitUntilCompleted()
        await waiter.value
    }

    @Test func waitForIdleIncludesRunsStartedWhileWaiting() async {
        let store = ViewTaskStore()
        let firstRelease = AsyncGate()
        let secondRelease = AsyncGate()
        let waiterStarted = AsyncGate()
        let waiterCompleted = AsyncGate()

        store.start(id: "first", lifetime: .screenBound) { _ in
            await firstRelease.waitUntilOpened()
        }

        let waiter = Task { @MainActor in
            await waiterStarted.markCompleted()
            await store.waitForIdle()
            await waiterCompleted.markCompleted()
        }
        await waiterStarted.waitUntilCompleted()

        store.start(id: "second", lifetime: .screenBound) { _ in
            await secondRelease.waitUntilOpened()
        }
        await firstRelease.open()
        try? await Task.sleep(for: .milliseconds(10))
        let completedBeforeSecondRun = await waiterCompleted.hasCompleted
        #expect(!completedBeforeSecondRun)

        await secondRelease.open()
        await waiterCompleted.waitUntilCompleted()
        await waiter.value
    }

    @Test func cancelAllMovesEveryRunToTerminationOwnership() async {
        let store = ViewTaskStore()
        let release = AsyncGate()

        store.start(id: "one", lifetime: .screenBound) { _ in
            await release.waitUntilOpened()
        }
        store.start(id: "two", lifetime: .appBound) { _ in
            await release.waitUntilOpened()
        }

        store.cancelAll()
        #expect(!store.isRunning(id: "one"))
        #expect(!store.isRunning(id: "two"))

        await release.open()
        await store.waitForIdle()
    }

    @Test func awaitCompletionReturnsForRunOwnedByAnotherStore() async {
        let store = ViewTaskStore()
        let otherStore = ViewTaskStore()
        let release = AsyncGate()

        let outcome = otherStore.start(id: "other", lifetime: .screenBound) { _ in
            await release.waitUntilOpened()
        }
        guard let run = outcome.run else {
            Issue.record("Expected task to start.")
            return
        }

        await store.awaitCompletion(of: run)
        #expect(otherStore.isRunning(run))

        otherStore.cancelAll()
        await release.open()
        await otherStore.waitForIdle()
    }

    @Test func unhandledErrorHookReceivesRunBeforeItIsUntracked() async {
        let observer = UnhandledErrorObserver()
        let store = ViewTaskStore { run, failure in
            observer.record(run: run, failure: failure)
        }
        observer.store = store

        let outcome = store.start(id: "failure", lifetime: .screenBound) { _ in
            throw SampleError.offline
        }
        guard let run = outcome.run else {
            Issue.record("Expected task to start.")
            return
        }

        await store.awaitCompletion(of: run)

        #expect(observer.run == run)
        #expect(observer.failure?.typeName.contains("SampleError") == true)
        #expect(observer.failure?.message == "offline")
        #expect(observer.wasTrackedWhenReported)
        #expect(!store.isRunning(run))
    }

    @Test func deallocatingStoreReleasesUnhandledErrorHandlerWhileOperationIsRunning() async {
        let operationStarted = AsyncGate()
        let releaseOperation = AsyncGate()
        var handlerCapture: UnhandledErrorHandlerCapture? = .init()
        weak var weakHandlerCapture = handlerCapture
        defer { weakHandlerCapture = nil }

        var store: ViewTaskStore? = ViewTaskStore { [handlerCapture] _, _ in
            handlerCapture?.recordInvocation()
        }
        weak var weakStore = store
        defer { weakStore = nil }

        store?.start(id: "handler-lifetime", lifetime: .screenBound) { _ in
            await operationStarted.markCompleted()
            await releaseOperation.waitUntilOpened()
        }
        await operationStarted.waitUntilCompleted()

        store = nil
        handlerCapture = nil

        #expect(weakStore == nil)
        #expect(weakHandlerCapture == nil)
        await releaseOperation.open()
    }

    @Test func completionGateSupportsMultipleWaiters() async {
        let gate = AsyncGate()

        async let first: Void = gate.waitUntilCompleted()
        async let second: Void = gate.waitUntilCompleted()
        await gate.waitUntilCompletedWaiterCount(2)
        await gate.markCompleted()

        _ = await (first, second)
    }

    #if !DEBUG
    @Test func currentRunAwaitCompletionReturnsInRelease() async {
        let store = ViewTaskStore()
        let runReference = RunReference()
        let returned = AsyncGate()

        let outcome = store.start(id: "self-await", lifetime: .screenBound) { _ in
            guard let run = runReference.run else {
                Issue.record("Run was not published before operation execution.")
                return
            }
            await store.awaitCompletion(of: run)
            await returned.markCompleted()
        }
        runReference.run = outcome.run

        await returned.waitUntilCompleted()
        await store.waitForIdle()
    }

    @Test func currentRunWaitForIdleReturnsInRelease() async {
        let store = ViewTaskStore()
        let returned = AsyncGate()

        store.start(id: "self-idle", lifetime: .screenBound) { _ in
            await store.waitForIdle()
            await returned.markCompleted()
        }

        await returned.waitUntilCompleted()
        await store.waitForIdle()
    }

    @Test func nestedUnstructuredTaskInheritsSelfWaitProtection() async {
        let store = ViewTaskStore()
        let returned = AsyncGate()

        store.start(id: "nested-self-idle", lifetime: .screenBound) { _ in
            let inner = Task { @MainActor in
                await store.waitForIdle()
            }
            await inner.value
            await returned.markCompleted()
        }

        await returned.waitUntilCompleted()
        await store.waitForIdle()
    }

    @Test func unhandledErrorWithoutHookKeepsLegacyReleaseBehavior() async {
        let store = ViewTaskStore()
        let outcome = store.start(id: "legacy-failure", lifetime: .screenBound) { _ in
            throw SampleError.offline
        }

        if let run = outcome.run {
            await store.awaitCompletion(of: run)
        }
        #expect(!store.isRunning(id: "legacy-failure"))
    }
    #endif
}

private actor AsyncGate {
    private var completedContinuations: [CheckedContinuation<Void, Never>] = []
    private var completedWaiterCountContinuations: [
        (target: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private var openedContinuations: [CheckedContinuation<Void, Never>] = []
    private var isCompleted = false
    private var isOpen = false

    var hasCompleted: Bool {
        isCompleted
    }

    func markCompleted() {
        isCompleted = true
        let continuations = completedContinuations
        completedContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func waitUntilCompleted() async {
        if isCompleted {
            return
        }

        await withCheckedContinuation { continuation in
            completedContinuations.append(continuation)
            resumeCompletedWaiterCountContinuations()
        }
    }

    func waitUntilCompletedWaiterCount(_ target: Int) async {
        guard completedContinuations.count < target else {
            return
        }
        await withCheckedContinuation { continuation in
            completedWaiterCountContinuations.append((target, continuation))
        }
    }

    func waitUntilOpened() async {
        if isOpen {
            return
        }

        await withCheckedContinuation { continuation in
            openedContinuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let continuations = openedContinuations
        openedContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func resumeCompletedWaiterCountContinuations() {
        var remaining: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in completedWaiterCountContinuations {
            if completedContinuations.count >= waiter.target {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        completedWaiterCountContinuations = remaining
    }
}

private enum SampleError: Error, CustomStringConvertible {
    case offline

    var description: String {
        "offline"
    }
}

@MainActor
private final class UnhandledErrorObserver {
    weak var store: ViewTaskStore?
    private(set) var run: ActionRun?
    private(set) var failure: ActionFailure?
    private(set) var wasTrackedWhenReported = false

    func record(run: ActionRun, failure: ActionFailure) {
        self.run = run
        self.failure = failure
        wasTrackedWhenReported = store?.isRunning(run) == true
    }
}

@MainActor
private final class UnhandledErrorHandlerCapture {
    private(set) var invocationCount = 0

    func recordInvocation() {
        invocationCount += 1
    }
}

@MainActor
private final class RunReference {
    var run: ActionRun?
}
