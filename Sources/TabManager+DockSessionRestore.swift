import Foundation

extension TabManager {
    @discardableResult
    /// Restores each workspace's persisted Dock after workspace topology exists.
    ///
    /// Deferred browser panels are passed through without constructing WebKit
    /// until the corresponding Dock pane becomes visible.
    func restoreWorkspaceDockSessionSnapshots(
        from snapshot: SessionTabManagerSnapshot,
        excludingStableIdentities: Set<UUID>,
        deferBrowserPanels: Bool = false
    ) -> [[UUID: UUID]] {
        let pairs = restoredSessionWorkspacePairs(from: snapshot)
        var workspacesByOriginalId: [UUID: Workspace] = [:]
        for pair in pairs {
            if let originalId = pair.snapshot.workspaceId {
                workspacesByOriginalId[originalId] = pair.workspace
            }
        }
        return pairs.map { pair in
            guard let dockSnapshot = pair.snapshot.dock,
                  let dockSplit = pair.workspace.dockSplit else { return [:] }
            return dockSplit.restoreSessionSnapshot(
                dockSnapshot,
                excludingStableIdentities: excludingStableIdentities,
                deferBrowserPanels: deferBrowserPanels,
                sourceWorkspaceResolver: { workspacesByOriginalId[$0] }
            )
        }
    }

    func restoredSessionWorkspace(
        originalId: UUID,
        from snapshot: SessionTabManagerSnapshot
    ) -> Workspace? {
        restoredSessionWorkspacePairs(from: snapshot).first {
            $0.snapshot.workspaceId == originalId
        }?.workspace
    }

    private func restoredSessionWorkspacePairs(
        from snapshot: SessionTabManagerSnapshot
    ) -> [(snapshot: SessionWorkspaceSnapshot, workspace: Workspace)] {
        let (normalizedSnapshots, _) = Self.normalizedCloudVMSessionRestoreWorkspaces(
            snapshot.workspaces.prefix(SessionPersistencePolicy.maxWorkspacesPerWindow),
            selectedWorkspaceIndex: snapshot.selectedWorkspaceIndex
        )
        return Array(zip(
            normalizedSnapshots.prefix(SessionPersistencePolicy.maxWorkspacesPerWindow),
            tabs
        ))
    }
}
