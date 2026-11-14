public import Foundation

// cmux-rbf #cm-126.3: an Agent Pane mutation prepared by the app.

/// One validated action, applied synchronously after its read-only check.
public struct ControlAgentPanePlan: Sendable, Equatable {
    /// The action to take without changing focus.
    public enum Action: Sendable, Equatable {
        /// Create a split beside the caller.
        case open
        /// Navigate an existing owned browser surface; count any additional panes.
        case navigate(panelID: UUID, others: Int)
        /// Hold the latest page during Design Focus, naming an existing pane if any.
        case hold(panelID: UUID?, others: Int)
    }

    /// The action selected by the check.
    public let action: Action
    /// The workspace containing the terminal now.
    public let workspaceID: UUID
    /// The terminal's live identifier.
    public let terminalID: UUID
    /// The terminal's restart-stable ownership key.
    public let ownerStableID: UUID
    /// The validated page.
    public let url: URL

    /// Creates a validated action description.
    /// - Parameters:
    ///   - action: Whether to open, navigate, or hold.
    ///   - workspaceID: The caller's current workspace.
    ///   - terminalID: The caller's live surface identifier.
    ///   - ownerStableID: The ownership key saved with the session.
    ///   - url: The requested page.
    public init(action: Action, workspaceID: UUID, terminalID: UUID, ownerStableID: UUID, url: URL) {
        self.action = action
        self.workspaceID = workspaceID
        self.terminalID = terminalID
        self.ownerStableID = ownerStableID
        self.url = url
    }
}
