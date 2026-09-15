/// Owns one active unstructured task outside UI isolation.
///
/// Replacing or cancelling requests cooperative cancellation. Superseded operations
/// remain owned until they finish, so `waitForIdle()` also waits for that work.
/// Avoid strongly capturing the object that owns the slot inside an operation.
public actor TaskSlot {
    private var tasks = OwnedTasks<TaskOwnership>()
    private var activeTask: TaskOwnership?
    private var isClosed = false

    public init() {}

    deinit {
        tasks.cancelAll()
    }

    /// Cancels the active task and starts a replacement, or returns `false` after closure.
    ///
    /// The operation must inspect its cancellation context at meaningful suspension
    /// boundaries. The priority is forwarded to `Task`; `nil` inherits caller priority.
    @discardableResult
    public func replace(
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable (CancellationContext) async -> Void
    ) -> Bool {
        guard !isClosed else { return false }
        cancel()

        let ownership = TaskOwnership()
        let context = ownership.inheritingCurrent
        // Retaining the slot here would prevent its deinit cancellation safety net.
        let handle = Task(priority: priority) { [weak self] in
            await TaskOwnership.$current.withValue(context) {
                await operation(CancellationContext())
            }
            await self?.finish(ownership)
        }
        tasks.insert(handle, for: ownership, ownership: ownership)
        activeTask = ownership
        return true
    }

    /// Permanently rejects replacements without cancelling existing work.
    /// Closing is idempotent. Follow with `waitForIdle()` for a graceful drain.
    public func close() {
        isClosed = true
    }

    /// Requests cooperative cancellation of the active task. Admission stays open.
    public func cancel() {
        guard let activeTask else { return }
        tasks.cancel(activeTask)
        self.activeTask = nil
    }

    /// Closes admission, requests cancellation, and waits for all owned work to finish.
    /// No replacement can start while this method is suspended. Closure is terminal.
    public func cancelAndWaitForIdle() async {
        close()
        cancel()
        await waitForIdle()
    }

    /// Waits for all owned tasks, including replacements admitted during the wait.
    ///
    /// An operation must not wait on its own slot. Debug builds assert on this misuse;
    /// release builds exclude its inherited ownership context and wait for other work.
    /// Cancelling the caller does not cancel owned work or interrupt this wait.
    public func waitForIdle() async {
        let excluded = tasks.keysExcludedFromWait()
        while let handle = tasks.firstHandle(excluding: excluded) {
            await handle.value
        }
    }

    private func finish(_ ownership: TaskOwnership) {
        tasks.remove(ownership)
        if activeTask == ownership {
            activeTask = nil
        }
    }
}
