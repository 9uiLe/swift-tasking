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
        try? await Task.sleep(for: .milliseconds(10))
        let completedBeforeTermination = await probe.isCompleted
        XCTAssertFalse(completedBeforeTermination)

        await gate.open()
        await waiter
        let completedAfterTermination = await probe.isCompleted
        XCTAssertTrue(completedAfterTermination)
    }

    func testCloseRejectsReplacementWithoutRunningIt() async {
        let slot = TaskSlot()
        let recorder = ValueRecorder()

        await slot.close()
        let accepted = await slot.replace { _ in
            await recorder.append("unexpected")
        }

        XCTAssertFalse(accepted)
        await slot.waitForIdle()
        let values = await recorder.values
        XCTAssertTrue(values.isEmpty)
    }

    func testCloseIsIdempotentAndAllowsGracefulDrain() async {
        let slot = TaskSlot()
        let gate = ManualGate()
        let recorder = ValueRecorder()

        await slot.replace { cancellation in
            await gate.wait()
            await recorder.append(cancellation.isCancelled ? "cancelled" : "finished")
        }
        await gate.waitUntilArrival()

        await slot.close()
        await slot.close()
        await gate.open()
        await slot.waitForIdle()

        let values = await recorder.values
        XCTAssertEqual(values, ["finished"])
        let accepted = await slot.replace { _ in }
        XCTAssertFalse(accepted)
    }

    func testClosedIdleSlotAllowsRepeatedCancelAndWaitCalls() async {
        let slot = TaskSlot()

        await slot.close()
        await slot.cancel()
        await slot.waitForIdle()
        await slot.cancelAndWaitForIdle()
        await slot.cancel()
        await slot.waitForIdle()

        let accepted = await slot.replace { _ in }
        XCTAssertFalse(accepted)
    }

    func testCancelAndWaitForIdleRejectsReplacementWhileSuspended() async {
        let slot = TaskSlot()
        let started = Event()
        let cancellationObserved = Event()
        let terminationGate = ManualGate()
        let recorder = ValueRecorder()

        await slot.replace { _ in
            await started.signal()
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                await cancellationObserved.signal()
                await terminationGate.wait()
            } catch {
                XCTFail("Unexpected sleep error: \(error)")
            }
        }
        await started.wait()

        let closingTask = Task {
            await slot.cancelAndWaitForIdle()
        }
        await cancellationObserved.wait()

        let accepted = await slot.replace { _ in
            await recorder.append("unexpected")
        }
        XCTAssertFalse(accepted)

        await terminationGate.open()
        await closingTask.value
        await slot.cancelAndWaitForIdle()

        let values = await recorder.values
        XCTAssertTrue(values.isEmpty)
        let acceptedAfterCompletion = await slot.replace { _ in }
        XCTAssertFalse(acceptedAfterCompletion)
    }

    func testWaitForIdleIncludesReplacementStartedWhileWaiting() async {
        let slot = TaskSlot()
        let firstGate = ManualGate()
        let secondGate = ManualGate()
        let waiterProbe = CompletionProbe()

        await slot.replace { _ in
            await firstGate.wait()
        }
        await firstGate.waitUntilArrival()

        let waiter = Task {
            await recordWhenSlotBecomesIdle(slot, probe: waiterProbe)
        }
        await waiterProbe.waitUntilStarted()

        await slot.replace { _ in
            await secondGate.wait()
        }
        await secondGate.waitUntilArrival()
        await firstGate.open()
        try? await Task.sleep(for: .milliseconds(10))
        let completedBeforeReplacement = await waiterProbe.isCompleted
        XCTAssertFalse(completedBeforeReplacement)

        await secondGate.open()
        await waiter.value
        let completedAfterReplacement = await waiterProbe.isCompleted
        XCTAssertTrue(completedAfterReplacement)
    }

    func testDeinitCancelsOwnedTask() async {
        let started = Event()
        let cancellationObserved = Event()
        var slot: TaskSlot? = TaskSlot()
        weak var weakSlot = slot
        defer { weakSlot = nil }

        await slot?.replace { _ in
            await started.signal()
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                await cancellationObserved.signal()
            } catch {
                XCTFail("Unexpected sleep error: \(error)")
            }
        }
        await started.wait()

        slot = nil
        await cancellationObserved.wait()

        XCTAssertNil(weakSlot)
    }

    #if !DEBUG
    func testOwnedOperationWaitExcludesItselfButWaitsForOtherOwnedTasks() async {
        let slot = TaskSlot()
        let supersededGate = ManualGate()
        let currentStarted = Event()
        let currentReturned = Event()

        await slot.replace { _ in
            await supersededGate.wait()
        }
        await supersededGate.waitUntilArrival()

        await slot.replace { _ in
            await currentStarted.signal()
            await slot.waitForIdle()
            await currentReturned.signal()
        }
        await currentStarted.wait()
        try? await Task.sleep(for: .milliseconds(10))
        let returnedBeforeOtherTaskFinished = await currentReturned.isSignaled
        XCTAssertFalse(returnedBeforeOtherTaskFinished)

        await supersededGate.open()
        await currentReturned.wait()
        await slot.waitForIdle()
    }

    func testStructuredChildInheritsSelfWaitProtection() async {
        let slot = TaskSlot()
        let returned = Event()

        await slot.replace { _ in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await slot.waitForIdle()
                }
            }
            await returned.signal()
        }

        await returned.wait()
        await slot.waitForIdle()
    }

    func testNestedUnstructuredTaskInheritsSelfWaitProtection() async {
        let slot = TaskSlot()
        let returned = Event()

        await slot.replace { _ in
            let inner = Task {
                await slot.waitForIdle()
            }
            await inner.value
            await returned.signal()
        }

        await returned.wait()
        await slot.waitForIdle()
    }
    #endif
}

private func recordWhenSlotBecomesIdle(_ slot: TaskSlot, probe: CompletionProbe) async {
    await probe.markStarted()
    await slot.waitForIdle()
    await probe.markCompleted()
}

private actor ManualGate {
    private var arrivals = 0
    private var isOpen = false
    private var arrivalContinuations: [CheckedContinuation<Void, Never>] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        arrivals += 1
        let waitingForArrival = arrivalContinuations
        arrivalContinuations.removeAll()
        for continuation in waitingForArrival {
            continuation.resume()
        }
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitUntilArrival() async {
        guard arrivals == 0 else {
            return
        }
        await withCheckedContinuation { continuation in
            arrivalContinuations.append(continuation)
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

private actor Event {
    private(set) var isSignaled = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func signal() {
        isSignaled = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }

    func wait() async {
        guard !isSignaled else {
            return
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}

private actor CompletionProbe {
    private var hasStarted = false
    private(set) var isCompleted = false
    private var startContinuations: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        hasStarted = true
        let waiting = startContinuations
        startContinuations.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }

    func waitUntilStarted() async {
        guard !hasStarted else {
            return
        }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func markCompleted() {
        isCompleted = true
    }
}
