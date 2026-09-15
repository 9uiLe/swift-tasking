import TaskingCore
import TaskingTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct CancellationContextTests {
    @Test func contextReadsExecutingTaskInsteadOfCapturingCreationState() async {
        let context = CancellationContext()
        #expect(!context.isCancelled)
        let gate = Gate()
        let task = Task {
            await gate.wait()
            #expect(context.isCancelled)
            #expect(throws: CancellationError.self) { try context.check() }
        }
        await gate.waitForArrivals()
        task.cancel()
        await gate.open()
        await task.value
        #expect(!context.isCancelled)
    }

    @Test func cancellationPropagatesThroughStructuredChildren() async {
        let slot = TaskSlot()
        let gate = Gate()
        await slot.replace { context in
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<2 {
                    group.addTask {
                        await gate.wait()
                        #expect(context.isCancelled)
                        #expect(throws: CancellationError.self) { try context.check() }
                    }
                }
            }
        }
        await gate.waitForArrivals(2)
        await slot.cancel()
        await gate.open()
        await slot.waitForIdle()
    }

    @Test func passingContextIntoUnstructuredTaskDoesNotConnectCancellation() async {
        let gate = Gate()
        let outer = Task {
            let context = CancellationContext()
            let inner = Task {
                await gate.wait()
                #expect(!context.isCancelled)
            }
            await inner.value
            #expect(context.isCancelled)
        }
        await gate.waitForArrivals()
        outer.cancel()
        await gate.open()
        await outer.value
    }
}
