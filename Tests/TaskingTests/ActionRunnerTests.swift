import Tasking
import TaskingTestSupport
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ActionRunnerTests {
    @Test func successfulResultFinishesTracking() async {
        let runner = ActionRunner()
        let result = await runner.run(id: "save") {
            #expect(runner.isTracked(id: "save"))
            #expect(runner.trackedCount(for: "save") == 1)
            return "saved"
        }
        #expect(result == "saved")
        #expect(!runner.isTracked(id: "save"))
    }

    @Test func ignoreNewRejectsDuplicateWithoutExecutingIt() async {
        let runner = ActionRunner()
        let gate = Gate()
        async let first = runner.run(id: "refresh") {
            await gate.wait()
            return "first"
        }
        await gate.waitForArrivals()
        let duplicate = await runner.run(id: "refresh") {
            Issue.record("拒否した処理が実行されました。")
            return "duplicate"
        }
        #expect(duplicate == nil)
        #expect(runner.trackedCount(for: "refresh") == 1)
        await gate.open()
        #expect(await first == "first")
        #expect(!runner.isTracked(id: "refresh"))
    }

    @Test func concurrentRunsRemainTrackedUntilEachCompletes() async {
        let runner = ActionRunner()
        let firstGate = Gate()
        let secondGate = Gate()
        async let first = runner.run(id: "refresh", policy: .allowConcurrent) {
            await firstGate.wait()
            return "first"
        }
        await firstGate.waitForArrivals()
        async let second = runner.run(id: "refresh", policy: .allowConcurrent) {
            await secondGate.wait()
            return "second"
        }
        await secondGate.waitForArrivals()
        #expect(runner.trackedCount(for: "refresh") == 2)
        await secondGate.open()
        #expect(await second == "second")
        #expect(runner.trackedCount(for: "refresh") == 1)
        await firstGate.open()
        #expect(await first == "first")
        #expect(!runner.isTracked(id: "refresh"))
    }

    @Test func preservesNativeErrorAndReleasesAdmission() async {
        let runner = ActionRunner()
        do {
            let _: Int? = try await runner.run(id: "work") { throw SampleError.offline }
            Issue.record("処理のエラーが送出されませんでした。")
        } catch {
            #expect(error as? SampleError == .offline)
        }
        #expect(runner.trackedCount(for: "work") == 0)
        #expect(await runner.run(id: "work") { 42 } == 42)
    }

    @Test func cancellationReachesOperationAndIsRethrown() async {
        let runner = ActionRunner()
        let gate = Gate()
        let task = Task {
            try await runner.run(id: "cancel") {
                await gate.wait()
                try Task.checkCancellation()
                return "finished"
            }
        }
        await gate.waitForArrivals()
        task.cancel()
        await gate.open()
        do {
            _ = try await task.value
            Issue.record("キャンセルエラーが送出されませんでした。")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(!runner.isTracked(id: "cancel"))
    }

    @Test func cancelledCallerCanReturnASuccessfulResult() async {
        let runner = ActionRunner()
        let task = Task {
            await runner.run(id: "work") {
                #expect(Task.isCancelled)
                return "intentional result"
            }
        }
        task.cancel()
        #expect(await task.value == "intentional result")
    }

    @Test func recursiveSameActionIsRejectedWhileDifferentActionRuns() async {
        let runner = ActionRunner()
        let result = await runner.run(id: "outer") {
            #expect(await runner.run(id: "outer") { 1 } == nil)
            #expect(await runner.run(id: "inner") { 2 } == 2)
            #expect(runner.isTracked(id: "outer"))
            return 3
        }
        #expect(result == 3)
        #expect(!runner.isTracked(id: "outer"))
    }

    @Test func optionalSuccessIsDistinctFromRejectedAdmission() async {
        let runner = ActionRunner()
        let gate = Gate()
        async let first: Int?? = runner.run(id: "optional") {
            await gate.wait()
            return Optional<Int>.none
        }
        await gate.waitForArrivals()
        let rejected: Int?? = await runner.run(id: "optional") { nil }
        guard case .none = rejected else {
            Issue.record("受付拒否が外側の nil になりませんでした。")
            await gate.open()
            _ = await first
            return
        }
        await gate.open()
        guard case .some(.none) = await first else {
            Issue.record("成功した nil を受付拒否と区別できませんでした。")
            return
        }
    }

    @Test func resultAndOperationStateCanRemainNonSendableOnMainActor() async {
        let runner = ActionRunner()
        let value = LocalValue()
        let result = await runner.run(id: "local") {
            value.count += 1
            return value
        }
        #expect(result === value)
        #expect(value.count == 1)
    }
}

private enum SampleError: Error, Equatable { case offline }

private final class LocalValue {
    var count = 0
}
