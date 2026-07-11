/// Owns one active unstructured task outside UI isolation.
///
/// Replacing or cancelling a task requests cooperative cancellation. Cancelled operations
/// remain owned until they actually finish, so `waitForIdle()` also waits for superseded work.
public actor TaskSlot {
    private var tasksByID: [UInt64: Task<Void, Never>] = [:]
    private var activeTaskID: UInt64?
    private var nextTaskID: UInt64 = 0

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
    public func replace(
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable (CancellationContext) async -> Void
    ) {
        cancelActiveTask()

        nextTaskID &+= 1
        let taskID = nextTaskID
        activeTaskID = taskID
        let task = Task(priority: priority) { [weak self] in
            await operation(CancellationContext())
            await self?.finish(taskID: taskID)
        }
        tasksByID[taskID] = task
    }

    /// Requests cooperative cancellation of the active task.
    public func cancel() {
        cancelActiveTask()
    }

    /// Suspends until every task currently owned by the slot has actually finished.
    ///
    /// This includes superseded and cancelled operations that have not terminated yet,
    /// as well as replacements started while this method is suspended.
    public func waitForIdle() async {
        while let task = tasksByID.values.first {
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
