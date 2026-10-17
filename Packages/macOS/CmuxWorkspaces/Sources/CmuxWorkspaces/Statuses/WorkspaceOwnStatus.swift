/// One of his own statuses, as a workspace holds it. Not `Codable`: only `id` is saved.
public struct WorkspaceOwnStatus: Hashable, Sendable {
    /// The entry's id.
    public var id: String

    /// Creates a held status.
    public init(id: String) {
        self.id = id
    }
}
