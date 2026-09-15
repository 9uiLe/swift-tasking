import TaskingCore

/// `Tasking` と `TaskingCore` が共有するキャンセル契約。
///
/// アクセスするたびに、その時点で実行中のタスクを参照する。
/// この値は親のキャンセルを新しい非構造化 `Task` に伝播しない。
/// キャンセルを伝播させる場合は構造化子タスクを使う。
public typealias CancellationContext = TaskingCore.CancellationContext
