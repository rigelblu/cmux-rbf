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
struct SidebarGroupedPinTests {
    private let list = WorkspaceStatusList(entries: [WorkspaceStatusEntry(id: "parked", name: "Parked", extends: .todo)], source: .file)

    @MainActor
    private struct Fixture {
        let own = Workspace(), pin = Workspace(), plain = Workspace(), parentOwn = Workspace()
        let groups: [WorkspaceGroup]
        var tabs: [Workspace] { (groups.count > 1 ? [parentOwn] : []) + [own, pin, plain] }
        init(nested: Bool, pinnedParent: Bool = false) {
            let parent = WorkspaceGroup(id: UUID(), name: "Parent", isCollapsed: false, isPinned: pinnedParent, anchorWorkspaceId: parentOwn.id, customColor: nil, iconSymbol: nil)
            let group = WorkspaceGroup(id: UUID(), name: "G", isCollapsed: false, isPinned: false, anchorWorkspaceId: own.id, customColor: nil, iconSymbol: nil, parentGroupId: nested ? parent.id : nil)
            groups = nested ? [parent, group] : [group]
            parentOwn.groupId = nested ? parent.id : nil
            own.groupId = group.id; pin.groupId = group.id; plain.groupId = group.id
            pin.isPinned = true
        }
    }

    private func sectionProjection(tabs: [Workspace], groups: [WorkspaceGroup]) -> WorkspaceStatusGroupProjection? {
        VerticalTabsSidebar.statusGroupProjection(items: VerticalTabsSidebar.statusGroupProjectionItems(tabs: tabs, list: list, groups: groups),
            list: list, colorHexes: [:], controlsEnabled: true, workspaceGroups: groups)
    }

    @Test(arguments: [false, true])
    func groupedPinOwnsItsRowAndCountsOnlyInPinned(_ nested: Bool) {
        let f = Fixture(nested: nested)
        let order = f.tabs.map(\.id), membership = f.tabs.map(\.groupId)
        let layout = SidebarStatusAreaLayout(items: f.tabs.map { .workspace(workspaceId: $0.id) }, tabs: f.tabs, groups: f.groups, statusProjection: sectionProjection(tabs: f.tabs, groups: f.groups))
        #expect(layout.pinnedSectionMemberIds == [f.pin.id])
        #expect(!layout.workspacesSectionMemberIds.contains(f.pin.id))
        #expect(layout.owner(of: .workspace(f.pin.id)) == "workspace:\(f.pin.id.uuidString)")
        #expect(f.tabs.map(\.id) == order)
        #expect(f.tabs.map(\.groupId) == membership)
    }

    @Test(arguments: [false, true])
    func headerDropTargetReadsGroupedPinsDrawnTier(_ nested: Bool) throws {
        let f = Fixture(nested: nested)
        let row = SidebarWorkspaceRenderItem.workspace(workspaceId: f.pin.id)
        let layout = SidebarStatusAreaLayout(items: [row], tabs: f.tabs, groups: f.groups, statusProjection: sectionProjection(tabs: f.tabs, groups: f.groups))
        let target = SidebarWorkspaceReorderDropOverlay.Target(workspaceId: f.pin.id, groupId: f.pin.groupId,
            isGroupHeader: false, frame: CGRect(x: 0, y: 0, width: 300, height: 20), renderItemId: row.id)
        #expect(try #require(layout.headerDropTargets(measured: [target]).first).isPinned)
    }

    @Test(arguments: [false, true])
    func selectionReadsGroupedPinsDrawnSection(_ nested: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let key = BetaFeaturesCatalogSection().workspaceTodoControls.userDefaultsKey
            let previous = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.set(true, forKey: key)
            defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
            let f = Fixture(nested: nested)
            let state = SidebarState()
            let place = try #require(state.statusSidePlace(containing: f.pin, list: list, resolvedHexByStatusId: [:], workspaceGroups: f.groups))
            #expect(place.isPinned)
            #expect(place.statusId == nil)

        }
    }

    @Test(arguments: [false, true])
    func statusProjectionLeavesGroupedPinOutOfItsParentsStatus(_ nested: Bool) throws {
        let f = Fixture(nested: nested)
        var groups = f.groups
        groups[groups.count - 1].statusId = "parked"
        let projection = try #require(VerticalTabsSidebar.statusGroupProjection(
            items: VerticalTabsSidebar.statusGroupProjectionItems(tabs: f.tabs, list: list, groups: groups),
            list: list, colorHexes: [:], controlsEnabled: true, workspaceGroups: groups))
        #expect(projection.workspaceGroups?.statusIdByWorkspaceId[f.pin.id] == nil)
        #expect(projection.workspaceGroups?.statusIdByWorkspaceId[f.plain.id] == "parked")
    }

    @Test func nestedPinnedGroupKeepsItsOwnPinnedMemberWithItInPinned() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let key = BetaFeaturesCatalogSection().workspaceTodoControls.userDefaultsKey
            let previous = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.set(true, forKey: key)
            defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
            let f = Fixture(nested: true)
            var groups = f.groups
            groups[1].isPinned = true
            let state = SidebarState()
            let place = try #require(state.statusSidePlace(containing: f.pin, list: list, resolvedHexByStatusId: [:], workspaceGroups: groups))
            #expect(place.isPinned)
            let layout = SidebarStatusAreaLayout(items: [.workspace(workspaceId: f.pin.id)], tabs: f.tabs, groups: groups, statusProjection: sectionProjection(tabs: f.tabs, groups: groups))
            #expect(layout.pinnedSectionMemberIds.contains(f.pin.id))
            #expect(layout.owner(of: .workspace(f.pin.id)) == "group:\(groups[1].id.uuidString)")

        }
    }

    @Test func anchorsOwnPinKeepsItsGroupsSection() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let key = BetaFeaturesCatalogSection().workspaceTodoControls.userDefaultsKey
            let previous = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.set(true, forKey: key)
            defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
            let f = Fixture(nested: false)
            f.own.isPinned = true
            let state = SidebarState()
            let place = try #require(state.statusSidePlace(containing: f.own, list: list, resolvedHexByStatusId: [:], workspaceGroups: f.groups))
            #expect(!place.isPinned)

        }
    }
}

extension SidebarGroupedPinTests {
    private func inSidebar(nested: Bool, controls: Bool = true, source: String? = nil,
                           _ body: (Fixture, TabManager, SidebarState) throws -> Void) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let handle = try SidebarNestedRootStatusTests.installStatusListHandle(source: source, controls: controls)
            defer { handle.restore() }
            let fixture = Fixture(nested: nested)
            let manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false)
            manager.tabs = fixture.tabs
            manager.workspaceGroups = fixture.groups
            try body(fixture, manager, SidebarState())
        }
    }

    @Test(arguments: [false, true])
    func groupedPinRendersOnceBeforeWorkspacesAndItsGroupStaysAfterTheHeader(_ nested: Bool) async throws {
        try await inSidebar(nested: nested) { f, manager, state in
            let before = manager.tabs.map(\.id), membership = manager.tabs.map(\.groupId)
            let ids = VerticalTabsSidebar.statusRenderItemsForSnapshot(tabManager: manager, state: state).items.map(\.id)
            let pin = try #require(ids.firstIndex(of: .workspace(f.pin.id)))
            let workspaces = try #require(ids.firstIndex(of: .workspacesArea()))
            let group = try #require(ids.firstIndex(of: .group(f.groups.last!.id)))
            #expect(ids.first == .pinnedArea())
            #expect(pin < workspaces)
            #expect(group > workspaces)
            #expect(ids.filter { $0 == .workspace(f.pin.id) }.count == 1)
            #expect(manager.tabs.map(\.id) == before)
            #expect(manager.tabs.map(\.groupId) == membership)
        }
    }

    @Test(arguments: [false, true])
    func aFoldedGroupCannotHideItsSeparatelyPinnedMember(_ nested: Bool) async throws {
        try await inSidebar(nested: nested) { f, manager, state in
            manager.workspaceGroups = manager.workspaceGroups.map { group in var next = group; next.isCollapsed = true; return next }
            let ids = VerticalTabsSidebar.statusRenderItemsForSnapshot(tabManager: manager, state: state).items.map(\.id)
            #expect(ids.first == .pinnedArea())
            #expect(ids.filter { $0 == .workspace(f.pin.id) }.count == 1)
            #expect(manager.workspaceGroups.allSatisfy { $0.isCollapsed })
        }
    }

    @Test(arguments: [false, true])
    func snapshotColorProjectionPutsGroupedPinAfterLoosePinsOfItsColor(_ nested: Bool) async throws {
        try await inSidebar(nested: nested) { f, manager, state in
            let loose = Workspace(); loose.isPinned = true; loose.customColor = "#112233"
            f.pin.customColor = "#112233"
            manager.tabs = [loose] + manager.tabs
            let items = VerticalTabsSidebar.statusRenderItemsForSnapshot(tabManager: manager, state: state).items
            let colors = items.compactMap { item -> SidebarWorkspaceColorSection? in
                if case .colorSectionHeader(let section) = item { return section }; return nil
            }
            let color = try #require(colors.first { $0.id.pinTier == .pinned && $0.id.normalizedHex == "#112233" })
            #expect(color.memberWorkspaceIds == [loose.id, f.pin.id])
            #expect(items.map(\.id).filter { $0 == .workspace(f.pin.id) }.count == 1)
        }
    }

    @Test(arguments: [false, true])
    func aGroupUnderAStatusKeepsItsHeaderAndUnpinnedRowsWhileItsPinShowsAbove(_ nested: Bool) async throws {
        try await inSidebar(nested: nested) { f, manager, state in
            let groupId = f.groups.last!.id
            let index = try #require(manager.workspaceGroups.firstIndex { $0.id == groupId })
            manager.workspaceGroups[index].statusId = "parked"
            let ids = VerticalTabsSidebar.statusRenderItemsForSnapshot(tabManager: manager, state: state).items.map(\.id)
            let pin = try #require(ids.firstIndex(of: .workspace(f.pin.id)))
            let statuses = try #require(ids.firstIndex(of: .statusesArea()))
            let group = try #require(ids.firstIndex(of: .group(groupId)))
            let plain = try #require(ids.firstIndex(of: .workspace(f.plain.id)))
            #expect(pin < statuses)
            #expect(group > statuses && plain > group)
            #expect(ids.filter { $0 == .workspace(f.pin.id) }.count == 1)
        }
    }

    @Test(arguments: [false, true])
    func aGroupLeftWithOnlyItsAnchorStillShowsItsHeaderAndKeepsItsPinnedMember(_ nested: Bool) async throws {
        try await inSidebar(nested: nested) { f, manager, state in
            manager.tabs.removeAll { $0.id == f.plain.id }
            let group = f.groups.last!
            let ids = VerticalTabsSidebar.statusRenderItemsForSnapshot(tabManager: manager, state: state).items.map(\.id)
            let header = try #require(ids.firstIndex(of: .group(group.id)))
            let section = try #require(ids.firstIndex(of: .workspacesArea()))
            #expect(header > section)
            let items = VerticalTabsSidebar.statusRenderItemsForSnapshot(tabManager: manager, state: state).items
            let workspaceIds = items.compactMap { item -> UUID? in
                if case .workspace(let id) = item { return id }; return nil
            }
            #expect(workspaceIds == [f.pin.id])
            #expect(manager.tabs.filter { $0.groupId == group.id }.map(\.id) == [f.own.id, f.pin.id])
            #expect(!group.isEmpty)
        }
    }

    @Test(arguments: [false, true], ["builtin", "controlsOff"])
    func withoutSectionsTheGroupedPinKeepsTheUnprojectedRows(_ nested: Bool, _ mode: String) async throws {
        try await inSidebar(nested: nested, controls: mode != "controlsOff", source: mode == "builtin" ? "{}" : nil) { _, manager, state in
            let base = SidebarWorkspaceRenderItem.renderItems(tabs: manager.tabs,
                groupsById: Dictionary(uniqueKeysWithValues: manager.workspaceGroups.map { ($0.id, $0) }), orderedGroups: manager.workspaceGroups)
            let actual = VerticalTabsSidebar.statusRenderItemsForSnapshot(tabManager: manager, state: state)
            #expect(actual.items.map(\.id) == base.map(\.id))
            #expect(!actual.items.map(\.id).contains(.pinnedArea()))
        }
    }
}

extension SidebarGroupedPinTests {
    @Test(arguments: [false, true], [false, true])
    func selectingAGroupedPinOpensNoModelFoldWhileSectionsShow(_ nested: Bool, _ controls: Bool) async throws {
        try await inSidebar(nested: nested, controls: controls) { f, manager, _ in
            let other = Workspace(); manager.tabs.append(other); manager.selectWorkspace(other)
            for group in f.groups { manager.setWorkspaceGroupCollapsed(groupId: group.id, isCollapsed: true) }
            manager.selectWorkspace(f.pin)
            #expect(manager.workspaceGroups.allSatisfy { $0.isCollapsed == controls })
        }
    }

    @Test(arguments: [false, true])
    func pinOpensPinnedWithoutOpeningItsGroupsAndUnpinRevealsWhereItLands(_ nested: Bool) async throws {
        try await inSidebar(nested: nested) { f, manager, state in
            f.pin.isPinned = false
            let other = Workspace(); manager.tabs.append(other); manager.selectWorkspace(other)
            state.installMoveReveal(on: manager)
            state.setStatusGroups(.init(pinnedCollapsed: true))
            for group in f.groups { manager.setWorkspaceGroupCollapsed(groupId: group.id, isCollapsed: true) }
            manager.setPinned(f.pin, pinned: true)
            #expect(state.statusGroups?.pinnedCollapsed == false)
            #expect(manager.workspaceGroups.allSatisfy { $0.isCollapsed })
            state.setStatusGroups(.init(workspacesCollapsed: true))
            manager.setPinned(f.pin, pinned: false)
            #expect(manager.workspaceGroups.allSatisfy { !$0.isCollapsed })
            #expect(state.statusGroups?.workspacesCollapsed == false)
        }
    }

    @Test(arguments: [false, true])
    func aGroupedPinsColorMoveOpensThePinnedColorGroup(_ nested: Bool) async throws {
        try await inSidebar(nested: nested) { f, manager, state in
            state.installMoveReveal(on: manager)
            f.pin.customColor = "#112233"
            #expect(state.movePlace(of: f.pin, tabManager: manager).colorHex == "#112233")
            state.restoreCollapsedColorSections(["#334455"])
            manager.setTabColor(tabId: f.pin.id, color: "#334455")
            #expect(!state.collapsedColorSectionHexes.contains("#334455"))
        }
    }

    @Test(arguments: [false, true])
    func aFoldedGroupsBadgeExcludesItsSeparatePinWhileGroupActionsKeepIt(_ nested: Bool) async throws {
        try await inSidebar(nested: nested) { f, manager, _ in
            let group = f.groups.last!
            let all = manager.workspaces.workspaceIdsInside(group.id)
            let projection = VerticalTabsSidebar.currentStatusGroupProjection(tabs: manager.tabs, groups: manager.workspaceGroups)
            let badge = VerticalTabsSidebar.foldedGroupBadgeWorkspaceIds(group: group, memberWorkspaceIds: all, projection: projection, tabs: manager.tabs, groups: manager.workspaceGroups)
            #expect(!badge.contains(f.pin.id))
            #expect(badge.contains(f.plain.id))
            #expect(all.contains(f.pin.id))
        }
    }

    @Test(arguments: [false, true])
    func windowCycleAndDigitsKeepTheGroupedPinsTabSlot(_ nested: Bool) async throws {
        try await inSidebar(nested: nested) { f, manager, state in
            let first = Workspace(); manager.tabs.insert(first, at: 0)
            for workspace in manager.tabs { workspace.hideTaskStatus() }
            let index = try #require(manager.tabs.firstIndex { $0.id == f.pin.id })
            let eligibility = WorkspaceShortcutEligibility.resolve(workspaces: manager.tabs, groups: manager.workspaceGroups, todoControlsEnabled: true)
            #expect(WorkspaceShortcutMapper.digitForWorkspace(atFlatIndex: index, eligibility: eligibility) == 2)
            #expect(manager.workspaces.cycleDestination(from: f.own.id, direction: .next, scope: .window) == f.pin.id)
            let ids = VerticalTabsSidebar.statusRenderItemsForSnapshot(tabManager: manager, state: state).items.map(\.id)
            let drawnPin = try #require(ids.firstIndex(of: .workspace(f.pin.id)))
            let drawnFirst = try #require(ids.firstIndex(of: .workspace(first.id)))
            #expect(drawnPin < drawnFirst)
        }
    }
}

@MainActor
@Suite(.serialized)
struct SidebarGroupedPinDropTests {
    private typealias Fixture = SidebarNestedStatusDropFixture

    private func inDrop(colored: Bool, _ body: (Fixture) async throws -> Void) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try Fixture(scene: .f1, role: .grouped)
            defer { fixture.close() }
            fixture.projectsWorkspaceGroups = true
            fixture.manager.setPinned(fixture.source, pinned: true)
            if colored {
                fixture.source.customColor = "#119933"
                fixture.w("pinA").customColor = "#119933"
            }
            let colorMember = fixture.snapshot().colorSectionProjection.sectionByWorkspaceId[fixture.source.id] != nil
            #expect(colorMember == colored)
            await fixture.applyRows()
            try fixture.begin(row: .workspace(fixture.source.id))
            try await body(fixture)
        }
    }

    @Test(arguments: SidebarNestedStatusDropFixture.Renderer.allCases, [false, true])
    func aReorderAmongPinsIsRefusedWithoutAnIndicator(_ renderer: SidebarNestedStatusDropFixture.Renderer, _ colored: Bool) async throws {
        try await inDrop(colored: colored) { f in
            let before = f.held, order = f.manager.tabs.map(\.id)
            let targets = f.targets(renderer)
            let target = try #require(targets.first { $0.workspaceId == f.w("pinA").id })
            let plan = try f.route(point: CGPoint(x: 60, y: target.frame.minY + target.frame.height * 0.25), targets: targets)
            #expect(plan == nil)
            #expect(f.manager.tabs.map(\.id) == order && f.held == before)
        }
    }

    @Test(arguments: SidebarNestedStatusDropFixture.Renderer.allCases, [false, true])
    func aDropOnAStatusSetsItAndKeepsTheGroupedPinPinned(_ renderer: SidebarNestedStatusDropFixture.Renderer, _ colored: Bool) async throws {
        try await inDrop(colored: colored) { f in
            let group = f.source.groupId
            let targets = f.targets(renderer)
            let point = try f.point(.header, fraction: 0.5, side: .left, targets: targets)
            let plan = try #require(try f.route(point: point, targets: targets))
            try #require(f.commit(plan))
            #expect(f.source.todoState.ownStatus?.id == "parked")
            #expect(f.source.isPinned && f.source.groupId == group)
        }
    }

    @Test(arguments: SidebarNestedStatusDropFixture.Renderer.allCases, [false, true])
    func aDropIntoAnotherGroupKeepsThePinAndMovesMembership(_ renderer: SidebarNestedStatusDropFixture.Renderer, _ colored: Bool) async throws {
        try await inDrop(colored: colored) { f in
            let targets = f.targets(renderer)
            let target = try #require(targets.first { $0.workspaceId == f.w("pa").id })
            let plan = try #require(try f.route(point: CGPoint(x: 60, y: target.frame.minY + target.frame.height * 0.25), targets: targets))
            try #require(f.commit(plan))
            #expect(f.source.isPinned && f.source.groupId == f.p)
        }
    }
}

extension SidebarGroupedPinTests {
    @Test(arguments: [false, true])
    func selectionOpensAGroupedPinsColorFoldDirectly(_ nested: Bool) async throws {
        try await inSidebar(nested: nested) { f, manager, state in
            f.pin.customColor = "#112233"
            state.restoreCollapsedColorSections(["#112233"])
            state.prepareStatusGroupsForSelection(list: AppDelegate.statusListInUse, resolvedHexByStatusId: [:],
                selectedWorkspace: f.pin, workspaceGroups: manager.workspaceGroups)
            #expect(!state.collapsedColorSectionHexes.contains("#112233"))
        }
    }

    @Test(arguments: [false, true])
    func builtInMovePlaceKeepsTheOutermostGroupsPin(_ nested: Bool) async throws {
        try await inSidebar(nested: nested, source: "{}") { f, manager, state in
            #expect(!state.movePlace(of: f.pin, tabManager: manager).isPinned)
            manager.workspaceGroups[0].isPinned = true
            #expect(state.movePlace(of: f.plain, tabManager: manager).isPinned)
        }
    }
}

@MainActor
@Suite("Nested pinned groups in the sidebar", .serialized)
struct SidebarNestedPinnedGroupTests {
    typealias World = SidebarNestedRootStatusTests.World

    private func inSidebar(controls: Bool = true, source: String? = nil,
                           _ body: (World, SidebarState) async throws -> Void) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let handle = try SidebarNestedRootStatusTests.installStatusListHandle(source: source, controls: controls)
            defer { handle.restore() }
            try await body(World(), SidebarState())
        }
    }

    @Test(arguments: [false, true], [false, true])
    func aNestedPinnedGroupAndItsWholeRunShowOnceInPinned(_ parentFolded: Bool, _ memberPinned: Bool) async throws {
        try await inSidebar { world, _ in
            world.manager.toggleWorkspaceGroupPinned(groupId: world.n)
            if memberPinned { world.manager.setPinned(world.w("n1"), pinned: true) }
            world.fold(world.r, parentFolded)
            let order = world.tabOrder, parents = world.parents, memberships = world.memberships
            let ids = world.items()
            let boundary = try #require(ids.firstIndex(of: .workspacesArea()))
            let pinned = Array(ids.prefix(boundary))
            #expect(pinned == [.pinnedArea()] + world.rows(["#N", "n1", "#M", "m1", "n2"]))
            for id in world.rows(["#N", "n1", "#M", "m1", "n2"]) { #expect(ids.filter { $0 == id }.count == 1) }
            #expect(ids.firstIndex(of: .group(world.r))! > boundary)
            let layout = SidebarStatusAreaLayout(items: world.resolution().items, tabs: world.manager.tabs, groups: world.manager.workspaceGroups,
                statusProjection: world.projection())
            #expect(layout.owner(of: .group(world.n)) == "group:\(world.n.uuidString)")
            #expect(layout.owner(of: .workspace(world.w("n1").id)) == "group:\(world.n.uuidString)")
            #expect(layout.pinnedSectionMemberIds.isSuperset(of: Set(["n", "n1", "m", "m1", "n2"].map { world.w($0).id })))
            #expect(!layout.workspacesSectionMemberIds.contains(world.w("n1").id))
            #expect(world.tabOrder == order && world.parents == parents && world.memberships == memberships)
        }
    }

    @Test func separatePinsAndHoistedGroupsKeepTheirTabOrderInPinned() async throws {
        try await inSidebar { world, _ in
            world.manager.toggleWorkspaceGroupPinned(groupId: world.n)
            world.manager.setPinned(world.w("g1"), pinned: true)
            let earlier = [world.w("g"), world.w("g1")]
            world.manager.tabs = earlier + world.manager.tabs.filter { !earlier.map(\.id).contains($0.id) }
            let ids = world.items()
            let boundary = try #require(ids.firstIndex(of: .workspacesArea()))
            #expect(Array(ids.prefix(boundary)) == [.pinnedArea(), .workspace(world.w("g1").id)] + world.rows(["#N", "n1", "#M", "m1", "n2"]))
        }
    }

    @Test func aNestedPinnedBranchLeavesItsParentsStatus() async throws {
        try await inSidebar { world, _ in
            try world.setStatus(world.r, "parked")
            world.manager.toggleWorkspaceGroupPinned(groupId: world.n)
            let ids = world.items()
            let pinnedEnd = try #require(ids.firstIndex(of: .workspacesArea()))
            #expect(ids.firstIndex(of: .group(world.n))! < pinnedEnd)
            #expect(ids.firstIndex(of: .group(world.r))! > ids.firstIndex(of: .statusGroup("parked"))!)
            let projection = try #require(world.projection()?.workspaceGroups)
            #expect(projection.statusIdByGroupId[world.n] == nil)
            #expect(projection.statusIdByWorkspaceId[world.w("m1").id] == nil)
        }
    }

    @Test(arguments: ["builtin", "controlsOff"])
    func withoutSectionHeadersANestedPinnedGroupKeepsTheOrdinaryWalk(_ mode: String) async throws {
        try await inSidebar(controls: mode != "controlsOff", source: mode == "builtin" ? "{}" : nil) { world, _ in
            world.manager.toggleWorkspaceGroupPinned(groupId: world.n)
            let groups = Dictionary(uniqueKeysWithValues: world.manager.workspaceGroups.map { ($0.id, $0) })
            let base = SidebarWorkspaceRenderItem.renderItems(tabs: world.manager.tabs, groupsById: groups, orderedGroups: world.manager.workspaceGroups)
            #expect(world.items() == base.map(\.id))
            #expect(!world.items().contains(.pinnedArea()))
        }
    }

    @Test func unpinningTheGroupKeepsItsStillPinnedMemberAloneInPinned() async throws {
        try await inSidebar { world, _ in
            world.manager.toggleWorkspaceGroupPinned(groupId: world.n)
            world.manager.setPinned(world.w("n1"), pinned: true)
            #expect(world.items().first == .pinnedArea(), "the group first arrives in Pinned")
            world.manager.toggleWorkspaceGroupPinned(groupId: world.n)
            let ids = world.items()
            let boundary = try #require(ids.firstIndex(of: .workspacesArea()))
            #expect(Array(ids.prefix(boundary)) == [.pinnedArea(), .workspace(world.w("n1").id)])
            #expect(ids.firstIndex(of: .group(world.n))! > boundary)
            #expect(ids.firstIndex(of: .group(world.n))! < ids.firstIndex(of: .workspace(world.w("r1").id))!)
            #expect(world.group(world.n).parentGroupId == world.r && world.w("n1").groupId == world.n)
        }
    }

    @Test func selectionOpensThePinnedGroupsOwnFoldAndLeavesItsModelParentFolded() async throws {
        try await inSidebar { world, _ in
            world.manager.toggleWorkspaceGroupPinned(groupId: world.n)
            world.manager.selectWorkspace(world.w("u"))
            world.fold(world.r, true); world.fold(world.n, true)
            world.manager.selectWorkspace(world.w("n1"))
            #expect(world.group(world.r).isCollapsed, "the parent's fold does not hide the hoisted group")
            #expect(!world.group(world.n).isCollapsed, "its own fold still hides its member")
        }
    }

    @Test func pinningTheNestedGroupOpensPinnedAndUnpinningOpensItsParent() async throws {
        try await inSidebar { world, state in
            state.installMoveReveal(on: world.manager)
            world.manager.selectWorkspace(world.w("u"))
            world.fold(world.r, true); world.fold(world.n, true)
            state.setStatusGroups(.init(workspacesCollapsed: true, pinnedCollapsed: true))
            world.manager.toggleWorkspaceGroupPinned(groupId: world.n)
            #expect(state.statusGroups?.pinnedCollapsed == false, "the nested group arrived in Pinned")
            #expect(world.group(world.r).isCollapsed && world.group(world.n).isCollapsed, "pinning leaves both model folds alone")
            world.manager.toggleWorkspaceGroupPinned(groupId: world.n)
            #expect(!world.group(world.r).isCollapsed && world.group(world.n).isCollapsed, "unpin opens the parent and preserves the group's own fold")
            #expect(state.statusGroups?.workspacesCollapsed == false)
        }
    }

    @Test func theParentsFoldedBadgeLeavesOutTheHoistedBranchButItsOwnBadgeKeepsItsMembers() async throws {
        try await inSidebar { world, _ in
            world.manager.toggleWorkspaceGroupPinned(groupId: world.n)
            world.manager.setPinned(world.w("n1"), pinned: true)
            let groups = Dictionary(uniqueKeysWithValues: world.manager.workspaceGroups.map { ($0.id, $0) })
            let effective = SidebarWorkspaceRenderItem.effectiveGroupIdByWorkspaceId(tabs: world.manager.tabs, groupsById: groups)
            let inside = SidebarNestedWorkspaceRows.workspaceIdsInside(tabs: world.manager.tabs, groupsById: groups, effectiveMembership: effective)
            let parentBadge = VerticalTabsSidebar.foldedGroupBadgeWorkspaceIds(group: world.group(world.r), memberWorkspaceIds: inside[world.r] ?? [],
                projection: world.projection(), tabs: world.manager.tabs, groups: world.manager.workspaceGroups)
            #expect(!parentBadge.contains(world.w("n1").id) && !parentBadge.contains(world.w("m1").id))
            let ownBadge = VerticalTabsSidebar.foldedGroupBadgeWorkspaceIds(group: world.group(world.n), memberWorkspaceIds: inside[world.n] ?? [],
                projection: world.projection(), tabs: world.manager.tabs, groups: world.manager.workspaceGroups)
            #expect(ownBadge.contains(world.w("n1").id) && ownBadge.contains(world.w("m1").id))
            #expect(inside[world.r]?.contains(world.w("n1").id) == true, "group-wide actions retain the whole branch")
        }
    }

    #if DEBUG
    @Test(arguments: [false, true])
    func aHoistedGroupsMountedHeaderAndRowsIndentLikeATopLevelPinnedGroup(_ parentFolded: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let handle = try SidebarNestedRootStatusTests.installStatusListHandle(); defer { handle.restore() }
            let harness = SidebarSectionIndentMountedTests()
            let world = try SidebarSectionIndentMountedTests.World(colored: false)
            let child = try #require(world.m)
            world.manager.toggleWorkspaceGroupPinned(groupId: child)
            world.manager.setPinned(world.w("m1"), pinned: true)
            world.manager.setWorkspaceGroupCollapsed(groupId: world.r, isCollapsed: parentFolded)
            let mounted = try await harness.mount(world.manager); defer { harness.close(mounted) }
            #expect(try harness.depth(mounted, group: child) == harness.depth(mounted, group: world.g))
            let childRow = try #require(try harness.memberCell(mounted, "m1", in: world).currentModelForMeasurement)
            let topRow = try #require(try harness.memberCell(mounted, "g1", in: world).currentModelForMeasurement)
            #expect(childRow.depth == topRow.depth)
            #expect(childRow.indentPoints(width: 280) == topRow.indentPoints(width: 280))
        }
    }
    #endif
}

extension SidebarGroupedPinTests {
    @Test(arguments: [false, true])
    func aFoldedGroupsSeparatePinKeepsItsDigitAndRowNumber(_ nested: Bool) async throws {
        try await inSidebar(nested: nested) { f, manager, state in
            let first = Workspace(); manager.tabs.insert(first, at: 0)
            for workspace in manager.tabs { workspace.hideTaskStatus() }
            let index = try #require(manager.tabs.firstIndex { $0.id == f.pin.id })
            let before = VerticalTabsSidebar.statusRenderItemsForSnapshot(tabManager: manager, state: state).numberedWorkspaceIndexById[f.pin.id]
            for group in f.groups { manager.setWorkspaceGroupCollapsed(groupId: group.id, isCollapsed: true) }
            #expect(WorkspaceShortcutMapper.digitForWorkspace(atFlatIndex: index, eligibility: manager.workspaceShortcutEligibility) == 2)
            let rendered = VerticalTabsSidebar.statusRenderItemsForSnapshot(tabManager: manager, state: state)
            #expect(rendered.items.map(\.id).contains(.workspace(f.pin.id)))
            #expect(rendered.numberedWorkspaceIndexById[f.pin.id] == before, "the visible pin retains its row number while its model groups are folded")
        }
    }

    enum SectionExitCase: CaseIterable { case flatMember, nestedMember, nestedGroup }

    @Test(arguments: SectionExitCase.allCases, ["controlsOff", "builtin"])
    func theWindowRevealsItsSelectedPinWhenSectionsStopShowing(_ kind: SectionExitCase, _ how: String) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let handle = try SidebarNestedRootStatusTests.installStatusListHandle(); defer { handle.restore() }
            let f = Fixture(nested: kind != .flatMember)
            let manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false)
            manager.tabs = f.tabs; manager.workspaceGroups = f.groups
            if kind == .nestedGroup { manager.workspaceGroups[manager.workspaceGroups.count - 1].isPinned = true }
            manager.selectWorkspace(f.pin)
            for group in manager.workspaceGroups where kind != .nestedGroup || group.id != f.groups.last!.id {
                manager.setWorkspaceGroupCollapsed(groupId: group.id, isCollapsed: true)
            }
            let harness = SidebarSectionIndentMountedTests()
            let mounted = try await harness.mount(manager); defer { harness.close(mounted) }
            #expect(manager.workspaceGroups.contains { $0.isCollapsed })
            #expect(VerticalTabsSidebar.statusRenderItemsForSnapshot(tabManager: manager, state: SidebarState()).items.map(\.id).contains(.workspace(f.pin.id)))
            if how == "builtin" { try handle.rewrite("{}") }
            else { UserDefaults.standard.set(false, forKey: BetaFeaturesCatalogSection().workspaceTodoControls.userDefaultsKey) }
            await harness.drain(mounted.window)
            #expect(manager.workspaceGroups.allSatisfy { !$0.isCollapsed }, "the window opens the model folds that now hide its selection")
            #expect(manager.selectedTabId == f.pin.id)
            #expect(VerticalTabsSidebar.statusRenderItemsForSnapshot(tabManager: manager, state: SidebarState()).items.map(\.id).contains(.workspace(f.pin.id)))
        }
    }
}

extension SidebarGroupedPinDropTests {
    @Test(arguments: SidebarNestedStatusDropFixture.Renderer.allCases, [(false, false), (false, true), (true, false), (true, true)])
    func aDropOnAnotherSeparatePinIsRefusedInTheSameOrAnotherGroup(_ renderer: SidebarNestedStatusDropFixture.Renderer, _ settings: (Bool, Bool)) async throws {
        let (colored, sameGroup) = settings
        try await inDrop(colored: colored) { f in
            let targetWorkspace = f.w("l1")
            f.manager.addWorkspaceToGroup(workspaceId: targetWorkspace.id, groupId: sameGroup ? f.q : f.p)
            f.manager.setPinned(targetWorkspace, pinned: true)
            if colored { targetWorkspace.customColor = "#119933" }
            await f.applyRows()
            try f.begin(row: .workspace(f.source.id))
            let order = f.manager.tabs.map(\.id), membership = f.manager.tabs.map(\.groupId)
            let targets = f.targets(renderer)
            let target = try #require(targets.first { $0.workspaceId == targetWorkspace.id })
            let plan = try f.route(point: CGPoint(x: 60, y: target.frame.minY + target.frame.height * 0.25), targets: targets)
            #expect(plan == nil, "a row drawn on its own in Pinned is not a group join target")
            #expect(f.manager.tabs.map(\.id) == order && f.manager.tabs.map(\.groupId) == membership)
        }
    }
}

extension SidebarGroupedPinTests {
    @Test(arguments: ["controlsOn", "controlsOff", "builtin", "empty"])
    func selectionAndRenderingUseTheSameSectionVisibilityGate(_ mode: String) async throws {
        try await inSidebar(nested: false, controls: mode != "controlsOff", source: mode == "builtin" ? "{}" : nil) { f, manager, state in
            let input = mode == "empty" ? WorkspaceStatusList(entries: [], source: .file) : AppDelegate.statusListInUse
            let place = state.statusSidePlace(containing: f.pin, list: input, resolvedHexByStatusId: [:], workspaceGroups: manager.workspaceGroups)
            let projection = VerticalTabsSidebar.statusGroupProjection(items: VerticalTabsSidebar.statusGroupProjectionItems(tabs: manager.tabs, list: input, groups: manager.workspaceGroups),
                list: input, colorHexes: [:], controlsEnabled: mode != "controlsOff", workspaceGroups: manager.workspaceGroups)
            #expect((place != nil) == (projection != nil))
            #expect((place != nil) == (mode == "controlsOn"))
        }
    }
}
