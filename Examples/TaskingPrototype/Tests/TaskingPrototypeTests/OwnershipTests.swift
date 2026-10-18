import Tasking
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct OwnershipTests {
    @Test func repeatedReplacementFinishesAllWorkAndReleasesOperationCaptures() async throws {
        let store = ViewTaskStore()
        let gate = OperationGate()
        var payload: Payload? = Payload()
        weak var weakPayload = payload
        defer { weakPayload = nil }
        var survivors = 0
        var completed = 0
        for _ in 0..<100 {
            store.start(id: "replace", policy: .cancelExisting) { [payload] in
                await gate.wait()
                #expect(payload != nil)
                if !Task.isCancelled { survivors += 1 }
                completed += 1
            }
            #expect(store.trackedCount(for: "replace") == 1)
        }
        payload = nil
        #expect(weakPayload != nil)
        gate.open()
        await store.waitForIdle()
        #expect(completed == 100)
        #expect(survivors == 1)
        #expect(weakPayload == nil)
        #expect(!store.isTracked(id: "replace"))
        #expect(store.unfinishedCount == 0)
    }

    @Test func cancellingFromInsideOperationKeepsTrackingConsistent() async {
        let store = ViewTaskStore()
        store.start(id: "self") {
            store.cancel(id: "self")
            #expect(!store.isTracked(id: "self"))
            #expect(Task.isCancelled)
        }
        await store.waitForIdle()
        #expect(store.trackedCount(for: "self") == 0)
    }

    @Test func finalStoreReferenceCanBeReleasedOffMainActorDuringCompletion() async {
        for _ in 0..<100 {
            var store: ViewTaskStore? = ViewTaskStore()
            weak var weakStore = store
            defer { weakStore = nil }
            let gate = OperationGate()
            for _ in 0..<4 {
                store?.start(id: "work", policy: .allowConcurrent) {
                    await gate.wait()
                }
            }
            await gate.waitForArrivals(4)
            let owner = StoreOwner(store: store)
            store = nil
            gate.open()
            await owner.release()
            #expect(weakStore == nil)
        }
    }
}

private final class Payload: Sendable {}

private actor StoreOwner {
    private var store: ViewTaskStore?
    init(store: ViewTaskStore?) { self.store = store }
    func release() { store = nil }
}
