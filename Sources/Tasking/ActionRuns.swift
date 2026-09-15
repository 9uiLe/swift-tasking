/// 追跡中の実行を管理する単一の索引。キャンセル済みの処理はハンドルの所有だけに残る。
struct ActionRuns<Metadata> {
    private var actions: [ActionID: [ActionRunID: Metadata]] = [:]

    mutating func insert(_ run: ActionRun, metadata: Metadata) {
        actions[run.actionID, default: [:]][run.runID] = metadata
    }

    @discardableResult
    mutating func remove(_ run: ActionRun) -> Metadata? {
        let removed = actions[run.actionID]?.removeValue(forKey: run.runID)
        if actions[run.actionID]?.isEmpty == true {
            actions[run.actionID] = nil
        }
        return removed
    }

    mutating func removeAll() {
        actions.removeAll()
    }

    func contains(_ run: ActionRun) -> Bool {
        actions[run.actionID]?[run.runID] != nil
    }

    func contains(matching predicate: (Metadata) -> Bool) -> Bool {
        actions.values.contains { runs in
            runs.values.contains(where: predicate)
        }
    }

    func count(for id: ActionID) -> Int {
        actions[id]?.count ?? 0
    }

    func runs(for id: ActionID) -> [ActionRun] {
        actions[id]?.keys.map { ActionRun(actionID: id, runID: $0) } ?? []
    }

    func runs(matching predicate: (Metadata) -> Bool) -> [ActionRun] {
        actions.flatMap { actionID, runs in
            runs.compactMap { runID, metadata in
                predicate(metadata) ? ActionRun(actionID: actionID, runID: runID) : nil
            }
        }
    }

    func count(matching predicate: (Metadata) -> Bool) -> Int {
        actions.values.reduce(0) { count, runs in
            count + runs.values.count(where: predicate)
        }
    }
}
