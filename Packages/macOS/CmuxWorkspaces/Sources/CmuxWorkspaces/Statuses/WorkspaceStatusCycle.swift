/// Where a press of the cycle key goes next.
public struct WorkspaceStatusCycle: Sendable {
    /// What the cycle sets.
    public enum Target: Equatable, Sendable {
        /// An entry of the list in use.
        case entry(WorkspaceStatusEntry)
        /// One of cmux's five, by cmux's own rule. The answer only where the list in use gives that status no
        /// entry of his: cmux's five in use (row 1), or his list leaves it out (row 8). The write path writes no
        /// color for it.
        case cmux(WorkspaceTaskStatus)
    }

    /// Creates the cycle.
    public init() {}

    /// The status a press sets, or `nil` for "change nothing". "Up" means toward the top of the file: from
    /// place `i` to place `i - 1`, and from the top to the bottom.
    ///
    /// - Parameters:
    ///   - resolution: What the workspace shows now.
    ///   - list: The list in use.
    public func target(
        resolution: WorkspaceStatusResolution,
        list: WorkspaceStatusList
    ) -> Target? {
        // Row 1: cmux's five in use, so the press is cmux's own.
        if list.source == .cmux { return .cmux(resolution.effective.next) }
        let entries = list.entries
        // Rows 2 and 3.
        if entries.isEmpty { return nil }
        if entries.count == 1 { return .entry(entries[0]) }

        // Row 4: he holds a status the list has, in effect or waiting: the next one up. A held id the list lacks
        // is not found here when the resolution and the list come from one read of the list (Decisions,
        // 2026-10-12, point 19), so no test of the kind of hold is needed.
        if let id = resolution.heldID,
           let place = entries.firstIndex(where: { $0.id == id }) {
            return .entry(entries[(place - 1 + entries.count) % entries.count])
        }

        // Row 5: anything else starts from the status in effect.
        let start = resolution.effective
        // Row 6: an entry whose id is that status.
        if let entry = list.entry(id: start.rawValue) { return .entry(entry) }
        // Row 7: else the first entry from the top that extends it.
        if let entry = list.firstExtending(start) { return .entry(entry) }
        // Row 8: else cmux's next status after it: his entry with that id when the list has one (so the write path
        // writes its color), else cmux's own.
        let next = start.next
        if let entry = list.entry(id: next.rawValue) { return .entry(entry) }
        return .cmux(next)
    }
}
