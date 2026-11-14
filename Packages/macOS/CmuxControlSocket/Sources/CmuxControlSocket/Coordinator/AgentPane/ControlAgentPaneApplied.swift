public import Foundation

// cmux-rbf #cm-126.3: the result of applying an Agent Pane plan.

/// The outcome of showing or holding one page, before RPC handles are minted.
public struct ControlAgentPaneApplied: Sendable, Equatable {
    /// The CLI-visible outcome.
    public enum Action: String, Sendable {
        /// A new split was created.
        case opened
        /// An existing owned surface was navigated.
        case navigated
        /// The page waits until Design Focus ends.
        case heldDesignFocus = "held-design-focus"
    }

    /// What the app did.
    public let action: Action
    /// The browser surface, or nil for a hold before the first pane exists.
    public let surfaceID: UUID?
    /// Its layout pane, or nil before the first pane exists.
    public let paneID: UUID?
    /// The caller's workspace.
    public let workspaceID: UUID
    /// The owning terminal's live surface identifier.
    public let ownerSurfaceID: UUID?
    /// The ownership key persisted in the session.
    public let ownerStableID: UUID
    /// The requested page, including a page held for later.
    public let url: URL
    /// Additional Agent Panes owned by this terminal in the workspace.
    public let others: Int

    /// Creates an applied result from app-owned identifiers.
    /// - Parameters:
    ///   - action: The outcome.
    ///   - surfaceID: The browser surface, or nil on a hold before creation.
    ///   - paneID: The layout pane, or nil on a hold before creation.
    ///   - workspaceID: The workspace containing the caller.
    ///   - ownerSurfaceID: The terminal's live identifier.
    ///   - ownerStableID: The saved ownership key.
    ///   - url: The requested page.
    ///   - others: The count of additional owned panes.
    public init(
        action: Action, surfaceID: UUID?, paneID: UUID?, workspaceID: UUID,
        ownerSurfaceID: UUID?, ownerStableID: UUID, url: URL, others: Int
    ) {
        self.action = action
        self.surfaceID = surfaceID
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.ownerSurfaceID = ownerSurfaceID
        self.ownerStableID = ownerStableID
        self.url = url
        self.others = others
    }
}
