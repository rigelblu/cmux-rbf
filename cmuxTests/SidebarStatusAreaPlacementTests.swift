import AppKit
import CmuxFoundation
import CmuxSettings
import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SidebarStatusAreaPlacementTests {
    private let a = UUID(), b = UUID(), pin = UUID(), secondPin = UUID()
    private var rows: [SidebarWorkspaceRenderItem] { [.workspace(workspaceId: a), .workspace(workspaceId: b)] }
    private var area: [SidebarWorkspaceRenderItem] { [.statusesHeader] }
    private func key(_ id: UUID) -> String { "workspace:\(id.uuidString)" }
    private func ids(_ items: [SidebarWorkspaceRenderItem]) -> [SidebarWorkspaceRenderItemID] { items.map(\.id) }

    @Test func abovePresentPlacesAreaAfterThatItem() {
        let result = SidebarStatusAreaLayout(items: rows).placing(area: area, state: .init(last: false, aboveRow: key(a), belowRow: key(b)))
        #expect(ids(result) == [.workspace(a), .statusesArea(), .workspace(b)])
    }
    @Test func aboveGoneUsesBelow() {
        let result = SidebarStatusAreaLayout(items: rows).placing(area: area, state: .init(last: false, aboveRow: "workspace:gone", belowRow: key(b)))
        #expect(ids(result) == [.workspace(a), .statusesArea(), .workspace(b)])
    }
    @Test func bothNeighboursGoneDefaultsToBottom() {
        let result = SidebarStatusAreaLayout(items: rows).placing(area: area, state: .init(aboveRow: "gone", belowRow: "also-gone"))
        #expect(ids(result) == [.workspace(a), .workspace(b), .statusesArea()])
    }
    @Test func anAboveWorkspaceNowInsideAreaCannotAnchorIt() {
        let projection = WorkspaceStatusGroupProjection(groups: [.init(statusId: "parked", memberWorkspaceIds: [a])])
        let layout = SidebarStatusAreaLayout(items: [.workspace(workspaceId: b)], statusProjection: projection)
        let result = layout.placing(area: area, state: .init(aboveRow: key(a), belowRow: key(b)))
        #expect(ids(result) == [.statusesArea(), .workspace(b)])
    }
    @Test func anOldSessionWithNoRecordDefaultsToBottom() throws {
        let old = try JSONDecoder().decode(SessionSidebarSnapshot.self,
            from: Data(#"{"isVisible":true,"selection":"tabs","width":280}"#.utf8))
        #expect(ids(SidebarStatusAreaLayout(items: rows).placing(area: area, state: old.statusGroups)) ==
                [.workspace(a), .workspace(b), .statusesArea()])
    }
    @Test func topMeansBelowBothPinnedRows() {
        let p = Workspace(), q = Workspace(), loose = Workspace()
        p.isPinned = true; q.isPinned = true
        let input: [SidebarWorkspaceRenderItem] = [p, q, loose].map { .workspace(workspaceId: $0.id) }
        let result = SidebarStatusAreaLayout(items: input, tabs: [p, q, loose]).placing(area: area, state: .init(aboveRow: "top"))
        #expect(ids(result) == [.workspace(p.id), .workspace(q.id), .statusesArea(), .workspace(loose.id)])
    }
    @Test func lastStaysLastAfterAddingATrailingRowAndEmptyGroup() {
        let empty = group()
        let input = rows + [.groupHeader(groupId: empty.id, anchorWorkspaceId: empty.anchorWorkspaceId)]
        let state = WorkspaceStatusGroupsState(last: true, aboveRow: "removed")
        let result = SidebarStatusAreaLayout(items: input, groups: [empty]).placing(area: area, state: state)
        #expect(ids(result) == ids(input) + [.statusesArea()])
    }
    @Test(arguments: [false, true])
    func areaAfterWorkspaceGroupMeansAfterTheWholeFoldedOrOpenGroup(_ folded: Bool) {
        let g = group(collapsed: folded)
        let member = Workspace(); member.groupId = g.id
        let block: [SidebarWorkspaceRenderItem] = [.groupHeader(groupId: g.id, anchorWorkspaceId: g.anchorWorkspaceId)]
            + (folded ? [] : [.workspace(workspaceId: member.id)])
        let input = block + [.workspace(workspaceId: b)]
        let layout = SidebarStatusAreaLayout(items: input, tabs: [member], groups: [g])
        let result = layout.placing(area: area, state: .init(aboveRow: "group:\(g.id.uuidString)", belowRow: key(b)))
        #expect(ids(result) == ids(block) + [.statusesArea(), .workspace(b)])
    }
    @Test func writerMapsANestedMemberToItsTopLevelGroupHeader() throws {
        let root = group(), child = group()
        var nested = child; nested.parentGroupId = root.id
        let member = Workspace(); member.groupId = child.id
        let input: [SidebarWorkspaceRenderItem] = [
            .groupHeader(groupId: root.id, anchorWorkspaceId: root.anchorWorkspaceId),
            .groupHeader(groupId: child.id, anchorWorkspaceId: child.anchorWorkspaceId),
            .workspace(workspaceId: member.id), .statusesHeader, .workspace(workspaceId: b),
        ]
        let layout = SidebarStatusAreaLayout(items: input, tabs: [member], groups: [root, nested])
        let saved = try #require(layout.saving(state: .init()))
        #expect(layout.owner(of: .workspace(member.id)) == "group:\(root.id.uuidString)")
        #expect(layout.owner(of: .group(child.id)) == "group:\(root.id.uuidString)")
        #expect(saved.aboveRow == "group:\(root.id.uuidString)")
        #expect(saved.belowRow == key(b))
        #expect(saved.last == false)
    }
    @Test func writerMapsAColorMemberToItsColorHeader() throws {
        let section = SidebarWorkspaceColorSection(id: .init(normalizedHex: "#AABBCC", pinTier: .unpinned),
            title: "Color", memberWorkspaceIds: [a], isCollapsed: false)
        let input: [SidebarWorkspaceRenderItem] = [.colorSectionHeader(section: section), .workspace(workspaceId: a),
                                                  .statusesHeader, .workspace(workspaceId: b)]
        let layout = SidebarStatusAreaLayout(items: input)
        let saved = try #require(layout.saving(state: .init()))
        #expect(layout.owner(of: .workspace(a)) == "color:#AABBCC")
        #expect(saved.aboveRow == "color:#AABBCC")
        #expect(saved.belowRow == key(b))
    }
    @Test func absentAreaSaveKeepsPlaceForListReturn() throws {
        let original = WorkspaceStatusGroupsState(order: ["parked", "not-listed"], last: false, aboveRow: key(a), belowRow: key(b))
        let savedWithoutArea = try #require(SidebarStatusAreaLayout(items: rows).saving(state: original))
        #expect(savedWithoutArea == original)
        let result = SidebarStatusAreaLayout(items: rows).placing(area: area, state: savedWithoutArea)
        #expect(ids(result) == [.workspace(a), .statusesArea(), .workspace(b)])
    }
    @Test func newRecordOrderAndPlaceRoundTripWithoutPruningIds() throws {
        let expected = WorkspaceStatusGroupsState(areaCollapsed: true, collapsedStatusIds: ["parked"],
            order: ["parked", "not-listed"], last: false, aboveRow: key(a), belowRow: key(b))
        let snapshot = SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 280, statusGroups: expected)
        let decoded = try JSONDecoder().decode(SessionSidebarSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.statusGroups == expected)
    }
    @Test func foldOnlyOldRecordLeavesOrderAndPlaceAbsent() throws {
        let state = try JSONDecoder().decode(WorkspaceStatusGroupsState.self,
            from: Data(#"{"areaCollapsed":true,"collapsedStatusIds":["parked"]}"#.utf8))
        #expect(state.order == nil && state.last == nil && state.aboveRow == nil && state.belowRow == nil)
    }
    @Test func aNewWindowAndOrdinarySnapshotNeverWriteOrder() throws {
        let state = SidebarState()
        let saved = try #require(SidebarStatusAreaLayout(items: rows + area).saving(state: state.statusGroups))
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        #expect(object["order"] == nil)
        #expect(saved.order == nil)
    }
    @Test func lastTrueNeverEncodesABelowNeighbour() throws {
        let state = WorkspaceStatusGroupsState(last: true, aboveRow: key(a), belowRow: "stale-below")
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        #expect(object["belowRow"] == nil)
    }
    @Test(arguments: [CGFloat(2), 82])
    func realTargetBuilderClampsBothEndsOfTwoPinsIncludingPinnedGroupDescendants(_ y: CGFloat) throws {
        let first = Workspace(), member = Workspace(), loose = Workspace()
        first.isPinned = true
        let root = group(pinned: true)
        let child = group(parent: root.id)
        member.groupId = child.id // Its own pin flag stays false; root's pin tier owns it.
        #expect(!member.isPinned)
        let input: [SidebarWorkspaceRenderItem] = [.workspace(workspaceId: first.id),
            .groupHeader(groupId: root.id, anchorWorkspaceId: root.anchorWorkspaceId),
            .groupHeader(groupId: child.id, anchorWorkspaceId: child.anchorWorkspaceId),
            .workspace(workspaceId: member.id), .workspace(workspaceId: loose.id), .statusesHeader,
            .statusGroupHeader(statusId: "parked")]
        let identities = [first.id, root.anchorWorkspaceId, child.anchorWorkspaceId, member.id, loose.id,
                          SidebarStatusHeaderIdentity.statusesAreaUUID, SidebarStatusHeaderIdentity.uuid(forStatusId: "parked")]
        let measured = input.enumerated().map { index, item in
            SidebarWorkspaceReorderDropOverlay.Target(workspaceId: identities[index], groupId: nil, isGroupHeader: false,
                frame: CGRect(x: 0, y: CGFloat(index) * 22, width: 300, height: 20), renderItemId: item.id)
        }
        let targets = SidebarStatusAreaLayout(items: input, tabs: [first, member, loose], groups: [root, child])
            .headerDropTargets(measured: measured)
        #expect(targets.first(where: { $0.rowId == member.id })?.isPinned == true)
        let plan = try #require(SidebarStatusHeaderDropPlanner().plan(point: .init(x: 220, y: y), draggedStatusId: nil, targets: targets))
        #expect(plan.action == .area(aboveRow: "top", belowRow: key(loose.id), last: false))
        #expect(plan.indicator == .init(tabId: loose.id, edge: .top))
    }

    @Test func theAppProjectionUsesTheWindowsExplicitOrder() {
        let list = WorkspaceStatusList(entries: [WorkspaceStatusEntry(id: "a", name: "A", extends: .todo),
                                                WorkspaceStatusEntry(id: "b", name: "B", extends: .working)], source: .file)
        let projection = VerticalTabsSidebar.statusGroupProjection(items: [], list: list, colorHexes: [:],
            controlsEnabled: true, storedOrder: ["b", "a"])
        #expect(projection?.groups.map(\.statusId) == ["b", "a"])
    }
    @Test func aNewStatusIsRememberedBeforeAFollowingFileReorder() throws {
        let state = SidebarState(statusGroups: .init(order: ["b", "not-listed", "a"]))
        func list(_ ids: [String]) -> WorkspaceStatusList {
            .init(entries: ids.map { WorkspaceStatusEntry(id: $0, name: $0, extends: .todo) }, source: .file)
        }
        state.reconcileStatusGroupOrder(list: list(["a", "new", "b"]))
        #expect(state.statusGroups?.order == ["b", "not-listed", "a", "new"])
        state.reconcileStatusGroupOrder(list: list(["new", "b", "a"]))
        #expect(state.statusGroups?.order == ["b", "not-listed", "a", "new"])
    }
    @Test func listArrivalNeverCreatesAnExplicitOrderForANoDragWindow() {
        let state = SidebarState()
        state.reconcileStatusGroupOrder(list: .init(entries: [WorkspaceStatusEntry(id: "a", name: "A", extends: .todo)], source: .file))
        #expect(state.statusGroups?.order == nil)
    }
    @Test func orderReconciliationDoesNotSeedAPendingOldWindow() {
        let state = SidebarState(statusGroups: nil)
        state.reconcileStatusGroupOrder(list: .init(entries: [WorkspaceStatusEntry(id: "a", name: "A", extends: .todo)], source: .file))
        #expect(state.statusGroups == nil)
    }
    @Test func displayOrderDoesNotChangeFileOrderColorMatchingPrecedence() throws {
        let list = WorkspaceStatusList(entries: [WorkspaceStatusEntry(id: "a", name: "A", extends: .todo),
                                                WorkspaceStatusEntry(id: "b", name: "B", extends: .working)], source: .file)
        let member = UUID()
        let item = WorkspaceStatusGroupProjectionItem(workspaceId: member, isStatusHidden: true,
            normalizedColorHex: "#AABBCC", resolution: .detected(.todo))
        let projection = try #require(VerticalTabsSidebar.statusGroupProjection(items: [item], list: list,
            colorHexes: ["a": "#AABBCC", "b": "#AABBCC"], controlsEnabled: true, storedOrder: ["b", "a"]))
        #expect(projection.groups.map(\.statusId) == ["b", "a"])
        #expect(projection.group(for: "a")?.memberWorkspaceIds == [member])
        #expect(projection.group(for: "b")?.memberWorkspaceIds == [])
    }
    @Test(arguments: [false, true])
    func listDisappearanceOrEmptyListDoesNotEraseExplicitUnknownIds(_ empty: Bool) {
        let original = WorkspaceStatusGroupsState(order: ["b", "not-listed", "a"])
        let state = SidebarState(statusGroups: original)
        state.reconcileStatusGroupOrder(list: empty ? .init(entries: [], source: .file) : .cmuxFive)
        #expect(state.statusGroups == original)
    }

    // MARK: An ordinary reorder moves the row the area was saved under (#cm-110.1)

    /// The Statuses area renders only with the status controls on (a beta setting, off in the test host) and a file
    /// list in use (the app delegate's store). Runs `body` with both, and puts both back.
    private func withStatusControlsOn(_ body: () throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarStatusAreaPlacementTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("cmux.json")
        try ##"{ "workspaceStatuses": [ { "id": "parked", "name": "Parked", "extends": "todo", "color": "#445566" } ] }"##
            .write(to: file, atomically: true, encoding: .utf8)
        let suite = "SidebarStatusAreaPlacementTests.\(UUID().uuidString)"
        let storeDefaults = try #require(UserDefaults(suiteName: suite))
        let store = WorkspaceStatusListStore(fileURL: file, defaults: storeDefaults, resolveColor: { _ in nil },
                                             paletteFingerprint: { "fixed" }, clock: ContinuousClock())
        store.load()
        let previousDelegate = AppDelegate.shared
        let delegate = AppDelegate()
        delegate.workspaceStatusListStore = store
        AppDelegate.shared = delegate
        let defaults = UserDefaults.standard
        let key = BetaFeaturesCatalogSection().workspaceTodoControls.userDefaultsKey
        let previous = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
            AppDelegate.shared = previousDelegate
            storeDefaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try #require(WorkspaceTodoFeature.isEnabled, "the area needs the status controls on in the test host")
        try #require(AppDelegate.statusListInUse.source == .file, "the area needs a file list in use")
        try body()
    }
    private func makeManager() -> TabManager {
        TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false)
    }
    private func render(_ manager: TabManager, _ state: SidebarState) -> [SidebarWorkspaceRenderItemID] {
        ids(VerticalTabsSidebar.statusRenderItemsForSnapshot(tabManager: manager, state: state).items)
    }

    /// `home, L2 | area | L1` with the area saved under L2; L2 is dropped below every row.
    @Test func theAreaStaysPutWhenTheRowItWasSavedUnderMovesToTheEnd() throws {
        try withStatusControlsOn {
            let manager = makeManager()
            let home = manager.addWorkspace(autoWelcomeIfNeeded: false)
            let l2 = manager.addWorkspace(autoWelcomeIfNeeded: false)
            let l1 = manager.addWorkspace(autoWelcomeIfNeeded: false)
            let state = SidebarState(statusGroups: .init(last: false, aboveRow: key(l2.id), belowRow: key(l1.id)))
            #expect(render(manager, state) == [.workspace(home.id), .workspace(l2.id), .statusesArea(), .statusGroup("parked"), .workspace(l1.id)])

            state.reanchorStatusAreaBeforeMove(tabManager: manager, movingWorkspaceIds: [l2.id], movingGroupIds: [])
            #expect(manager.reorderSidebarWorkspace(tabId: l2.id, toIndex: 2, isDragOperation: true, usesTopLevelRows: true))

            #expect(manager.tabs.map(\.id) == [home.id, l1.id, l2.id])
            #expect(render(manager, state) == [.workspace(home.id), .statusesArea(), .statusGroup("parked"), .workspace(l1.id), .workspace(l2.id)])
        }
    }
    /// Control, the other direction: the row under the area moves above the row the area was saved under.
    @Test func theAreaStaysPutWhenTheRowBelowItMovesAboveTheRowItWasSavedUnder() throws {
        try withStatusControlsOn {
            let manager = makeManager()
            let home = manager.addWorkspace(autoWelcomeIfNeeded: false)
            let l2 = manager.addWorkspace(autoWelcomeIfNeeded: false)
            let l1 = manager.addWorkspace(autoWelcomeIfNeeded: false)
            let state = SidebarState(statusGroups: .init(last: false, aboveRow: key(l2.id), belowRow: key(l1.id)))

            state.reanchorStatusAreaBeforeMove(tabManager: manager, movingWorkspaceIds: [l1.id], movingGroupIds: [])
            #expect(manager.reorderSidebarWorkspace(tabId: l1.id, toIndex: 1, isDragOperation: true, usesTopLevelRows: true))

            #expect(manager.tabs.map(\.id) == [home.id, l1.id, l2.id])
            #expect(render(manager, state) == [.workspace(home.id), .workspace(l1.id), .workspace(l2.id), .statusesArea(), .statusGroup("parked")])
        }
    }
    /// `home, G1 | area | G2, L1`: the group directly above the area is dragged below G2.
    @Test func theAreaStaysAboveTheRowsThatDidNotMoveWhenTheGroupAboveItMoves() throws {
        try withStatusControlsOn {
            let manager = makeManager()
            let home = manager.addWorkspace(autoWelcomeIfNeeded: false)
            let m1 = manager.addWorkspace(autoWelcomeIfNeeded: false)
            let m2 = manager.addWorkspace(autoWelcomeIfNeeded: false)
            let l1 = manager.addWorkspace(autoWelcomeIfNeeded: false)
            let g1 = try #require(manager.createWorkspaceGroup(name: "G1", childWorkspaceIds: [m1.id]))
            let g2 = try #require(manager.createWorkspaceGroup(name: "G2", childWorkspaceIds: [m2.id]))
            let anchor1 = try #require(manager.workspaceGroupAnchor(for: g1)), anchor2 = try #require(manager.workspaceGroupAnchor(for: g2))
            manager.tabs = [home, anchor1, m1, anchor2, m2, l1]
            let state = SidebarState(statusGroups: .init(last: false, aboveRow: "group:\(g1.uuidString)", belowRow: "group:\(g2.uuidString)"))
            #expect(render(manager, state) == [.workspace(home.id), .group(g1), .workspace(m1.id), .statusesArea(), .statusGroup("parked"),
                                               .group(g2), .workspace(m2.id), .workspace(l1.id)])

            state.reanchorStatusAreaBeforeMove(tabManager: manager, movingWorkspaceIds: [], movingGroupIds: [g1])
            manager.moveWorkspaceGroup(groupId: g1, toIndex: 1)

            #expect(manager.workspaceGroups.map(\.id) == [g2, g1])
            #expect(render(manager, state) == [.workspace(home.id), .statusesArea(), .statusGroup("parked"), .group(g2), .workspace(m2.id),
                                               .group(g1), .workspace(m1.id), .workspace(l1.id)])
        }
    }

    /// `home, L2 | area | L1`: L2 is dropped back on its own place, so nothing moves and the area must not.
    @Test func aWorkspaceReorderThatMovesNothingLeavesTheAreaWhereItWas() throws {
        try withStatusControlsOn {
            let manager = makeManager()
            let home = manager.addWorkspace(autoWelcomeIfNeeded: false)
            let l2 = manager.addWorkspace(autoWelcomeIfNeeded: false)
            let l1 = manager.addWorkspace(autoWelcomeIfNeeded: false)
            let state = SidebarState(statusGroups: .init(last: false, aboveRow: key(l2.id), belowRow: key(l1.id)))
            let before = state.statusGroups
            let orderBefore = manager.tabs.map(\.id)

            let previous = state.reanchorStatusAreaBeforeMove(tabManager: manager, movingWorkspaceIds: [l2.id], movingGroupIds: [])
            _ = manager.reorderSidebarWorkspace(tabId: l2.id, toIndex: 1, isDragOperation: true, usesTopLevelRows: true)
            state.settleStatusAreaAfterMove(previous: previous, moved: manager.tabs.map(\.id) != orderBefore)

            #expect(manager.tabs.map(\.id) == orderBefore)
            #expect(state.statusGroups == before)
            #expect(render(manager, state) == [.workspace(home.id), .workspace(l2.id), .statusesArea(), .statusGroup("parked"), .workspace(l1.id)])
        }
    }
    /// The same for a group header dropped on its own slot, and a move that did happen keeps its new anchors.
    @Test func aGroupReorderThatMovesNothingLeavesTheAreaWhereItWas() throws {
        try withStatusControlsOn {
            let manager = makeManager()
            let home = manager.addWorkspace(autoWelcomeIfNeeded: false)
            let m1 = manager.addWorkspace(autoWelcomeIfNeeded: false)
            let l1 = manager.addWorkspace(autoWelcomeIfNeeded: false)
            let g1 = try #require(manager.createWorkspaceGroup(name: "G1", childWorkspaceIds: [m1.id]))
            let anchor1 = try #require(manager.workspaceGroupAnchor(for: g1))
            manager.tabs = [home, anchor1, m1, l1]
            let state = SidebarState(statusGroups: .init(last: false, aboveRow: "group:\(g1.uuidString)", belowRow: key(l1.id)))
            let before = state.statusGroups
            let groupsBefore = manager.workspaceGroups.map(\.id)

            let previous = state.reanchorStatusAreaBeforeMove(tabManager: manager, movingWorkspaceIds: [], movingGroupIds: [g1])
            manager.moveWorkspaceGroup(groupId: g1, toIndex: 0)
            state.settleStatusAreaAfterMove(previous: previous, moved: manager.workspaceGroups.map(\.id) != groupsBefore)

            #expect(state.statusGroups == before)
            #expect(render(manager, state) == [.workspace(home.id), .group(g1), .workspace(m1.id), .statusesArea(), .statusGroup("parked"), .workspace(l1.id)])
        }
    }

    /// One member leaving a group does not take the group's place from the area; the same holds for a color group.
    @Test func aMemberLeavingAGroupOrColorGroupLeavesItsHeaderAnchoring() throws {
        let g = group(), first = Workspace(), second = Workspace()
        first.groupId = g.id; second.groupId = g.id
        let groupItems: [SidebarWorkspaceRenderItem] = [.groupHeader(groupId: g.id, anchorWorkspaceId: g.anchorWorkspaceId),
            .workspace(workspaceId: first.id), .workspace(workspaceId: second.id), .statusesHeader, .workspace(workspaceId: b)]
        let inGroup = SidebarStatusAreaLayout(items: groupItems, tabs: [first, second], groups: [g])
            .saving(state: .init(), movingWorkspaceIds: [second.id], movingGroupIds: [])
        #expect(inGroup?.aboveRow == "group:\(g.id.uuidString)")

        let section = SidebarWorkspaceColorSection(id: .init(normalizedHex: "#AABBCC", pinTier: .unpinned),
            title: "Color", memberWorkspaceIds: [a, pin], isCollapsed: false)
        let colorItems: [SidebarWorkspaceRenderItem] = [.colorSectionHeader(section: section), .workspace(workspaceId: a),
            .workspace(workspaceId: pin), .statusesHeader, .workspace(workspaceId: b)]
        let layout = SidebarStatusAreaLayout(items: colorItems)
        #expect(layout.saving(state: .init(), movingWorkspaceIds: [pin], movingGroupIds: [])?.aboveRow == "color:#AABBCC")
        #expect(layout.saving(state: .init(), movingWorkspaceIds: [a, pin], movingGroupIds: [])?.aboveRow == "top")
    }

    private func group(collapsed: Bool = false, pinned: Bool = false, parent: UUID? = nil) -> WorkspaceGroup {
        WorkspaceGroup(id: UUID(), name: "Group", isCollapsed: collapsed, isPinned: pinned, anchor: .empty(UUID()),
                       customColor: nil, iconSymbol: nil, parentGroupId: parent)
    }
}
