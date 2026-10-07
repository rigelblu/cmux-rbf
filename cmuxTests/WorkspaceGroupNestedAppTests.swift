import Foundation
import Testing
import CmuxWorkspaces

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Nested workspace groups (#cm-106): the parts of the nested operations that live in `Sources/`.
@MainActor
@Suite("Workspace group nesting, app side", .serialized)
struct WorkspaceGroupNestedAppTests {
    /// A window `w0 | P[p: Q[q]]`: P holds Q. Nested state is built directly; nothing in the app nests a group yet.
    private func nestedManager() throws -> (manager: TabManager, outer: UUID, inner: UUID) {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let ids = manager.tabs.map(\.id)
        let outer = try #require(manager.createWorkspaceGroup(name: "P", childWorkspaceIds: [ids[1]]))
        let inner = try #require(manager.createWorkspaceGroup(name: "Q", childWorkspaceIds: [ids[2]]))
        let index = try #require(manager.workspaceGroups.firstIndex { $0.id == inner })
        manager.workspaceGroups[index].parentGroupId = outer
        manager.workspaces.normalizeWorkspaceGroupContiguity()
        return (manager, outer, inner)
    }

    // MARK: - The two phone refusals

    @Test func phoneDeleteOnAGroupThatHoldsGroupsIsRefusedBeforeAnythingCloses() throws {
        let (manager, outer, _) = try nestedManager()
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previousManager) }
        let tabsBefore = manager.tabs.map(\.id)

        let result = TerminalController.shared.v2MobileWorkspaceGroupAction(params: [
            "group_id": outer.uuidString,
            "action": "delete",
        ])

        guard case .err(let code, let message, _) = result else {
            return #expect(Bool(false), "delete on a group that holds groups should be refused")
        }
        #expect(code == "invalid_request")
        #expect(message == "This group holds other groups. Delete it on the Mac.")
        #expect(manager.tabs.map(\.id) == tabsBefore)
        #expect(manager.workspaceGroups.contains { $0.id == outer })
    }

    @Test func phoneDragOfANestedGroupsHeaderIsRefusedAndATopLevelHeaderIsNot() throws {
        let (manager, outer, inner) = try nestedManager()
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previousManager) }
        let innerHeader = try #require(manager.workspaceGroups.first { $0.id == inner }).anchorWorkspaceId
        let outerHeader = try #require(manager.workspaceGroups.first { $0.id == outer }).anchorWorkspaceId
        let tabsBefore = manager.tabs.map(\.id)

        let nested = TerminalController.shared.v2MobileWorkspaceMove(params: [
            "workspace_id": innerHeader.uuidString,
            "move_group": true,
        ])
        guard case .err(let code, let message, _) = nested else {
            return #expect(Bool(false), "a drag of a nested group's header should be refused")
        }
        #expect(code == "invalid_request")
        #expect(message == "A group inside another group can only be moved on the Mac")
        #expect(manager.tabs.map(\.id) == tabsBefore)

        // The top-level header is not refused for that reason.
        let topLevel = TerminalController.shared.v2MobileWorkspaceMove(params: [
            "workspace_id": outerHeader.uuidString,
            "move_group": true,
        ])
        if case .err(_, let otherMessage, _) = topLevel {
            #expect(otherMessage != "A group inside another group can only be moved on the Mac")
        }
    }

    // MARK: - The restore reads a legal tree

    private func restoreWorkspace(_ id: UUID, groupId: UUID) -> SessionWorkspaceSnapshot {
        SessionWorkspaceSnapshot(
            workspaceId: id,
            processTitle: "w",
            customTitle: nil,
            isPinned: false,
            groupId: groupId,
            currentDirectory: "/tmp/cmux-test",
            focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )
    }

    @Test func aSavedFileWithALoopOfGroupsIsRepairedOnRestoreAndLogsOneLinePerRepair() throws {
        let aId = UUID()
        let bId = UUID()
        let wa = UUID()
        let wb = UUID()
        // A names B as its parent and B names A: a loop.
        let snapshot = SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: [restoreWorkspace(wa, groupId: aId), restoreWorkspace(wb, groupId: bId)],
            workspaceGroups: [
                SessionWorkspaceGroupSnapshot(id: aId, name: "A", isCollapsed: false, anchorWorkspaceId: wa, anchorMemberIndex: 0, parentGroupId: bId),
                SessionWorkspaceGroupSnapshot(id: bId, name: "B", isCollapsed: false, anchorWorkspaceId: wb, anchorMemberIndex: 0, parentGroupId: aId)
            ]
        )
        let manager = TabManager(autoWelcomeIfNeeded: false)
        var logged: [String] = []
        manager.workspaceGroupRepairLog = { logged.append($0) }
        manager.restoreSessionSnapshot(snapshot)

        // The first group in list order is read as top-level, which opens the loop.
        #expect(manager.workspaceGroups.map(\.id) == [aId, bId])
        #expect(manager.workspaceGroups.map(\.parentGroupId) == [nil, aId])
        #expect(logged == ["Repaired loop for group \(aId.uuidString) by clearing parent"])
    }

    @Test func aSavedParentThatNamesNoGroupIsRepairedOnRestoreAndLogsOneLine() throws {
        let groupId = UUID()
        let workspaceId = UUID()
        let ghost = UUID()
        let snapshot = SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: [restoreWorkspace(workspaceId, groupId: groupId)],
            workspaceGroups: [
                SessionWorkspaceGroupSnapshot(id: groupId, name: "A", isCollapsed: false, anchorWorkspaceId: workspaceId, anchorMemberIndex: 0, parentGroupId: ghost)
            ]
        )
        let manager = TabManager(autoWelcomeIfNeeded: false)
        var logged: [String] = []
        manager.workspaceGroupRepairLog = { logged.append($0) }
        manager.restoreSessionSnapshot(snapshot)

        #expect(manager.workspaceGroups.first?.parentGroupId == nil)
        #expect(logged == ["Repaired unknown parent for group \(groupId.uuidString): parent \(ghost.uuidString) not found"])
    }

    @Test func aRestoredNestedWindowEndsInOneNestedBareRepair() throws {
        let g0 = UUID(), g1 = UUID(), g2 = UUID(), g3 = UUID()
        let wa = UUID(), wb = UUID(), wc = UUID()
        // Saved with the list of groups out of the order the runs start in: G2's run (a, c) starts before G1's (b).
        let snapshot = SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: [restoreWorkspace(wa, groupId: g2), restoreWorkspace(wc, groupId: g3), restoreWorkspace(wb, groupId: g1)],
            workspaceGroups: [
                SessionWorkspaceGroupSnapshot(id: g0, name: "G0", isCollapsed: false, anchorIsEmpty: true),
                SessionWorkspaceGroupSnapshot(id: g1, name: "G1", isCollapsed: false, anchorWorkspaceId: wb, anchorMemberIndex: 0),
                SessionWorkspaceGroupSnapshot(id: g2, name: "G2", isCollapsed: false, anchorWorkspaceId: wa, anchorMemberIndex: 0),
                SessionWorkspaceGroupSnapshot(id: g3, name: "G3", isCollapsed: false, anchorWorkspaceId: wc, anchorMemberIndex: 0, parentGroupId: g2)
            ]
        )
        let manager = TabManager(autoWelcomeIfNeeded: false)
        manager.restoreSessionSnapshot(snapshot)

        #expect(manager.tabs.map(\.id) == [wa, wc, wb])
        // G0 keeps its index; the groups with a run follow where their runs start; a child follows its parent.
        #expect(manager.workspaceGroups.map(\.id) == [g0, g2, g3, g1])
    }

    /// v0.31.0 drops the unpinned empty header `G0` on restore; this fork keeps it (the keep rule in `WorkspaceGroupPersistenceRule`).
    /// What this proves is that a window with no nested group is not repaired: the list of groups stays in
    /// the order it was saved in, though the runs start in the other order.
    @Test func aRestoredWindowWithNoNestedGroupKeepsTheUnpinnedEmptyHeaderAndIsNotRepaired() throws {
        let g0 = UUID(), g1 = UUID(), g2 = UUID()
        let wa = UUID(), wb = UUID()
        let snapshot = SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: [restoreWorkspace(wa, groupId: g2), restoreWorkspace(wb, groupId: g1)],
            workspaceGroups: [
                SessionWorkspaceGroupSnapshot(id: g0, name: "G0", isCollapsed: false, anchorIsEmpty: true),
                SessionWorkspaceGroupSnapshot(id: g1, name: "G1", isCollapsed: false, anchorWorkspaceId: wb, anchorMemberIndex: 0),
                SessionWorkspaceGroupSnapshot(id: g2, name: "G2", isCollapsed: false, anchorWorkspaceId: wa, anchorMemberIndex: 0)
            ]
        )
        let manager = TabManager(autoWelcomeIfNeeded: false)
        manager.restoreSessionSnapshot(snapshot)
        #expect(manager.workspaceGroups.map(\.id) == [g0, g1, g2])
    }

    /// The claim "exactly as v0.31.0": no empty header, so the keep rule changes nothing, and no nested group.
    @Test func aRestoredFlatWindowWithNoEmptyHeaderIsLeftExactlyAsV0310RestoresIt() throws {
        let g1 = UUID(), g2 = UUID()
        let wa = UUID(), wb = UUID()
        let snapshot = SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: [restoreWorkspace(wa, groupId: g2), restoreWorkspace(wb, groupId: g1)],
            workspaceGroups: [
                SessionWorkspaceGroupSnapshot(id: g1, name: "G1", isCollapsed: false, anchorWorkspaceId: wb, anchorMemberIndex: 0),
                SessionWorkspaceGroupSnapshot(id: g2, name: "G2", isCollapsed: false, anchorWorkspaceId: wa, anchorMemberIndex: 0)
            ]
        )
        let manager = TabManager(autoWelcomeIfNeeded: false)
        manager.restoreSessionSnapshot(snapshot)
        #expect(manager.tabs.map(\.id) == [wa, wb])
        #expect(manager.workspaceGroups.map(\.id) == [g1, g2])
        #expect(manager.workspaceGroups.allSatisfy { $0.parentGroupId == nil })
    }

    // MARK: - When the Delete Group dialog shows, and with which numbers

    private func confirmation(_ manager: TabManager, _ groupId: UUID) throws -> WorkspaceGroupDeletionConfirmation {
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })
        return try #require(manager.workspaceGrouping.deletionConfirmation(
            groupId: groupId,
            fallbackGroupName: group.name,
            fallbackAnchorWorkspaceId: group.anchorWorkspaceId
        ))
    }

    @Test func aFlatGroupOfTwoMembersAsksAndCountsThree() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        for _ in 0..<2 { manager.addWorkspace(autoWelcomeIfNeeded: false) }
        let ids = manager.tabs.map(\.id)
        let group = try #require(manager.createWorkspaceGroup(name: "F", childWorkspaceIds: [ids[0], ids[1]]))
        let confirmation = try confirmation(manager, group)
        #expect(deleteGroupAsk(isPinned: false, confirmation: confirmation)
            == DeleteGroupAsk(groupName: "F", memberCount: 3, groupsInside: 0))
    }

    @Test func aGroupThatIsOnlyItsOwnWorkspaceAsksOnlyWhenPinned() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let group = try #require(manager.createWorkspaceGroup(name: "Alone", childWorkspaceIds: []))
        let confirmation = try confirmation(manager, group)
        #expect(confirmation.memberCount == 1)
        #expect(deleteGroupAsk(isPinned: false, confirmation: confirmation) == nil)
        #expect(deleteGroupAsk(isPinned: true, confirmation: confirmation)
            == DeleteGroupAsk(groupName: "Alone", memberCount: 1, groupsInside: 0))
    }

    @Test func aGroupThatHoldsGroupsAsksWithTheNumbersOfEveryLevel() throws {
        let (manager, outer, _) = try nestedManager()
        let confirmation = try confirmation(manager, outer)
        let ask = try #require(deleteGroupAsk(isPinned: false, confirmation: confirmation))
        // P's own workspace, P's member, Q's own workspace and Q's member.
        #expect(ask == DeleteGroupAsk(groupName: "P", memberCount: 4, groupsInside: 1))
        #expect(
            deleteMessageForGroupsInside(groupName: ask.groupName, inside: ask.groupsInside, workspaces: ask.memberCount)
                == "Delete the group \u{201C}P\u{201D}, the group inside it, and close their 4 workspaces?"
        )
    }

    @Test func aGroupThatHoldsOnlyAnEmptyGroupStillAsks() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let outer = try #require(manager.createWorkspaceGroup(name: "P", childWorkspaceIds: []))
        let innerId = UUID()
        manager.workspaceGroups.append(WorkspaceGroup(
            id: innerId,
            name: "Q",
            isCollapsed: false,
            isPinned: false,
            anchor: .empty(innerId),
            customColor: nil,
            iconSymbol: nil,
            parentGroupId: outer
        ))
        let confirmation = try confirmation(manager, outer)
        #expect(confirmation.containedWorkspaceCount == 0)
        #expect(deleteGroupAsk(isPinned: false, confirmation: confirmation)
            == DeleteGroupAsk(groupName: "P", memberCount: 1, groupsInside: 1))
    }

    // MARK: - The delete messages for a group that holds groups

    @Test func theDeleteMessageForAGroupThatHoldsGroupsFollowsTheTable() {
        func message(_ inside: Int, _ workspaces: Int) -> String {
            deleteMessageForGroupsInside(groupName: "Area", inside: inside, workspaces: workspaces)
        }
        let open = "Delete the group \u{201C}Area\u{201D}"
        #expect(message(1, 0) == "\(open) and the group inside it?")
        #expect(message(1, 1) == "\(open), the group inside it, and close their workspace?")
        #expect(message(1, 4) == "\(open), the group inside it, and close their 4 workspaces?")
        #expect(message(3, 0) == "\(open) and the 3 groups inside it?")
        #expect(message(3, 1) == "\(open), the 3 groups inside it, and close their workspace?")
        #expect(message(3, 4) == "\(open), the 3 groups inside it, and close their 4 workspaces?")
    }

    // MARK: - Move to Window

    /// `D[c: N[n], f, M[m]]`: `D` holds a workspace `f` and two groups, and `N` stands above `f`. Built through the
    /// entrances the app has: groups made, moved into `D`, and `N` brought up with Move to Top.
    private func detachFixture() throws -> (manager: TabManager, c: UUID, f: UUID, n: UUID, m: UUID) {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        for _ in 0..<2 { manager.addWorkspace(autoWelcomeIfNeeded: false) }
        let ids = manager.tabs.map(\.id)
        let d = try #require(manager.createWorkspaceGroup(name: "D", childWorkspaceIds: [ids[1]]))
        let n = try #require(manager.createWorkspaceGroup(name: "N", childWorkspaceIds: []))
        let m = try #require(manager.createWorkspaceGroup(name: "M", childWorkspaceIds: []))
        #expect(manager.moveWorkspaceGroup(groupId: n, intoParent: d) == .moved)
        #expect(manager.moveWorkspaceGroup(groupId: m, intoParent: d) == .moved)
        let c = try #require(manager.workspaceGroupAnchor(for: d)).id
        let nAnchor = try #require(manager.workspaceGroupAnchor(for: n)).id
        let mAnchor = try #require(manager.workspaceGroupAnchor(for: m)).id
        manager.moveTabToTop(nAnchor)
        return (manager, c, ids[1], nAnchor, mAnchor)
    }

    @Test func movingTheHeaderWorkspaceToAnotherWindowNamesTheRowsLeftBehindThatChangedPlaceInANestedWindow() throws {
        let (manager, c, f, n, _) = try detachFixture()
        #expect(manager.workspaces.hasNestedWorkspaceGroup)
        // The detached workspace is the selected one, so the window has to move the selection before anyone hears of the order.
        manager.selectWorkspace(try #require(manager.tabs.first { $0.id == c }))
        let orderBefore = manager.tabs.map(\.id)
        var notices: [[UUID]] = []
        var selectionWasInTheWindowAtTheNotice: [Bool] = []
        let token = NotificationCenter.default.addObserver(forName: .workspaceOrderDidChange, object: manager, queue: nil) { notification in
            notices.append(notification.userInfo?[WorkspaceOrderChangeNotificationKey.movedWorkspaceIds] as? [UUID] ?? [])
            selectionWasInTheWindowAtTheNotice.append(manager.tabs.contains { $0.id == manager.selectedTabId })
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let detached = try #require(manager.detachWorkspace(tabId: c))
        #expect(detached.id == c)
        let orderAfter = manager.tabs.map(\.id)
        let left = orderBefore.filter { $0 != c }
        #expect(orderAfter != left, "the rows left behind changed order")
        #expect(notices == [[f, n]], "one notice, naming exactly the rows that changed place, in tabs order")
        #expect(selectionWasInTheWindowAtTheNotice == [true], "at the notice the selection names a workspace that is in the window")
    }

    /// A flat window in which a detach does reorder the rows left: pinned group `D*` beside `G[g: w1*, w2]`; detaching
    /// `g` dissolves `G` and its pinned member rises into the pinned tier.
    @Test func movingAWorkspaceToAnotherWindowFromAFlatWindowThatReordersTheRowsLeftSendsNoNotice() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        for _ in 0..<4 { manager.addWorkspace(autoWelcomeIfNeeded: false) }
        let ids = manager.tabs.map(\.id)
        let pinnedGroup = try #require(manager.createWorkspaceGroup(name: "D", childWorkspaceIds: [ids[3]]))
        manager.toggleWorkspaceGroupPinned(groupId: pinnedGroup)
        let group = try #require(manager.createWorkspaceGroup(name: "G", childWorkspaceIds: [ids[1], ids[2]]))
        _ = manager.setPinned(workspaceIds: [ids[1]], pinned: true)
        let header = try #require(manager.workspaceGroupAnchor(for: group)).id
        #expect(!manager.workspaces.hasNestedWorkspaceGroup)
        let orderBefore = manager.tabs.map(\.id)
        var notices = 0
        let token = NotificationCenter.default.addObserver(forName: .workspaceOrderDidChange, object: manager, queue: nil) { _ in notices += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        _ = try #require(manager.detachWorkspace(tabId: header))
        #expect(manager.tabs.map(\.id) != orderBefore.filter { $0 != header }, "the rows left behind changed order")
        #expect(notices == 0, "a flat window sends nothing, as v0.31.0 does")
    }
}
