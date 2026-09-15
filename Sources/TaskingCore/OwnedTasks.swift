// 継承したコンテキストがこの識別子を保持し、マーカーの生存中にアドレスが再利用されるのを防ぐ。
package final class TaskOwnership: Hashable, Sendable {
    @TaskLocal package static var current: Set<TaskOwnership> = []

    package init() {}

    package static func == (lhs: TaskOwnership, rhs: TaskOwnership) -> Bool {
        lhs === rhs
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    package var inheritingCurrent: Set<TaskOwnership> {
        Self.current.union([self])
    }
}

/// ハンドルの所有は、受付や重複ポリシーの追跡から独立している。
package struct OwnedTasks<Key: Hashable & Sendable>: Sendable {
    private struct Entry: Sendable {
        let handle: Task<Void, Never>
        let ownership: TaskOwnership
    }

    private var entries: [Key: Entry] = [:]

    package init() {}

    package mutating func insert(
        _ handle: Task<Void, Never>, for key: Key, ownership: TaskOwnership
    ) {
        precondition(entries[key] == nil)
        entries[key] = Entry(handle: handle, ownership: ownership)
    }

    package mutating func remove(_ key: Key) {
        entries[key] = nil
    }

    package func cancel(_ key: Key) {
        entries[key]?.handle.cancel()
    }

    package func cancelAll() {
        for entry in entries.values {
            entry.handle.cancel()
        }
    }

    package func handleToWait(for key: Key) -> Task<Void, Never>? {
        guard let entry = entries[key] else { return nil }
        guard !TaskOwnership.current.contains(entry.ownership) else {
            assertionFailure("現在の所有文脈に属するタスクの終了を待つことはできません。")
            return nil
        }
        return entry.handle
    }

    package func keysExcludedFromWait() -> Set<Key> {
        guard !TaskOwnership.current.isEmpty else { return [] }
        let excluded = Set(entries.compactMap { key, entry in
            TaskOwnership.current.contains(entry.ownership) ? key : nil
        })
        assert(excluded.isEmpty, "所有される処理から全体の完了を待つことはできません。その所有文脈を待機対象から除外しました。")
        return excluded
    }

    package func firstHandle(excluding excluded: Set<Key>) -> Task<Void, Never>? {
        entries.first { !excluded.contains($0.key) }?.value.handle
    }
}
