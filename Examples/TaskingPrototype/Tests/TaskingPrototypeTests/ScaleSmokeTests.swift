import Testing
import Tasking
@testable import TaskingPrototype

/// 大規模アプリ想定のスケール検証(スモーク)。
/// 数値は絶対性能の保証ではなく、オーダーの逸脱(秒単位の遅延など)の検出が目的。
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ScaleSmokeTests {
    /// 1 万 run を追跡させた状態での一括操作のオーダー確認。
    /// cancel(lifetime:) は全追跡 task の線形走査、cancelAll は全消し。
    @Test func tenThousandTrackedRunsBulkOperations() async throws {
        let store = ViewTaskStore()
        let clock = ContinuousClock()
        let gate = OperationGate()
        var completed = 0

        let startDuration = clock.measure {
            for index in 0..<10_000 {
                store.start(
                    id: ActionID("scale.\(index % 100)"),
                    lifetime: index % 2 == 0 ? .screenBound : "featureScope",
                    policy: .allowConcurrent
                ) { _ in
                    await gate.wait()
                    completed += 1
                }
            }
        }
        #expect(store.runningCount(lifetime: .screenBound) == 5_000)

        let queryDuration = clock.measure {
            _ = store.runningCount(lifetime: "featureScope")
            _ = store.isRunning(id: "scale.42")
        }

        let cancelLifetimeDuration = clock.measure {
            store.cancel(lifetime: "featureScope") // 5,000 件の選別+除去
        }
        #expect(store.runningCount(lifetime: "featureScope") == 0)

        let cancelAllDuration = clock.measure {
            store.cancelAll() // 残り 5,000 件
        }
        #expect(!store.isRunning(lifetime: .screenBound))
        gate.open()
        await store.waitForIdle()
        #expect(completed == 10_000)

        print("""
        [scale] start x10k: \(startDuration)
        [scale] lifetime query on 10k: \(queryDuration)
        [scale] cancel(lifetime:) 5k of 10k: \(cancelLifetimeDuration)
        [scale] cancelAll 5k: \(cancelAllDuration)
        """)

        // 時間は診断にだけ使う。Sanitizer や CI の負荷下での所要時間を性能の契約にしない。
    }
}
