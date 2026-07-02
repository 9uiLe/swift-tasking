/// `ActionRunner` 経由で実行するアクションの重複実行ポリシー。
public enum ActionDuplicatePolicy: Equatable, Sendable {
    /// 同じ `ActionID` の実行中は新しい実行を拒否します。
    case rejectWhileRunning

    /// 同じ `ActionID` の複数実行が重なることを許可します。
    case allowConcurrent
}

/// アクションが生成したエラーを `Sendable` かつ比較可能な形で表した値。
public struct ActionFailure: Equatable, Sendable {
    public let typeName: String
    public let message: String

    public init(typeName: String, message: String) {
        self.typeName = typeName
        self.message = message
    }

    public init(error: any Error) {
        typeName = String(reflecting: type(of: error))
        message = String(describing: error)
    }
}

/// `ActionRunner` 経由で実行したアクションの最終結果。
public enum ActionOutcome<Success: Sendable>: Sendable {
    case succeeded(Success)
    case cancelled
    case skipped(ActionSkipReason)
    case failed(ActionFailure)
}

extension ActionOutcome: Equatable where Success: Equatable {}

/// 1 つのアクションに対する静的な設定。
public struct ActionDescriptor: Equatable, Sendable {
    public let id: ActionID
    public let duplicatePolicy: ActionDuplicatePolicy

    public init(
        id: ActionID,
        duplicatePolicy: ActionDuplicatePolicy = .rejectWhileRunning
    ) {
        self.id = id
        self.duplicatePolicy = duplicatePolicy
    }
}

/// 既存の async 文脈でアクションを実行し、アクション状態を一元管理します。
///
/// `ActionRunner` は task を作成せず、所有もしません。すでに async 文脈にいて、
/// 重複実行制御と型付きの最終結果が必要な場合に使います。
/// unstructured task のハンドル所有という別責務には `ViewTaskStore` を使います。
@MainActor
public final class ActionRunner {
    private var runningRunsByActionID: [ActionID: Set<ActionRunID>] = [:]

    public init() {}

    public func run<Success: Sendable>(
        _ descriptor: ActionDescriptor,
        onStart: (ActionRun) -> Void = { _ in },
        operation: @MainActor @Sendable (CancellationContext) async throws -> Success
    ) async -> ActionOutcome<Success> {
        switch start(descriptor) {
        case let .started(run):
            onStart(run)
            defer {
                finish(run)
            }

            do {
                return .succeeded(try await operation(CancellationContext()))
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failed(ActionFailure(error: error))
            }

        case let .skipped(reason):
            return .skipped(reason)
        }
    }

    public func isRunning(_ id: ActionID) -> Bool {
        runningRunsByActionID[id]?.isEmpty == false
    }

    public func runningCount(for id: ActionID) -> Int {
        runningRunsByActionID[id]?.count ?? 0
    }

    private func start(_ descriptor: ActionDescriptor) -> ActionStart {
        let runningRuns = runningRunsByActionID[descriptor.id, default: []]

        switch descriptor.duplicatePolicy {
        case .rejectWhileRunning where !runningRuns.isEmpty:
            return .skipped(.alreadyRunning)

        case .rejectWhileRunning, .allowConcurrent:
            let run = ActionRun(actionID: descriptor.id)
            runningRunsByActionID[descriptor.id, default: []].insert(run.runID)
            return .started(run)
        }
    }

    private func finish(_ run: ActionRun) {
        runningRunsByActionID[run.actionID]?.remove(run.runID)
        if runningRunsByActionID[run.actionID]?.isEmpty == true {
            runningRunsByActionID[run.actionID] = nil
        }
    }
}

private enum ActionStart: Sendable {
    case started(ActionRun)
    case skipped(ActionSkipReason)
}
