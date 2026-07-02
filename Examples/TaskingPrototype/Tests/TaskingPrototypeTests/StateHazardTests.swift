import Testing
import Tasking
@testable import TaskingPrototype

/// F1/F2: ViewModel state と store の相互作用に潜む考慮漏れの検証。
@MainActor
@Suite struct StateHazardTests {
    /// F1: README の推奨パターン(CancellationError を素通しするだけ)では、
    /// キャンセル後に loading state が残留する。
    /// このテストは「危険な現状」をそのまま観測して文書化するもの。
    @Test func f1_readmePatternLeavesStaleLoadingStateAfterCancel() async throws {
        let gate = Signal()
        let store = ViewTaskStore()

        // README の SettingsViewModel と同じ形(キャンセル時に state を戻さない)
        @MainActor
        final class ReadmeStyleViewModel {
            var state = "idle"
            func save(gate: Signal, cancellation: CancellationContext) async throws {
                state = "saving"
                do {
                    await gate.wait()
                    try cancellation.check()
                    state = "saved"
                } catch let error as CancellationError {
                    throw error // README のとおり: state を戻さず rethrow
                } catch {
                    state = "failed"
                }
            }
        }

        let viewModel = ReadmeStyleViewModel()
        let outcome = store.start(id: "settings.save", lifetime: .screenBound) { cancellation in
            try await viewModel.save(gate: gate, cancellation: cancellation)
        }
        #expect(outcome.run != nil)
        try await waitUntil { viewModel.state == "saving" }

        // ユーザーが Cancel をタップ
        store.cancel(id: "settings.save")
        await gate.signal()
        try await waitUntil { !store.isRunning(id: "settings.save") }
        await Task.yield()

        // 画面は生きているのに state は "saving" のまま = スピナーが固まる
        #expect(viewModel.state == "saving")
    }

    /// F1 対策: プロトタイプの SettingsViewModel(キャンセル時に idle へ戻す)なら
    /// state が残留しない。
    @Test func f1_prototypePatternResetsStateOnCancel() async throws {
        let gate = Signal()
        let store = ViewTaskStore()
        let viewModel = SettingsViewModel(performSave: { await gate.wait() })

        store.start(id: SettingsAction.save, lifetime: .screenBound) { cancellation in
            try await viewModel.save(cancellation: cancellation)
        }
        try await waitUntil { viewModel.saveState == .saving }

        store.cancel(id: SettingsAction.save)
        await gate.signal()
        try await waitUntil { viewModel.saveState == .idle }
    }

    /// F2: `.cancelExisting` ではキャンセルされた旧 run の後始末が新 run の
    /// state を上書きしうる。素朴な defer リセット(世代ガードなし)だと、
    /// 検索中なのに isSearching=false になる。
    @Test func f2_naiveDeferClobbersNewRunsLoadingFlag() async throws {
        let firstGate = Signal()
        let secondGate = Signal()
        let store = ViewTaskStore()

        @MainActor
        final class NaiveSearchViewModel {
            var isSearching = false
            func search(gate: Signal, cancellation: CancellationContext) async throws {
                isSearching = true
                defer { isSearching = false } // 世代ガードなし
                await gate.wait()
                try cancellation.check()
            }
        }

        let viewModel = NaiveSearchViewModel()

        // run1 開始("sw" と入力)
        store.start(id: SearchAction.query, lifetime: .screenBound, policy: .cancelExisting) { c in
            try await viewModel.search(gate: firstGate, cancellation: c)
        }
        try await waitUntil { viewModel.isSearching }

        // run2 開始("swift" と入力)→ run1 はキャンセル要求を受けるが gate で滞留中
        store.start(id: SearchAction.query, lifetime: .screenBound, policy: .cancelExisting) { c in
            try await viewModel.search(gate: secondGate, cancellation: c)
        }
        try await waitUntil { store.runningCount(for: SearchAction.query) == 1 }

        // run1 が遅れて終了 → defer が発火し、run2 実行中なのにフラグが折れる
        await firstGate.signal()
        try await waitUntil { viewModel.isSearching == false }
        #expect(store.isRunning(id: SearchAction.query)) // 検索は実際にはまだ走っている

        await secondGate.signal()
        try await waitUntil { !store.isRunning(id: SearchAction.query) }
    }

    /// F2 対策: プロトタイプの SearchViewModel(世代ガードあり)では、
    /// 旧 run の後始末が新 run のフラグを折らない。
    @Test func f2_generationGuardKeepsNewRunsLoadingFlag() async throws {
        let firstGate = Signal()
        let secondGate = Signal()
        let store = ViewTaskStore()
        var gates = [firstGate, secondGate]
        let viewModel = SearchViewModel(performSearch: { term in
            let gate = gates.removeFirst()
            await gate.wait()
            return [term]
        })

        store.start(id: SearchAction.query, lifetime: .screenBound, policy: .cancelExisting) { c in
            try await viewModel.search(term: "sw", cancellation: c)
        }
        try await waitUntil { viewModel.isSearching }

        store.start(id: SearchAction.query, lifetime: .screenBound, policy: .cancelExisting) { c in
            try await viewModel.search(term: "swift", cancellation: c)
        }
        try await waitUntil { store.runningCount(for: SearchAction.query) == 1 }

        await firstGate.signal()
        // 旧 run の defer は世代ガードにより no-op。フラグは立ったまま。
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(viewModel.isSearching)

        await secondGate.signal()
        try await waitUntil { viewModel.isSearching == false }
        #expect(viewModel.results == ["swift"])
    }
}
