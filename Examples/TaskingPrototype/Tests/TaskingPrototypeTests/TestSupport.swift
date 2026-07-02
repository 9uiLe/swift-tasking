import Foundation

/// テストから operation の進行を制御するための一回性シグナル。
/// `wait()` はキャンセルに反応しない(checked continuation)ため、
/// 「キャンセルを無視して走り続ける処理」の再現にも使える。
actor Signal {
    private var pendingSignals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        if waiters.isEmpty {
            pendingSignals += 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    func wait() async {
        if pendingSignals > 0 {
            pendingSignals -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

struct TimeoutError: Error {}

/// MainActor 上の条件が真になるまで yield しながら待つ。
@MainActor
func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        if clock.now > deadline {
            throw TimeoutError()
        }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
}

/// MainActor 上でイベント列を記録する。テストの観測点。
@MainActor
final class Recorder {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func count(of event: String) -> Int {
        events.filter { $0 == event }.count
    }
}
