import Foundation

/// Local title ownership; Cloud requests enter the catalog before any UI mutation.
extension Workspace {
    // cmux-rbf (#cm-142.1): upstream's catalog-first overload, restored. The #cm-97 sync replaced it with a comment,
    // so a user rename of a cloud terminal applied locally before the daemon accepted it. A call without `catalog:`
    // resolves here; this forwards with `catalog:`, so the fork's ownership rules (#cm-9, #cm-48.2) stay in one body.
    @discardableResult
    func setPanelCustomTitle(
        panelId: UUID,
        title: String?,
        source: CustomTitleSource = .user,
        propagateToRemoteTmux: Bool = true,
        propagateToCloud: Bool = true
    ) -> Bool {
        guard panels[panelId] != nil else { return false }
        // `.agentSession` is the fork's source (#cm-9); it keeps its ownership check in the body below.
        if propagateToCloud, source != .remote, source != .agentSession,
           let submitted = SurfaceCatalog.shared.submitCloudPanelRename(
               workspace: self, panelID: panelId, title: title, source: source
           ) { return submitted }
        return setPanelCustomTitle(
            panelId: panelId,
            title: title,
            source: source,
            propagateToRemoteTmux: propagateToRemoteTmux,
            propagateToCloud: propagateToCloud,
            catalog: SurfaceCatalog.shared
        )
    }
}
