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

// `cm-110.3`: an unpinned nested workspace group with a status shows under its status, held as a view (Decisions, 2026-10-23 and the
// 2026-10-25 view entry). These tests drive the app's own wiring: the status list the app reads (`AppDelegate.statusListInUse`), the
// controls setting, the model closure `TabManager` sets, the sidebar's shared base-item builder and its snapshot path.
@MainActor
@Suite("A nested group under its status", .serialized)
struct SidebarNestedRootStatusTests {
    typealias Sidebar = VerticalTabsSidebar

    /// The app's real status store holding `parked` and `doing`, and Workspace Todo Controls set; `restore` puts both back.
    @MainActor
    final class StatusListHandle {
        let store: WorkspaceStatusListStore
        let file: URL
        let restore: () -> Void
        init(store: WorkspaceStatusListStore, file: URL, restore: @escaping () -> Void) { self.store = store; self.file = file; self.restore = restore }
        /// Rewrites the list file and has the store read it, as an edit of `cmux.json` does.
        func rewrite(_ json: String) throws {
            try json.write(to: file, atomically: true, encoding: .utf8)
            store.load()
        }
    }
    static var retainedDelegates: [AppDelegate] = []
    static let bothStatuses = ##"{"workspaceStatuses":[{"id":"parked","name":"Parked","extends":"todo","color":"#112233"},{"id":"doing","name":"Doing","extends":"working","color":"#334455"}]}"##
    static let onlyDoing = ##"{"workspaceStatuses":[{"id":"doing","name":"Doing","extends":"working","color":"#334455"}]}"##

    static func installStatusListHandle(source: String? = nil, controls: Bool = true) throws -> StatusListHandle {
        let suite = "cmux.nestedroot.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("cmux.json")
        try (source ?? bothStatuses).write(to: file, atomically: true, encoding: .utf8)
        let store = WorkspaceStatusListStore(fileURL: file, defaults: defaults, resolveColor: { $0 }, paletteFingerprint: { "fixed" }, clock: ContinuousClock())
        store.load()
        let previous = AppDelegate.shared, delegate = AppDelegate()
        delegate.workspaceStatusListStore = store
        AppDelegate.shared = delegate
        // A mounted window can hold the delegate past the test, and its last release then lands off the main thread, where
        // `AppDelegate`'s deinit asserts main-actor isolation and takes the test host down. Keep every one for the process.
        retainedDelegates.append(delegate)
        let key = BetaFeaturesCatalogSection().workspaceTodoControls.userDefaultsKey
        let previousControls = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(controls, forKey: key)
        return StatusListHandle(store: store, file: file, restore: {
            AppDelegate.shared = previous
            if let previousControls { UserDefaults.standard.set(previousControls, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        })
    }

    static func installStatusList(source: String? = nil, controls: Bool = true) throws -> () -> Void {
        try installStatusListHandle(source: source, controls: controls).restore
    }

    /// `u | R[r, r1, N[n, n1, M[m, m1], n2], r2] | G[g, g1] | v | p1 | Q[q, q1]` in that tab order. `N` sits between `r1` and `r2` of its
    /// parent `R`, and `M` sits inside `N`. `G` and `Q` are top-level, unpinned and have no status.
    @MainActor
    final class World {
        let manager: TabManager
        let ws: [String: Workspace]
        let r: UUID, n: UUID, m: UUID, g: UUID, q: UUID
        init() throws {
            let manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false)
            var ws: [String: Workspace] = [:]
            for key in ["u", "r1", "r2", "n1", "n2", "m1", "g1", "q1", "v", "p1"] {
                let workspace = Workspace(); workspace.hideTaskStatus(); ws[key] = workspace
            }
            manager.tabs = ["u", "r1", "r2", "n1", "n2", "m1", "g1", "q1", "v", "p1"].compactMap { ws[$0] }
            let r = try #require(manager.createWorkspaceGroup(name: "R", childWorkspaceIds: [ws["r1"]!.id, ws["r2"]!.id]))
            let n = try #require(manager.createWorkspaceGroup(name: "N", childWorkspaceIds: [ws["n1"]!.id, ws["n2"]!.id]))
            let m = try #require(manager.createWorkspaceGroup(name: "M", childWorkspaceIds: [ws["m1"]!.id]))
            let g = try #require(manager.createWorkspaceGroup(name: "G", childWorkspaceIds: [ws["g1"]!.id]))
            let q = try #require(manager.createWorkspaceGroup(name: "Q", childWorkspaceIds: [ws["q1"]!.id]))
            _ = manager.moveWorkspaceGroup(groupId: m, intoParent: n)
            _ = manager.moveWorkspaceGroup(groupId: n, intoParent: r)
            for (key, group) in [("r", r), ("n", n), ("m", m), ("g", g), ("q", q)] {
                ws[key] = try #require(manager.workspaceGroupAnchor(for: group))
            }
            for workspace in ws.values { workspace.hideTaskStatus() }
            manager.tabs = ["u", "r", "r1", "n", "n1", "m", "m1", "n2", "r2", "g", "g1", "v", "p1", "q", "q1"].compactMap { ws[$0] }
            self.manager = manager; self.ws = ws
            self.r = r; self.n = n; self.m = m; self.g = g; self.q = q
        }
        func w(_ key: String) -> Workspace { ws[key]! }
        var tabOrder: [UUID] { manager.tabs.map(\.id) }
        var parents: [UUID: UUID?] { Dictionary(uniqueKeysWithValues: manager.workspaceGroups.map { ($0.id, $0.parentGroupId) }) }
        var memberships: [UUID: UUID?] { Dictionary(uniqueKeysWithValues: manager.tabs.map { ($0.id, $0.groupId) }) }
        func group(_ id: UUID) -> WorkspaceGroup { manager.workspaceGroups.first { $0.id == id }! }
        func setStatus(_ id: UUID, _ status: String?) throws {
            let actions = WorkspaceGroupStatusUIActions(tabManager: manager,
                writer: .init(list: AppDelegate.statusListInUse, resolveColor: { $0 }), controlsEnabled: true)
            try #require(actions.applyGroup(status.map { .status(id: $0) } ?? .hide, groupId: id))
        }
        func setLooseStatus(_ key: String, _ status: String) throws {
            let list = AppDelegate.statusListInUse
            try #require(w(key).setOwnStatus(try #require(list.entry(id: status)), list: list))
        }
        func fold(_ id: UUID, _ folded: Bool) { manager.setWorkspaceGroupCollapsed(groupId: id, isCollapsed: folded) }
        /// What the sidebar's snapshot path builds: the same base-item builder, projection and resolver the window's body uses.
        func resolution(state: SidebarState = SidebarState()) -> SidebarStatusRenderItemsResolution {
            Sidebar.statusRenderItemsForSnapshot(tabManager: manager, state: state)
        }
        func items(state: SidebarState = SidebarState()) -> [SidebarWorkspaceRenderItemID] { resolution(state: state).items.map(\.id) }
        func projection() -> WorkspaceStatusGroupProjection? {
            Sidebar.currentStatusGroupProjection(tabs: manager.tabs, groups: manager.workspaceGroups)
        }
        func rows(_ keys: String...) -> [SidebarWorkspaceRenderItemID] { rows(keys) }
        /// `"r1"` is a workspace; `"#N"` is the header of the group `N` (r, n, m, g, q).
        func rows(_ keys: [String]) -> [SidebarWorkspaceRenderItemID] {
            keys.map { key in
                if key.hasPrefix("#") {
                    let groups: [String: UUID] = ["R": r, "N": n, "M": m, "G": g, "Q": q]
                    return .group(groups[String(key.dropFirst())]!)
                }
                return .workspace(w(key).id)
            }
        }
    }

    private func gate(_ body: @MainActor () async throws -> Void) async throws {
        try await AppContextSerialGate.withExclusiveAppContext { try await body() }
    }

    private let areas: (workspaces: SidebarWorkspaceRenderItemID, statuses: SidebarWorkspaceRenderItemID) = (.workspacesArea(), .statusesArea())
    private func slice(_ items: [SidebarWorkspaceRenderItemID], from start: SidebarWorkspaceRenderItemID, to end: SidebarWorkspaceRenderItemID) -> [SidebarWorkspaceRenderItemID] {
        guard let a = items.firstIndex(of: start), let b = items[(a + 1)...].firstIndex(of: end) else { return [] }
        return Array(items[(a + 1)..<b])
    }

    // MARK: the root rule, through the app's wiring

    @Test func theSidebarsProjectionTakesAStatusInAnUnstagedParentAsARootAndTheModelClosureAgrees() async throws {
        try await gate {
            let restore = try Self.installStatusList(); defer { restore() }
            let world = try World()
            #expect(world.projection()?.workspaceGroups?.rootGroupIds.isEmpty == true)
            try world.setStatus(world.n, "parked")
            let grouped = try #require(world.projection()?.workspaceGroups)
            #expect(grouped.rootGroupIds == [world.n] && grouped.nestedRootGroupIds == [world.n])
            #expect(grouped.statusIdByGroupId == [world.n: "parked", world.m: "parked"])
            #expect(Sidebar.groupsShownOutsideTheirParent(groups: world.manager.workspaceGroups, projection: world.projection()) == [world.n])
            // TabManager hands the model the sidebar's own answer; an unset closure would answer "none" and leave every fold as it was.
            #expect(world.manager.workspaces.groupIdsShownOutsideParent() == [world.n])
        }
    }

    @Test func nothingIsShownUnderAStatusWithTheBuiltInListOrWithControlsOff() async throws {
        try await gate {
            do {
                let restore = try Self.installStatusList(source: "{}"); defer { restore() }
                let world = try World()
                let index = try #require(world.manager.workspaceGroups.firstIndex { $0.id == world.n })
                // A status the built-in list itself lists, so only the "no list in use" guards keep the group in its parent.
                let builtIn = try #require(WorkspaceStatusList.cmuxFive.entries.first?.id)
                world.manager.workspaceGroups[index].statusId = builtIn
                #expect(AppDelegate.statusListInUse.source == .cmux && AppDelegate.statusListInUse.entry(id: builtIn) != nil)
                #expect(Sidebar.groupsShownOutsideTheirParent(groups: world.manager.workspaceGroups, projection: world.projection()).isEmpty)
                #expect(world.manager.workspaces.groupIdsShownOutsideParent().isEmpty)
                #expect(world.projection()?.workspaceGroups?.statusIdByGroupId.isEmpty != false)
            }
            do {
                let restore = try Self.installStatusList(controls: false); defer { restore() }
                let world = try World()
                let index = try #require(world.manager.workspaceGroups.firstIndex { $0.id == world.n })
                world.manager.workspaceGroups[index].statusId = "parked"
                #expect(world.projection() == nil)
                #expect(Sidebar.groupsShownOutsideTheirParent(groups: world.manager.workspaceGroups, projection: world.projection()).isEmpty)
                #expect(world.manager.workspaces.groupIdsShownOutsideParent().isEmpty)
            }
        }
    }

    @Test func aNestedColorWithoutAStoredStatusAndAnUnlistedStatusAreNotShownUnderAStatus() async throws {
        try await gate {
            let restore = try Self.installStatusList(); defer { restore() }
            let world = try World()
            let index = try #require(world.manager.workspaceGroups.firstIndex { $0.id == world.n })
            world.manager.workspaceGroups[index].customColor = "#112233"
            #expect(world.manager.workspaces.groupIdsShownOutsideParent().isEmpty)
            world.manager.workspaceGroups[index].statusId = "unlisted"
            #expect(world.manager.workspaces.groupIdsShownOutsideParent().isEmpty)
            #expect(!world.items().contains(.statusGroup("unlisted")))
        }
    }

    @Test func aPinnedTopLevelAncestorKeepsItsNestedStatusAmongTheSectionsPins() async throws {
        try await gate {
            let restore = try Self.installStatusList(); defer { restore() }
            let world = try World()
            world.manager.toggleWorkspaceGroupPinned(groupId: world.r)
            try world.setStatus(world.n, "parked")      // depth 1
            #expect(world.manager.workspaces.groupIdsShownOutsideParent().isEmpty)
            try world.setStatus(world.n, nil)
            try world.setStatus(world.m, "parked")      // depth 2
            #expect(world.manager.workspaces.groupIdsShownOutsideParent().isEmpty)
            let items = world.items()
            #expect(items.first == .pinnedArea())
            try world.setStatus(world.n, "parked")
            let pinned = slice(world.items(), from: .pinnedArea(), to: .workspacesArea())
            #expect(pinned.contains(.group(world.n)) && pinned.contains(.workspace(world.w("n1").id)))
            #expect(slice(world.items(), from: .statusGroup("parked"), to: .statusGroup("doing")).isEmpty)
        }
    }

    @Test func aParentWithAStatusKeepsItsNestedGroupInsideAndTheNestedStatusStaysOnTheHeader() async throws {
        try await gate {
            let restore = try Self.installStatusList(); defer { restore() }
            let world = try World()
            try world.setStatus(world.r, "doing")
            try world.setStatus(world.n, "parked")
            #expect(world.manager.workspaces.groupIdsShownOutsideParent().isEmpty)
            let items = world.items()
            #expect(slice(items, from: .statusGroup("parked"), to: .statusGroup("doing")).isEmpty, "Parked lists nothing")
            let doing = Array(items.drop { $0 != .statusGroup("doing") })
            #expect(doing.contains(.group(world.r)) && doing.contains(.group(world.n)) && doing.contains(.workspace(world.w("n1").id)),
                "Q8: N stays inside R, under the outermost group's status")
            #expect(world.group(world.n).statusId == "parked", "and its own header still wears its own status")
        }
    }

    // MARK: the view

    @Test func settingAndClearingAStatusMovesNothingButWhereTheGroupIsDrawn() async throws {
        try await gate {
            let restore = try Self.installStatusList(); defer { restore() }
            let world = try World()
            let tabs0 = world.tabOrder, parents0 = world.parents, members0 = world.memberships
            let before = world.items()
            let inRoot = world.rows(["u", "#R", "r1", "#N", "n1", "#M", "m1", "n2", "r2", "#G", "g1", "v", "p1", "#Q", "q1"])
            #expect(before == [areas.workspaces] + inRoot + [areas.statuses, .statusGroup("parked"), .statusGroup("doing")])

            try world.setStatus(world.n, "parked")
            #expect(world.group(world.n).statusId == "parked" && world.group(world.n).customColor == "#112233")
            #expect(world.items() == [areas.workspaces] + world.rows(["u", "#R", "r1", "r2", "#G", "g1", "v", "p1", "#Q", "q1"])
                + [areas.statuses, .statusGroup("parked")] + world.rows(["#N", "n1", "#M", "m1", "n2"]) + [.statusGroup("doing")],
                "N is drawn under Parked with everything inside it, and R shows nothing in its place")
            #expect(world.tabOrder == tabs0 && world.parents == parents0 && world.memberships == members0)

            try world.setStatus(world.n, nil)
            #expect(world.items() == before, "cleared, it is back inside R between r1 and r2, row for row")
            #expect(world.tabOrder == tabs0 && world.parents == parents0 && world.memberships == members0)
            #expect(world.group(world.n).customColor == nil)
        }
    }

    @Test func aWorkspaceInsideTheRootKeepsItsOwnStatusAndIsNotPulledOutByIt() async throws {
        try await gate {
            let restore = try Self.installStatusList(); defer { restore() }
            let world = try World()
            try world.setLooseStatus("n1", "doing")
            try world.setStatus(world.n, "parked")
            let parked = slice(world.items(), from: .statusGroup("parked"), to: .statusGroup("doing"))
            #expect(parked.contains(.workspace(world.w("n1").id)), "n1 goes where N goes")
            #expect(world.w("n1").todoState.ownStatus?.id == "doing")
            #expect(world.projection()?.group(for: "doing")?.memberWorkspaceIds.contains(world.w("n1").id) != true)
        }
    }

    @Test func aNestedRootSortsAmongLooseRowsAndTopLevelGroupsByTabOrder() async throws {
        try await gate {
            let restore = try Self.installStatusList(); defer { restore() }
            let world = try World()
            try world.setLooseStatus("u", "parked"); try world.setLooseStatus("p1", "parked")
            try world.setStatus(world.g, "parked"); try world.setStatus(world.n, "parked")
            let parked = slice(world.items(), from: .statusGroup("parked"), to: .statusGroup("doing"))
            #expect(parked == world.rows(["u", "#N", "n1", "#M", "m1", "n2", "#G", "g1", "p1"]),
                "a loose row before it, then N, then the top-level group after R's run, then a loose row after it in the tab order")
        }
    }

    @Test func aRootAndEverythingInsideItAreDrawnAtTheDepthsOfATopLevelRoot() async throws {
        try await gate {
            let restore = try Self.installStatusList(); defer { restore() }
            let world = try World()
            try world.setStatus(world.g, "parked"); try world.setStatus(world.n, "parked")
            let projection = try #require(world.projection())
            let groups = Dictionary(uniqueKeysWithValues: world.manager.workspaceGroups.map { ($0.id, $0) })
            let real = SidebarNestedWorkspaceRows.depthById(groupsById: groups,
                effectiveMembership: SidebarWorkspaceRenderItem.effectiveGroupIdByWorkspaceId(tabs: world.manager.tabs, groupsById: groups))
            @MainActor func depth(_ id: UUID) -> Int { Sidebar.rowDepth(of: id, rowDepthById: real, statusGroupProjection: projection) }
            #expect(real[world.n] == 1 && real[world.m] == 2, "the real depths are the ones inside R")
            #expect(depth(world.n) == 2 && depth(world.n) == depth(world.g))
            #expect(depth(world.w("n1").id) == 3 && depth(world.w("n1").id) == depth(world.w("g1").id))
            #expect(depth(world.m) == 3 && depth(world.w("m1").id) == 4)
        }
    }

    @Test func anEmptyNestedGroupWithAStatusIsDrawnUnderItAtItsParentsRunStart() async throws {
        try await gate {
            let restore = try Self.installStatusList(); defer { restore() }
            let world = try World()
            let id = UUID()
            var empty = WorkspaceGroup(id: id, name: "E", isCollapsed: false, isPinned: false, anchor: .empty(id),
                customColor: "#112233", iconSymbol: nil, parentGroupId: world.r)
            empty.statusId = "parked"
            world.manager.workspaceGroups.append(empty)
            try world.setStatus(world.n, "parked")
            #expect(world.manager.workspaces.groupIdsShownOutsideParent() == [id, world.n])
            let parked = slice(world.items(), from: .statusGroup("parked"), to: .statusGroup("doing"))
            #expect(parked.first == .group(id), "before N: it sorts where R's run starts")
            #expect(parked.dropFirst().first == .group(world.n))
        }
    }

    // MARK: the parent's fold

    private func eligibility(_ world: World) -> WorkspaceShortcutEligibility { world.manager.workspaceShortcutEligibility }

    @Test(arguments: [false, true])
    func foldingTheParentHidesItsOtherRowsAndNotTheRootUnderItsStatus(_ throughToggle: Bool) async throws {
        try await gate {
            let restore = try Self.installStatusList(); defer { restore() }
            let world = try World()
            try world.setStatus(world.n, "parked")
            world.manager.selectWorkspace(world.w("n1"))
            if throughToggle { world.manager.toggleWorkspaceGroupCollapsed(groupId: world.r) } else { world.fold(world.r, true) }
            #expect(world.group(world.r).isCollapsed)
            let items = world.items()
            #expect(items == [areas.workspaces] + world.rows(["u", "#R", "#G", "g1", "v", "p1", "#Q", "q1"])
                + [areas.statuses, .statusGroup("parked")] + world.rows(["#N", "n1", "#M", "m1", "n2"]) + [.statusGroup("doing")],
                "R keeps its header and loses r1 and r2; the root is untouched")
            #expect(world.manager.selectedTabId == world.w("n1").id, "a selected row inside the root stays selected")
            // Ruling (21): a row has a number exactly when it is shown, in tab order, and the sidebar and the key handlers agree.
            let numbered = world.resolution().numberedWorkspaceIndexById
            let eligibility = eligibility(world)
            let shown = ["u", "n1", "m1", "n2", "g1", "v", "p1", "q1"]
            #expect(Set(numbered.keys) == Set(shown.map { world.w($0).id }))
            for (offset, tab) in world.manager.tabs.enumerated() {
                #expect(eligibility.position(forFlatIndex: offset) == numbered[tab.id], "\(offset)")
            }
            #expect(numbered[world.w("n1").id] == 1 && numbered[world.w("n2").id] == 3)
        }
    }

    @Test func theRootsOwnFoldAndTheFoldsInsideItStillHideWhatTheyHideWhileTheParentIsFolded() async throws {
        try await gate {
            let restore = try Self.installStatusList(); defer { restore() }
            let world = try World()
            try world.setStatus(world.n, "parked")
            world.fold(world.r, true); world.fold(world.m, true)
            let inner = slice(world.items(), from: .statusGroup("parked"), to: .statusGroup("doing"))
            #expect(inner == world.rows(["#N", "n1", "#M", "n2"]), "M's own fold hides m1")
            world.fold(world.n, true)
            #expect(slice(world.items(), from: .statusGroup("parked"), to: .statusGroup("doing")) == world.rows(["#N"]))
            let numbered = Set(world.resolution().numberedWorkspaceIndexById.keys)
            #expect(!numbered.contains(world.w("n1").id) && !numbered.contains(world.w("m1").id))
            let eligibility = eligibility(world)
            for key in ["n1", "m1", "n2"] {
                let index = try #require(world.manager.tabs.firstIndex { $0.id == world.w(key).id })
                #expect(eligibility.position(forFlatIndex: index) == nil, Comment(rawValue: key))
            }
        }
    }

    @Test(arguments: [false, true])
    func withTheBuiltInListOrControlsOffAFoldedParentHidesTheNestedGroupAndSelectionUnfoldsIt(_ controlsOff: Bool) async throws {
        try await gate {
            let restore = controlsOff ? try Self.installStatusList(controls: false) : try Self.installStatusList(source: "{}")
            defer { restore() }
            let world = try World()
            let index = try #require(world.manager.workspaceGroups.firstIndex { $0.id == world.n })
            // With the built-in list, a status that list itself lists, so only the "no list in use" guards keep it inside.
            world.manager.workspaceGroups[index].statusId = controlsOff ? "parked" : try #require(WorkspaceStatusList.cmuxFive.entries.first?.id)
            world.manager.workspaceGroups[index].customColor = "#112233"
            world.fold(world.r, true)
            #expect(!world.items().contains(.workspace(world.w("n1").id)), "as today: the folded parent hides it")
            #expect(eligibility(world).position(forFlatIndex: world.manager.tabs.firstIndex { $0.id == world.w("n1").id }!) == nil)
            world.manager.selectWorkspace(world.w("n1"))
            #expect(!world.group(world.r).isCollapsed, "selecting a row inside unfolds the parent, as it always has")
            world.manager.toggleWorkspaceGroupCollapsed(groupId: world.r)
            #expect(world.manager.selectedTabId == world.w("r").id, "folding moves the selection to the parent's own workspace")
        }
    }

    @Test func selectingARowInsideTheRootLeavesTheFoldedParentFoldedAndRevealsItsStatusGroup() async throws {
        try await gate {
            let restore = try Self.installStatusList(); defer { restore() }
            let world = try World()
            try world.setStatus(world.n, "parked")
            world.fold(world.r, true); world.fold(world.n, true)
            let state = SidebarState(statusGroups: .init(collapsedStatusIds: ["parked"]))
            world.manager.selectWorkspace(world.w("n1"))
            #expect(world.group(world.r).isCollapsed, "R's fold does not hide the root, so opening it would change a fold nobody asked to change")
            #expect(!world.group(world.n).isCollapsed, "the root's own fold hides the row, so it opens")
            state.prepareStatusGroupsForSelection(list: AppDelegate.statusListInUse, resolvedHexByStatusId: ["parked": "#112233"],
                selectedWorkspace: world.w("n1"), workspaceGroups: world.manager.workspaceGroups)
            #expect(state.statusGroups?.collapsedStatusIds.contains("parked") == false, "the status group opens instead")
        }
    }

    @Test func aFoldedParentsBadgeLeavesOutRowsShownUnderAStatusButNotItsOwnRows() async throws {
        try await gate {
            let restore = try Self.installStatusList(); defer { restore() }
            let world = try World()
            try world.setStatus(world.n, "parked")
            let inside = world.manager.workspaces.workspaceIdsInside(world.r)
            #expect(Set(inside) == Set(["r", "r1", "r2", "n", "n1", "m", "m1", "n2"].map { world.w($0).id }), "Mark All Read and Delete Group still see everything")
            let projection = world.projection()
            let badge = Sidebar.foldedGroupBadgeWorkspaceIds(group: world.group(world.r), memberWorkspaceIds: inside, projection: projection, tabs: world.manager.tabs, groups: world.manager.workspaceGroups)
            #expect(Set(badge) == Set(["r", "r1", "r2"].map { world.w($0).id }))
            // The root's own badge, and a group inside it, keep every row they hold.
            let ownInside = world.manager.workspaces.workspaceIdsInside(world.n)
            #expect(Sidebar.foldedGroupBadgeWorkspaceIds(group: world.group(world.n), memberWorkspaceIds: ownInside, projection: projection, tabs: world.manager.tabs, groups: world.manager.workspaceGroups) == ownInside)
            let innerInside = world.manager.workspaces.workspaceIdsInside(world.m)
            #expect(Sidebar.foldedGroupBadgeWorkspaceIds(group: world.group(world.m), memberWorkspaceIds: innerInside, projection: projection, tabs: world.manager.tabs, groups: world.manager.workspaceGroups) == innerInside)
            // Without a projection, as with controls off, nothing is left out.
            #expect(Sidebar.foldedGroupBadgeWorkspaceIds(group: world.group(world.r), memberWorkspaceIds: inside, projection: nil, tabs: world.manager.tabs, groups: world.manager.workspaceGroups) == inside)
        }
    }

    // MARK: Move Group to

    @Test func moveGroupToKeepsTheStatusAndTheRootRuleDecidesWhereItShows() async throws {
        try await gate {
            let restore = try Self.installStatusList(); defer { restore() }
            // Into an unpinned group with no status: still under its status, nested in the new parent (ruling (4), ER 173).
            do {
                let world = try World(); try world.setStatus(world.n, "parked")
                #expect(world.manager.moveWorkspaceGroup(groupId: world.n, intoParent: world.q) == .moved)
                #expect(world.group(world.n).parentGroupId == world.q && world.group(world.n).statusId == "parked")
                let parked = slice(world.items(), from: .statusGroup("parked"), to: .statusGroup("doing"))
                #expect(parked.first == .group(world.n))
                #expect(world.manager.workspaces.groupIdsShownOutsideParent() == [world.n])
            }
            // Into a group with a status: inside it, under that group's status (Q8).
            do {
                let world = try World(); try world.setStatus(world.n, "parked"); try world.setStatus(world.g, "doing")
                #expect(world.manager.moveWorkspaceGroup(groupId: world.n, intoParent: world.g) == .moved)
                #expect(world.group(world.n).statusId == "parked", "the move never writes a status")
                let doing = Array(world.items().drop { $0 != .statusGroup("doing") })
                #expect(doing.contains(.group(world.n)) && doing.contains(.workspace(world.w("n1").id)))
                #expect(slice(world.items(), from: .statusGroup("parked"), to: .statusGroup("doing")).isEmpty)
                #expect(world.manager.workspaces.groupIdsShownOutsideParent().isEmpty)
            }
            // Into a pinned group: in Pinned, with its status's glyph and color, and not under its status.
            do {
                let world = try World(); try world.setStatus(world.n, "parked")
                world.manager.toggleWorkspaceGroupPinned(groupId: world.q)
                #expect(world.manager.moveWorkspaceGroup(groupId: world.n, intoParent: world.q) == .moved)
                let items = world.items()
                #expect(items.first == .pinnedArea())
                let pinned = slice(items, from: .pinnedArea(), to: .workspacesArea())
                #expect(pinned.contains(.group(world.n)) && pinned.contains(.workspace(world.w("n1").id)))
                #expect(slice(items, from: .statusGroup("parked"), to: .statusGroup("doing")).isEmpty)
                #expect(world.group(world.n).statusId == "parked" && world.group(world.n).customColor == "#112233")
            }
            // Top Level: a top-level group with a status, under its status by `cm-110.2`.
            do {
                let world = try World(); try world.setStatus(world.n, "parked")
                #expect(world.manager.moveWorkspaceGroup(groupId: world.n, intoParent: nil) == .moved)
                #expect(world.group(world.n).parentGroupId == nil)
                #expect(slice(world.items(), from: .statusGroup("parked"), to: .statusGroup("doing")).first == .group(world.n))
                #expect(world.manager.workspaces.groupIdsShownOutsideParent().isEmpty, "a top-level root is not a nested root")
            }
        }
    }

    // MARK: what the agent lane reads

    @Test func debugRowsReportANestedRootUnderItsStatusAndKeepEveryRealParentInsideIt() async throws {
        try await gate {
            let restore = try Self.installStatusList(); defer { restore() }
            let world = try World()
            try world.setStatus(world.n, "parked")
            let projection = try #require(world.projection())
            let groups = Dictionary(uniqueKeysWithValues: world.manager.workspaceGroups.map { ($0.id, $0) })
            let tabs = Dictionary(uniqueKeysWithValues: world.manager.tabs.map { ($0.id, $0) })
            let rows = SidebarDebugRow.rows(from: world.resolution().items,
                workspaceTitle: { _ in "W" }, groupName: { groups[$0]?.name ?? "" }, groupIsFolded: { groups[$0]?.isCollapsed ?? false },
                groupIdOfWorkspace: { tabs[$0]?.groupId }, statusName: { $0 },
                statusIdByWorkspaceId: Dictionary(uniqueKeysWithValues: projection.groups.flatMap { g in g.memberWorkspaceIds.map { ($0, g.statusId) } }),
                groupStatusId: { groups[$0]?.statusId }, parentGroupId: { groups[$0]?.parentGroupId },
                statusIdByGroupId: projection.workspaceGroups?.statusIdByGroupId ?? [:])
            func row(_ id: UUID) -> SidebarDebugRow? { rows.first { $0.id == id.uuidString } }
            #expect(row(world.n)?.header == "parked" && row(world.n)?.statusId == "parked", "the way a top-level group under a status reads")
            #expect(row(world.m)?.header == world.n.uuidString, "a group inside the root keeps its real parent")
            #expect(row(world.w("n1").id)?.header == world.n.uuidString)
            #expect(row(world.r)?.header == nil && row(world.g)?.header == nil)
        }
    }

    @Test func theDropDataTheTabDropPlannerReadsStaysTheModelsWhetherTheRootIsFoldedOrNot() async throws {
        try await gate {
            let restore = try Self.installStatusList(); defer { restore() }
            let world = try World()
            try world.setStatus(world.n, "parked")
            let groupsById = Dictionary(uniqueKeysWithValues: world.manager.workspaceGroups.map { ($0.id, $0) })
            let membership = SidebarWorkspaceRenderItem.effectiveGroupIdByWorkspaceId(tabs: world.manager.tabs, groupsById: groupsById)
            let tabIds = world.tabOrder
            func dropIds(_ group: UUID) -> [UUID] {
                Sidebar.groupDropTabIds(group: groupsById[group]!, tabIds: tabIds, groupIdByWorkspaceId: membership, groupsById: groupsById)
            }
            #expect(dropIds(world.n) == [world.w("n").id], "unfolded: the header stands for its own workspace")
            world.fold(world.n, true)
            let folded = Dictionary(uniqueKeysWithValues: world.manager.workspaceGroups.map { ($0.id, $0) })
            let foldedIds = Sidebar.groupDropTabIds(group: folded[world.n]!, tabIds: tabIds, groupIdByWorkspaceId: membership, groupsById: folded)
            #expect(foldedIds == ["n", "n1", "m", "m1", "n2"].map { world.w($0).id }, "folded: everything it holds, nested groups too")
            for id in [world.n, world.m] { #expect(!Sidebar.isPinnedByGroup(groupId: id, groupsById: groupsById), "R is not pinned") }
            for key in ["n1", "m1"] { #expect(!Sidebar.isPinnedByGroup(groupId: membership[world.w(key).id] ?? nil, groupsById: groupsById)) }
            // Inside a pinned parent it is pinned, and then it is not drawn under a status at all.
            world.manager.toggleWorkspaceGroupPinned(groupId: world.r)
            let pinned = Dictionary(uniqueKeysWithValues: world.manager.workspaceGroups.map { ($0.id, $0) })
            #expect(Sidebar.isPinnedByGroup(groupId: world.n, groupsById: pinned))
            #expect(world.manager.workspaces.groupIdsShownOutsideParent().isEmpty)
        }
    }

    // MARK: a group leaving its status (ruling (27))

    /// R is folded, N is drawn under Parked with the selection inside it; then N loses its status. N is back inside R, whose
    /// fold would hide the selected row, so R opens.
    @Test(arguments: ["none", "auto", "groupColor"])
    func aGroupLeavingItsStatusWhileTheSelectionIsInsideItUnfoldsTheFoldedParent(_ how: String) async throws {
        try await gate {
            let restore = try Self.installStatusList(); defer { restore() }
            let world = try World()
            try world.setStatus(world.n, "parked")
            world.manager.selectWorkspace(world.w("n1"))
            world.fold(world.r, true)
            #expect(world.group(world.r).isCollapsed && world.items().contains(.workspace(world.w("n1").id)), "the selected row is shown under Parked")
            switch how {
            case "none": try world.setStatus(world.n, nil)
            case "auto":
                let actions = WorkspaceGroupStatusUIActions(tabManager: world.manager,
                    writer: .init(list: AppDelegate.statusListInUse, resolveColor: { $0 }), controlsEnabled: true)
                try #require(actions.applyGroup(.auto, groupId: world.n))
            default: world.manager.setWorkspaceGroupColor(groupId: world.n, hex: nil)
            }
            #expect(world.group(world.n).statusId == nil)
            #expect(!world.group(world.r).isCollapsed, "R's fold would hide the selected row, so it opens")
            #expect(world.manager.selectedTabId == world.w("n1").id)
            #expect(world.items().contains(.workspace(world.w("n1").id)), "and the selected row is shown, inside R")
        }
    }

    /// The status-cycle shortcut only moves a group between listed statuses (it has no None stop), so the group stays drawn under
    /// a status and nothing opens.
    @Test func theStatusCycleShortcutKeepsTheGroupUnderAStatusAndLeavesTheFoldAlone() async throws {
        try await gate {
            let restore = try Self.installStatusList(); defer { restore() }
            let world = try World()
            try world.setStatus(world.n, "doing")
            world.manager.selectWorkspace(world.w("n"))
            world.fold(world.r, true)
            let actions = WorkspaceGroupStatusUIActions(tabManager: world.manager,
                writer: .init(list: AppDelegate.statusListInUse, resolveColor: { $0 }), controlsEnabled: true)
            try #require(actions.cycleSelected())
            #expect(world.group(world.n).statusId == "parked")
            #expect(world.group(world.r).isCollapsed && world.items().contains(.group(world.n)))
        }
    }

    /// A status taken out of the list, or Workspace Todo Controls turned off, changes no group; the window's own observers
    /// announce it, and the same reveal runs.
    @Test(arguments: ["listChange", "controlsOff"])
    func theListOrTheControlsLeavingAGroupWithoutItsStatusUnfoldsTheFoldedParent(_ how: String) async throws {
        try await gate {
            let handle = try Self.installStatusListHandle(); defer { handle.restore() }
            let world = try World()
            try world.setStatus(world.n, "parked")
            world.manager.selectWorkspace(world.w("n1"))
            world.fold(world.r, true)
            #expect(world.group(world.r).isCollapsed && world.items().contains(.workspace(world.w("n1").id)))
            if how == "listChange" { try handle.rewrite(Self.onlyDoing) }
            else { UserDefaults.standard.set(false, forKey: BetaFeaturesCatalogSection().workspaceTodoControls.userDefaultsKey) }
            #expect(world.manager.workspaces.groupIdsShownOutsideParent().isEmpty && world.group(world.r).isCollapsed, "nothing announced it yet")
            world.manager.revealSelectionIfItsGroupLeftItsStatus()
            #expect(!world.group(world.r).isCollapsed)
            #expect(world.items().contains(.workspace(world.w("n1").id)))
            #expect(world.group(world.n).statusId == "parked", "the stored status is untouched: it comes back with the list or the setting")
        }
    }

#if DEBUG
    /// The window's own body is what builds the rows the user sees; `SidebarDebugRowSnapshots` is what that body recorded. A cut of the
    /// body's base-item call (which the snapshot-path tests above do not run) leaves the root out while its parent is folded. (#cm-110.3)
    @Test(arguments: [false, true])
    func theMountedSidebarDrawsTheRootUnderItsStatusWhileItsParentIsFolded(_ appKit: Bool) async throws {
        try await gate {
            let restore = try Self.installStatusList(); defer { restore() }
            _ = NSApplication.shared
            let delegate = try #require(AppDelegate.shared)
            let suite = "SidebarNestedRootStatusTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let flags = CmuxFeatureFlags(defaults: defaults, remoteFlagValueProvider: { _ in nil })
            flags.setOverride(appKit, for: CmuxFeatureFlags.appKitSidebarListFlag)
            defaults.set(CmuxExtensionSidebarSelection.defaultProviderId, forKey: CmuxExtensionSidebarSelection.defaultsKey)
            let world = try World()
            try world.setStatus(world.n, "parked")
            world.fold(world.r, true)
            let windowId = UUID()
            let previousPresence = MobileWorkspaceListObserver.subscriberPresenceOverrideForTesting
            delegate.registerMainWindowContextForTesting(windowId: windowId, tabManager: world.manager)
            defer {
                delegate.unregisterMainWindowContextForTesting(windowId: windowId)
                delegate.forgetRecoverableMainWindowRoute(windowId: windowId)
                MobileWorkspaceListObserver.subscriberPresenceOverrideForTesting = previousPresence
            }
            let root = VerticalTabsSidebar(
                updateViewModel: UpdateStateModel(), fileExplorerState: FileExplorerState(), featureFlags: flags,
                sidebarUnread: SidebarUnreadModel(), titlebarControlsLayoutModel: TitlebarControlsLayoutModel(),
                windowId: windowId, onSendFeedback: {}, onToggleSidebar: {}, onNewTab: {},
                observedWindowReference: WeakWindowReference(), chromeBackgroundColor: .black,
                selection: .constant(.tabs), selectedTabIds: .constant([]), lastSidebarSelectionIndex: .constant(nil),
                sidebarRenderWorkerClient: .constant(nil)
            )
            .frame(width: 280, height: 640)
            .environmentObject(world.manager)
            .environmentObject(CmuxConfigStore())
            .environmentObject(SidebarState())
            .environmentObject(SidebarSelectionState())
            .defaultAppStorage(defaults)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 640),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: root)
            defer { window.contentView = nil; window.close() }
            var recorded: [SidebarWorkspaceRenderItem] = []
            let deadline = Date().addingTimeInterval(4)
            repeat {
                SidebarLazyLayoutScaleTests.turnMainRunLoopOnce(layingOut: window)
                await Task.yield()
                recorded = SidebarDebugRowSnapshots.items(windowId: windowId) ?? []
            } while !recorded.contains(where: { $0.id == .workspace(world.w("n1").id) }) && Date() < deadline
            let drawn = recorded.map(\.id)
            #expect(drawn.contains(.group(world.n)) && drawn.contains(.workspace(world.w("n1").id)) && drawn.contains(.workspace(world.w("m1").id)),
                "the mounted window draws the root under its status although R is folded")
            #expect(drawn.contains(.group(world.r)) && !drawn.contains(.workspace(world.w("r1").id)), "and R keeps its header and loses its other rows")
        }
    }

    // MARK: the whole window mounted (ContentView), AppKit renderer

    @MainActor
    struct MountedWindow {
        let window: NSWindow
        let table: NSTableView
        let defaults: UserDefaults
        let suite: String
    }

    func descendants<View: NSView>(of type: View.Type, in root: NSView?) -> [View] {
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

    /// The same mount `WorkspaceGroupNestedMountedSidebarTests` uses: the real `ContentView`, the AppKit table, the shared
    /// notification store (its `sidebarUnread` is what the table reads).
    func mountWindow(_ manager: TabManager) async throws -> MountedWindow {
        _ = NSApplication.shared
        let suite = "SidebarNestedRootStatusTests.mounted"
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = MainWindowHostingView(rootView: root)
        await drain(window)
        let container = try #require(descendants(of: SidebarWorkspaceTableContainerView.self, in: window.contentView).first)
        return MountedWindow(window: window, table: container.tableView, defaults: defaults, suite: suite)
    }

    func closeWindow(_ mounted: MountedWindow) {
        mounted.window.contentView = nil
        mounted.window.close()
        mounted.defaults.removePersistentDomain(forName: mounted.suite)
    }

    /// Ruling (27) through the window's own observers: a status taken out of the list, or Workspace Todo Controls turned off.
    @Test(arguments: ["listChange", "controlsOff"])
    func theMountedWindowUnfoldsTheParentWhenTheListOrTheControlsTakeTheStatusAway(_ how: String) async throws {
        try await gate {
            let handle = try Self.installStatusListHandle(); defer { handle.restore() }
            let world = try World()
            try world.setStatus(world.n, "parked")
            world.manager.selectWorkspace(world.w("n1"))
            world.fold(world.r, true)
            let mounted = try await mountWindow(world.manager); defer { closeWindow(mounted) }
            #expect(world.group(world.r).isCollapsed, "the mount leaves the fold alone")
            if how == "listChange" { try handle.rewrite(Self.onlyDoing) }
            else { UserDefaults.standard.set(false, forKey: BetaFeaturesCatalogSection().workspaceTodoControls.userDefaultsKey) }
            await drain(mounted.window)
            #expect(!world.group(world.r).isCollapsed, "the window's observer ran the reveal")
            #expect(world.manager.selectedTabId == world.w("n1").id)
        }
    }

    /// The folded parent's badge, read off the header cell the table drew: it sums the parent's own rows and leaves out the
    /// rows drawn under Parked. The sums are made by the call sites in `VerticalTabsSidebar+WorkspaceGroups.swift`, which no
    /// pure test of the helper reaches.
    @Test func theMountedFoldedParentsBadgeLeavesOutRowsDrawnUnderAStatus() async throws {
        try await gate {
            let restore = try Self.installStatusList(); defer { restore() }
            let world = try World()
            try world.setStatus(world.n, "parked")
            world.fold(world.r, true)
            let unread = TerminalNotificationStore.shared.sidebarUnread
            let counts: [(String, Int)] = [("r1", 1), ("r2", 2), ("n1", 10), ("m1", 100), ("n2", 1000)]
            for (key, count) in counts {
                unread.applyWorkspaceSummaryProjection(forWorkspaceId: world.w(key).id,
                    summary: SidebarWorkspaceUnreadSummary(unreadCount: count, latestNotificationText: nil), totalUnreadCount: count)
            }
            defer { for (key, _) in counts { unread.applyWorkspaceSummaryProjection(forWorkspaceId: world.w(key).id, summary: nil, totalUnreadCount: 0) } }
            let mounted = try await mountWindow(world.manager); defer { closeWindow(mounted) }
            await drain(mounted.window, iterations: 80)
            let cell = try #require(descendants(of: SidebarGroupHeaderTableCellView.self, in: mounted.table)
                .first { $0.currentModelForTesting?.groupId == world.r }, "R's header is drawn")
            #expect(cell.currentModelForTesting?.isCollapsed == true)
            #expect(cell.currentModelForTesting?.anchorUnreadCount == 3, "r1 + r2 only: n1, m1 and n2 show their own unread under Parked")
        }
    }
#endif
}
