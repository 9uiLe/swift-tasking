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
        let sizes = option("--sizes", default: "1,8,32,128,1000,10000").split(separator: ",").map { Int($0)! }
        let samples = Int(option("--samples", default: "7"))!
        let queries = Int(option("--queries", default: "1000"))!
        let selected = option("--scenario", default: "all")
        let order = option("--order", default: "tasking-first")
        precondition(samples > 0 && queries > 0 && sizes.allSatisfy { $0 > 0 })
        precondition(["all", "store", "runner", "slot", "ownership"].contains(selected))
        precondition(["tasking-first", "native-first"].contains(order))
        for size in sizes {
            for sample in -1..<samples {
                let variants = (sample.isMultiple(of: 2) != (order == "native-first")) ? [true, false] : [false, true]
                if selected == "all" || selected == "store" {
                    for actions in Set([1, min(size, 100), size]).sorted() {
                        await store(size: size, actionCount: actions, queries: queries, sample: sample)
                    }
                }
                for useTasking in variants {
                    if selected == "all" || selected == "runner" {
                        await runner(size: size, sample: sample, useTasking: useTasking)
                    }
                    if selected == "all" || selected == "slot" {
                        await slot(size: size, sample: sample, useTasking: useTasking)
                    }
                    if selected == "all" || selected == "ownership" {
                        await ownership(size: size, sample: sample, useTasking: useTasking)
                    }
                }
            }
        }
    }

    @MainActor
    private static func store(size: Int, actionCount: Int, queries: Int, sample: Int) async {
        let store = ViewTaskStore()
        let ids = (0..<actionCount).map { ActionID("action.\($0)") }
        let scenario = "store.\(actionCount)-actions"
        let gate = MainActorGate(expected: size)
        let group: CancellationGroup = "batch"
        var completed = 0
        var started = ContinuousClock.now
        for index in 0..<size {
            store.start(id: ids[index % actionCount], group: group, policy: .allowConcurrent) {
                await gate.wait()
                completed += 1
            }
        }
        emit(scenario, "start", size, sample, size, since: started)
        started = .now
        var hits = 0
        for _ in 0..<queries { hits += store.isTracked(group: group) ? 1 : 0 }
        precondition(hits == queries)
        emit(scenario, "group-hit", size, sample, queries, since: started)
        started = .now
        var misses = 0
        for _ in 0..<queries { misses += store.isTracked(group: "absent") ? 0 : 1 }
        precondition(misses == queries)
        emit(scenario, "group-miss", size, sample, queries, since: started)
        started = .now
        var count = 0
        for _ in 0..<queries { count += store.trackedCount(group: group) }
        precondition(count == size * queries)
        emit(scenario, "group-count", size, sample, queries, since: started)
        started = .now
        for _ in 0..<queries {
            precondition(store.start(id: ids[0]) { preconditionFailure("拒否した処理が実行されました") } == .skipped(.unfinished))
        }
        emit(scenario, "ignore-new", size, sample, queries, since: started)
        started = .now
        store.cancel(group: group)
        emit(scenario, "cancel-group", size, sample, size, since: started)
        precondition(!store.isTracked(group: group) && store.unfinishedCount == size)
        started = .now
        gate.open()
        await store.cancelAndWaitForIdle()
        precondition(completed == size && store.unfinishedCount == 0)
        emit(scenario, "drain", size, sample, size, since: started)
    }

    @MainActor
    private static func runner(size: Int, sample: Int, useTasking: Bool) async {
        let runner = ActionRunner()
        let native = NativeActionGate()
        let expected = (0..<size).reduce(0) { $0 + payload($1) }
        let started = ContinuousClock.now
        var sum = 0
        for index in 0..<size {
            let value: Int?
            if useTasking {
                value = await runner.run(id: "run") { payload(index) }
            } else {
                value = await native.run { payload(index) }
            }
            sum += value!
        }
        precondition(sum == expected)
        emit(useTasking ? "runner" : "native.async-gate", "run", size, sample, size, since: started)
    }

    @inline(never)
    private static func payload(_ value: Int) -> Int { value & 255 }

    private static func slot(size: Int, sample: Int, useTasking: Bool) async {
        let slot = TaskSlot()
        let native = NativeTaskSlot()
        let gate = BackgroundGate()
        var started = ContinuousClock.now
        for _ in 0..<size {
            if useTasking {
                await slot.replace { await gate.wait() }
            } else {
                await native.replace { await gate.wait() }
            }
        }
        let scenario = useTasking ? "slot" : "native.slot"
        emit(scenario, "replace", size, sample, size, since: started)
        started = .now
        await gate.open()
        if useTasking {
            await slot.cancelAndWaitForIdle()
        } else {
            await native.cancelAndWaitForIdle()
        }
        emit(scenario, "drain", size, sample, size, since: started)
        let arrivals = await gate.arrivalCount
        precondition(arrivals == size)
    }

    @MainActor
    private static func ownership(size: Int, sample: Int, useTasking: Bool) async {
        let store = ViewTaskStore()
        let native = NativeTaskOwner()
        let gate = MainActorGate(expected: size)
        let scenario = useTasking ? "ownership.store" : "ownership.native"
        var startLatencies: [Double] = []
        var cancellationLatencies: [Double] = []
        var cancellationStarted = ContinuousClock.now
        let batchStarted = ContinuousClock.now
        let probe = Task { @MainActor in milliseconds(batchStarted.duration(to: .now)) }
        for _ in 0..<size {
            let admitted = ContinuousClock.now
            let operation: @MainActor @Sendable () async -> Void = {
                startLatencies.append(milliseconds(admitted.duration(to: .now)))
                await gate.wait()
                precondition(Task.isCancelled)
                cancellationLatencies.append(milliseconds(cancellationStarted.duration(to: .now)))
            }
            if useTasking {
                store.start(id: "batch", policy: .allowConcurrent, operation: operation)
            } else {
                native.start(operation: operation)
            }
        }
        let admissionElapsed = milliseconds(batchStarted.duration(to: .now))
        let probeDelay = await probe.value
        await gate.waitForArrivals()
        let unfinished = useTasking ? store.unfinishedCount : native.unfinishedCount
        precondition(unfinished == size)
        cancellationStarted = .now
        if useTasking { store.cancelAll() } else { native.cancelAll() }
        precondition((useTasking ? store.unfinishedCount : native.unfinishedCount) == size)
        gate.open()
        if useTasking { await store.cancelAndWaitForIdle() } else { await native.cancelAndWaitForIdle() }
        let cancellationElapsed = milliseconds(cancellationStarted.duration(to: .now))
        emit(scenario, "uninterrupted-admission", size, sample, size, value: admissionElapsed, unit: "ms")
        emit(scenario, "main-actor-probe-delay", size, sample, 1, value: probeDelay, unit: "ms")
        emit(scenario, "unfinished-after-cancel", size, sample, size, value: Double(unfinished), unit: "count")
        emit(scenario, "cancel-to-idle", size, sample, size, value: cancellationElapsed, unit: "ms")
        precondition(startLatencies.count == size && cancellationLatencies.count == size)
        precondition((useTasking ? store.unfinishedCount : native.unfinishedCount) == 0)
        for (metric, values) in [("admission-to-start", startLatencies), ("cancel-to-body-end", cancellationLatencies)] {
            let sorted = values.sorted()
            for (label, percentile) in [("p50", 0.5), ("p95", 0.95), ("p99", 0.99)] {
                emit(scenario, "\(metric).\(label)", size, sample, size,
                     value: sorted[Int((Double(sorted.count - 1) * percentile).rounded(.up))], unit: "ms")
            }
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }

    private static func emit(
        _ scenario: String, _ metric: String, _ size: Int, _ sample: Int, _ operations: Int,
        since start: ContinuousClock.Instant
    ) {
        emit(scenario, metric, size, sample, operations, value: milliseconds(start.duration(to: .now)), unit: "ms")
    }

    private static func emit(
        _ scenario: String, _ metric: String, _ size: Int, _ sample: Int, _ operations: Int,
        value: Double, unit: String
    ) {
        guard sample >= 0 else { return }
        let row: [String: Any] = ["scenario": scenario, "metric": metric, "size": size,
                                 "sample": sample, "operations": operations, "unit": unit, "value": value]
        let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}

@MainActor
private final class MainActorGate {
    private let expected: Int
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    init(expected: Int) { self.expected = expected }
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            if waiters.count == expected {
                let ready = arrivals
                arrivals.removeAll()
                for waiter in ready { waiter.resume() }
            }
        }
    }
    func waitForArrivals() async {
        guard waiters.count < expected else { return }
        await withCheckedContinuation { arrivals.append($0) }
    }
    func open() {
        isOpen = true
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }
}

private actor BackgroundGate {
    private(set) var arrivalCount = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        arrivalCount += 1
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

@MainActor
private final class NativeActionGate {
    private var isRunning = false
    @inline(never)
    func run<Success>(operation: @MainActor () async throws -> Success) async rethrows -> Success? {
        guard !isRunning else { return nil }
        isRunning = true
        defer { isRunning = false }
        return try await operation()
    }
}

// 対照は、この負荷で使う受付・キャンセル・実終了までの所有だけを実装する。
// Tasking のグループ選択、複数 ActionID、自己待機検出は比較の契約に含めない。
@MainActor
private final class NativeTaskOwner {
    private var handles: [Int: Task<Void, Never>] = [:]
    private var nextID = 0
    private var isClosed = false
    var unfinishedCount: Int { handles.count }
    deinit { for handle in handles.values { handle.cancel() } }
    func start(operation: @escaping @MainActor @Sendable () async -> Void) {
        precondition(!isClosed)
        let id = nextID
        nextID += 1
        handles[id] = Task { @MainActor [weak self] in
            await operation()
            self?.handles[id] = nil
        }
    }
    func cancelAll() { for handle in handles.values { handle.cancel() } }
    func cancelAndWaitForIdle() async {
        isClosed = true
        cancelAll()
        while let handle = handles.first?.value { await handle.value }
    }
}

private actor NativeTaskSlot {
    private var handles: [Int: Task<Void, Never>] = [:]
    private var nextID = 0
    private var active: Int?
    private var isClosed = false
    deinit { for handle in handles.values { handle.cancel() } }
    func replace(operation: @escaping @Sendable () async -> Void) {
        precondition(!isClosed)
        if let active { handles[active]?.cancel() }
        let id = nextID
        nextID += 1
        handles[id] = Task { [weak self] in
            await operation()
            await self?.finish(id)
        }
        active = id
    }
    private func finish(_ id: Int) {
        handles[id] = nil
        if active == id { active = nil }
    }
    func cancelAndWaitForIdle() async {
        isClosed = true
        if let active { handles[active]?.cancel() }
        active = nil
        while let handle = handles.first?.value { await handle.value }
    }
}
