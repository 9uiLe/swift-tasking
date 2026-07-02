/// `ViewTaskStore` が所有する task の論理的なライフタイム。
///
/// 組み込み値は一般的な UI 所有スコープを表します。
/// たとえば `"accountSettings"` のように、機能固有のスコープも定義できます。
public struct ActionLifetime: Hashable, Sendable, RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible {
    public static let screenBound = ActionLifetime("screenBound")
    public static let sceneBound = ActionLifetime("sceneBound")
    public static let appBound = ActionLifetime("appBound")

    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: StringLiteralType) {
        rawValue = value
    }

    public var description: String {
        rawValue
    }
}

/// 同じ `ActionID` の task がすでに追跡中の場合の開始ポリシー。
public enum TaskStartPolicy: Equatable, Sendable {
    /// 既存の task を維持し、新しい要求をスキップします。
    case ignoreNew

    /// 同じアクションとして追跡中の task をキャンセルしてから開始します。
    ///
    /// キャンセルは協調的です。古い処理がキャンセルを無視する場合、store が
    /// 重複判定上は実行中として扱わなくなった後も、その処理自体は継続する
    /// 可能性があります。
    case cancelExisting

    /// 同じ action ID の task を追加で開始します。
    case allowConcurrent
}

public enum TaskStartOutcome: Equatable, Sendable {
    case started(ActionRun)
    case skipped(ActionSkipReason)

    public var run: ActionRun? {
        guard case let .started(run) = self else {
            return nil
        }
        return run
    }

    public var skipReason: ActionSkipReason? {
        guard case let .skipped(reason) = self else {
            return nil
        }
        return reason
    }
}

/// View の同期 UI コールバックから作成された unstructured task のハンドルを所有します。
///
/// `ViewTaskStore` は SwiftUI view に所有されることを主な用途としているため、
/// `@MainActor` です。
/// task の所有者、ライフタイム、重複実行ポリシーを呼び出し箇所で明示できます。
@MainActor
public final class ViewTaskStore {
    private var tasksByRunID: [ActionRunID: ManagedTask] = [:]
    private var runIDsByActionID: [ActionID: Set<ActionRunID>] = [:]

    public init() {}

    deinit {
        for task in tasksByRunID.values {
            task.handle.cancel()
        }
    }

    /// ViewModel の async メソッドを unstructured task として開始します。
    ///
    /// operation には `CancellationContext` が渡されます。長い処理では
    /// `try cancellation.check()` を呼び、キャンセル要求に協調してください。
    /// `CancellationError` は通常終了として扱います。その他のエラーは ViewModel 側で
    /// state に変換することを想定しており、漏れた場合は debug assertion で検出します。
    @discardableResult
    public func start(
        id: ActionID,
        lifetime: ActionLifetime,
        policy: TaskStartPolicy = .ignoreNew,
        priority: TaskPriority? = nil,
        operation: @escaping @MainActor @Sendable (CancellationContext) async throws -> Void
    ) -> TaskStartOutcome {
        let runningRunIDs = runIDsByActionID[id, default: []]

        switch policy {
        case .ignoreNew where !runningRunIDs.isEmpty:
            return .skipped(.alreadyRunning)

        case .cancelExisting:
            cancel(id: id)

        case .ignoreNew, .allowConcurrent:
            break
        }

        let run = ActionRun(actionID: id)
        let handle = Task(priority: priority) { @MainActor [weak self] in
            defer {
                self?.finish(run)
            }

            do {
                try await operation(CancellationContext())
            } catch is CancellationError {
                return
            } catch {
                assertionFailure("Unhandled ViewTaskStore operation failure: \(error)")
            }
        }

        tasksByRunID[run.runID] = ManagedTask(
            actionID: id,
            lifetime: lifetime,
            handle: handle
        )
        runIDsByActionID[id, default: []].insert(run.runID)
        return .started(run)
    }

    public func cancel(id: ActionID) {
        let runIDs = runIDsByActionID[id, default: []]
        for runID in runIDs {
            cancel(runID: runID)
        }
    }

    public func cancel(_ run: ActionRun) {
        cancel(runID: run.runID)
    }

    public func cancel(lifetime: ActionLifetime) {
        let runIDs = tasksByRunID.compactMap { runID, task in
            task.lifetime == lifetime ? runID : nil
        }
        for runID in runIDs {
            cancel(runID: runID)
        }
    }

    public func cancelAll() {
        for task in tasksByRunID.values {
            task.handle.cancel()
        }
        tasksByRunID.removeAll()
        runIDsByActionID.removeAll()
    }

    public func isRunning(id: ActionID) -> Bool {
        runIDsByActionID[id]?.isEmpty == false
    }

    public func isRunning(_ run: ActionRun) -> Bool {
        tasksByRunID[run.runID] != nil
    }

    public func isRunning(lifetime: ActionLifetime) -> Bool {
        tasksByRunID.values.contains { $0.lifetime == lifetime }
    }

    public func runningCount(for id: ActionID) -> Int {
        runIDsByActionID[id]?.count ?? 0
    }

    public func runningCount(lifetime: ActionLifetime) -> Int {
        tasksByRunID.values.filter { $0.lifetime == lifetime }.count
    }

    private func cancel(runID: ActionRunID) {
        tasksByRunID[runID]?.handle.cancel()
        finish(runID: runID)
    }

    private func finish(_ run: ActionRun) {
        finish(runID: run.runID)
    }

    private func finish(runID: ActionRunID) {
        guard let task = tasksByRunID[runID] else {
            return
        }

        tasksByRunID[runID] = nil
        runIDsByActionID[task.actionID]?.remove(runID)
        if runIDsByActionID[task.actionID]?.isEmpty == true {
            runIDsByActionID[task.actionID] = nil
        }
    }
}

private struct ManagedTask {
    let actionID: ActionID
    let lifetime: ActionLifetime
    let handle: Task<Void, Never>
}
