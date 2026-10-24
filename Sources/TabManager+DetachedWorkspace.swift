import Foundation
import CmuxSettings
import CmuxWorkspaces
import CmuxTerminalCore

extension TabManager {
    struct WorkspaceCreationTabSnapshot {
        let id: UUID
        let isPinned: Bool

        @MainActor
        init(workspace: Workspace) {
            self.id = workspace.id
            self.isPinned = workspace.isPinned
        }
    }

    struct WorkspaceCreationSnapshot {
        let tabs: [WorkspaceCreationTabSnapshot]
        let selectedTabId: UUID?
        let selectedTabWasPinned: Bool
        let preferredWorkingDirectory: String?
        let inheritedTerminalFontSizeLineage: TerminalFontSizeLineage?
    }

    @discardableResult
    func addWorkspace(
        fromDetachedSurface detached: Workspace.DetachedSurfaceTransfer,
        title: String? = nil,
        titleSource: Workspace.CustomTitleSource = .auto,
        select: Bool = true,
        placementOverride: WorkspacePlacement? = nil,
        insertionIndexOverride: Int? = nil,
        focusIntent: PanelFocusIntent? = nil
    ) -> Workspace? {
        guard !isFinalizedForWindowClose else { return nil }
        let sourceWorkspace = selectedWorkspace
        let capturedTabs = tabs
        let capturedSelectedTabId = sourceWorkspace?.id

        return withExtendedLifetime((capturedTabs, sourceWorkspace, detached.panel)) {
            let inheritedDirectory = implicitWorkingDirectoryForNewWorkspace(from: sourceWorkspace)
            let fontSizeLineage = inheritedTerminalFontSizeLineageForNewWorkspace(
                workspace: sourceWorkspace
            )
            let snapshot = workspaceCreationSnapshotLite(
                currentTabs: capturedTabs,
                currentSelectedTabId: capturedSelectedTabId,
                preferredWorkingDirectory: inheritedDirectory,
                inheritedTerminalFontSizeLineage: fontSizeLineage
            )
            didCaptureWorkspaceCreationSnapshot()
#if DEBUG
            maybeMutateSelectionDuringWorkspaceCreationForDev(snapshot: snapshot)
#endif
            let nextTabCount = snapshot.tabs.count + 1
            sentryBreadcrumb("workspace.create.fromDetachedSurface", data: ["tabCount": nextTabCount])

            let inheritedConfig = workspaceCreationConfigTemplate(
                inheritedTerminalFontSizeLineage: snapshot.inheritedTerminalFontSizeLineage
            )
            let plannedInsertIndex = detachedWorkspaceInsertIndex(
                insertionIndexOverride: insertionIndexOverride,
                snapshot: snapshot,
                placementOverride: placementOverride
            )
            let ordinal = Self.nextPortOrdinal
            Self.nextPortOrdinal += 1
            let workingDirectory =
                normalizedWorkingDirectory(detached.directory) ?? snapshot.preferredWorkingDirectory
            let newWorkspace = makeWorkspaceForDetachedSurface(
                title: title ?? detached.title,
                workingDirectory: workingDirectory,
                portOrdinal: ordinal,
                configTemplate: inheritedConfig,
                detachedSurface: detached
            )
            guard newWorkspace.panels[detached.panelId] != nil,
                  newWorkspace.paneId(forPanelId: detached.panelId) != nil else {
                return nil
            }

            applyCreationChromeInheritance(to: newWorkspace, from: sourceWorkspace ?? capturedTabs.first)
            newWorkspace.owningTabManager = self
            applyCreationWorkspaceCustomization(
                to: newWorkspace,
                explicitTitle: title,
                explicitTitleSource: titleSource
            )
            wireClosedBrowserTracking(for: newWorkspace)

            var updatedTabs = tabs
            let insertIndex = Self.clampedDetachedWorkspaceInsertIndex(plannedInsertIndex, workspaces: updatedTabs, groups: workspaceGroups) // (#cm-110.5)
            updatedTabs.insert(newWorkspace, at: insertIndex)
            tabs = updatedTabs
            // The insert index can fall inside an area of a nested window: repair the order (#cm-106).
            if workspaces.hasNestedWorkspaceGroup { workspaces.normalizeWorkspaceGroupContiguity() }

            if select {
#if DEBUG
                debugPrimeWorkspaceSwitchTrigger("createFromDetachedSurface", to: newWorkspace.id)
#endif
                selectedTabId = newWorkspace.id
                NotificationCenter.default.post(
                    name: .ghosttyDidFocusTab,
                    object: nil,
                    userInfo: [GhosttyNotificationKey.tabId: newWorkspace.id]
                )
                newWorkspace.focusPanel(detached.panelId, focusIntent: focusIntent)
            }
#if DEBUG
            UITestRecorder.incrementInt("addTabInvocations")
            UITestRecorder.record([
                "tabCount": String(updatedTabs.count),
                "selectedTabId": select ? newWorkspace.id.uuidString : (snapshot.selectedTabId?.uuidString ?? "")
            ])
#endif
            return newWorkspace
        }
    }

    private func detachedWorkspaceInsertIndex(
        insertionIndexOverride: Int?,
        snapshot: WorkspaceCreationSnapshot,
        placementOverride: WorkspacePlacement?
    ) -> Int {
        guard let insertionIndexOverride else {
            return newTabInsertIndex(snapshot: snapshot, placementOverride: placementOverride)
        }
        return Self.clampedDetachedWorkspaceInsertIndex(insertionIndexOverride, tabs: snapshot.tabs)
    }

    private static func clampedDetachedWorkspaceInsertIndex(
        _ proposedInsertion: Int,
        tabs: [WorkspaceCreationTabSnapshot]
    ) -> Int {
        let pinnedCount = tabs.reduce(into: 0) { count, tab in
            if tab.isPinned {
                count += 1
            }
        }
        return clampedDetachedWorkspaceInsertIndex(proposedInsertion, totalCount: tabs.count, pinnedCount: pinnedCount)
    }

    private static func clampedDetachedWorkspaceInsertIndex(
        _ proposedInsertion: Int,
        workspaces: [Workspace],
        groups: [WorkspaceGroup] // (#cm-110.5)
    ) -> Int {
        // A pinned group pins its members, though they are not pinned one by one (#cm-110.5)
        let groupsById = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) // (#cm-110.5)
        func isPinnedByGroup(_ workspace: Workspace) -> Bool { // (#cm-110.5)
            var next = workspace.groupId // (#cm-110.5)
            var seen: Set<UUID> = [] // (#cm-110.5)
            while let groupId = next, seen.insert(groupId).inserted, let group = groupsById[groupId] { // (#cm-110.5)
                if group.isPinned { return true } // (#cm-110.5)
                next = group.parentGroupId // (#cm-110.5)
            } // (#cm-110.5)
            return false // (#cm-110.5)
        } // (#cm-110.5)
        let pinnedCount = workspaces.prefix { $0.isPinned || isPinnedByGroup($0) }.count // (#cm-110.5)
        return clampedDetachedWorkspaceInsertIndex(
            proposedInsertion,
            totalCount: workspaces.count,
            pinnedCount: pinnedCount
        )
    }

    private static func clampedDetachedWorkspaceInsertIndex(
        _ proposedInsertion: Int,
        totalCount: Int,
        pinnedCount: Int
    ) -> Int {
        let clampedCount = max(0, totalCount)
        let clampedPinnedCount = max(0, min(pinnedCount, clampedCount))
        let clampedInsertion = max(0, min(proposedInsertion, clampedCount))
        return max(clampedInsertion, clampedPinnedCount)
    }
}
