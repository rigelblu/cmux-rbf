import AppKit
import CmuxControlSocket
import CmuxFoundation
import CmuxSettings
import CmuxSidebar
import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// `cm-110.14`: a folded group opens when a workspace he moves gets there, whichever way he moves it (Decisions, the 2026-10-29
// entries on the folds a moved workspace opens and on which moves count). Each test moves a real workspace through one family's
// real call, on a real `TabManager` and `SidebarState` joined the way the app joins them (`SidebarState.installMoveReveal`), and
// reads the folds after. No test selects the moved workspace unless it says so: `.14` adds no selection change.
@MainActor
@Suite("A folded group opens where a moved workspace lands (cm-110.14)", .serialized)
struct WorkspaceMoveRevealTests {
    typealias Nested = SidebarNestedRootStatusTests
    typealias Sidebar = VerticalTabsSidebar

    /// `parked` and `doing`, in the file's order, with a colour each.
    static let doingColor = "#334455"

    /// `done` and `doing`, for the detection test: cmux's own Done is `done`.
    static let doneListSource = ##"{"workspaceStatuses":[{"id":"doing","name":"Doing","extends":"working","color":"#334455"},{"id":"done","name":"Done","extends":"done","color":"#445566"}]}"##

    /// Five entries whose cycle runs e1, e2, e3, e4, e5: a press moves one place up the file, so e1 is last in it.
    static let fiveStatuses = ##"{"workspaceStatuses":[{"id":"e5","name":"E5","extends":"todo","color":"#550005"},{"id":"e4","name":"E4","extends":"todo","color":"#440004"},{"id":"e3","name":"E3","extends":"todo","color":"#330003"},{"id":"e2","name":"E2","extends":"todo","color":"#220002"},{"id":"e1","name":"E1","extends":"todo","color":"#110001"}]}"##

    private let routing = ControlRoutingSelectors(
        hasWindowIDParam: false, windowID: nil, groupID: nil, workspaceID: nil, surfaceID: nil, paneID: nil
    )

    /// One window's manager and sidebar state, registered with the app delegate the status list handle installed.
    @MainActor
    final class Rig {
        let manager: TabManager
        let state = SidebarState()
        let handle: Nested.StatusListHandle
        let delegate: AppDelegate
        private var windowIds: [UUID] = []

        init(handle: Nested.StatusListHandle, manager: TabManager) throws {
            self.handle = handle
            self.manager = manager
            self.delegate = try #require(AppDelegate.shared)
            windowIds.append(delegate.registerMainWindowContextForTesting(tabManager: manager))
            state.installMoveReveal(on: manager)
            _ = state.prepareWorkspaceSections(tabManager: manager)
        }

        /// A second window, with its own sidebar state.
        func addWindow() throws -> (TabManager, SidebarState) {
            let other = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false)
            let otherState = SidebarState()
            windowIds.append(delegate.registerMainWindowContextForTesting(tabManager: other))
            otherState.installMoveReveal(on: other)
            return (other, otherState)
        }

        func finish() {
            for id in windowIds { delegate.unregisterMainWindowContextForTesting(windowId: id) }
            handle.restore()
        }
    }

    private func gate(_ body: @MainActor () async throws -> Void) async throws {
        try await AppContextSerialGate.withExclusiveAppContext { try await body() }
    }

    /// The nested world (`R[N[M]]`, `G`, `Q`, loose `u`, `v`, `p1`) inside a rig.
    private func inNested(list: String? = nil, controls: Bool = true,
                          _ body: (Rig, Nested.World) throws -> Void) async throws {
        try await gate {
            let handle = try Nested.installStatusListHandle(source: list, controls: controls)
            let world = try Nested.World()
            let rig = try Rig(handle: handle, manager: world.manager)
            defer { rig.finish() }
            try body(rig, world)
        }
    }

    /// A flat window: loose `a`, `b`, `d`, and the group `G` holding `c`.
    private func inFlat(controls: Bool = true, _ body: (Rig, [String: Workspace], UUID) throws -> Void) async throws {
        try await gate {
            let handle = try Nested.installStatusListHandle(controls: controls)
            let manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false)
            var ws: [String: Workspace] = [:]
            for key in ["a", "b", "c", "d"] { ws[key] = Workspace() }
            manager.tabs = ["a", "b", "c", "d"].compactMap { ws[$0] }
            let g = try #require(manager.createWorkspaceGroup(name: "G", childWorkspaceIds: [ws["c"]!.id]))
            ws["g"] = try #require(manager.workspaceGroupAnchor(for: g))
            manager.selectWorkspace(ws["a"]!)
            let rig = try Rig(handle: handle, manager: manager)
            defer { rig.finish() }
            try body(rig, ws, g)
        }
    }

    // MARK: Reading and folding

    private func folded(_ rig: Rig, _ id: UUID) -> Bool {
        rig.manager.workspaceGroups.first { $0.id == id }?.isCollapsed ?? false
    }

    private func setFolds(_ rig: Rig, statuses: Set<String> = [], area: Bool = false, workspaces: Bool = false, pinned: Bool = false) {
        var next = rig.state.statusGroups ?? WorkspaceStatusGroupsState()
        next.collapsedStatusIds = statuses
        next.areaCollapsed = area
        next.workspacesCollapsed = workspaces
        next.pinnedCollapsed = pinned
        rig.state.setStatusGroups(next)
    }

    private func statusFolds(_ rig: Rig) -> Set<String> { rig.state.statusGroups?.collapsedStatusIds ?? [] }
    private func areaFolded(_ rig: Rig) -> Bool { rig.state.statusGroups?.areaCollapsed ?? false }
    private func workspacesFolded(_ rig: Rig) -> Bool { rig.state.statusGroups?.workspacesCollapsed ?? false }
    private func pinnedFolded(_ rig: Rig) -> Bool { rig.state.statusGroups?.pinnedCollapsed ?? false }

    private func own(_ workspace: Workspace, _ status: String) throws {
        let list = AppDelegate.statusListInUse
        try #require(workspace.setOwnStatus(try #require(list.entry(id: status)), list: list))
    }

    // MARK: Drops into a workspace group (A1, A2, A5, G1)

    @Test func aDropIntoAFoldedGroupOpensItFlat() async throws {
        try await inFlat { rig, ws, g in
            let m = rig.manager
            m.setWorkspaceGroupCollapsed(groupId: g, isCollapsed: true)
            m.selectWorkspace(ws["a"]!)
            let selected = m.selectedTabId
            let index = try #require(m.tabs.firstIndex { $0.id == ws["c"]!.id })
            m.reorderSidebarWorkspace(tabId: ws["b"]!.id, toIndex: index, isDragOperation: true, explicitGroupId: g)
            try #require(ws["b"]!.groupId == g, "the drag put b into G")
            #expect(!folded(rig, g), "G is folded after the drop; expected open")
            #expect(m.selectedTabId == selected, "a drop changed the selection")
        }
    }

    @Test func aDropIntoAFoldedNestedGroupOpensItAndTheGroupsAbove() async throws {
        try await inNested { rig, world in
            let m = rig.manager
            m.selectWorkspace(world.w("u"))
            for id in [world.r, world.n] { world.fold(id, true) }
            let selected = m.selectedTabId
            let index = try #require(m.tabs.firstIndex { $0.id == world.w("n1").id })
            m.reorderSidebarWorkspace(tabId: world.w("v").id, toIndex: index, isDragOperation: true, explicitGroupId: world.n)
            try #require(world.w("v").groupId == world.n, "the drag put v into N")
            #expect(!folded(rig, world.n) && !folded(rig, world.r), "N folded=\(folded(rig, world.n)) R folded=\(folded(rig, world.r)); expected both open")
            #expect(m.selectedTabId == selected)
        }
    }

    @Test func aMultiSelectionDroppedIntoAFoldedGroupOpensIt() async throws {
        try await inFlat { rig, ws, g in
            let m = rig.manager
            m.setWorkspaceGroupCollapsed(groupId: g, isCollapsed: true)
            m.selectWorkspace(ws["a"]!)
            let index = try #require(m.tabs.firstIndex { $0.id == ws["c"]!.id })
            m.reorderSidebarWorkspaces(tabIds: [ws["b"]!.id, ws["d"]!.id], draggedTabId: ws["b"]!.id, toIndex: index,
                                       isDragOperation: true, explicitGroupId: g)
            try #require(ws["b"]!.groupId == g, "the drag put b into G")
            #expect(!folded(rig, g), "G is folded after the multi-selection drop; expected open")
        }
    }

    // MARK: Drop on a status group (A4, C1 through the same performer)

    @Test func aDropOnAFoldedStatusGroupOpensItAndTheStatusesArea() async throws {
        try await inNested(list: Nested.bothStatuses) { rig, world in
            let m = rig.manager
            m.selectWorkspace(world.w("p1"))
            try own(world.w("v"), "doing")
            setFolds(rig, statuses: ["doing"], area: true)
            let plan = SidebarStatusGroupWorkspaceDropPlan(
                statusId: "doing", placement: .first, setsStatus: true,
                indicator: .init(tabId: SidebarStatusHeaderIdentity.uuid(forStatusId: "doing"), edge: .bottom))
            let performer = StatusGroupDropPerformer(
                statusActions: .app(),
                currentProjection: { Sidebar.currentStatusGroupProjection(tabs: m.tabs, groups: m.workspaceGroups) },
                reorder: { _, _, _, _ in true })
            try #require(performer.perform(plan, dragged: world.w("u"), sourceKind: .workspace), "the drop was refused")
            try #require(world.w("u").todoState.ownStatus?.id == "doing")
            #expect(!statusFolds(rig).contains("doing"), "doing is still folded: \(statusFolds(rig))")
            #expect(!areaFolded(rig), "the Statuses area is still folded")
        }
    }

    // MARK: Move to Group (D1, F6, F7, G3, H4 through addWorkspaceToGroup)

    @Test func moveToGroupOpensTheFoldedGroupFlat() async throws {
        try await inFlat { rig, ws, g in
            let m = rig.manager
            m.setWorkspaceGroupCollapsed(groupId: g, isCollapsed: true)
            m.selectWorkspace(ws["a"]!)
            m.addWorkspaceToGroup(workspaceId: ws["b"]!.id, groupId: g)
            try #require(ws["b"]!.groupId == g)
            #expect(!folded(rig, g), "G is folded after Move to Group; expected open")
            #expect(m.selectedTabId == ws["a"]!.id)
        }
    }

    @Test func moveToGroupOpensTheFoldedGroupsAboveNested() async throws {
        try await inNested { rig, world in
            let m = rig.manager
            m.selectWorkspace(world.w("p1"))
            for id in [world.r, world.n, world.m] { world.fold(id, true) }
            m.addWorkspaceToGroup(workspaceId: world.w("u").id, groupId: world.m)
            try #require(world.w("u").groupId == world.m)
            let open = [world.m, world.n, world.r].map { !folded(rig, $0) }
            #expect(open == [true, true, true], "M, N, R open flags \(open); expected all open")
            #expect(m.selectedTabId == world.w("p1").id)
        }
    }

    @Test func moveToGroupStopsAtAGroupDrawnUnderAStatus() async throws {
        try await inNested(list: Nested.bothStatuses) { rig, world in
            let m = rig.manager
            m.selectWorkspace(world.w("p1"))
            try world.setStatus(world.n, "doing")
            for id in [world.r, world.n, world.m] { world.fold(id, true) }
            setFolds(rig, statuses: ["doing"], area: true)
            m.addWorkspaceToGroup(workspaceId: world.w("u").id, groupId: world.m)
            try #require(world.w("u").groupId == world.m)
            #expect(!folded(rig, world.m) && !folded(rig, world.n), "M and N should open")
            #expect(folded(rig, world.r), "R opened; the walk must stop at N, which is drawn under its status")
            #expect(!statusFolds(rig).contains("doing") && !areaFolded(rig), "doing \(statusFolds(rig)) area \(areaFolded(rig)); the status group and the area should open")
        }
    }

    @Test func moveToGroupOnTwoRowsOpensEachGroup() async throws {
        try await inNested { rig, world in
            let m = rig.manager
            m.selectWorkspace(world.w("p1"))
            world.fold(world.m, true); world.fold(world.q, true)
            m.addWorkspaceToGroup(workspaceId: world.w("u").id, groupId: world.m)
            m.addWorkspaceToGroup(workspaceId: world.w("v").id, groupId: world.q)
            #expect(!folded(rig, world.m) && !folded(rig, world.q), "M folded=\(folded(rig, world.m)) Q folded=\(folded(rig, world.q))")
        }
    }

    // MARK: Remove from Group, Ungroup (D3, F8, B7, F13)

    @Test func removeFromGroupOpensTheParentNested() async throws {
        try await inNested { rig, world in
            let m = rig.manager
            m.selectWorkspace(world.w("u"))
            world.fold(world.n, true); world.fold(world.r, true)
            m.removeWorkspaceFromGroup(workspaceId: world.w("n2").id)
            try #require(world.w("n2").groupId == world.r, "n2 left N for R")
            #expect(!folded(rig, world.r), "R, the new parent, is folded")
        }
    }

    @Test func ungroupOpensTheNewParentAndTheGroupsAboveNested() async throws {
        try await inNested { rig, world in
            let m = rig.manager
            m.selectWorkspace(world.w("u"))
            world.fold(world.n, true); world.fold(world.r, true)
            m.ungroupWorkspaceGroup(groupId: world.m)
            try #require(world.w("m1").groupId == world.n, "m1 went to N")
            #expect(!folded(rig, world.n) && !folded(rig, world.r), "N folded=\(folded(rig, world.n)) R folded=\(folded(rig, world.r)); expected both open")
        }
    }

    // MARK: A new workspace in a group (H1, H2, H3, F10, F11)

    @Test func aNewWorkspaceInAFoldedGroupOpensItAndTheGroupsAbove() async throws {
        try await inNested { rig, world in
            let m = rig.manager
            m.selectWorkspace(world.w("p1"))
            for id in [world.r, world.n, world.m] { world.fold(id, true) }
            let created = try #require(m.createWorkspaceInGroup(groupId: world.m, select: false))
            try #require(created.groupId == world.m)
            let open = [world.m, world.n, world.r].map { !folded(rig, $0) }
            #expect(open == [true, true, true], "M, N, R open flags \(open); expected all open")
            #expect(m.selectedTabId == world.w("p1").id, "a new workspace that is not selected changed the selection")
        }
    }

    @Test func aNewGroupMadeInsideAFoldedGroupOpensTheGroupsAbove() async throws {
        try await inNested { rig, world in
            let m = rig.manager
            m.selectWorkspace(world.w("p1"))
            for id in [world.r, world.n] { world.fold(id, true) }
            let created = try #require(m.createWorkspaceGroup(name: "X", childWorkspaceIds: [world.w("n2").id], selectAnchor: false, collapseSidebarSelection: false))
            try #require(world.w("n2").groupId == created, "n2 moved into the new group")
            try #require(world.group(created).parentGroupId == world.n, "the new group sits inside N")
            #expect(!folded(rig, world.n) && !folded(rig, world.r), "N folded=\(folded(rig, world.n)) R folded=\(folded(rig, world.r)); expected both open")
            #expect(m.selectedTabId == world.w("p1").id)
        }
    }

    @Test func aSelectedNewWorkspaceInAFoldedGroupKeepsBothRevealsOpen() async throws {
        try await inNested { rig, world in
            let m = rig.manager
            m.selectWorkspace(world.w("p1"))
            for id in [world.r, world.n, world.m] { world.fold(id, true) }
            let created = try #require(m.createWorkspaceInGroup(groupId: world.m, select: true))
            try #require(m.selectedTabId == created.id)
            let open = [world.m, world.n, world.r].map { !folded(rig, $0) }
            #expect(open == [true, true, true], "M, N, R open flags \(open)")
        }
    }

    // MARK: A whole group moved keeps its own fold (B1, B3, B4, B5, B6, F12)

    @Test func moveGroupToOpensTheNewParentAndKeepsTheGroupsOwnFold() async throws {
        try await inNested { rig, world in
            let m = rig.manager
            m.selectWorkspace(world.w("u"))
            for id in [world.g, world.n, world.r] { world.fold(id, true) }
            m.moveWorkspaceGroup(groupId: world.g, intoParent: world.n)
            try #require(world.group(world.g).parentGroupId == world.n, "G moved into N")
            #expect(!folded(rig, world.n) && !folded(rig, world.r), "N folded=\(folded(rig, world.n)) R folded=\(folded(rig, world.r)); the parent and the groups above should open")
            #expect(folded(rig, world.g), "G opened; a whole group moved keeps its own fold")
        }
    }

    @Test func aGroupGivenAStatusOpensTheStatusGroupAndAreaAndKeepsItsFold() async throws {
        try await inNested(list: Nested.bothStatuses) { rig, world in
            let m = rig.manager
            m.selectWorkspace(world.w("u"))
            world.fold(world.g, true)
            setFolds(rig, statuses: ["doing"], area: true)
            try world.setStatus(world.g, "doing")
            try #require(world.group(world.g).statusId == "doing")
            #expect(!statusFolds(rig).contains("doing") && !areaFolded(rig), "doing \(statusFolds(rig)) area \(areaFolded(rig)); expected both open")
            #expect(folded(rig, world.g), "G opened; a whole group moved keeps its own fold")
        }
    }

    @Test func aGroupColoredWithAListedStatusColorOpensTheStatusGroup() async throws {
        try await inNested(list: Nested.bothStatuses) { rig, world in
            let m = rig.manager
            m.selectWorkspace(world.w("u"))
            world.fold(world.g, true)
            setFolds(rig, statuses: ["doing"], area: true)
            m.setWorkspaceGroupColor(groupId: world.g, hex: Self.doingColor)
            try #require(world.group(world.g).statusId == "doing", "the color picked the status")
            #expect(!statusFolds(rig).contains("doing") && !areaFolded(rig), "doing \(statusFolds(rig)) area \(areaFolded(rig))")
            #expect(folded(rig, world.g))
        }
    }

    @Test func theDoneKeyOnAGroupsOwnWorkspaceOpensItsStatusGroupAndKeepsItsFold() async throws {
        try await inNested(list: Nested.bothStatuses) { rig, world in
            let m = rig.manager
            m.selectWorkspace(world.w("g"))
            world.fold(world.g, true)
            setFolds(rig, statuses: ["doing"], area: true)
            let actions = WorkspaceGroupStatusUIActions(tabManager: m,
                writer: .init(list: AppDelegate.statusListInUse, resolveColor: { $0 }), controlsEnabled: true)
            try #require(actions.applySelected(.status(id: "doing")))
            try #require(world.group(world.g).statusId == "doing")
            #expect(!statusFolds(rig).contains("doing") && !areaFolded(rig), "doing \(statusFolds(rig)) area \(areaFolded(rig))")
            #expect(folded(rig, world.g))
        }
    }

    @Test func aGroupPinnedOpensPinnedAndKeepsItsFold() async throws {
        try await inNested { rig, world in
            let m = rig.manager
            m.selectWorkspace(world.w("u"))
            world.fold(world.g, true)
            setFolds(rig, pinned: true)
            m.setWorkspaceGroupPinned(groupId: world.g, isPinned: true)
            try #require(world.group(world.g).isPinned)
            #expect(!pinnedFolded(rig), "Pinned is still folded")
            #expect(folded(rig, world.g))
        }
    }

    // MARK: A workspace status (D4, D5, E1, E2, E5, F1, F3)

    @Test func aStatusFromTheMenuOnARowThatIsNotSelectedOpensItsGroupAndTheArea() async throws {
        try await inNested(list: Nested.bothStatuses) { rig, world in
            let m = rig.manager
            m.selectWorkspace(world.w("v"))
            setFolds(rig, statuses: ["doing"], area: true)
            WorkspaceTodoActions.applyStatusOverride(.status(id: "doing"), to: [world.w("u")])
            try #require(world.w("u").todoState.ownStatus?.id == "doing")
            #expect(!statusFolds(rig).contains("doing") && !areaFolded(rig), "doing \(statusFolds(rig)) area \(areaFolded(rig)); expected both open")
            #expect(m.selectedTabId == world.w("v").id)
        }
    }

    @Test func aStatusFromTheSocketOnARowThatIsNotSelectedOpensItsGroupAndTheArea() async throws {
        try await inNested(list: Nested.bothStatuses) { rig, world in
            let m = rig.manager
            m.selectWorkspace(world.w("v"))
            setFolds(rig, statuses: ["doing"], area: true)
            let result = TerminalController.shared.controlSetWorkspaceTaskStatus(
                routing: routing, workspaceID: world.w("u").id, statusRaw: "doing")
            guard case .resolved = result else { Issue.record("the set did not resolve: \(result)"); return }
            #expect(!statusFolds(rig).contains("doing") && !areaFolded(rig), "doing \(statusFolds(rig)) area \(areaFolded(rig))")
            #expect(m.selectedTabId == world.w("v").id)
        }
    }

    @Test func aStatusFromThePhoneOpensItsGroup() async throws {
        try await inNested(list: Nested.bothStatuses) { rig, world in
            rig.manager.selectWorkspace(world.w("v"))
            setFolds(rig, statuses: ["doing"], area: true)
            let result = WorkspaceStatusOrigin.$current.withValue(.phone) {
                TerminalController.shared.controlSetWorkspaceTaskStatus(routing: routing, workspaceID: world.w("u").id, statusRaw: "doing")
            }
            guard case .resolved = result else { Issue.record("the set did not resolve: \(result)"); return }
            #expect(!statusFolds(rig).contains("doing") && !areaFolded(rig), "doing \(statusFolds(rig)) area \(areaFolded(rig))")
        }
    }

    @Test(arguments: ["menu", "socket"])
    func noneOpensTheWorkspacesSectionForARowThatLeavesAStatusGroup(_ how: String) async throws {
        try await inNested(list: Nested.bothStatuses) { rig, world in
            rig.manager.selectWorkspace(world.w("v"))
            try own(world.w("u"), "doing")
            setFolds(rig, workspaces: true)
            try #require(rig.state.statusGroups?.sectionOrder != nil, "the sections are resolved")
            if how == "menu" {
                WorkspaceTodoActions.hideStatus(for: [world.w("u")])
            } else {
                _ = TerminalController.shared.controlSetWorkspaceTaskStatus(routing: routing, workspaceID: world.w("u").id, statusRaw: "none")
            }
            try #require(world.w("u").todoState.statusHidden && world.w("u").todoState.ownStatus == nil)
            #expect(!workspacesFolded(rig), "the Workspaces section is still folded")
        }
    }

    @Test func aStatusOnAPinnedWorkspaceChangesNoFold() async throws {
        try await inNested(list: Nested.bothStatuses) { rig, world in
            let m = rig.manager
            m.selectWorkspace(world.w("v"))
            m.setPinned(world.w("u"), pinned: true)
            setFolds(rig, statuses: ["doing"], area: true, workspaces: true, pinned: true)
            let before = rig.state.statusGroups
            WorkspaceTodoActions.applyStatusOverride(.status(id: "doing"), to: [world.w("u")])
            try #require(world.w("u").todoState.ownStatus?.id == "doing")
            #expect(rig.state.statusGroups == before, "the folds changed for a row that did not move")
        }
    }

    @Test func aStatusOnAWorkspaceInsideAWorkspaceGroupChangesNoFold() async throws {
        try await inNested(list: Nested.bothStatuses) { rig, world in
            let m = rig.manager
            m.selectWorkspace(world.w("v"))
            for id in [world.r, world.n] { world.fold(id, true) }
            setFolds(rig, statuses: ["doing"], area: true, workspaces: true, pinned: true)
            let before = rig.state.statusGroups
            WorkspaceTodoActions.applyStatusOverride(.status(id: "doing"), to: [world.w("n1")])
            try #require(world.w("n1").todoState.ownStatus?.id == "doing")
            #expect(rig.state.statusGroups == before, "a status on a grouped row changed the status side")
            #expect(folded(rig, world.r) && folded(rig, world.n), "a status on a grouped row opened a group")
        }
    }

    // MARK: A color (D6, E6, F4)

    @Test func aColorOnARowWithAListedStatusChangesNoFold() async throws {
        try await inNested(list: Nested.bothStatuses) { rig, world in
            rig.manager.selectWorkspace(world.w("v"))
            try own(world.w("u"), "doing")
            setFolds(rig, statuses: ["doing"], area: true, workspaces: true)
            rig.state.toggleColorSection(hex: "#AA5500")
            let before = rig.state.statusGroups
            let colorsBefore = rig.state.collapsedColorSectionHexes
            rig.manager.applyWorkspaceColor("#AA5500", toWorkspaceIds: [world.w("u").id])
            try #require(world.w("u").todoState.ownStatus?.id == "doing", "the hand-set status keeps the row in its status group")
            #expect(rig.state.statusGroups == before, "a color on a row that stays in its status group changed the status side")
            #expect(rig.state.collapsedColorSectionHexes == colorsBefore, "a color group opened for a row drawn in a status group")
        }
    }

    @Test func aColorOpensTheColorGroupItLandsIn() async throws {
        try await inNested { rig, world in
            rig.manager.selectWorkspace(world.w("v"))
            rig.state.toggleColorSection(hex: "#AA5500")
            try #require(rig.state.collapsedColorSectionHexes.contains("#AA5500"), "the color group is folded")
            rig.manager.applyWorkspaceColor("#AA5500", toWorkspaceIds: [world.w("u").id])
            #expect(!rig.state.collapsedColorSectionHexes.contains("#AA5500"), "the color group is still folded")
        }
    }

    @Test func aListedStatusColorOpensTheStatusGroupItPutsTheRowIn() async throws {
        try await inNested(list: Nested.bothStatuses) { rig, world in
            rig.manager.selectWorkspace(world.w("v"))
            WorkspaceTodoActions.applyStatusOverride(.auto, to: [world.w("u")])
            setFolds(rig, statuses: ["doing"], area: true)
            rig.manager.setTabColor(tabId: world.w("u").id, color: Self.doingColor)
            #expect(!statusFolds(rig).contains("doing") && !areaFolded(rig), "doing \(statusFolds(rig)) area \(areaFolded(rig))")
        }
    }

    // MARK: Pin (D7, E6, F5)

    @Test func pinOpensPinnedAndUnpinOpensTheWorkspacesSection() async throws {
        try await inNested { rig, world in
            let m = rig.manager
            m.selectWorkspace(world.w("v"))
            setFolds(rig, pinned: true)
            m.setPinned(world.w("u"), pinned: true)
            try #require(world.w("u").isPinned)
            #expect(!pinnedFolded(rig), "Pinned is still folded after a pin")
            setFolds(rig, workspaces: true)
            m.setPinned(world.w("u"), pinned: false)
            #expect(!workspacesFolded(rig), "Workspaces is still folded after an unpin")
        }
    }

    // MARK: Another window (A8, D8, F14, G4)

    @Test func rowsMovedToAnotherWindowOpenTheirFoldsThereForEveryRow() async throws {
        try await inNested(list: Nested.bothStatuses) { rig, world in
            let (other, otherState) = try rig.addWindow()
            _ = otherState.prepareWorkspaceSections(tabManager: other)
            var folds = otherState.statusGroups ?? WorkspaceStatusGroupsState()
            folds.collapsedStatusIds = ["doing"]; folds.workspacesCollapsed = true
            otherState.setStatusGroups(folds)
            let before = rig.state.statusGroups
            try own(world.w("u"), "doing")
            let windowId = try #require(rig.delegate.windowId(for: other))
            try #require(rig.delegate.moveWorkspaceToWindow(workspaceId: world.w("u").id, windowId: windowId, focus: false))
            try #require(rig.delegate.moveWorkspaceToWindow(workspaceId: world.w("v").id, windowId: windowId, focus: false))
            try #require(other.tabs.contains { $0.id == world.w("u").id } && other.tabs.contains { $0.id == world.w("v").id })
            #expect(!(otherState.statusGroups?.collapsedStatusIds.contains("doing") ?? true), "doing is still folded in the window u landed in")
            #expect(!(otherState.statusGroups?.workspacesCollapsed ?? true), "Workspaces is still folded in the window v landed in")
            #expect(rig.state.statusGroups == before, "the window the rows left changed its folds")
        }
    }

    // MARK: The cycle key (E4, F2, F3)

    @Test func theCycleKeyOpensEachGroupItMovesIntoAndFoldsBackThePreviousPressesGroupOnly() async throws {
        try await inNested(list: Self.fiveStatuses) { rig, world in
            rig.manager.selectWorkspace(world.w("v"))
            let u = world.w("u")
            try own(u, "e1")
            setFolds(rig, statuses: ["e2", "e4", "e5"])
            @MainActor func press() { WorkspaceTodoActions.cycleStatus(for: u) }
            press()
            try #require(u.todoState.ownStatus?.id == "e2", "press 1 moved u to e2")
            #expect(statusFolds(rig) == ["e4", "e5"], "after press 1 the folded groups are \(statusFolds(rig)); expected e4, e5 (e2 opened)")
            press()
            try #require(u.todoState.ownStatus?.id == "e3")
            #expect(statusFolds(rig) == ["e2", "e4", "e5"], "after press 2 the folded groups are \(statusFolds(rig)); expected e2 folded back, e3 open")
            press()
            try #require(u.todoState.ownStatus?.id == "e4")
            #expect(statusFolds(rig) == ["e2", "e5"], "after press 3 the folded groups are \(statusFolds(rig)); e3 was open before press 1 and stays open")
            press()
            try #require(u.todoState.ownStatus?.id == "e5")
            #expect(statusFolds(rig) == ["e2", "e4"], "after press 4 the folded groups are \(statusFolds(rig)); expected e4 folded back, e5 open")
        }
    }

    @Test func aGroupHeOpenedHimselfIsNeverFoldedBackByAPress() async throws {
        try await inNested(list: Self.fiveStatuses) { rig, world in
            rig.manager.selectWorkspace(world.w("v"))
            let u = world.w("u")
            try own(u, "e1")
            setFolds(rig, statuses: ["e2", "e3"])
            WorkspaceTodoActions.cycleStatus(for: u)
            rig.state.toggleStatusGroup(id: "e2")
            rig.state.toggleStatusGroup(id: "e2")
            try #require(!statusFolds(rig).contains("e2"), "he opened e2 by hand")
            WorkspaceTodoActions.cycleStatus(for: u)
            try #require(u.todoState.ownStatus?.id == "e3")
            #expect(!statusFolds(rig).contains("e2"), "press 2 folded back e2, which he had opened himself")
        }
    }

    @Test func theCycleKeyOpensAFoldedStatusesAreaAndNeverFoldsItBack() async throws {
        try await inNested(list: Self.fiveStatuses) { rig, world in
            rig.manager.selectWorkspace(world.w("v"))
            let u = world.w("u")
            try own(u, "e1")
            setFolds(rig, statuses: ["e2", "e3"], area: true)
            WorkspaceTodoActions.cycleStatus(for: u)
            #expect(!areaFolded(rig) && !statusFolds(rig).contains("e2"), "area folded=\(areaFolded(rig)) folds \(statusFolds(rig)); press 1 should open the area and e2")
            WorkspaceTodoActions.cycleStatus(for: u)
            #expect(!areaFolded(rig), "press 2 folded the Statuses area back")
            #expect(!statusFolds(rig).contains("e3") && statusFolds(rig).contains("e2"), "folds \(statusFolds(rig)); expected e3 open and e2 folded back")
        }
    }

    @Test func theCycleKeyOnAGroupsOwnWorkspaceFollowsTheSameRuleAndKeepsTheGroupsFold() async throws {
        try await inNested(list: Self.fiveStatuses) { rig, world in
            let m = rig.manager
            m.selectWorkspace(world.w("g"))
            try world.setStatus(world.g, "e1")
            world.fold(world.g, true)
            setFolds(rig, statuses: ["e2", "e3"])
            let actions = WorkspaceGroupStatusUIActions(tabManager: m,
                writer: .init(list: AppDelegate.statusListInUse, resolveColor: { $0 }), controlsEnabled: true)
            try #require(actions.cycleSelected())
            try #require(world.group(world.g).statusId == "e2")
            #expect(!statusFolds(rig).contains("e2"), "press 1 left e2 folded: \(statusFolds(rig))")
            try #require(actions.cycleSelected())
            try #require(world.group(world.g).statusId == "e3")
            #expect(statusFolds(rig) == ["e2"], "after press 2 the folded groups are \(statusFolds(rig)); expected e2 folded back, e3 open")
            #expect(folded(rig, world.g), "the group's own fold changed")
        }
    }

    @Test func theCycleFromTheSocketOpensItsGroupAndLeavesTheSelection() async throws {
        try await inNested(list: Self.fiveStatuses) { rig, world in
            let m = rig.manager
            m.selectWorkspace(world.w("v"))
            try own(world.w("u"), "e1")
            setFolds(rig, statuses: ["e2"])
            let result = TerminalController.shared.controlCycleWorkspaceTaskStatus(routing: routing, workspaceID: world.w("u").id)
            guard case .resolved = result else { Issue.record("the cycle did not resolve: \(result)"); return }
            #expect(!statusFolds(rig).contains("e2"), "the socket's cycle left e2 folded")
            #expect(m.selectedTabId == world.w("v").id, "a cycle press changed the selection")
        }
    }

    // MARK: With the status controls off

    @Test func withTheControlsOffAMoveStillOpensAFoldedWorkspaceGroupAndColorGroup() async throws {
        try await inNested(controls: false) { rig, world in
            let m = rig.manager
            m.selectWorkspace(world.w("p1"))
            for id in [world.r, world.n, world.m] { world.fold(id, true) }
            rig.state.toggleColorSection(hex: "#AA5500")
            m.addWorkspaceToGroup(workspaceId: world.w("u").id, groupId: world.m)
            m.applyWorkspaceColor("#AA5500", toWorkspaceIds: [world.w("v").id])
            let open = [world.m, world.n, world.r].map { !folded(rig, $0) }
            #expect(open == [true, true, true], "M, N, R open flags \(open)")
            #expect(!rig.state.collapsedColorSectionHexes.contains("#AA5500"), "the color group is still folded")
        }
    }

    // MARK: A row dragged out to below every row (A7), the phone's move (F7)

    @Test func aMemberDraggedOutOfAGroupUnderAStatusToBelowEveryRowOpensTheWorkspacesSection() async throws {
        try await inNested(list: Nested.bothStatuses) { rig, world in
            let m = rig.manager
            m.selectWorkspace(world.w("v"))
            try world.setStatus(world.n, "doing")
            setFolds(rig, workspaces: true)
            try #require(rig.state.statusGroups?.sectionOrder != nil, "the sections are resolved")
            let topLevelCount = m.sidebarReorderWorkspaceIds(forDraggedWorkspaceId: nil, usesTopLevelRows: true).count
            m.reorderSidebarWorkspace(tabId: world.w("n1").id, toIndex: topLevelCount, isDragOperation: true, usesTopLevelRows: true)
            try #require(world.w("n1").groupId == nil, "n1 left N for the top level")
            #expect(!workspacesFolded(rig), "the Workspaces section is still folded after the row landed there")
        }
    }

    @Test func thePhonesMoveWithAGroupOpensTheFoldedGroups() async throws {
        try await inNested { rig, world in
            let m = rig.manager
            m.selectWorkspace(world.w("p1"))
            for id in [world.r, world.n, world.m] { world.fold(id, true) }
            let previous = TerminalController.shared.activeTabManagerForCallerNotification()
            TerminalController.shared.setActiveTabManager(m)
            defer { TerminalController.shared.setActiveTabManager(previous) }
            let result = TerminalController.shared.v2MobileWorkspaceMove(
                params: ["workspace_id": world.w("u").id.uuidString, "group_id": world.m.uuidString])
            guard case .ok = result else { Issue.record("the move did not succeed: \(result)"); return }
            try #require(world.w("u").groupId == world.m, "u moved into M")
            let open = [world.m, world.n, world.r].map { !folded(rig, $0) }
            #expect(open == [true, true, true], "M, N, R open flags \(open); expected all open")
        }
    }

    // MARK: What cmux does on its own opens nothing (Scenario 91)

    @Test func aReorderThatIsNotADragOpensNothingForAHiddenRow() async throws {
        try await inNested { rig, world in
            let m = rig.manager
            m.selectWorkspace(world.w("v"))
            for id in [world.r, world.n] { world.fold(id, true) }
            setFolds(rig, statuses: ["doing"], area: true, workspaces: true)
            let before = rig.state.statusGroups
            let index = try #require(m.tabs.firstIndex { $0.id == world.w("r2").id })
            m.reorderWorkspace(tabId: world.w("r1").id, toIndex: index)
            #expect(folded(rig, world.r) && folded(rig, world.n), "a reorder that is not a drag opened a group")
            #expect(rig.state.statusGroups == before, "a reorder that is not a drag changed the status side")
        }
    }

    @Test func movingARowToTheTopForANotificationOpensNothing() async throws {
        try await inNested { rig, world in
            let m = rig.manager
            m.selectWorkspace(world.w("v"))
            for id in [world.r, world.n] { world.fold(id, true) }
            setFolds(rig, statuses: ["doing"], area: true, workspaces: true)
            let before = rig.state.statusGroups
            m.moveTabToTopForNotification(world.w("n2").id)
            #expect(folded(rig, world.r) && folded(rig, world.n), "a notification's move to the top opened a group")
            #expect(rig.state.statusGroups == before, "a notification's move to the top changed the status side")
        }
    }

    @Test func aDetectedPullRequestMovesARowAndOpensNothing() async throws {
        try await inNested(list: WorkspaceMoveRevealTests.doneListSource) { rig, world in
            let m = rig.manager
            m.selectWorkspace(world.w("v"))
            let u = world.w("u")
            WorkspaceTodoActions.applyStatusOverride(.auto, to: [u])
            setFolds(rig, statuses: ["done", "doing"], area: true)
            let before = rig.state.statusGroups
            let panelId = try #require(u.focusedPanelId)
            u.panelGitBranches[panelId] = SidebarGitBranchState(branch: "feature/pr", isDirty: false)
            u.panelPullRequests[panelId] = SidebarPullRequestState(
                number: 1, label: "PR #1", url: try #require(URL(string: "https://example.com/pr/1")), status: .merged, branch: "feature/pr")
            let projection = try #require(world.projection())
            #expect(projection.group(for: "done")?.memberWorkspaceIds.contains(u.id) == true, "detection should have put u under done")
            #expect(rig.state.statusGroups == before, "detection opened a fold")
        }
    }

    @Test func aSessionRestoreOpensNothing() async throws {
        try await inNested { rig, world in
            let m = rig.manager
            m.selectWorkspace(world.w("p1"))
            for id in [world.r, world.n, world.m] { world.fold(id, true) }
            let snapshot = m.sessionSnapshot(includeScrollback: false)
            let restored = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false)
            let restoredState = SidebarState()
            restoredState.installMoveReveal(on: restored)
            _ = restored.restoreSessionSnapshot(snapshot)
            let folds = restored.workspaceGroups.filter { $0.parentGroupId != nil || $0.name == "R" }.map(\.isCollapsed)
            #expect(!restored.workspaceGroups.isEmpty, "the snapshot restored its groups")
            #expect(folds.allSatisfy { $0 }, "a restore opened a group: folded flags \(folds)")
            #expect(restoredState.statusGroups == SidebarState().statusGroups, "a restore changed the status side")
        }
    }
}
