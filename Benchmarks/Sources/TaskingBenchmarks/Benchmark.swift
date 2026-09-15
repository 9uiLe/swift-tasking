import Foundation
import Tasking
import TaskingCore

@main
struct Benchmark {
    @MainActor
    static func main() async {
        let arguments = CommandLine.arguments
        func option(_ name: String, default fallback: String) -> String {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
                return fallback
            }
            return arguments[index + 1]
        }
        let sizes = option("--sizes", default: "100,1000,10000").split(separator: ",").map { Int($0)! }
        let samples = Int(option("--samples", default: "7"))!
        let queries = Int(option("--queries", default: "1000"))!
        let selected = option("--scenario", default: "all")
        precondition(samples > 0 && queries > 0 && sizes.allSatisfy { $0 > 0 })
        for size in sizes {
            for sample in -1..<samples {
                if selected == "all" || selected == "store" {
                    for actions in Set([1, min(size, 100), size]).sorted() {
                        await store(size: size, actionCount: actions, queries: queries, sample: sample)
                    }
                }
                if selected == "all" || selected == "runner" {
                    await runner(size: size, sample: sample)
                }
                if selected == "all" || selected == "slot" {
                    await slot(size: size, sample: sample)
                }
            }
        }
    }

    @MainActor
    private static func store(size: Int, actionCount: Int, queries: Int, sample: Int) async {
        let store = ViewTaskStore()
        let ids = (0..<actionCount).map { ActionID("action.\($0)") }
        let scenario = "store.\(actionCount)-actions"
        let gate = MainActorGate()
        let clock = ContinuousClock()
        var completed = 0
        var started = clock.now
        for index in 0..<size {
            store.start(id: ids[index % actionCount], lifetime: .screenBound, policy: .allowConcurrent) { _ in
                await gate.wait()
                completed += 1
            }
        }
        emit(scenario, "start", size, sample, size, since: started)

        started = clock.now
        var hits = 0
        for _ in 0..<queries { hits += store.isRunning(lifetime: .screenBound) ? 1 : 0 }
        precondition(hits == queries)
        emit(scenario, "lifetime-hit", size, sample, queries, since: started)

        started = clock.now
        var misses = 0
        for _ in 0..<queries { misses += store.isRunning(lifetime: .appBound) ? 0 : 1 }
        precondition(misses == queries)
        emit(scenario, "lifetime-miss", size, sample, queries, since: started)

        started = clock.now
        var count = 0
        for _ in 0..<queries { count += store.runningCount(lifetime: .screenBound) }
        precondition(count == size * queries)
        emit(scenario, "lifetime-count", size, sample, queries, since: started)

        started = clock.now
        var duplicates = 0
        for _ in 0..<queries {
            let outcome = store.start(id: ids[0], lifetime: .screenBound, operation: { _ in
                preconditionFailure("重複した処理が実行されました")
            })
            if outcome.run == nil { duplicates += 1 }
        }
        precondition(duplicates == queries)
        emit(scenario, "ignore-new", size, sample, queries, since: started)

        started = clock.now
        store.cancel(lifetime: .screenBound)
        emit(scenario, "cancel-lifetime", size, sample, size, since: started)
        precondition(!store.isRunning(lifetime: .screenBound))

        started = clock.now
        gate.open()
        await store.waitForIdle()
        precondition(completed == size)
        emit(scenario, "drain", size, sample, size, since: started)

        started = clock.now
        for _ in 0..<queries { await store.waitForIdle() }
        emit(scenario, "idle-after-burst", size, sample, queries, since: started)
    }

    @MainActor
    private static func runner(size: Int, sample: Int) async {
        let runner = ActionRunner()
        let descriptor = ActionDescriptor(id: "run")
        let started = ContinuousClock.now
        var sum = 0
        for _ in 0..<size {
            if case let .succeeded(value) = await runner.run(descriptor, operation: { _ in 1 }) {
                sum += value
            }
        }
        precondition(sum == size)
        emit("runner", "run", size, sample, size, since: started)
    }

    private static func slot(size: Int, sample: Int) async {
        let slot = TaskSlot()
        let gate = BackgroundGate()
        var started = ContinuousClock.now
        for _ in 0..<size {
            await slot.replace { _ in await gate.wait() }
        }
        emit("slot", "replace", size, sample, size, since: started)
        started = ContinuousClock.now
        await slot.cancel()
        await gate.open()
        await slot.waitForIdle()
        emit("slot", "drain", size, sample, size, since: started)
    }

    private static func emit(
        _ scenario: String, _ metric: String, _ size: Int, _ sample: Int, _ operations: Int,
        since start: ContinuousClock.Instant
    ) {
        let elapsed = start.duration(to: .now).components
        guard sample >= 0 else { return }
        let row: [String: Any] = [
            "scenario": scenario, "metric": metric, "size": size, "sample": sample,
            "operations": operations,
            "milliseconds": Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        ]
        let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}

@MainActor
private final class MainActorGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }
}

private actor BackgroundGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }
}
