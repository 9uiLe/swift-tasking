import Tasking
import Testing
import TaskingTestSupport

@MainActor
@Suite(.timeLimit(.minutes(1)))
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
                #expect(runner.isRunning(id: run.actionID))
                #expect(runner.runningCount(for: run.actionID) == 1)
            },
            operation: { _ in
                #expect(startedRun != nil)
                return "done"
            }
        )

        #expect(outcome == .succeeded("done"))
        #expect(startedRun != nil)
    }

    @Test func ignoreNewSkipsDuplicateWhileRunning() async {
        let runner = ActionRunner()
        let gate = Gate()
        let started = Checkpoint()

        async let firstOutcome = runner.run(
            ActionDescriptor(id: "refresh"),
            onStart: { _ in started.reach() }
        ) { _ in
            await gate.wait()
            return "first"
        }

        await started.wait()

        let secondOutcome = await runner.run(
            ActionDescriptor(id: "refresh"),
            onStart: { _ in Issue.record("A skipped run must not report a start.") }
        ) { _ in
            Issue.record("A skipped operation must not execute.")
            return "second"
        }

        #expect(secondOutcome == .skipped(.alreadyRunning))

        await gate.open()
        _ = await firstOutcome
        #expect(!runner.isRunning(id: "refresh"))
    }

    @Test func allowsConcurrentRunsWhenRequested() async {
        let runner = ActionRunner()
        let firstGate = Gate()
        let secondGate = Gate()

        async let firstOutcome = runner.run(
            ActionDescriptor(id: "refresh", duplicatePolicy: .allowConcurrent)
        ) { _ in
            await firstGate.wait()
            return "first"
        }

        await firstGate.waitForArrivals()

        async let secondOutcome = runner.run(
            ActionDescriptor(id: "refresh", duplicatePolicy: .allowConcurrent)
        ) { _ in
            await secondGate.wait()
            return "second"
        }

        await secondGate.waitForArrivals()
        #expect(runner.runningCount(for: "refresh") == 2)

        await secondGate.open()
        #expect(await secondOutcome == .succeeded("second"))
        #expect(runner.runningCount(for: "refresh") == 1)
        await firstGate.open()
        #expect(await firstOutcome == .succeeded("first"))
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

    @Test func recursiveSameActionSkipsButDifferentActionRuns() async {
        let runner = ActionRunner()
        let outcome = await runner.run(ActionDescriptor(id: "outer")) { _ in
            let duplicate = await runner.run(ActionDescriptor(id: "outer")) { _ in 1 }
            #expect(duplicate == .skipped(.alreadyRunning))
            let inner = await runner.run(ActionDescriptor(id: "inner")) { _ in 2 }
            #expect(inner == .succeeded(2))
            #expect(runner.isRunning(id: "outer"))
            return 3
        }
        #expect(outcome == .succeeded(3))
        #expect(!runner.isRunning(id: "outer"))
    }

    @Test(arguments: [false, true])
    func terminalErrorsReleaseDuplicateAdmission(cancelled: Bool) async {
        let runner = ActionRunner()
        let _: ActionOutcome<Int> = await runner.run(ActionDescriptor(id: "work")) { _ in
            if cancelled { throw CancellationError() }
            throw SampleError.offline
        }
        #expect(runner.runningCount(for: "work") == 0)
        let next = await runner.run(ActionDescriptor(id: "work")) { _ in 42 }
        #expect(next == .succeeded(42))
    }

    @Test func cancellationIsCooperativeAndDoesNotRewriteASuccessfulReturn() async {
        let runner = ActionRunner()
        let task = Task {
            await runner.run(ActionDescriptor(id: "work")) { c in
                #expect(c.isCancelled)
                return "intentional result"
            }
        }
        task.cancel()
        #expect(await task.value == .succeeded("intentional result"))
    }

    @available(*, deprecated)
    @Test func rejectWhileRunningRemainsACompatibilityAlias() {
        let legacy: ActionDuplicatePolicy = .rejectWhileRunning

        #expect(legacy == .ignoreNew)
    }
}

private enum SampleError: Error, CustomStringConvertible {
    case offline

    var description: String {
        "offline"
    }
}
