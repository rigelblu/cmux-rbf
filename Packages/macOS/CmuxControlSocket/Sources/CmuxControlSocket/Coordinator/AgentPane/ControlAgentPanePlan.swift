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
        /// Show the cleared page in this existing owned pane (cmux-rbf #cm-126.14).
        case clear(panelID: UUID, others: Int)
        /// The pane is already cleared: change nothing (cmux-rbf #cm-126.14).
        case alreadyCleared(panelID: UUID, others: Int)
        /// Hold a clear until Design Focus ends, replacing any held page; the pane is `nil` when only a held page exists
        /// and no pane is open yet (cmux-rbf #cm-126.14).
        case holdClear(panelID: UUID?, others: Int)
    }

    /// The action selected by the check.
    public let action: Action
    /// The workspace containing the terminal now.
    public let workspaceID: UUID
    /// The terminal's live identifier.
    public let terminalID: UUID
    /// The terminal's restart-stable ownership key.
    public let ownerStableID: UUID
    /// The validated page. For a clear, the pane's cleared page; for a clear held with no pane open yet, the
    /// cleared-pages folder, which the socket answers as a null url.
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
