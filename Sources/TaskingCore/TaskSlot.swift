/// Owns one active unstructured task outside UI isolation.
///
/// Replacing or cancelling a task requests cooperative cancellation. Cancelled operations
/// remain owned until they actually finish, so `waitForIdle()` also waits for superseded work.
public actor TaskSlot {
    private var tasksByID: [UInt64: Task<Void, Never>] = [:]
    private var activeTaskID: UInt64?
    private var nextTaskID: UInt64 = 0
    private var isClosed = false

    public init() {}

    deinit {
        for task in tasksByID.values {
            task.cancel()
        }
    }

    /// Cancels the active task, if any, and starts a replacement owned by this slot.
    ///
    /// The operation must inspect the supplied cancellation context at meaningful
    /// suspension boundaries. Cancellation does not forcibly stop an operation.
    /// Returns `false` without running the operation after the slot has been closed.
    @discardableResult
    public func replace(
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable (CancellationContext) async -> Void
    ) -> Bool {
        guard !isClosed else {
            return false
        }

        cancelActiveTask()

        nextTaskID &+= 1
        let taskID = nextTaskID
        activeTaskID = taskID
        let ownedTask = TaskSlotOwnedTask(
            slotID: ObjectIdentifier(self),
            taskID: taskID
        )
        let ownership = TaskSlotOwnership.current.union([ownedTask])
        let task = Task(priority: priority) { [weak self] in
            await TaskSlotOwnership.$current.withValue(ownership) {
                await operation(CancellationContext())
            }
            await self?.finish(taskID: taskID)
        }
        tasksByID[taskID] = task
        return true
    }

    /// Permanently stops this slot from accepting replacements.
    ///
    /// Closing is idempotent and does not cancel work already owned by the slot. Call
    /// `waitForIdle()` after closing for a graceful drain, or use
    /// `cancelAndWaitForIdle()` for teardown that requests cancellation first.
    public func close() {
        isClosed = true
    }

    /// Requests cooperative cancellation of the active task.
    public func cancel() {
        cancelActiveTask()
    }

    /// Closes the slot, requests cancellation of its active task, and waits for all
    /// owned work to actually finish.
    ///
    /// The slot is closed and cancellation is requested before this method suspends, so no
    /// replacement can be admitted while shutdown is waiting. After it returns, the slot is
    /// permanently idle.
    public func cancelAndWaitForIdle() async {
        // Keep both state changes before the first suspension. Closing later could admit a
        // replacement, while cancelling later would let active work continue into the wait.
        isClosed = true
        cancelActiveTask()
        await waitForIdle()
    }

    /// Suspends until every task currently owned by the slot has actually finished.
    ///
    /// This includes superseded and cancelled operations that have not terminated yet,
    /// as well as replacements started while this method is suspended.
    /// If called from an operation owned by this slot, that operation and inherited
    /// child contexts are excluded to avoid self-waiting; a debug assertion reports
    /// the contract violation while release builds still make finite progress.
    public func waitForIdle() async {
        let slotID = ObjectIdentifier(self)
        let excludedTaskIDs = Set(
            TaskSlotOwnership.current.lazy
                .filter { $0.slotID == slotID }
                .map(\.taskID)
        )

        if !excludedTaskIDs.isEmpty {
            assertionFailure(
                "TaskSlot.waitForIdle() cannot wait for an operation owned by the same slot; "
                    + "the current ownership context was excluded."
            )
        }

        while let task = tasksByID.first(where: { !excludedTaskIDs.contains($0.key) })?.value {
            await task.value
        }
    }

    private func cancelActiveTask() {
        guard let activeTaskID else {
            return
        }
        tasksByID[activeTaskID]?.cancel()
        self.activeTaskID = nil
    }

    private func finish(taskID: UInt64) {
        tasksByID[taskID] = nil
        if activeTaskID == taskID {
            activeTaskID = nil
        }
    }
}

private struct TaskSlotOwnedTask: Hashable, Sendable {
    let slotID: ObjectIdentifier
    let taskID: UInt64
}

private enum TaskSlotOwnership {
    @TaskLocal static var current: Set<TaskSlotOwnedTask> = []
}
