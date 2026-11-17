/// In-memory alias-chain resolver over the journal's restore identity maps.
///
/// A replay fold canonicalizes every event's workspace/surface identity; doing
/// that through per-event SQL lookups costs two round-trips per event, so the
/// consumer loads the (tiny) alias tables once and resolves chains here.
/// Chains are followed up to ``AgentJournalStore/maximumAliasChainLength``
/// hops, and a recorded cycle fails closed with `nil`. Workspace resolution
/// matches ``AgentJournalStore/resolvedWorkspaceId(_:)``. (cm-128.19) Surface
/// resolution stops at the first id that is live and has an alias, which the
/// store's ``AgentJournalStore/resolvedSurfaceId(_:)`` never does: its walk has
/// no liveness test, and nothing in the app calls it. The two agree when no id
/// on the chain is live.
public struct AgentJournalAliasResolver: Sendable, Equatable {
    /// Old workspace UUID string → new workspace UUID string.
    public private(set) var workspaces: [String: String]
    /// Old surface UUID string → new surface UUID string.
    public private(set) var surfaces: [String: String]

    /// Creates a resolver over the given maps.
    ///
    /// - Parameters:
    ///   - workspaces: Old workspace UUID string → new workspace UUID string.
    ///   - surfaces: Old surface UUID string → new surface UUID string.
    public init(workspaces: [String: String] = [:], surfaces: [String: String] = [:]) {
        self.workspaces = workspaces
        self.surfaces = surfaces
    }

    /// Merges freshly recorded aliases into the resolver.
    ///
    /// - Parameters:
    ///   - workspaces: Newly recorded workspace aliases.
    ///   - surfaces: Newly recorded surface aliases.
    public mutating func merge(workspaces: [String: String], surfaces: [String: String]) {
        self.workspaces.merge(workspaces) { _, new in new }
        self.surfaces.merge(surfaces) { _, new in new }
    }

    /// Resolves a surface identity through the chain, stopping at the first
    /// surface that is live (`cm-128.19`).
    ///
    /// The alias table can map an open pane's id to a restored copy's id: rows
    /// recorded before `cm-128.19` do, and a restore records none now. Following
    /// such a row would send the open pane's events to the copy, so an id that
    /// is live is never followed past. Pass the
    /// liveness test per call: the resolver is `Sendable, Equatable`, which a
    /// stored closure would break.
    ///
    /// - Parameters:
    ///   - surfaceId: The (possibly stale) surface UUID string.
    ///   - isLive: Whether a surface with this id is open. Asked only for an id
    ///     that has an alias, never for one that resolves to itself.
    /// - Returns: The current identity, or `nil` on a recorded cycle.
    public func resolvedSurfaceId(_ surfaceId: String, isLive: (String) -> Bool) -> String? {
        Self.resolve(surfaceId, in: surfaces, isLive: isLive)
    }

    /// Resolves a workspace identity through the chain.
    ///
    /// - Parameter workspaceId: The (possibly stale) workspace UUID string.
    /// - Returns: The current identity, or `nil` on a recorded cycle.
    public func resolvedWorkspaceId(_ workspaceId: String) -> String? {
        // (cm-128.19) A workspace has no liveness rule: its aliases set preferences only.
        Self.resolve(workspaceId, in: workspaces, isLive: { _ in false })
    }

    // (cm-128.19) `isLive` is new; the walk is upstream's.
    private static func resolve(
        _ identifier: String,
        in map: [String: String],
        isLive: (String) -> Bool
    ) -> String? {
        var current = identifier
        var hops = 0
        while hops < AgentJournalStore.maximumAliasChainLength {
            guard let next = map[current], next != current else { return current }
            if isLive(current) { return current } // (cm-128.19)
            current = next
            hops += 1
        }
        return nil
    }
}
