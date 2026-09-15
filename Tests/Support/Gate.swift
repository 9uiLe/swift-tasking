/// A one-shot gate that deliberately ignores cancellation and records arrivals.
public actor Gate {
    private var isOpen = false
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    public init() {}

    public func wait() async {
        arrivals += 1
        let ready = arrivalWaiters.filter { $0.0 <= arrivals }
        arrivalWaiters.removeAll { $0.0 <= arrivals }
        for (_, waiter) in ready { waiter.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func waitForArrivals(_ count: Int = 1) async {
        guard arrivals < count else { return }
        await withCheckedContinuation { arrivalWaiters.append((count, $0)) }
    }

    public func open() {
        isOpen = true
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }
}

/// Synchronous signalling on the main actor lets tests observe the next suspension
/// of another main-actor task without assuming a scheduler delay.
@MainActor
public final class Checkpoint {
    public private(set) var isReached = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func reach() {
        isReached = true
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }

    public func wait() async {
        guard !isReached else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
