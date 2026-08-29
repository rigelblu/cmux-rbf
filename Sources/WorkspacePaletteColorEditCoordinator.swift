import CmuxSettingsUI
import Foundation

/// Coordinates one revision-checked palette edit across the app's explicit color owners.
@MainActor
struct WorkspacePaletteColorEditCoordinator {
    private struct Snapshot {
        let palette: [String: String]
        let workspaces: [(workspace: Workspace, color: String?)]
        let groups: [(manager: TabManager, id: UUID, color: String?)]
    }

    func preview(
        appDelegate: AppDelegate?,
        paletteName: String,
        expectedOldHex: String,
        proposedHex: String
    ) -> Result<WorkspacePaletteColorEditPreview, WorkspacePaletteColorEditRejection> {
        guard let newHex = WorkspaceTabColorSettings.normalizedHex(proposedHex) else {
            return .failure(.invalidHex)
        }
        let palette = WorkspaceTabColorSettings.resolvedPaletteMap()
        let builtInNames = Set(WorkspaceTabColorSettings.defaultPalette.map(\.name))
        guard !builtInNames.contains(paletteName),
              let currentHex = palette[paletteName],
              WorkspaceTabColorSettings.normalizedHex(currentHex)
                == WorkspaceTabColorSettings.normalizedHex(expectedOldHex) else {
            return .failure(.unavailablePaletteEntry)
        }
        if let duplicate = palette.first(where: { name, hex in
            name != paletteName && WorkspaceTabColorSettings.normalizedHex(hex) == newHex
        }) {
            return .failure(.duplicatePaletteValue(paletteName: duplicate.key))
        }

        let oldHex = WorkspaceTabColorSettings.normalizedHex(currentHex) ?? currentHex
        let managers = appDelegate?.liveWorkspaceIdentityTabManagers() ?? []
        let snapshot = snapshot(palette: palette, managers: managers)
        let matchingWorkspaces = snapshot.workspaces.filter {
            WorkspaceTabColorSettings.normalizedHex($0.color ?? "") == oldHex
        }
        let matchingGroups = snapshot.groups.filter {
            WorkspaceTabColorSettings.normalizedHex($0.color ?? "") == oldHex
        }
        let oldValueOwnerCount = palette.values.reduce(into: 0) { count, hex in
            if WorkspaceTabColorSettings.normalizedHex(hex) == oldHex { count += 1 }
        }
        return .success(
            WorkspacePaletteColorEditPreview(
                paletteName: paletteName,
                oldHex: oldHex,
                newHex: newHex,
                workspaceCount: matchingWorkspaces.count,
                groupCount: matchingGroups.count,
                propagationAllowed: oldValueOwnerCount == 1,
                revisionToken: revisionToken(snapshot)
            )
        )
    }

    func apply(
        _ preview: WorkspacePaletteColorEditPreview,
        decision: WorkspacePaletteColorEditDecision,
        appDelegate: AppDelegate?
    ) -> WorkspacePaletteColorEditResult {
        let currentPreview: WorkspacePaletteColorEditPreview
        switch self.preview(
            appDelegate: appDelegate,
            paletteName: preview.paletteName,
            expectedOldHex: preview.oldHex,
            proposedHex: preview.newHex
        ) {
        case .success(let replacement):
            currentPreview = replacement
        case .failure(let rejection):
            return .rejected(rejection)
        }
        guard currentPreview == preview else { return .stale(replacement: currentPreview) }
        if decision == .paletteAndAssignments, !preview.propagationAllowed {
            return .rejected(.staleValue)
        }

        let managers = appDelegate?.liveWorkspaceIdentityTabManagers() ?? []
        let before = snapshot(
            palette: WorkspaceTabColorSettings.resolvedPaletteMap(),
            managers: managers
        )
        var afterPalette = before.palette
        afterPalette[preview.paletteName] = preview.newHex
        WorkspaceTabColorSettings.persistPaletteMap(afterPalette)

        if decision == .paletteAndAssignments {
            for item in before.workspaces where
                WorkspaceTabColorSettings.normalizedHex(item.color ?? "") == preview.oldHex {
                item.workspace.setCustomColor(preview.newHex)
            }
            for item in before.groups where
                WorkspaceTabColorSettings.normalizedHex(item.color ?? "") == preview.oldHex {
                item.manager.setWorkspaceGroupColor(groupId: item.id, hex: preview.newHex)
            }
        }

        if mutationMatches(
            palette: afterPalette,
            preview: preview,
            decision: decision,
            before: before
        ) {
            return .applied(palette: WorkspaceTabColorSettings.resolvedPaletteMap())
        }

        restore(before)
        let restored = snapshot(
            palette: WorkspaceTabColorSettings.resolvedPaletteMap(),
            managers: managers
        )
        if snapshotMatches(restored, expected: before) {
            return .failedRestored(palette: restored.palette)
        }
        return .failedUnrecovered(palette: restored.palette)
    }

    private func snapshot(palette: [String: String], managers: [TabManager]) -> Snapshot {
        var seenWorkspaces: Set<ObjectIdentifier> = []
        var workspaces: [(Workspace, String?)] = []
        var seenGroups: Set<UUID> = []
        var groups: [(TabManager, UUID, String?)] = []
        for manager in managers {
            for workspace in manager.tabs where seenWorkspaces.insert(ObjectIdentifier(workspace)).inserted {
                workspaces.append((workspace, workspace.customColor))
            }
            for group in manager.workspaceGroups where seenGroups.insert(group.id).inserted {
                groups.append((manager, group.id, group.customColor))
            }
        }
        return Snapshot(palette: palette, workspaces: workspaces, groups: groups)
    }

    private func revisionToken(_ snapshot: Snapshot) -> String {
        let palette = snapshot.palette
            .sorted { $0.key < $1.key }
            .map { "p:\($0.key)=\($0.value)" }
        let workspaces = snapshot.workspaces
            .map { "w:\($0.workspace.id.uuidString)=\($0.color ?? "nil")" }
            .sorted()
        let groups = snapshot.groups
            .map { "g:\($0.id.uuidString)=\($0.color ?? "nil")" }
            .sorted()
        return (palette + workspaces + groups).joined(separator: "\n")
    }

    private func mutationMatches(
        palette: [String: String],
        preview: WorkspacePaletteColorEditPreview,
        decision: WorkspacePaletteColorEditDecision,
        before: Snapshot
    ) -> Bool {
        guard WorkspaceTabColorSettings.resolvedPaletteMap() == palette else { return false }
        guard decision == .paletteAndAssignments else { return true }
        for item in before.workspaces where
            WorkspaceTabColorSettings.normalizedHex(item.color ?? "") == preview.oldHex {
            guard WorkspaceTabColorSettings.normalizedHex(item.workspace.customColor ?? "") == preview.newHex else {
                return false
            }
        }
        for item in before.groups where
            WorkspaceTabColorSettings.normalizedHex(item.color ?? "") == preview.oldHex {
            guard let group = item.manager.workspaceGroups.first(where: { $0.id == item.id }),
                  WorkspaceTabColorSettings.normalizedHex(group.customColor ?? "") == preview.newHex else {
                return false
            }
        }
        return true
    }

    private func restore(_ snapshot: Snapshot) {
        WorkspaceTabColorSettings.persistPaletteMap(snapshot.palette)
        for item in snapshot.workspaces {
            item.workspace.setCustomColor(item.color)
        }
        for item in snapshot.groups {
            item.manager.setWorkspaceGroupColor(groupId: item.id, hex: item.color)
        }
    }

    private func snapshotMatches(_ actual: Snapshot, expected: Snapshot) -> Bool {
        guard actual.palette == expected.palette else { return false }
        let expectedWorkspaceColors = Dictionary(
            uniqueKeysWithValues: expected.workspaces.map { ($0.workspace.id, $0.color) }
        )
        let actualWorkspaceColors = Dictionary(
            uniqueKeysWithValues: actual.workspaces.map { ($0.workspace.id, $0.color) }
        )
        let expectedGroupColors = Dictionary(uniqueKeysWithValues: expected.groups.map { ($0.id, $0.color) })
        let actualGroupColors = Dictionary(uniqueKeysWithValues: actual.groups.map { ($0.id, $0.color) })
        return actualWorkspaceColors == expectedWorkspaceColors && actualGroupColors == expectedGroupColors
    }
}
