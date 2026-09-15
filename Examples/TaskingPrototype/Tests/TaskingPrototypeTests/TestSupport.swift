/// A one-shot operation gate. Cancellation deliberately does not open it.
@MainActor
final class OperationGate {
    private var isOpen = false
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func wait() async {
        arrivals += 1
        let ready = arrivalWaiters.filter { $0.0 <= arrivals }
        arrivalWaiters.removeAll { $0.0 <= arrivals }
        for (_, waiter) in ready { waiter.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitForArrivals(_ count: Int = 1) async {
        guard arrivals < count else { return }
        await withCheckedContinuation { arrivalWaiters.append((count, $0)) }
    }

    func open() {
        isOpen = true
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }
}

enum ServiceError: Error { case offline }
