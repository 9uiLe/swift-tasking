import TaskingCore
import XCTest

final class TaskSlotTests: XCTestCase {
    func testImmediateOperationFinishesBeforeWaitForIdleReturns() async {
        let slot = TaskSlot()
        let recorder = ValueRecorder()

        await slot.replace { _ in
            await recorder.append("completed")
        }
        await slot.waitForIdle()

        let values = await recorder.values
        XCTAssertEqual(values, ["completed"])
    }

    func testReplaceCancelsPreviousOperationAndRunsLatest() async {
        let slot = TaskSlot()
        let firstGate = ManualGate()
        let latestGate = ManualGate()
        let recorder = ValueRecorder()

        await slot.replace { cancellation in
            await firstGate.wait()
            guard !cancellation.isCancelled else {
                return
            }
            await recorder.append("first")
        }
        await firstGate.waitUntilArrival()

        await slot.replace { cancellation in
            await latestGate.wait()
            guard !cancellation.isCancelled else {
                return
            }
            await recorder.append("latest")
        }
        await latestGate.waitUntilArrival()

        await latestGate.open()
        await firstGate.open()
        await slot.waitForIdle()

        let values = await recorder.values
        XCTAssertEqual(values, ["latest"])
    }

    func testCancelPreventsTheOperationEffectAndWaitsForTermination() async {
        let slot = TaskSlot()
        let gate = ManualGate()
        let recorder = ValueRecorder()

        await slot.replace { cancellation in
            await gate.wait()
            guard !cancellation.isCancelled else {
                return
            }
            await recorder.append("completed")
        }
        await gate.waitUntilArrival()

        await slot.cancel()
        await gate.open()
        await slot.waitForIdle()

        let values = await recorder.values
        XCTAssertTrue(values.isEmpty)
    }

    func testWaitForIdleDoesNotFinishUntilCancelledOperationTerminates() async {
        let slot = TaskSlot()
        let gate = ManualGate()
        let probe = CompletionProbe()

        await slot.replace { _ in
            await gate.wait()
        }
        await gate.waitUntilArrival()
        await slot.cancel()

        async let waiter: Void = recordWhenSlotBecomesIdle(slot, probe: probe)
        await probe.waitUntilStarted()
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        let completedBeforeTermination = await probe.isCompleted
        XCTAssertFalse(completedBeforeTermination)

        await gate.open()
        await waiter
        let completedAfterTermination = await probe.isCompleted
        XCTAssertTrue(completedAfterTermination)
    }
}

private func recordWhenSlotBecomesIdle(_ slot: TaskSlot, probe: CompletionProbe) async {
    await probe.markStarted()
    await slot.waitForIdle()
    await probe.markCompleted()
}

private actor ManualGate {
    private var arrivals = 0
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        arrivals += 1
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitUntilArrival() async {
        while arrivals == 0 {
            await Task.yield()
        }
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations = []
        for continuation in waiting {
            continuation.resume()
        }
    }
}

private actor ValueRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private actor CompletionProbe {
    private var hasStarted = false
    private(set) var isCompleted = false

    func markStarted() {
        hasStarted = true
    }

    func waitUntilStarted() async {
        while !hasStarted {
            await Task.yield()
        }
    }

    func markCompleted() {
        isCompleted = true
    }
}
