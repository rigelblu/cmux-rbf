public import Foundation

// cmux-rbf #cm-126.3: the Agent Pane's app-state seam.

/// Reads and changes Agent Panes without importing app or layout types.
/// Main-actor isolation is required because the app reads and changes Bonsplit layout.
@MainActor
public protocol ControlAgentPaneContext: AnyObject {
    /// Validates a caller and page without changing state.
    /// - Parameters:
    ///   - surfaceID: The caller terminal's live surface identifier.
    ///   - url: The requested page.
    /// - Returns: A refusal or an applicable plan.
    func controlAgentPaneCheck(surfaceID: UUID, url: URL) -> ControlAgentPaneCheck

    /// Applies a validated plan through the app's shared action path.
    /// - Parameter plan: The plan returned by the check.
    /// - Returns: The applied result, or nil if the target disappeared or creation failed.
    func controlAgentPaneApply(_ plan: ControlAgentPanePlan) -> ControlAgentPaneApplied?

    /// Lists Agent Panes, including restore placeholders.
    /// - Parameter workspaceID: One workspace, or nil for all workspaces.
    /// - Returns: The panes, or nil if the requested workspace does not exist.
    func controlAgentPaneList(workspaceID: UUID?) -> [ControlAgentPaneSummary]?
}
