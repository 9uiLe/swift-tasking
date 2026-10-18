import Testing
import Tasking
@testable import TaskingPrototype

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ScaleSmokeTests {
    @Test func tenThousandRunsRemainOwnedUntilActualCompletion() async {
        let store = ViewTaskStore()
        let gate = OperationGate()
        var completed = 0

        for index in 0..<10_000 {
            store.start(
                id: ActionID("scale.\(index % 100)"),
                group: index % 2 == 0 ? "screen" : "feature",
                policy: .allowConcurrent
            ) {
                await gate.wait()
                completed += 1
            }
        }
        #expect(store.trackedCount(group: "screen") == 5_000)
        #expect(store.trackedCount(group: "feature") == 5_000)
        #expect(store.isTracked(id: "scale.42"))

        store.cancel(group: "feature")
        #expect(store.trackedCount(group: "feature") == 0)
        #expect(store.trackedCount(group: "screen") == 5_000)
        #expect(store.unfinishedCount == 10_000)

        store.cancelAll()
        #expect(!store.isTracked(group: "screen"))
        #expect(store.unfinishedCount == 10_000)
        gate.open()
        await store.waitForIdle()
        #expect(completed == 10_000)
        #expect(store.unfinishedCount == 0)
    }
}
