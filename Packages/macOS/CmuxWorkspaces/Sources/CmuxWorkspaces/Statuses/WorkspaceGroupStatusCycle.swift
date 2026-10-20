/// A group's explicit status cycles upward through the list, without inference or a None stop.
public struct WorkspaceGroupStatusCycle: Sendable {
    /// Creates the pure cycle rule.
    public init() {}

    /// The previous entry, wrapping; an unset or unavailable status starts at the bottom.
    public func target(statusId: String?, list: WorkspaceStatusList) -> String? {
        guard let bottom = list.entries.last else { return nil }
        guard let statusId, let index = list.entries.firstIndex(where: { $0.id == statusId }) else { return bottom.id }
        return list.entries[(index - 1 + list.entries.count) % list.entries.count].id
    }
}
