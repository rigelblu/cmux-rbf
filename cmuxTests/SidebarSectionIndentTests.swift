import AppKit
import CmuxFoundation
import CmuxNotifications
import CmuxSettings
import CmuxSidebar
import CmuxUpdater
import CmuxWorkspaces
import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private enum BandFailure: Error { case noBand }

/// The x, in points, of the first column along the middle of `view` whose pixel differs from the leftmost one: where a band begins.
@MainActor
private func firstColumnThatIsNotTheBackground(of view: NSView) throws -> CGFloat {
    let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    let scale = CGFloat(rep.pixelsWide) / view.bounds.width
    let y = rep.pixelsHigh / 2
    let background = try #require(rep.colorAt(x: 0, y: y))
    for x in 0..<rep.pixelsWide {
        guard let color = rep.colorAt(x: x, y: y) else { continue }
        let delta = abs(color.redComponent - background.redComponent) + abs(color.greenComponent - background.greenComponent)
            + abs(color.blueComponent - background.blueComponent) + abs(color.alphaComponent - background.alphaComponent)
        if delta > 0.02 { return CGFloat(x) / scale }
    }
    throw BandFailure.noBand
}

// `cm-110.12`: the rows under the `Pinned` and `Workspaces` headers sit one 12 pt level further in, the way status groups already sit
// under `Statuses` (Decisions, 2026-10-26 entry on section rows; it supersedes Q6 of 2026-10-24). `Statuses` and everything under it
// stay where they are, and a list with no section header (controls off, or the built-in list) stays flush. The first suite is the
// pure parts; the second mounts the real window and reads what the table drew.
@MainActor
@Suite("Section rows, the parts")
struct SidebarSectionIndentPartsTests {
    typealias Sidebar = VerticalTabsSidebar

    private func section(_ hex: String, members: [UUID]) -> SidebarWorkspaceColorSection {
        SidebarWorkspaceColorSection(id: .init(normalizedHex: hex, pinTier: .unpinned), title: "T", memberWorkspaceIds: members, isCollapsed: false)
    }

    @Test func theSectionSetHoldsEveryRowUnderPinnedAndWorkspacesAndNothingUnderStatuses() {
        let p = UUID(), a = UUID(), g = UUID(), gAnchor = UUID(), m = UUID(), c = UUID(), s = UUID(), qAnchor = UUID(), q = UUID()
        let colors = section("#14B8A6", members: [c])
        let items: [SidebarWorkspaceRenderItem] = [
            .pinnedHeader, .workspace(workspaceId: p),
            .workspacesHeader, .workspace(workspaceId: a), .groupHeader(groupId: g, anchorWorkspaceId: gAnchor), .workspace(workspaceId: m),
            .colorSectionHeader(section: colors), .workspace(workspaceId: c),
            .statusesHeader, .statusGroupHeader(statusId: "parked"), .workspace(workspaceId: s),
            .groupHeader(groupId: q, anchorWorkspaceId: qAnchor),
        ]
        let ids = SidebarNestedIndent.sectionIndentedItemIds(in: items)
        #expect(ids == [.workspace(p), .workspace(a), .group(g), .workspace(m), .colorSection(colors.id), .workspace(c)])
        #expect(!ids.contains(.workspace(s)) && !ids.contains(.group(q)), "Statuses and what sits under it are not in the set")
        #expect(SidebarNestedIndent.sectionIndent(in: items) == 1)
    }

    @Test func theSectionSetFollowsTheItemsWhenStatusesComeFirst() {
        let s = UUID(), p = UUID(), a = UUID()
        let items: [SidebarWorkspaceRenderItem] = [
            .statusesHeader, .statusGroupHeader(statusId: "parked"), .workspace(workspaceId: s),
            .pinnedHeader, .workspace(workspaceId: p), .workspacesHeader, .workspace(workspaceId: a),
        ]
        #expect(SidebarNestedIndent.sectionIndentedItemIds(in: items) == [.workspace(p), .workspace(a)])
    }

    /// Each section header opens the section on its own: the set must not depend on a `Pinned` header coming first.
    @Test func eachSectionHeaderOpensItsSectionWithoutAPinnedHeader() {
        let a = UUID(), g = UUID(), s = UUID(), p = UUID()
        let workspacesFirst: [SidebarWorkspaceRenderItem] = [
            .workspacesHeader, .workspace(workspaceId: a), .groupHeader(groupId: g, anchorWorkspaceId: UUID()),
            .statusesHeader, .statusGroupHeader(statusId: "parked"), .workspace(workspaceId: s),
        ]
        #expect(SidebarNestedIndent.sectionIndentedItemIds(in: workspacesFirst) == [.workspace(a), .group(g)])
        let statusesFirst: [SidebarWorkspaceRenderItem] = [
            .statusesHeader, .statusGroupHeader(statusId: "parked"), .workspace(workspaceId: s), .workspacesHeader, .workspace(workspaceId: a),
        ]
        #expect(SidebarNestedIndent.sectionIndentedItemIds(in: statusesFirst) == [.workspace(a)])
        let pinnedAlone: [SidebarWorkspaceRenderItem] = [
            .pinnedHeader, .workspace(workspaceId: p), .statusesHeader, .statusGroupHeader(statusId: "parked"), .workspace(workspaceId: s),
        ]
        #expect(SidebarNestedIndent.sectionIndentedItemIds(in: pinnedAlone) == [.workspace(p)])
    }

    /// The SwiftUI list's color group row (`statusColorHeaderRow`) hands its indent to the header it draws; read off the pixels.
    @Test func theSwiftUIColorGroupRowDrawsItsBandOneLevelFurtherIn() throws {
        func band(_ levels: Int) throws -> CGFloat {
            let row = Sidebar.statusColorHeaderRow(section: section("#14B8A6", members: [UUID()]), colorScheme: .light, indentLevels: levels,
                collectTargets: false, toggle: { _ in }, frameChanged: { _, _ in }, disappeared: { _ in })
            let hosting = NSHostingView(rootView: row.frame(width: 240, height: 40))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            defer { window.contentView = nil; window.close() }
            for _ in 0..<20 {
                hosting.layoutSubtreeIfNeeded()
                _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
            }
            return try firstColumnThatIsNotTheBackground(of: hosting)
        }
        let flush = try band(0), indented = try band(SidebarNestedIndent.sectionLevels)
        #expect(abs((indented - flush) - 12) <= 1.5, "the band starts 12 pt further in (\(flush) -> \(indented))")
    }

    @Test func aListWithNoSectionHeaderHasNoSectionIndent() {
        let items: [SidebarWorkspaceRenderItem] = [.workspace(workspaceId: UUID()), .groupHeader(groupId: UUID(), anchorWorkspaceId: UUID())]
        #expect(SidebarNestedIndent.sectionIndentedItemIds(in: items).isEmpty)
        #expect(SidebarNestedIndent.sectionIndent(in: items) == 0)
        #expect(SidebarNestedIndent.sectionIndent(in: []) == 0)
    }

    /// The table keeps a hosted header while it is equal to the one it already shows, so a header that moved in must not be equal.
    @Test func aColorGroupHeaderThatMovedInIsNotTheSameHeaderForTheTable() {
        let flush = SidebarWorkspaceColorSectionHeader(section: section("#14B8A6", members: [UUID()]), colorScheme: .light, onToggle: {})
        var indented = flush
        indented.indentLevels = SidebarNestedIndent.sectionLevels
        #expect(flush == flush && indented == indented)
        #expect(flush != indented)
    }

    @Test func aRowsDepthTakesTheSectionLevelOnTopOfWhatItHeldBefore() {
        let loose = UUID(), flatMember = UUID(), nestedMember = UUID(), header = UUID(), statusRow = UUID()
        let map = [nestedMember: 2, header: 1]
        let none: WorkspaceStatusGroupProjection? = nil
        func depth(_ id: UUID, section: Int, held: Int = 0, projection: WorkspaceStatusGroupProjection? = none, map: [UUID: Int] = map) -> Int {
            Sidebar.rowDepth(of: id, rowDepthById: map, statusGroupProjection: projection, sectionIndent: section, heldLevels: held)
        }
        // Under a section header: a loose row is 1, a flat group's member 2, a nested member and a nested header one more than before.
        #expect(depth(loose, section: 1) == 1)
        #expect(depth(flatMember, section: 1, held: 1, map: [:]) == 2)
        #expect(depth(nestedMember, section: 1) == 3)
        #expect(depth(header, section: 1) == 2)
        #expect(depth(UUID(), section: 1, map: [:]) == 1, "a group header of a flat window")
        // With no section header every one of them is what it was.
        #expect(depth(loose, section: 0) == 0)
        #expect(depth(flatMember, section: 0, held: 1, map: [:]) == 0, "a flat member's one step still comes from the row's own fallback")
        #expect(depth(nestedMember, section: 0) == 2)
        #expect(depth(header, section: 0) == 1)
        // A loose status member keeps the depth of the status group, whether or not it is given a section level.
        let projection = WorkspaceStatusGroupProjection(groups: [WorkspaceStatusGroup(statusId: "parked", memberWorkspaceIds: [statusRow])])
        #expect(depth(statusRow, section: 0, projection: projection) == 2)
        #expect(depth(statusRow, section: 1, projection: projection) == 2)
    }

    @Test func atTheDefaultWidthTheExtraLevelCostsOneLevelOfTellingGroupsApart() {
        // 240 pt allows 8 levels (96 pt). A header sits at its group's depth + 1 now, a member at depth + 2.
        func header(depth: Int) -> CGFloat { SidebarNestedIndent.points(levels: depth + 1, availableWidth: 240) }
        func member(depth: Int) -> CGFloat { SidebarNestedIndent.points(levels: depth + 2, availableWidth: 240) }
        #expect(header(depth: 6) == 84 && header(depth: 7) == 96 && header(depth: 8) == 96, "headers: depth 7 and 8 draw alike (before: 8 and 9)")
        #expect(member(depth: 5) == 84 && member(depth: 6) == 96 && member(depth: 7) == 96, "members: depth 6 and 7 draw alike (before: 7 and 8)")
        #expect(SidebarNestedIndent.points(levels: 1, availableWidth: 240) == 12 && SidebarNestedIndent.sectionLevels == 1)
        #expect(SidebarNestedIndent.points(levels: 1, availableWidth: 20) == 12, "one level always fits, so a loose row under a section is 12 pt at any width")
    }

    // MARK: the drop line

    private func plan(_ action: SidebarWorkspaceReorderDropAction, dragged: UUID = UUID()) -> SidebarWorkspaceReorderDropPlan {
        SidebarWorkspaceReorderDropPlan(draggedWorkspaceId: dragged, indicator: .init(tabId: UUID(), edge: .top), indicatorScope: .raw, action: action)
    }

    @Test func aDropLineInAWindowWithSectionHeadersStartsAtTheLevelOfTheRowsItLandsAmong() {
        let group = UUID()
        func level(_ action: SidebarWorkspaceReorderDropAction, section: Int, depths: [UUID: Int] = [:]) -> Int? {
            SidebarNestedDropLine.level(for: plan(action), depthById: depths, sectionIndent: section)
        }
        let loose = SidebarWorkspaceReorderDropAction.reorder(targetIndex: 0, usesTopLevelRows: true, explicitGroupId: nil)
        let joined = SidebarWorkspaceReorderDropAction.reorder(targetIndex: 0, usesTopLevelRows: false, explicitGroupId: group)
        #expect(level(loose, section: 1) == 1, "among loose rows, which sit at level 1 under Workspaces")
        #expect(level(joined, section: 1) == 2, "inside a flat group, whose members sit at level 2")
        #expect(level(.reorderGroup(targetIndex: 0), section: 1) == 1)
        #expect(level(.crossWindow(insertionIndex: 0, proposedInsertionIndex: 0), section: 1) == 1)
        #expect(level(.colorSection(targetWorkspaceId: UUID(), insertBefore: true, memberWorkspaceIds: []), section: 1) == 2, "a color group's members sit one in from its header")
        // The depths it is given already count the section level (the app adds it before the lookup); a member is one in from its group.
        #expect(level(joined, section: 1, depths: [group: 2]) == 3)
        // With no section header it is what it was: nothing in a flat window, the depths in a nested one.
        #expect(level(loose, section: 0) == nil && level(joined, section: 0) == nil)
        #expect(level(.crossWindow(insertionIndex: 0, proposedInsertionIndex: 0), section: 0) == nil)
        #expect(level(loose, section: 0, depths: [group: 1]) == 0 && level(joined, section: 0, depths: [group: 1]) == 2)
        // The status drops keep their own levels either way.
        #expect(SidebarStatusHeaderDropAdapter.lineLevel(for: .moveStatusesArea(aboveRow: "top", belowRow: nil, last: true, sessionId: UUID())) == 0)
    }

    @Test func theAppAddsTheSectionLevelToEveryGroupDepthButNotToAProjectedOne() {
        let list = WorkspaceStatusList(entries: [WorkspaceStatusEntry(id: "parked", name: "Parked", extends: .todo, color: "#765432")], source: .file)
        func make(status: String?) -> WorkspaceGroup {
            let id = UUID()
            var group = WorkspaceGroup(id: id, name: "Group", isCollapsed: false, isPinned: false, anchor: .workspace(UUID()),
                customColor: nil, iconSymbol: nil, parentGroupId: nil)
            group.statusId = status
            return group
        }
        let plain = make(status: nil), root = make(status: "parked")
        // `plain` is 1 deep under Workspaces (a nested window's map says 1); `root` is a root under Parked, whose depth (2) already
        // counts Statuses and the status header.
        let projection = WorkspaceStatusGroupProjection(groups: [],
            workspaceGroups: WorkspaceGroupStatusProjection(groups: [plain, root], list: list))
        let nested = SidebarWorkspaceReorderDropAction.reorder(targetIndex: 0, usesTopLevelRows: false, explicitGroupId: plain.id)
        let underStatus = SidebarWorkspaceReorderDropAction.reorder(targetIndex: 0, usesTopLevelRows: false, explicitGroupId: root.id)
        func level(_ action: SidebarWorkspaceReorderDropAction, section: Int) -> Int? {
            Sidebar.workspaceProjectedStatusDropLineLevel(for: plan(action), depthById: [plain.id: 1, root.id: 0], projection: projection, sectionIndent: section)
        }
        #expect(level(nested, section: 1) == 3, "depth 1 + section 1, and one in from its group")
        #expect(level(nested, section: 0) == 2, "no section header: as before")
        #expect(level(underStatus, section: 1) == 3 && level(underStatus, section: 0) == 3, "a projected group keeps its own depth (2) plus one, section or not")
    }
}

#if DEBUG
@MainActor
@Suite("Section rows, the mounted window", .serialized)
struct SidebarSectionIndentMountedTests {
    typealias Status = SidebarNestedRootStatusTests

    /// `Pinned`: `p1`, and the pinned group `G[g, g1]` (`pinned: false` pins nothing, so there is no `Pinned` header and `p1` and `G` sit
    /// under `Workspaces` with the rest). `Workspaces`: `u`, `w`, a colored `c1`, and `R[r, r1, M[m, m1]]` (`M` only when nested).
    /// `Statuses`: `v` with its own status Doing, and `Q[q, q1]` with the status Parked.
    @MainActor
    final class World {
        let manager: TabManager
        let ws: [String: Workspace]
        let g: UUID, r: UUID, m: UUID?, q: UUID
        init(nested: Bool = true, colored: Bool = true, pinned: Bool = true) throws {
            let manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false)
            var ws: [String: Workspace] = [:]
            let keys = ["p1", "g1", "u", "w", "c1", "r1", "m1", "v", "q1"]
            for key in keys { let workspace = Workspace(); workspace.hideTaskStatus(); ws[key] = workspace }
            manager.tabs = keys.compactMap { ws[$0] }
            let g = try #require(manager.createWorkspaceGroup(name: "G", childWorkspaceIds: [ws["g1"]!.id]))
            let r = try #require(manager.createWorkspaceGroup(name: "R", childWorkspaceIds: [ws["r1"]!.id]))
            let q = try #require(manager.createWorkspaceGroup(name: "Q", childWorkspaceIds: [ws["q1"]!.id]))
            var m: UUID?
            if nested {
                m = try #require(manager.createWorkspaceGroup(name: "M", childWorkspaceIds: [ws["m1"]!.id]))
                _ = manager.moveWorkspaceGroup(groupId: try #require(m), intoParent: r)
                ws["m"] = try #require(manager.workspaceGroupAnchor(for: try #require(m)))
            } else {
                manager.tabs.removeAll { $0.id == ws["m1"]!.id }; ws["m1"] = nil
            }
            for (key, group) in [("g", g), ("r", r), ("q", q)] { ws[key] = try #require(manager.workspaceGroupAnchor(for: group)) }
            for workspace in ws.values { workspace.hideTaskStatus() }
            if pinned {
                manager.toggleWorkspaceGroupPinned(groupId: g)
                manager.setPinned(ws["p1"]!, pinned: true)
            }
            let order = ["p1", "g", "g1", "u", "w", "c1", "r", "r1", "m", "m1", "v", "q", "q1"]
            manager.tabs = order.compactMap { ws[$0] }
            if colored { ws["c1"]!.customColor = WorkspaceTabColorSettings.labeledPaletteEntries().first!.hex }
            self.manager = manager; self.ws = ws; self.g = g; self.r = r; self.m = m; self.q = q
        }
        func w(_ key: String) -> Workspace { ws[key]! }
        func setStatuses() throws {
            let list = AppDelegate.statusListInUse
            try #require(w("v").setOwnStatus(try #require(list.entry(id: "doing")), list: list))
            let actions = WorkspaceGroupStatusUIActions(tabManager: manager, writer: .init(list: list, resolveColor: { $0 }), controlsEnabled: true)
            try #require(actions.applyGroup(.status(id: "parked"), groupId: q))
        }
    }

    @MainActor
    struct Mounted {
        let window: NSWindow
        let table: NSTableView
        let controller: SidebarWorkspaceTableController
        let defaults: UserDefaults
        let suite: String
    }

    private func descendants<View: NSView>(of type: View.Type, in root: NSView?) -> [View] {
        guard let root else { return [] }
        var matches: [View] = []
        if let match = root as? View { matches.append(match) }
        for subview in root.subviews { matches.append(contentsOf: descendants(of: type, in: subview)) }
        return matches
    }

    func drain(_ window: NSWindow, iterations: Int = 40) async {
        for _ in 0..<iterations {
            window.contentView?.layoutSubtreeIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
            await Task.yield()
        }
    }

    /// The real `ContentView` with the AppKit table, in a window tall enough to realize every row.
    func mount(_ manager: TabManager) async throws -> Mounted {
        _ = NSApplication.shared
        let suite = "SidebarSectionIndentMountedTests.mounted"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(CmuxExtensionSidebarSelection.defaultProviderId, forKey: CmuxExtensionSidebarSelection.defaultsKey)
        let flags = CmuxFeatureFlags(defaults: defaults, remoteFlagValueProvider: { _ in nil })
        flags.setOverride(true, for: CmuxFeatureFlags.appKitSidebarListFlag)
        let root = ContentView(updateViewModel: UpdateStateModel(), windowId: UUID(), featureFlags: flags)
            .environmentObject(manager)
            .environmentObject(TerminalNotificationStore.shared)
            .environmentObject(SidebarState())
            .environmentObject(SidebarSelectionState())
            .environmentObject(FileExplorerState())
            .environmentObject(CmuxConfigStore())
            .defaultAppStorage(defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 1800), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = MainWindowHostingView(rootView: root)
        await drain(window, iterations: 80)
        let container = try #require(descendants(of: SidebarWorkspaceTableContainerView.self, in: window.contentView).first)
        let controller = try #require(container.tableView.dataSource as? SidebarWorkspaceTableController)
        return Mounted(window: window, table: container.tableView, controller: controller, defaults: defaults, suite: suite)
    }

    func close(_ mounted: Mounted) {
        mounted.window.contentView = nil
        mounted.window.close()
        mounted.defaults.removePersistentDomain(forName: mounted.suite)
    }

    /// The depth the table's own cell for a workspace row or a group header holds.
    func depth(_ mounted: Mounted, workspace key: String, in world: World) throws -> Int {
        let id = world.w(key).id
        let cell = try #require(descendants(of: SidebarWorkspaceRowTableCellView.self, in: mounted.table)
            .first { $0.currentModelForMeasurement?.workspaceId == id }, "row \(key) is drawn")
        return try #require(cell.currentModelForMeasurement).depth
    }

    func depth(_ mounted: Mounted, group id: UUID) throws -> Int {
        let cell = try #require(descendants(of: SidebarGroupHeaderTableCellView.self, in: mounted.table)
            .first { $0.currentModelForTesting?.groupId == id }, "the group's header is drawn")
        return try #require(cell.currentModelForTesting).depth
    }

    private func gate(_ body: @MainActor () async throws -> Void) async throws {
        try await AppContextSerialGate.withExclusiveAppContext { try await body() }
    }

    // MARK: rows

    @Test func everyRowUnderPinnedAndWorkspacesSitsOneLevelInAndStatusesDoNotMove() async throws {
        try await gate {
            let restore = try Status.installStatusList(); defer { restore() }
            let world = try World()
            try world.setStatuses()
            let mounted = try await mount(world.manager); defer { close(mounted) }
            // Under Workspaces (before: 0, 0, 1, 1, 2).
            #expect(try depth(mounted, workspace: "u", in: world) == 1, "a loose row")
            #expect(try depth(mounted, group: world.r) == 1, "a group header")
            #expect(try depth(mounted, workspace: "r1", in: world) == 2, "its member")
            #expect(try depth(mounted, group: try #require(world.m)) == 2, "a nested group's header")
            #expect(try depth(mounted, workspace: "m1", in: world) == 3, "and its member")
            // Under Pinned (before: 0, 0, 1).
            #expect(try depth(mounted, workspace: "p1", in: world) == 1, "a pinned workspace")
            #expect(try depth(mounted, group: world.g) == 1, "a pinned group's header")
            #expect(try depth(mounted, workspace: "g1", in: world) == 2, "a pinned group's member")
            // Under Statuses: where they were (a loose status member 2, a group under its status 2, its member 3).
            #expect(try depth(mounted, workspace: "v", in: world) == 2, "a loose row under a status")
            #expect(try depth(mounted, group: world.q) == 2, "a group header under a status")
            #expect(try depth(mounted, workspace: "q1", in: world) == 3, "and its member")
        }
    }

    /// Every other window here has a `Pinned` header, so none of them tells a `Workspaces` header that opens the section from a
    /// `Pinned` header that opened it first. This one pins nothing: the section the rows sit in is opened by `Workspaces` alone.
    @Test func withNothingPinnedTheRowsUnderWorkspacesStillSitOneLevelIn() async throws {
        try await gate {
            let restore = try Status.installStatusList(); defer { restore() }
            let world = try World(pinned: false)
            try world.setStatuses()
            let mounted = try await mount(world.manager); defer { close(mounted) }
            #expect(try depth(mounted, workspace: "p1", in: world) == 1, "a loose row that is not pinned")
            #expect(try depth(mounted, group: world.g) == 1, "a group header that is not pinned")
            #expect(try depth(mounted, workspace: "g1", in: world) == 2, "its member")
            #expect(try depth(mounted, workspace: "u", in: world) == 1, "a loose row")
            #expect(try depth(mounted, group: world.r) == 1, "a group header")
            #expect(try depth(mounted, workspace: "r1", in: world) == 2, "its member")
            #expect(try depth(mounted, group: try #require(world.m)) == 2, "a nested group's header")
            #expect(try depth(mounted, workspace: "m1", in: world) == 3, "and its member")
            #expect(try depth(mounted, workspace: "c1", in: world) == 2, "a color group's member")
            #expect(try depth(mounted, workspace: "v", in: world) == 2, "Statuses did not move")
            #expect(try depth(mounted, group: world.q) == 2)
            #expect(try depth(mounted, workspace: "q1", in: world) == 3)
        }
    }

    @Test func aWindowWithNoNestedGroupHasTheSameLevels() async throws {
        try await gate {
            let restore = try Status.installStatusList(); defer { restore() }
            let world = try World(nested: false)
            try world.setStatuses()
            let mounted = try await mount(world.manager); defer { close(mounted) }
            #expect(try depth(mounted, workspace: "u", in: world) == 1)
            #expect(try depth(mounted, group: world.r) == 1)
            #expect(try depth(mounted, workspace: "r1", in: world) == 2, "a flat group's member: its one step plus the section's")
            #expect(try depth(mounted, workspace: "p1", in: world) == 1)
            #expect(try depth(mounted, group: world.g) == 1)
            #expect(try depth(mounted, workspace: "g1", in: world) == 2)
            #expect(try depth(mounted, workspace: "v", in: world) == 2)
            #expect(try depth(mounted, group: world.q) == 2)
            #expect(try depth(mounted, workspace: "q1", in: world) == 3)
        }
    }

    @Test func aColorGroupAndItsMembersMoveInWithTheOtherRows() async throws {
        try await gate {
            let restore = try Status.installStatusList(); defer { restore() }
            let world = try World()
            try world.setStatuses()
            let mounted = try await mount(world.manager); defer { close(mounted) }
            #expect(try depth(mounted, workspace: "c1", in: world) == 2, "a color group's member: its one step under the header plus the section's")
            let band = try colorBandStart(mounted, memberCell: try memberCell(mounted, "c1", in: world))
            restore()
            let flushRestore = try Status.installStatusList(controls: false); defer { flushRestore() }
            let flushWorld = try World()
            let flush = try await mount(flushWorld.manager); defer { close(flush) }
            let flushBand = try colorBandStart(flush, memberCell: try memberCell(flush, "c1", in: flushWorld))
            #expect(abs((band - flushBand) - 12) <= 1.5, "the color group header's band starts 12 pt further in (\(flushBand) -> \(band))")
        }
    }

    func memberCell(_ mounted: Mounted, _ key: String, in world: World) throws -> SidebarWorkspaceRowTableCellView {
        let id = world.w(key).id
        return try #require(descendants(of: SidebarWorkspaceRowTableCellView.self, in: mounted.table)
            .first { $0.currentModelForMeasurement?.workspaceId == id }, "row \(key) is drawn")
    }

    /// The x, in points, where the color group header's band begins: the first column of the hosted cell that is not the sidebar's.
    /// The header is the row right above its first member.
    private func colorBandStart(_ mounted: Mounted, memberCell: SidebarWorkspaceRowTableCellView) throws -> CGFloat {
        let row = mounted.table.row(for: memberCell) - 1
        let cell = try #require(mounted.table.view(atColumn: 0, row: row, makeIfNecessary: false), "the color group header is drawn")
        return try firstColumnThatIsNotTheBackground(of: cell)
    }


    @Test(arguments: ["controlsOff", "builtInList"])
    func withNoSectionHeaderEveryRowIsFlushAsBefore(_ how: String) async throws {
        try await gate {
            let restore = how == "controlsOff" ? try Status.installStatusList(controls: false) : try Status.installStatusList(source: "{}")
            defer { restore() }
            let world = try World()
            let mounted = try await mount(world.manager); defer { close(mounted) }
            #expect(try depth(mounted, workspace: "u", in: world) == 0)
            #expect(try depth(mounted, group: world.r) == 0)
            #expect(try depth(mounted, workspace: "r1", in: world) == 1)
            #expect(try depth(mounted, group: try #require(world.m)) == 1)
            #expect(try depth(mounted, workspace: "m1", in: world) == 2)
            #expect(try depth(mounted, workspace: "p1", in: world) == 0)
            #expect(try depth(mounted, group: world.g) == 0)
            #expect(try depth(mounted, workspace: "g1", in: world) == 1)
            #expect(try depth(mounted, workspace: "v", in: world) == 0)
            #expect(try depth(mounted, group: world.q) == 0)
        }
    }

    // MARK: the drop line, and where a drop lands

    private func drop(_ mounted: Mounted, _ dragged: String, _ target: String, _ zone: String, side: String = "right") throws -> SidebarDebugDropResult {
        let request = try #require(SidebarDebugDropRequest(params: ["drag": dragged, "target": target, "zone": zone, "side": side]))
        return try #require(mounted.controller.debugPerformSidebarDrop(request), "the drop \(dragged) -> \(target) \(zone) is measured")
    }

    @Test func aDropLineStartsAtTheIndentOfTheRowsItLandsAmong() async throws {
        try await gate {
            let restore = try Status.installStatusList(); defer { restore() }
            let world = try World()
            try world.setStatuses()
            let mounted = try await mount(world.manager); defer { close(mounted) }
            @MainActor func ref(_ key: String) -> String { "workspace:\(world.w(key).id.uuidString)" }
            // Loose rows under Workspaces sit at level 1: the line before `u` starts there. (The pointer is on the left of the
            // sidebar: on the right, above `u` is the end of the pinned group G, and the drop would join it, at level 2.)
            let loose = try drop(mounted, ref("w"), ref("u"), "upper", side: "left")
            #expect(loose.performed && loose.paint?.level == 1, "among loose rows under Workspaces (level \(String(describing: loose.paint?.level)))")
            await drain(mounted.window)
            // Inside R, next to r1 (level 2) and inside the nested M, next to m1 (level 3).
            let inR = try drop(mounted, ref("u"), ref("r1"), "upper")
            #expect(inR.performed && inR.paint?.level == 2, "among R's members (level \(String(describing: inR.paint?.level)))")
            await drain(mounted.window)
            let inM = try drop(mounted, ref("u"), ref("m1"), "upper")
            #expect(inM.performed && inM.paint?.level == 3, "among the nested M's members (level \(String(describing: inM.paint?.level)))")
            await drain(mounted.window)
            // Under Pinned: among the pinned rows, and among a pinned group's members.
            let pinned = try drop(mounted, ref("p1"), ref("g1"), "lower")
            #expect(pinned.paint?.level == 2, "among a pinned group's members (level \(String(describing: pinned.paint?.level)))")
            // Under Statuses: where it was, in the group under Parked (its depth 2, and one in from it).
            let under = try drop(mounted, ref("c1"), ref("q1"), "upper")
            #expect(under.paint?.level == 3, "among the members of a group under a status (level \(String(describing: under.paint?.level)))")
        }
    }

    @Test func aWindowWithNoNestedGroupDrawsItsLinesAtTheSectionLevelToo() async throws {
        try await gate {
            let restore = try Status.installStatusList(); defer { restore() }
            let world = try World(nested: false)
            try world.setStatuses()
            let mounted = try await mount(world.manager); defer { close(mounted) }
            @MainActor func ref(_ key: String) -> String { "workspace:\(world.w(key).id.uuidString)" }
            let loose = try drop(mounted, ref("w"), ref("u"), "upper", side: "left")
            #expect(loose.paint?.level == 1, "no nested group, yet the line is not left flush (level \(String(describing: loose.paint?.level)))")
            await drain(mounted.window)
            let inR = try drop(mounted, ref("u"), ref("r1"), "upper")
            #expect(inR.paint?.level == 2, "inside a flat group (level \(String(describing: inR.paint?.level)))")
        }
    }

    /// What a drop does to the tab order and the membership, as keys: the same drop is run in a window with section headers and in
    /// one without. The planner reads the pointer against the sidebar's middle and the row's edges, never against an indent, so the
    /// indent that moved must not move where a nesting drop lands. (Pins the finding of #cm-110.12.)
    private func outcome(sectioned: Bool, dragged: String, target: String, zone: String, side: String) async throws -> [String] {
        let restore = try Status.installStatusList(controls: sectioned); defer { restore() }
        let world = try World()
        let mounted = try await mount(world.manager); defer { close(mounted) }
        let request = try #require(SidebarDebugDropRequest(params: ["drag": "workspace:\(world.w(dragged).id.uuidString)",
            "target": "workspace:\(world.w(target).id.uuidString)", "zone": zone, "side": side]))
        let result = try #require(mounted.controller.debugPerformSidebarDrop(request))
        let key = Dictionary(uniqueKeysWithValues: world.ws.map { ($0.value.id, $0.key) })
        let groups = Dictionary(uniqueKeysWithValues: [(world.g, "G"), (world.r, "R"), (world.m!, "M"), (world.q, "Q")])
        return ["performed=\(result.performed)"] + world.manager.tabs.map { tab in
            "\(key[tab.id] ?? "?")@\(tab.groupId.flatMap { groups[$0] } ?? "-")"
        }
    }

    @Test(arguments: [("r1", "upper", "left"), ("r1", "upper", "right"), ("m1", "lower", "left"), ("m1", "lower", "right")])
    func aNestingDropLandsWhereItDidWhateverTheIndent(_ target: String, _ zone: String, _ side: String) async throws {
        try await gate {
            let withSections = try await outcome(sectioned: true, dragged: "u", target: target, zone: zone, side: side)
            let flush = try await outcome(sectioned: false, dragged: "u", target: target, zone: zone, side: side)
            #expect(withSections.first == "performed=true")
            #expect(withSections == flush, "u dropped on the \(zone) of \(target), pointer on the \(side): \(withSections) vs \(flush)")
        }
    }
}
#endif

#if DEBUG
extension SidebarSectionIndentMountedTests {
    @Test(arguments: [false, true], [false, true])
    func aGroupedPinHasTheSameRenderedDepthAndIndentAsALoosePin(_ nested: Bool, _ colored: Bool) async throws {
        try await gate {
            let restore = try Status.installStatusList(); defer { restore() }
            let world = try World(nested: nested, colored: false)
            let key = nested ? "m1" : "r1"
            world.manager.setPinned(world.w(key), pinned: true)
            if colored {
                world.w(key).customColor = "#112233"
                world.w("p1").customColor = "#112233"
            }
            let mounted = try await mount(world.manager); defer { close(mounted) }
            let grouped = try #require(try memberCell(mounted, key, in: world).currentModelForMeasurement)
            let loose = try #require(try memberCell(mounted, "p1", in: world).currentModelForMeasurement)
            #expect(grouped.depth == loose.depth)
            #expect(grouped.indentPoints(width: 280) == loose.indentPoints(width: 280))
        }
    }
}
#endif

#if DEBUG
extension SidebarSectionIndentMountedTests {
    @Test(arguments: [false, true])
    func theMountedFoldedGroupBadgeLeavesOutItsPinAndThePinKeepsItsUnread(_ nested: Bool) async throws {
        try await gate {
            let restore = try Status.installStatusList(); defer { restore() }
            let world = try World(nested: nested, colored: false)
            world.manager.selectWorkspace(world.w("w"))
            world.manager.setPinned(world.w("r1"), pinned: true)
            world.manager.setWorkspaceGroupCollapsed(groupId: world.r, isCollapsed: true)
            let unread = TerminalNotificationStore.shared.sidebarUnread
            for (key, count) in [("r", 1), ("r1", 2)] {
                unread.applyWorkspaceSummaryProjection(forWorkspaceId: world.w(key).id,
                    summary: SidebarWorkspaceUnreadSummary(unreadCount: count, latestNotificationText: nil), totalUnreadCount: count)
            }
            defer { for key in ["r", "r1"] { unread.applyWorkspaceSummaryProjection(forWorkspaceId: world.w(key).id, summary: nil, totalUnreadCount: 0) } }
            let mounted = try await mount(world.manager); defer { close(mounted) }
            let header = try #require(descendants(of: SidebarGroupHeaderTableCellView.self, in: mounted.table)
                .first { $0.currentModelForTesting?.groupId == world.r })
            #expect(header.currentModelForTesting?.anchorUnreadCount == 1)
            #expect(try memberCell(mounted, "r1", in: world).currentModelForMeasurement?.unreadCount == 2)
        }
    }
}
#endif
