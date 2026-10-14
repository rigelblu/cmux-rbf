/// One of his own statuses, as a workspace holds it. Not `Codable`: only `id` is saved.
public struct WorkspaceOwnStatus: Hashable, Sendable {
    /// The entry's id.
    public var id: String
    /// True from a pick made while an agent was already waiting, until that wait ends. Never saved.
    public var heldThroughWait: Bool

    /// Creates a held status.
    public init(id: String, heldThroughWait: Bool = false) {
        self.id = id
        self.heldThroughWait = heldThroughWait
    }
}
