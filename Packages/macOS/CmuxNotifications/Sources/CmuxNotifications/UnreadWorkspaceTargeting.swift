public import Foundation

/// Per-workspace unread-jump seam: resolve the panel to jump to, decide whether
/// to play the manual-unread dismiss flash, trigger that flash, and clear the
/// unread state after a jump. All keyed by workspace id so the coordinator never
/// holds a `Workspace` reference.
///
/// `preferredUnreadPanelIdForJump` mirrors `Workspace.preferredUnreadPanelIdForJump()`.
/// `shouldTriggerManualUnreadJumpFlash` mirrors the four-way OR in
/// `AppDelegate.shouldTriggerManualUnreadJumpFlash`. `clearUnreadAfterJump`
/// mirrors `Workspace.clearUnreadAfterJump(panelId:)`. A missing workspace makes
/// reads `nil`/`false` and mutations no-ops.
@MainActor
public protocol UnreadWorkspaceTargeting: AnyObject {
    /// The panel id the workspace prefers to jump to, if any.
    func preferredUnreadPanelIdForJump(workspaceId: UUID) -> UUID?

    /// Whether jumping to `panelId` should play the manual-unread dismiss flash.
    func shouldTriggerManualUnreadJumpFlash(workspaceId: UUID, panelId: UUID) -> Bool

    /// Flashes the panel to confirm a manual-unread dismissal on jump.
    func triggerUnreadIndicatorDismissFlash(workspaceId: UUID, panelId: UUID)

    /// Clears the workspace's unread state after a jump opened `panelId`.
    func clearUnreadAfterJump(workspaceId: UUID, panelId: UUID?)

    /// The pane he's on: the focused pane of the key window with cmux frontmost, or `nil` when cmux
    /// isn't frontmost or nothing is focused (`cm-128.11`). The unread walk reads such a pane and passes
    /// it by; the coordinator compares it with a stop through ``owningPanelId(workspaceId:surfaceId:)``.
    func frontmostFocusedPane() -> UnreadQueueTarget?

    /// The workspace panel that owns `surfaceId` (`cm-128.11`). It is `surfaceId` itself for an ordinary
    /// pane; a remote tmux pane inside a container panel maps to that container. A surface this doesn't
    /// know maps to itself. The walk maps one side at a time through this, never both, since two panes in
    /// one container are two panes.
    func owningPanelId(workspaceId: UUID, surfaceId: UUID) -> UUID
}
