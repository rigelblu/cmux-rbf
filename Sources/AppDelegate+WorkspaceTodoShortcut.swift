import AppKit

extension AppDelegate {
    /// Resolves the preferred/key window, then applies Done to its selected group anchor or workspace. (#cm-110.2)
    /// The UI target path is shared with the palette; explicit workspace CLI calls stay workspace-owned. (#cm-110.2)
    /// - Returns: Whether a selected target consumed the event. (#cm-110.2)
    func handleMarkWorkspaceDoneShortcut(preferredWindow: NSWindow? = nil) -> Bool {
        guard WorkspaceTodoFeature.isEnabled else { return false }
        let targetWindow = preferredWindow ?? shortcutRoutingActiveWindow
        let resolvedTabManager = contextForMainWindow(targetWindow)?.tabManager ?? tabManager
        guard let resolvedTabManager else { return false } // (#cm-110.2)
        return WorkspaceGroupStatusUIActions.app(tabManager: resolvedTabManager).applySelected(.done) // (#cm-110.2)
    }

    /// Cycles a selected group's explicit list upward, or preserves the workspace's existing cycle. (#cm-110.2)
    /// The selected anchor is the header selection, including focus in its own terminal. (#cm-110.2)
    /// - Returns: Whether a selected target consumed the event. (#cm-110.2)
    func handleCycleWorkspaceStatusShortcut(preferredWindow: NSWindow? = nil) -> Bool {
        guard WorkspaceTodoFeature.isEnabled else { return false }
        let targetWindow = preferredWindow ?? shortcutRoutingActiveWindow
        let resolvedTabManager = contextForMainWindow(targetWindow)?.tabManager ?? tabManager
        guard let resolvedTabManager else { return false } // (#cm-110.2)
        return WorkspaceGroupStatusUIActions.app(tabManager: resolvedTabManager).cycleSelected() // (#cm-110.2)
    }
}
