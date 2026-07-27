import AppKit

/// The pane a directional split acts on.
///
/// Entry points differ in how they know their target, and collapsing that
/// difference is what lets a tab-bar button or context menu split the wrong
/// pane: those controls are invoked on a specific pane, which may not own
/// global focus.
enum TerminalSplitActionSource {
    /// Resolve the target from current focus, preferring `window` when given.
    case focusedWindow(NSWindow?)

    /// Act on this exact main-workspace pane regardless of global focus.
    case explicitWorkspacePane(workspaceId: UUID, panelId: UUID)

    /// Act on this exact pane in an embedded multi-pane remote tmux mirror.
    case explicitRemoteMirrorPane(surfaceId: UUID)

}
