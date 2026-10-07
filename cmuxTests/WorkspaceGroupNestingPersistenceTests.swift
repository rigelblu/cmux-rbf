import Foundation
import Testing
import SwiftUI

import CmuxFoundation
import CmuxSettings
import CmuxWorkspaces

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Workspace group nesting persistence", .serialized)
struct WorkspaceGroupNestingPersistenceTests {

    private func makeTabManager() -> TabManager {
        let suiteName = "cmux.workspace-group-nesting-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            settings: UserDefaultsSettingsClient(defaults: defaults),
            closeTabWarningDefaults: defaults
        )
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        return manager
    }

    private func workspaceSnapshot(
        id: UUID,
        title: String,
        groupId: UUID?,
        directory: String = "/tmp/cmux-test",
        isTitled: Bool = true
    ) -> SessionWorkspaceSnapshot {
        SessionWorkspaceSnapshot(
            workspaceId: id,
            processTitle: title,
            customTitle: isTitled ? title : nil,
            isPinned: false,
            groupId: groupId,
            currentDirectory: directory,
            focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )
    }

    // Scenario 41: The saved file round-trips with a 5-level hierarchy,
    // a parent with no workspace of its own holding groups, and an unpinned empty header.
    @Test func sessionSnapshotEncodesAndDecodesFiveLevelHierarchyWithEmptyHeader() throws {
        let g1Id = UUID()
        let g2Id = UUID()
        let g3Id = UUID()
        let g4Id = UUID()
        let g5Id = UUID()
        let gEmptyId = UUID()

        let w1Id = UUID()
        let w2Id = UUID()
        let w4Id = UUID()
        let w5Id = UUID()
        let wLooseId = UUID()

        let initialSnapshot = SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: [
                workspaceSnapshot(id: w1Id, title: "w1", groupId: g1Id),
                workspaceSnapshot(id: w2Id, title: "w2", groupId: g2Id),
                workspaceSnapshot(id: w4Id, title: "w4", groupId: g4Id),
                workspaceSnapshot(id: w5Id, title: "w5", groupId: g5Id),
                workspaceSnapshot(id: wLooseId, title: "loose", groupId: nil)
            ],
            workspaceGroups: [
                SessionWorkspaceGroupSnapshot(
                    id: g1Id,
                    name: "G1",
                    isCollapsed: false,
                    anchorWorkspaceId: w1Id,
                    anchorMemberIndex: 0,
                    anchorIsEmpty: false,
                    isPinned: false,
                    parentGroupId: nil
                ),
                SessionWorkspaceGroupSnapshot(
                    id: g2Id,
                    name: "G2",
                    isCollapsed: false,
                    anchorWorkspaceId: w2Id,
                    anchorMemberIndex: 0,
                    anchorIsEmpty: false,
                    isPinned: false,
                    parentGroupId: g1Id
                ),
                SessionWorkspaceGroupSnapshot(
                    id: g3Id,
                    name: "G3",
                    isCollapsed: false,
                    anchorWorkspaceId: nil,
                    anchorMemberIndex: nil,
                    anchorIsEmpty: true,
                    isPinned: false,
                    parentGroupId: g2Id
                ),
                SessionWorkspaceGroupSnapshot(
                    id: g4Id,
                    name: "G4",
                    isCollapsed: true,
                    anchorWorkspaceId: w4Id,
                    anchorMemberIndex: 0,
                    anchorIsEmpty: false,
                    isPinned: false,
                    parentGroupId: g3Id
                ),
                SessionWorkspaceGroupSnapshot(
                    id: g5Id,
                    name: "G5",
                    isCollapsed: false,
                    anchorWorkspaceId: w5Id,
                    anchorMemberIndex: 0,
                    anchorIsEmpty: false,
                    isPinned: true,
                    parentGroupId: g4Id
                ),
                SessionWorkspaceGroupSnapshot(
                    id: gEmptyId,
                    name: "GEmpty",
                    isCollapsed: false,
                    anchorWorkspaceId: nil,
                    anchorMemberIndex: nil,
                    anchorIsEmpty: true,
                    isPinned: false,
                    parentGroupId: nil
                )
            ]
        )

        let manager1 = makeTabManager()
        manager1.restoreSessionSnapshot(initialSnapshot)

        let snapshot = manager1.sessionSnapshot(includeScrollback: false)
        let data = try JSONEncoder().encode(snapshot)
        let decoder = JSONDecoder()
        let decodedSnapshot = try decoder.decode(SessionTabManagerSnapshot.self, from: data)

        let manager2 = makeTabManager()
        manager2.restoreSessionSnapshot(decodedSnapshot)

        #expect(manager2.workspaceGroups.count == manager1.workspaceGroups.count)
        for (gA, gB) in zip(manager1.workspaceGroups, manager2.workspaceGroups) {
            #expect(gA.id == gB.id)
            #expect(gA.name == gB.name)
            #expect(gA.parentGroupId == gB.parentGroupId)
            #expect(gA.isCollapsed == gB.isCollapsed)
            #expect(gA.isPinned == gB.isPinned)
            #expect(gA.isEmpty == gB.isEmpty)
        }

        #expect(manager2.tabs.map(\.id) == manager1.tabs.map(\.id))
        #expect(manager2.tabs.map(\.groupId) == manager1.tabs.map(\.groupId))

        let rG1 = try #require(manager2.workspaceGroups.first { $0.id == g1Id })
        let rG2 = try #require(manager2.workspaceGroups.first { $0.id == g2Id })
        let rG3 = try #require(manager2.workspaceGroups.first { $0.id == g3Id })
        let rG4 = try #require(manager2.workspaceGroups.first { $0.id == g4Id })
        let rG5 = try #require(manager2.workspaceGroups.first { $0.id == g5Id })
        let rGEmpty = try #require(manager2.workspaceGroups.first { $0.id == gEmptyId })

        #expect(rG1.parentGroupId == nil)
        #expect(rG2.parentGroupId == g1Id)
        #expect(rG3.parentGroupId == g2Id)
        #expect(rG3.isEmpty == true)
        #expect(rG4.parentGroupId == g3Id)
        #expect(rG4.isCollapsed == true)
        #expect(rG5.parentGroupId == g4Id)
        #expect(rG5.isPinned == true)
        #expect(rGEmpty.parentGroupId == nil)
        #expect(rGEmpty.isPinned == false)
        #expect(rGEmpty.isEmpty == true)
    }

    // The bytes come from the real encoder, so the fixture cannot drift from the decoder;
    // the only hand edit is stripping the `parentGroupId` keys a pre-nesting file never wrote.
    @Test func legacySnapshotWithNoParentGroupIdRestoresAsFlatWindow() throws {
        let g1Id = UUID()
        let g2Id = UUID()
        let w1Id = UUID()
        let w2Id = UUID()

        let nested = SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: [
                workspaceSnapshot(id: w1Id, title: "w1", groupId: g1Id),
                workspaceSnapshot(id: w2Id, title: "w2", groupId: g2Id)
            ],
            workspaceGroups: [
                SessionWorkspaceGroupSnapshot(
                    id: g1Id,
                    name: "Legacy Group 1",
                    isCollapsed: false,
                    anchorWorkspaceId: w1Id,
                    anchorMemberIndex: 0,
                    parentGroupId: nil
                ),
                SessionWorkspaceGroupSnapshot(
                    id: g2Id,
                    name: "Legacy Group 2",
                    isCollapsed: false,
                    anchorWorkspaceId: w2Id,
                    anchorMemberIndex: 0,
                    parentGroupId: g1Id
                )
            ]
        )
        let encoded = try JSONEncoder().encode(nested)
        // Control: the encoder does write the key for a nested group, so stripping it changes the file.
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"parentGroupId\":\"\(g1Id.uuidString)\""))

        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let groups = try #require(object["workspaceGroups"] as? [[String: Any]])
        object["workspaceGroups"] = groups.map { group -> [String: Any] in
            var copy = group
            copy.removeValue(forKey: "parentGroupId")
            return copy
        }
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        #expect(!String(decoding: legacyData, as: UTF8.self).contains("parentGroupId"))

        let decoded = try JSONDecoder().decode(SessionTabManagerSnapshot.self, from: legacyData)
        let manager = makeTabManager()
        manager.restoreSessionSnapshot(decoded)

        #expect(manager.workspaceGroups.map(\.id) == [g1Id, g2Id])
        #expect(manager.workspaceGroups.allSatisfy { $0.parentGroupId == nil })
        #expect(manager.tabs.map(\.id) == [w1Id, w2Id])
        #expect(manager.tabs.map(\.groupId) == [g1Id, g2Id])
    }

    // A parent id that names no group is not restored: the group comes back at the top level.
    @Test func restoreSetsAParentOnlyWhenThatParentWasKept() throws {
        let groupId = UUID()
        let workspaceId = UUID()
        let snapshot = SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: [workspaceSnapshot(id: workspaceId, title: "w", groupId: groupId)],
            workspaceGroups: [
                SessionWorkspaceGroupSnapshot(
                    id: groupId,
                    name: "A",
                    isCollapsed: false,
                    anchorWorkspaceId: workspaceId,
                    anchorMemberIndex: 0,
                    parentGroupId: UUID()
                )
            ]
        )
        let manager = makeTabManager()
        manager.restoreSessionSnapshot(snapshot)

        #expect(manager.workspaceGroups.map(\.id) == [groupId])
        #expect(manager.workspaceGroups.first?.parentGroupId == nil)
    }

    @Test func changingOnlyParentGroupIdChangesAutosaveFingerprint() throws {
        let manager = makeTabManager()
        let w1 = manager.tabs[0].id
        let g1Id = try #require(manager.createWorkspaceGroup(name: "Group 1", childWorkspaceIds: [w1]))
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let w2 = manager.tabs.last!.id
        let g2Id = try #require(manager.createWorkspaceGroup(name: "Group 2", childWorkspaceIds: [w2]))

        let baselineFingerprint = manager.sessionAutosaveFingerprint()
        // Control: with nothing changed, two fingerprints are equal, so a difference below is the parent id.
        #expect(manager.sessionAutosaveFingerprint() == baselineFingerprint)

        let g2Index = try #require(manager.workspaceGroups.firstIndex { $0.id == g2Id })
        manager.workspaceGroups[g2Index].parentGroupId = g1Id

        let modifiedFingerprint = manager.sessionAutosaveFingerprint()
        #expect(modifiedFingerprint != baselineFingerprint)
    }

    private var crashDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/cmux/crash", isDirectory: true)
            .path
    }

    private func prunedGroups(
        workspaces: [SessionWorkspaceSnapshot],
        groups: [SessionWorkspaceGroupSnapshot]
    ) -> (groups: [SessionWorkspaceGroupSnapshot]?, removedAny: Bool) {
        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [
                SessionWindowSnapshot(
                    frame: nil,
                    display: nil,
                    tabManager: SessionTabManagerSnapshot(
                        selectedWorkspaceIndex: 0,
                        workspaces: workspaces,
                        workspaceGroups: groups
                    ),
                    sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
                )
            ]
        )
        let pruned = SessionPersistencePolicy.pruningCmuxCrashDiagnosticWindows(from: snapshot)
        return (pruned.snapshot?.windows.first?.tabManager.workspaceGroups, pruned.removedAny)
    }

    // The pruner never removes a workspace that names a group, so a parent loses its own
    // workspace here only when the file lists none for it. The child group is what keeps it.
    @Test func crashDiagnosticPruningKeepsParentWhoseOnlyKeptContentIsChildGroup() {
        let parentGroupId = UUID()
        let childGroupId = UUID()
        let projectWorkspaceId = UUID()

        let result = prunedGroups(
            workspaces: [
                workspaceSnapshot(id: UUID(), title: "crash", groupId: nil, directory: crashDirectory, isTitled: false),
                workspaceSnapshot(id: projectWorkspaceId, title: "project", groupId: childGroupId, directory: "/tmp/cmux-project", isTitled: false)
            ],
            groups: [
                SessionWorkspaceGroupSnapshot(
                    id: parentGroupId,
                    name: "Parent",
                    isCollapsed: false,
                    anchorWorkspaceId: UUID(),
                    anchorMemberIndex: 0,
                    isPinned: false,
                    parentGroupId: nil
                ),
                SessionWorkspaceGroupSnapshot(
                    id: childGroupId,
                    name: "Child",
                    isCollapsed: false,
                    anchorWorkspaceId: projectWorkspaceId,
                    anchorMemberIndex: 0,
                    isPinned: false,
                    parentGroupId: parentGroupId
                )
            ]
        )

        #expect(result.removedAny)
        #expect(result.groups?.map(\.id) == [parentGroupId, childGroupId])
        let parentGroup = result.groups?.first { $0.id == parentGroupId }
        #expect(parentGroup?.anchorIsEmpty == true)
        #expect(parentGroup?.anchorMemberIndex == nil)
        let childGroup = result.groups?.first { $0.id == childGroupId }
        #expect(childGroup?.anchorWorkspaceId == projectWorkspaceId)
        #expect(childGroup?.anchorIsEmpty == nil)
    }

    // v0.31.0 dropped a pinned group that has its own workspace when none of its workspaces
    // are kept; only the restore keeps it. The pruner has the base rule.
    @Test func crashDiagnosticPruningDropsPinnedGroupWithOwnWorkspaceAndNoKeptMember() {
        let pinnedGroupId = UUID()
        let pinnedEmptyGroupId = UUID()
        let emptyHeaderGroupId = UUID()

        let result = prunedGroups(
            workspaces: [
                workspaceSnapshot(id: UUID(), title: "crash", groupId: nil, directory: crashDirectory, isTitled: false),
                workspaceSnapshot(id: UUID(), title: "project", groupId: nil, directory: "/tmp/cmux-project", isTitled: false)
            ],
            groups: [
                SessionWorkspaceGroupSnapshot(
                    id: pinnedGroupId,
                    name: "Pinned with a workspace",
                    isCollapsed: false,
                    anchorWorkspaceId: UUID(),
                    anchorMemberIndex: 0,
                    isPinned: true
                ),
                SessionWorkspaceGroupSnapshot(
                    id: pinnedEmptyGroupId,
                    name: "Pinned empty",
                    isCollapsed: false,
                    anchorIsEmpty: true,
                    isPinned: true
                ),
                SessionWorkspaceGroupSnapshot(
                    id: emptyHeaderGroupId,
                    name: "Unpinned empty",
                    isCollapsed: false,
                    anchorIsEmpty: true,
                    isPinned: false
                )
            ]
        )

        #expect(result.removedAny)
        #expect(result.groups?.map(\.id) == [pinnedEmptyGroupId, emptyHeaderGroupId])
    }
}
