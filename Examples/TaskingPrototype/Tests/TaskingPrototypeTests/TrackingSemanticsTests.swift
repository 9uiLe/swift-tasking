import Testing
import Tasking
@testable import TaskingPrototype

/// F4/F5: 「追跡中(tracked)」と「実行中(executing)」のズレの検証。
/// store のキャンセルは追跡を即座に解除するが、協調しない処理は走り続ける。
@MainActor
@Suite struct TrackingSemanticsTests {
    /// F4: cancel 直後の `.ignoreNew` は重複を防がない。
    /// キャンセルで追跡が消えるため、ゾンビ(キャンセルを無視して走行中の旧処理)と
    /// 新 run が同時実行になる。
    @Test func f4_ignoreNewDoesNotGuardAgainstZombieRuns() async throws {
        let zombieGate = Signal()
        let newGate = Signal()
        let store = ViewTaskStore()
        let recorder = Recorder()

        // キャンセルに協調しない処理(check() を呼ばない)
        store.start(id: "sync", lifetime: .screenBound, policy: .ignoreNew) { _ in
            recorder.record("begin")
            await zombieGate.wait() // キャンセルされても待ち続ける
            recorder.record("end")
        }
        try await waitUntil { recorder.count(of: "begin") == 1 }

        store.cancel(id: "sync")
        #expect(!store.isRunning(id: "sync")) // 追跡上は「実行なし」

        // だが実際には旧処理はまだ走っている。ここで ignoreNew で再開始すると…
        let outcome = store.start(id: "sync", lifetime: .screenBound, policy: .ignoreNew) { _ in
            recorder.record("begin")
            await newGate.wait()
            recorder.record("end")
        }
        #expect(outcome.run != nil) // 開始できてしまう

        try await waitUntil { recorder.count(of: "begin") == 2 }
        // 「実行中は 1 つ」の意図に反し、2 つの処理が同時に走っている
        #expect(recorder.count(of: "begin") - recorder.count(of: "end") == 2)

        await zombieGate.signal()
        await newGate.signal()
        try await waitUntil { recorder.count(of: "end") == 2 }
    }

    /// `.cancelExisting` の README 注意書きどおり、協調しない旧処理は
    /// 追跡解除後も継続する(runningCount は新 run の 1 のみ)。
    @Test func cancelExistingLeavesUncooperativeWorkRunning() async throws {
        let oldGate = Signal()
        let newGate = Signal()
        let store = ViewTaskStore()
        let recorder = Recorder()

        store.start(id: "refresh", lifetime: .screenBound) { _ in
            recorder.record("old-begin")
            await oldGate.wait()
            recorder.record("old-end")
        }
        try await waitUntil { recorder.count(of: "old-begin") == 1 }

        store.start(id: "refresh", lifetime: .screenBound, policy: .cancelExisting) { _ in
            recorder.record("new-begin")
            await newGate.wait()
        }
        try await waitUntil { recorder.count(of: "new-begin") == 1 }

        #expect(store.runningCount(for: "refresh") == 1)
        #expect(recorder.count(of: "old-end") == 0) // 旧処理はまだ生きている

        await oldGate.signal()
        await newGate.signal()
        try await waitUntil { !store.isRunning(id: "refresh") }
    }

    /// 大量 start/finish 後に内部追跡が空に戻ること(ブックキーピングのリーク検査)。
    @Test func massConcurrentRunsLeaveNoBookkeeping() async throws {
        let store = ViewTaskStore()
        let recorder = Recorder()

        for index in 0..<100 {
            store.start(id: "bulk", lifetime: .screenBound, policy: .allowConcurrent) { _ in
                recorder.record("done-\(index % 2)")
            }
        }
        #expect(store.runningCount(for: "bulk") == 100)

        try await waitUntil { store.runningCount(for: "bulk") == 0 }
        #expect(!store.isRunning(lifetime: .screenBound))
        #expect(recorder.count(of: "done-0") + recorder.count(of: "done-1") == 100)
    }

    /// store の解放(deinit)が安全網として全 task をキャンセルすること。
    @Test func deinitCancelsOwnedTasks() async throws {
        let recorder = Recorder()
        var store: ViewTaskStore? = ViewTaskStore()

        store?.start(id: "orphaned", lifetime: .screenBound) { _ in
            do {
                try await Task.sleep(for: .seconds(30)) // キャンセルに反応する suspension
                recorder.record("finished")
            } catch is CancellationError {
                recorder.record("cancelled")
                throw CancellationError()
            }
        }
        try await waitUntil { store?.isRunning(id: "orphaned") == true }

        store = nil // 画面破棄に相当
        try await waitUntil { recorder.count(of: "cancelled") == 1 }
        #expect(recorder.count(of: "finished") == 0)
    }

    /// operation 内から同じ store に再入的に start しても破綻しないこと。
    @Test func reentrantStartFromInsideOperation() async throws {
        let store = ViewTaskStore()
        let recorder = Recorder()

        store.start(id: "outer", lifetime: .screenBound) { _ in
            recorder.record("outer")
            store.start(id: "inner", lifetime: .screenBound) { _ in
                recorder.record("inner")
            }
        }

        try await waitUntil { recorder.count(of: "inner") == 1 }
        try await waitUntil { !store.isRunning(id: "outer") && !store.isRunning(id: "inner") }
    }

    /// F6: 共有 store で複数画面が同じ lifetime タグを使うと、
    /// cancel(lifetime:) が他画面の task を巻き込む(docs/lifetimes.md の
    /// アンチパターンを実証)。
    @Test func f6_sharedStoreLifetimeCollisionCancelsAcrossScreens() async throws {
        let sharedStore = ViewTaskStore() // 2 画面が共有してしまった store
        let gateA = Signal()
        let gateB = Signal()
        let recorder = Recorder()

        // 画面 A の task
        sharedStore.start(id: "screenA.load", lifetime: .screenBound) { _ in
            do {
                await gateA.wait()
                try Task.checkCancellation()
                recorder.record("A-finished")
            } catch { recorder.record("A-cancelled") }
        }
        // 画面 B の task
        sharedStore.start(id: "screenB.load", lifetime: .screenBound) { _ in
            do {
                await gateB.wait()
                try Task.checkCancellation()
                recorder.record("B-finished")
            } catch { recorder.record("B-cancelled") }
        }

        // 画面 A だけが閉じたつもりの onDisappear
        sharedStore.cancel(lifetime: .screenBound)

        await gateA.signal()
        await gateB.signal()
        try await waitUntil { recorder.events.count == 2 }

        // B は生きている画面なのに巻き込まれてキャンセルされる
        #expect(recorder.count(of: "B-cancelled") == 1)
    }
}
