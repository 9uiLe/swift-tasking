import TaskingCore

/// Owns unstructured tasks started from synchronous UI callbacks on the main actor.
///
/// Lifetime labels and duplicate policies apply to tracked runs. Cancellation removes
/// tracking immediately, but the store owns the task handle until actual termination.
/// Running queries are synchronous snapshots, not observable UI state; loading and results
/// belong to the ViewModel. Operations must not strongly capture the store or its owner.
@MainActor
public final class ViewTaskStore {
    private var runs = ActionRuns<ActionLifetime>()
    private var tasks = OwnedTasks<ActionRun>()
    private var isClosed = false
    private let onUnhandledError: (@MainActor (ActionRun, ActionFailure) -> Void)?

    /// Creates a store with an optional observer for operation contract violations.
    ///
    /// Business errors should be converted into ViewModel state before escaping the
    /// operation. The observer runs before completion removes tracking; a previously
    /// cancelled run is already untracked. Without an observer, escaped errors trigger a
    /// debug assertion. Errors after deallocation use the same assertion fallback.
    /// The store retains the observer, so capture a store-owning object weakly.
    public init(
        onUnhandledError: (@MainActor (ActionRun, ActionFailure) -> Void)? = nil
    ) {
        self.onUnhandledError = onUnhandledError
    }

    deinit {
        tasks.cancelAll()
    }

    /// Starts an operation unless duplicate policy or terminal closure rejects it.
    ///
    /// The run is tracked before the operation begins. Call `cancellation.check()` at
    /// meaningful suspension boundaries to cooperate with cancellation requests.
    /// `CancellationError` is normal termination. Handle business errors in the ViewModel;
    /// other escaped errors are reported to the observer or trigger a debug assertion.
    @discardableResult
    public func start(
        id: ActionID,
        lifetime: ActionLifetime,
        policy: TaskStartPolicy = .ignoreNew,
        priority: TaskPriority? = nil,
        operation: @escaping @MainActor @Sendable (CancellationContext) async throws -> Void
    ) -> TaskStartOutcome {
        guard !isClosed else { return .skipped(.closed) }

        switch policy {
        case .ignoreNew where isRunning(id: id):
            return .skipped(.alreadyRunning)
        case .cancelExisting:
            cancel(id: id)
        case .ignoreNew, .allowConcurrent:
            break
        }

        let run = ActionRun(actionID: id)
        let ownership = TaskOwnership()
        let context = ownership.inheritingCurrent
        // A strong store or observer capture would defeat deinit cancellation or retain
        // the observer's dependencies after the store is gone.
        let handle = Task(priority: priority) { @MainActor [weak self] in
            await TaskOwnership.$current.withValue(context) {
                defer { self?.finish(run) }
                do {
                    try await operation(CancellationContext())
                } catch is CancellationError {
                    return
                } catch {
                    let failure = ActionFailure(error: error)
                    if let observer = self?.onUnhandledError {
                        observer(run, failure)
                    } else {
                        assertionFailure(
                            "Unhandled ViewTaskStore operation failure: "
                                + "\(failure.typeName): \(failure.message)"
                        )
                    }
                }
            }
        }

        tasks.insert(handle, for: run, ownership: ownership)
        runs.insert(run, metadata: lifetime)
        return .started(run)
    }

    /// Requests cancellation and immediately untracks runs with this Action ID.
    public func cancel(id: ActionID) {
        for run in runs.runs(for: id) { cancel(run) }
    }

    /// Requests cancellation and immediately untracks one concrete run.
    /// Finished, previously cancelled, and foreign runs have no effect.
    public func cancel(_ run: ActionRun) {
        guard runs.remove(run) != nil else { return }
        tasks.cancel(run)
    }

    /// Requests cancellation and immediately untracks runs with this lifetime label.
    public func cancel(lifetime: ActionLifetime) {
        for run in runs.runs(matching: { $0 == lifetime }) { cancel(run) }
    }

    /// Requests cancellation of all owned tasks and clears tracking. Admission stays open.
    public func cancelAll() {
        runs.removeAll()
        tasks.cancelAll()
    }

    /// Permanently rejects new starts without cancelling existing work.
    /// Closing is idempotent. Follow with `waitForIdle()` for a graceful drain.
    public func close() {
        isClosed = true
    }

    /// Closes admission, cancels all owned work, and waits for actual termination.
    /// No new run can start while this method is suspended. Closure is terminal.
    public func cancelAndWaitForIdle() async {
        close()
        cancelAll()
        await waitForIdle()
    }

    /// Waits for all owned tasks, including cancelled work and runs admitted during the wait.
    ///
    /// An operation must not wait on its own store. Debug builds assert on this misuse;
    /// release builds exclude its inherited ownership context and wait for other work.
    /// Cancelling the caller does not cancel owned work or interrupt this wait.
    public func waitForIdle() async {
        let excluded = tasks.keysExcludedFromWait()
        while let handle = tasks.firstHandle(excluding: excluded) {
            await handle.value
        }
    }

    /// Waits for one concrete run, including a cancelled run still owned until termination.
    /// Finished or foreign runs return immediately. Self-waiting asserts in debug builds
    /// and returns immediately in release builds, including from structured children.
    /// Cancelling the caller does not cancel the run or interrupt this wait.
    public func awaitCompletion(of run: ActionRun) async {
        await tasks.handleToWait(for: run)?.value
    }

    /// Whether any run with this Action ID is tracked.
    public func isRunning(id: ActionID) -> Bool {
        runningCount(for: id) > 0
    }

    /// Whether this concrete run is tracked.
    public func isRunning(_ run: ActionRun) -> Bool {
        runs.contains(run)
    }

    /// Whether any run with this lifetime label is tracked.
    public func isRunning(lifetime: ActionLifetime) -> Bool {
        runs.contains(matching: { $0 == lifetime })
    }

    /// The number of tracked runs with this Action ID.
    public func runningCount(for id: ActionID) -> Int {
        runs.count(for: id)
    }

    /// The number of tracked runs with this lifetime label.
    public func runningCount(lifetime: ActionLifetime) -> Int {
        runs.count(matching: { $0 == lifetime })
    }

    private func finish(_ run: ActionRun) {
        runs.remove(run)
        tasks.remove(run)
    }
}
