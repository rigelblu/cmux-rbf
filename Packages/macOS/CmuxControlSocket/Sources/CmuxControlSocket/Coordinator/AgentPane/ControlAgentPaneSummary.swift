public import Foundation

// cmux-rbf #cm-126.3: an Agent Pane as the list command reads it.

/// An owned browser surface, including a deferred restore placeholder.
public struct ControlAgentPaneSummary: Sendable, Equatable {
    /// The browser surface's live identifier.
    public let surfaceID: UUID
    /// The containing layout pane, when present.
    public let paneID: UUID?
    /// The workspace holding the pane.
    public let workspaceID: UUID
    /// The terminal carrying the saved owner key in this workspace, or nil.
    public let ownerSurfaceID: UUID?
    /// The ownership key, retained after the terminal closes or moves.
    public let ownerStableID: UUID
    /// The pane's current page, or nil before one is available.
    public let url: String?
    /// Additional Agent Panes with this owner in the workspace.
    public let others: Int

    /// Creates a list row without minting RPC handles.
    /// - Parameters:
    ///   - surfaceID: The browser surface.
    ///   - paneID: Its layout pane.
    ///   - workspaceID: Its workspace.
    ///   - ownerSurfaceID: A live terminal in this workspace, or nil.
    ///   - ownerStableID: The stored owner key.
    ///   - url: The current page, if available.
    ///   - others: Additional owned panes; zero when this is the only one.
    public init(
        surfaceID: UUID, paneID: UUID?, workspaceID: UUID, ownerSurfaceID: UUID?,
        ownerStableID: UUID, url: String?, others: Int = 0
    ) {
        self.surfaceID = surfaceID
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.ownerSurfaceID = ownerSurfaceID
        self.ownerStableID = ownerStableID
        self.url = url
        self.others = others
    }
}
