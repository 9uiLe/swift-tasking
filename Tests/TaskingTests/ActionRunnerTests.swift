import Tasking
import Testing

@MainActor
struct ActionRunnerTests {
    @Test func runReturnsSucceededOutcome() async {
        let runner = ActionRunner()

        let outcome = await runner.run(ActionDescriptor(id: "save")) { _ in
            "saved"
        }

        #expect(outcome == .succeeded("saved"))
        #expect(!runner.isRunning(id: "save"))
    }

    @Test func reportsStartBeforeAwaitingOperation() async {
        let runner = ActionRunner()
        var startedRun: ActionRun?

        let outcome = await runner.run(
            ActionDescriptor(id: "sync"),
            onStart: { run in
                startedRun = run
            },
            operation: { _ in
                "done"
            }
        )

        #expect(outcome == .succeeded("done"))
        #expect(startedRun != nil)
    }

    @Test func rejectsDuplicateWhileRunning() async {
        let runner = ActionRunner()
        let gate = AsyncGate()

        async let firstOutcome = runner.run(ActionDescriptor(id: "refresh")) { _ in
            await gate.wait()
            return "first"
        }

        await runner.waitUntilRunning("refresh")

        let secondOutcome = await runner.run(ActionDescriptor(id: "refresh")) { _ in
            "second"
        }

        #expect(secondOutcome == .skipped(.alreadyRunning))

        await gate.open()
        _ = await firstOutcome
        #expect(!runner.isRunning(id: "refresh"))
    }

    @Test func allowsConcurrentRunsWhenRequested() async {
        let runner = ActionRunner()
        let gate = AsyncGate()

        async let firstOutcome = runner.run(
            ActionDescriptor(id: "refresh", duplicatePolicy: .allowConcurrent)
        ) { _ in
            await gate.wait()
            return "first"
        }

        await runner.waitUntilRunning("refresh")

        async let secondOutcome = runner.run(
            ActionDescriptor(id: "refresh", duplicatePolicy: .allowConcurrent)
        ) { _ in
            await gate.wait()
            return "second"
        }

        await runner.waitUntilRunningCount("refresh", count: 2)
        #expect(runner.runningCount(for: "refresh") == 2)

        await gate.open()
        #expect(await firstOutcome == .succeeded("first"))
        #expect(await secondOutcome == .succeeded("second"))
        #expect(!runner.isRunning(id: "refresh"))
    }

    @Test func mapsCancellationErrorToCancelledOutcome() async {
        let runner = ActionRunner()

        let outcome = await runner.run(ActionDescriptor(id: "cancel")) { _ in
            throw CancellationError()
        }

        guard case .cancelled = outcome else {
            Issue.record("Expected cancelled outcome.")
            return
        }
    }

    @Test func mapsThrownErrorToFailure() async {
        let runner = ActionRunner()

        let outcome = await runner.run(ActionDescriptor(id: "fail")) { _ in
            throw SampleError.offline
        }

        guard case let .failed(failure) = outcome else {
            Issue.record("Expected failed outcome.")
            return
        }
        #expect(failure.typeName.contains("SampleError"))
        #expect(failure.message == "offline")
    }

    @Test func mapsCancellationContextCheckToCancelledOutcome() async {
        let runner = ActionRunner()

        let task = Task { @MainActor in
            await runner.run(ActionDescriptor(id: "cancel.context")) { cancellation in
                try cancellation.check()
                return "finished"
            }
        }

        task.cancel()

        let outcome = await task.value
        #expect(outcome == .cancelled)
    }
}

private enum SampleError: Error, CustomStringConvertible {
    case offline

    var description: String {
        "offline"
    }
}

private actor AsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen {
            return
        }

        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let continuations = continuations
        self.continuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private extension ActionRunner {
    func waitUntilRunning(_ id: ActionID) async {
        while !isRunning(id: id) {
            await Task.yield()
        }
    }

    func waitUntilRunningCount(_ id: ActionID, count: Int) async {
        while runningCount(for: id) != count {
            await Task.yield()
        }
    }
}
