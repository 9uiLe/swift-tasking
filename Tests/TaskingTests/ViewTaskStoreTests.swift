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

        guard case .started = outcome else {
            Issue.record("Expected task to start.")
            return
        }

        await gate.waitUntilCompleted()
        await store.waitUntilNotRunning("load")
        #expect(!store.isRunning(id: "load"))
    }

    @Test func ignoreNewSkipsWhenSameActionIsRunning() async {
        let store = ViewTaskStore()
        let gate = AsyncGate()

        store.start(id: "save", lifetime: .screenBound) { _ in
            await gate.waitUntilOpened()
        }

        await store.waitUntilRunning("save")

        let outcome = store.start(id: "save", lifetime: .screenBound, policy: .ignoreNew) { _ in }

        #expect(outcome == .skipped(.alreadyRunning))

        await gate.open()
        await store.waitUntilNotRunning("save")
    }

    @Test func cancelExistingStartsReplacement() async {
        let store = ViewTaskStore()
        let gate = AsyncGate()
        var replacementRan = false

        store.start(id: "sync", lifetime: .screenBound) { _ in
            await gate.waitUntilOpened()
        }

        await store.waitUntilRunning("sync")

        let outcome = store.start(id: "sync", lifetime: .screenBound, policy: .cancelExisting) { _ in
            replacementRan = true
        }

        guard case .started = outcome else {
            Issue.record("Expected replacement task to start.")
            return
        }

        await store.waitUntilNotRunning("sync")
        #expect(replacementRan)
        await gate.open()
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

        await store.waitUntilRunningCount("download", count: 2)
        #expect(store.runningCount(for: "download") == 2)

        await gate.open()
        await store.waitUntilNotRunning("download")
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

        await store.waitUntilRunningCount("upload", count: 2)
        store.cancel(firstRun)

        #expect(!store.isRunning(firstRun))
        #expect(store.isRunning(secondRun))
        #expect(store.runningCount(for: "upload") == 1)

        await gate.open()
        await store.waitUntilNotRunning("upload")
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

        await store.waitUntilRunning("screen")
        await store.waitUntilRunning("app")

        store.cancel(lifetime: .screenBound)

        #expect(!store.isRunning(id: "screen"))
        #expect(store.isRunning(id: "app"))

        await appGate.open()
        await store.waitUntilNotRunning("app")
        await screenGate.open()
    }

    @Test func customLifetimeCanBeCancelled() async {
        let store = ViewTaskStore()
        let lifetime: ActionLifetime = "accountSettings"
        let gate = AsyncGate()

        store.start(id: "refresh", lifetime: lifetime) { _ in
            await gate.waitUntilOpened()
        }

        await store.waitUntilRunning("refresh")
        #expect(store.isRunning(lifetime: lifetime))

        store.cancel(lifetime: lifetime)

        #expect(!store.isRunning(id: "refresh"))
        #expect(!store.isRunning(lifetime: lifetime))
        await gate.open()
    }

    @Test func cancellationContextThrowsAfterStoreCancellation() async {
        let store = ViewTaskStore()
        let release = AsyncGate()
        let observedCancellation = AsyncGate()

        store.start(id: "cancel", lifetime: .screenBound) { cancellation in
            await release.waitUntilOpened()

            do {
                try cancellation.check()
            } catch is CancellationError {
                await observedCancellation.markCompleted()
            }
        }

        await store.waitUntilRunning("cancel")
        store.cancel(id: "cancel")
        await release.open()
        await observedCancellation.waitUntilCompleted()
    }
}

private actor AsyncGate {
    private var completedContinuation: CheckedContinuation<Void, Never>?
    private var openedContinuations: [CheckedContinuation<Void, Never>] = []
    private var isCompleted = false
    private var isOpen = false

    func markCompleted() {
        isCompleted = true
        completedContinuation?.resume()
        completedContinuation = nil
    }

    func waitUntilCompleted() async {
        if isCompleted {
            return
        }

        await withCheckedContinuation { continuation in
            completedContinuation = continuation
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
}

private extension ViewTaskStore {
    func waitUntilRunning(_ id: ActionID) async {
        while !isRunning(id: id) {
            await Task.yield()
        }
    }

    func waitUntilNotRunning(_ id: ActionID) async {
        while isRunning(id: id) {
            await Task.yield()
        }
    }

    func waitUntilRunningCount(_ id: ActionID, count: Int) async {
        while runningCount(for: id) != count {
            await Task.yield()
        }
    }
}
