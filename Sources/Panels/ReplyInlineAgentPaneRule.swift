import CmuxWorkspaces

/// Whether a pane counts as an agent pane for the Reply toolbar (`cm-136.9`):
/// `#cm-89`'s live session, and a program running in the pane. A shell idle at
/// its prompt means no agent is in the foreground, as when a Claude did not come
/// back after a restart, so a quote pasted there would land in the shell. Any
/// other shell state, including `.unknown` (no shell integration), keeps the
/// live-only answer.
enum ReplyInlineAgentPaneRule {
    static func counts(hasLiveSession: Bool, shellState: PanelShellActivityState) -> Bool {
        guard hasLiveSession else { return false }
        return shellState != .promptIdle
    }
}
