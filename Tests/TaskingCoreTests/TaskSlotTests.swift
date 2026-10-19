import TaskingCore
import TaskingTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TaskSlotTests {
    @Test func immediateWorkFinishesBeforeIdleReturns() async {
        let slot = TaskSlot()
        let values = Values()
        #expect(await slot.replace { await values.append("finished") })
        await slot.waitForIdle()
        #expect(await values.items == ["finished"])
    }

    @Test func replacementCancelsOnlyOldWork() async {
        let slot = TaskSlot()
        let old = Gate()
        let latest = Gate()
        let values = Values()
        await slot.replace {
            await old.wait()
            #expect(Task.isCancelled)
            await values.append("old")
        }
        await old.waitForArrivals()
        await slot.replace {
            await latest.wait()
            #expect(!Task.isCancelled)
            await values.append("latest")
        }
        await latest.waitForArrivals()
        await old.open()
        await latest.open()
        await slot.waitForIdle()
        #expect(await Set(values.items) == ["old", "latest"])
    }

    @Test func completionOfSupersededWorkDoesNotLoseActiveCancellation() async {
        let slot = TaskSlot()
        let old = Gate()
        let latest = Gate()
        let oldFinished = Gate()
        await slot.replace {
            await old.wait()
            await oldFinished.open()
        }
        await old.waitForArrivals()
        await slot.replace {
            await latest.wait()
            #expect(Task.isCancelled)
        }
        await latest.waitForArrivals()
        await old.open()
        await oldFinished.wait()
        await slot.cancel()
        await latest.open()
        await slot.waitForIdle()
    }

    @Test func cancelKeepsAdmissionOpen() async {
        let slot = TaskSlot()
        let gate = Gate()
        await slot.replace {
            await gate.wait()
            #expect(Task.isCancelled)
        }
        await gate.waitForArrivals()
        await slot.cancel()
        let accepted = await slot.replace { #expect(!Task.isCancelled) }
        #expect(accepted)
        await gate.open()
        await slot.waitForIdle()
    }

    @Test func closeIsTerminalIdempotentAndDoesNotCancelWork() async {
        let slot = TaskSlot()
        let gate = Gate()
        await slot.replace {
            await gate.wait()
            #expect(!Task.isCancelled)
        }
        await gate.waitForArrivals()
        await slot.close()
        await slot.close()
        #expect(await !slot.replace { Issue.record("受付の閉鎖後に処理が実行されました。") })
        await gate.open()
        await slot.waitForIdle()
        await slot.cancelAndWaitForIdle()
        #expect(await !slot.replace { Issue.record("受付の閉鎖後に処理が実行されました。") })
    }

    @Test func teardownClosesAdmissionBeforeCancellationIsObserved() async {
        let slot = TaskSlot()
        let cancelled = Gate()
        let release = Gate()
        let stream = AsyncStream<Void>.makeStream()
        await slot.replace {
            await withTaskCancellationHandler {
                for await _ in stream.stream {}
                await cancelled.open()
                await release.wait()
            } onCancel: {
                stream.continuation.finish()
            }
        }
        let teardown = Task { await slot.cancelAndWaitForIdle() }
        await cancelled.wait()
        #expect(await !slot.replace { Issue.record("終了処理中に新しい処理を受け付けました。") })
        await release.open()
        await teardown.value
        await slot.cancelAndWaitForIdle()
    }

    @Test func idleWaitIncludesCancelledAndNewlyAdmittedWork() async {
        await verifyIdleWait(on: TaskSlot())
    }

    private func verifyIdleWait(on slot: isolated TaskSlot) async {
        let old = Gate()
        let latest = Gate()
        let started = AsyncStream<Void>.makeStream()
        var completed = false
        slot.replace { await old.wait() }
        await old.waitForArrivals()
        slot.cancel()
        let waiter = Task {
            started.continuation.yield(())
            await slot.waitForIdle()
            completed = true
        }
        var iterator = started.stream.makeAsyncIterator()
        await iterator.next()
        #expect(!completed)
        slot.replace { await latest.wait() }
        await latest.waitForArrivals()
        await old.open()
        #expect(!completed)
        await latest.open()
        await waiter.value
        #expect(completed)
    }

    @Test func deinitCancelsOwnedWork() async {
        let gate = Gate()
        let finished = Gate()
        var slot: TaskSlot? = TaskSlot()
        weak var weakSlot = slot
        defer { weakSlot = nil }
        await slot?.replace {
            await gate.wait()
            #expect(Task.isCancelled)
            await finished.open()
        }
        await gate.waitForArrivals()
        slot = nil
        #expect(weakSlot == nil)
        await gate.open()
        await finished.wait()
    }

    #if !DEBUG
    @Test func selfWaitExcludesCurrentStructuredContext() async {
        let slot = TaskSlot()
        await slot.replace {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await slot.waitForIdle() }
            }
        }
        await slot.waitForIdle()
    }

    @Test func selfWaitStillWaitsForSupersededWork() async {
        let slot = TaskSlot()
        let old = Gate()
        let started = Gate()
        let values = Values()
        await slot.replace {
            await old.wait()
            await values.append("old")
        }
        await old.waitForArrivals()
        await slot.replace {
            await started.open()
            await slot.waitForIdle()
            #expect(await values.items == ["old"])
        }
        await started.wait()
        await old.open()
        await slot.waitForIdle()
    }
    #endif
}

private actor Values {
    private(set) var items: [String] = []
    func append(_ value: String) { items.append(value) }
}
