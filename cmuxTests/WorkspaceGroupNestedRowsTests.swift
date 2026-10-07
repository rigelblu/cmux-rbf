import CoreGraphics
import Foundation
import Testing
import CmuxWorkspaces

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Nested workspace groups (#cm-106): the list of rows both sidebar renderers draw, and each row's depth and indent.
@MainActor
@Suite("Workspace group nesting, sidebar rows", .serialized)
struct WorkspaceGroupNestedRowsTests {
    /// A window `w0 | P[p: w1, Q[q: w2], w3] | w4`, with `P` holding `Q`. The names are `w<index>` in creation order.
    private func nestedManager() throws -> (manager: TabManager, outer: UUID, inner: UUID, names: [UUID: String]) {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        for _ in 0..<4 { manager.addWorkspace(autoWelcomeIfNeeded: false) }
        let ids = manager.tabs.map(\.id)
        let outer = try #require(manager.createWorkspaceGroup(name: "P", childWorkspaceIds: [ids[1], ids[3]]))
        let inner = try #require(manager.createWorkspaceGroup(name: "Q", childWorkspaceIds: [ids[2]]))
        let index = try #require(manager.workspaceGroups.firstIndex { $0.id == inner })
        manager.workspaceGroups[index].parentGroupId = outer
        manager.workspaces.normalizeWorkspaceGroupContiguity()
        var names: [UUID: String] = [:]
        for (i, id) in ids.enumerated() { names[id] = "w\(i)" }
        for tab in manager.tabs where names[tab.id] == nil { names[tab.id] = "own" }
        for group in manager.workspaceGroups { names[group.id] = "H(\(group.name))" }
        return (manager, outer, inner, names)
    }

    private func items(_ manager: TabManager) -> [SidebarWorkspaceRenderItem] {
        let groupsById = Dictionary(uniqueKeysWithValues: manager.workspaceGroups.map { ($0.id, $0) })
        let membership = SidebarWorkspaceRenderItem.effectiveGroupIdByWorkspaceId(tabs: manager.tabs, groupsById: groupsById)
        return SidebarWorkspaceRenderItem.renderItems(
            tabs: manager.tabs,
            groupsById: groupsById,
            orderedGroups: manager.workspaceGroups,
            effectiveMembership: membership
        )
    }

    private func labels(_ items: [SidebarWorkspaceRenderItem], _ names: [UUID: String]) -> [String] {
        items.map { item in
            switch item {
            case .groupHeader(let groupId, _): return names[groupId] ?? "?"
            case .workspace(let id): return names[id] ?? "?"
            case .colorSectionHeader: return "color"
            }
        }
    }

    private func depths(_ manager: TabManager) -> [UUID: Int] {
        let groupsById = Dictionary(uniqueKeysWithValues: manager.workspaceGroups.map { ($0.id, $0) })
        return SidebarNestedWorkspaceRows.depthById(
            groupsById: groupsById,
            effectiveMembership: SidebarWorkspaceRenderItem.effectiveGroupIdByWorkspaceId(tabs: manager.tabs, groupsById: groupsById)
        )
    }

    @Test func aNestedWindowDrawsAHeaderThenTheRowsInsideIt() throws {
        let (manager, _, _, names) = try nestedManager()
        let drawn = labels(items(manager), names).filter { $0 != "own" }
        #expect(drawn == ["w0", "H(P)", "w1", "w3", "H(Q)", "w2", "w4"])
    }

    @Test func aFoldedGroupHidesEverythingInsideAtEveryLevel() throws {
        let (manager, outer, inner, names) = try nestedManager()
        let innerIndex = try #require(manager.workspaceGroups.firstIndex { $0.id == inner })
        manager.workspaceGroups[innerIndex].isCollapsed = true
        #expect(labels(items(manager), names).filter { $0 != "own" } == ["w0", "H(P)", "w1", "w3", "H(Q)", "w4"])
        let outerIndex = try #require(manager.workspaceGroups.firstIndex { $0.id == outer })
        manager.workspaceGroups[outerIndex].isCollapsed = true
        #expect(labels(items(manager), names).filter { $0 != "own" } == ["w0", "H(P)", "w4"])
    }

    @Test func eachRowCarriesTheNumberOfGroupsAboveIt() throws {
        let (manager, outer, inner, _) = try nestedManager()
        let depth = depths(manager)
        #expect(depth[outer] == 0)
        #expect(depth[inner] == 1)
        // Every workspace in a group is one level below that group; an ungrouped one is at level 0.
        for tab in manager.tabs {
            let expected: Int = tab.groupId.map { (depth[$0] ?? 0) + 1 } ?? 0
            #expect((depth[tab.id] ?? 0) == expected, "workspace \(tab.id)")
        }
        #expect(manager.tabs.contains { $0.groupId == inner })
    }

    @Test func aWindowWithNoNestedGroupHasNoDepthAndDrawsTodaysRows() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        for _ in 0..<3 { manager.addWorkspace(autoWelcomeIfNeeded: false) }
        let ids = manager.tabs.map(\.id)
        let group = try #require(manager.createWorkspaceGroup(name: "G", childWorkspaceIds: [ids[1], ids[2]]))
        var names: [UUID: String] = [group: "H(G)"]
        for (i, id) in ids.enumerated() { names[id] = "w\(i)" }
        for tab in manager.tabs where names[tab.id] == nil { names[tab.id] = "own" }
        #expect(depths(manager).isEmpty)
        // Today's rows: the ungrouped workspace, the header, and the group's two workspaces.
        #expect(labels(items(manager), names).filter { $0 != "own" } == ["w0", "H(G)", "w1", "w2", "w3"])
        let index = try #require(manager.workspaceGroups.firstIndex { $0.id == group })
        manager.workspaceGroups[index].isCollapsed = true
        #expect(labels(items(manager), names).filter { $0 != "own" } == ["w0", "H(G)", "w3"])
    }

    @Test func theMembersOfAGroupAreEveryWorkspaceInsideInANestedWindowAndTheDirectOnesInAFlatOne() throws {
        let (manager, outer, inner, _) = try nestedManager()
        let groupsById = Dictionary(uniqueKeysWithValues: manager.workspaceGroups.map { ($0.id, $0) })
        let membership = SidebarWorkspaceRenderItem.effectiveGroupIdByWorkspaceId(tabs: manager.tabs, groupsById: groupsById)
        let members = SidebarWorkspaceRenderItem.memberWorkspaceIdsByGroupId(
            tabs: manager.tabs, groupsById: groupsById, effectiveMembership: membership
        )
        let direct = manager.tabs.filter { $0.groupId == outer }.map(\.id)
        let innerOnes = manager.tabs.filter { $0.groupId == inner }.map(\.id)
        #expect(Set(members[outer] ?? []) == Set(direct + innerOnes))
        #expect(members[inner] == innerOnes)
        // A flat window: the direct members, as today.
        manager.workspaceGroups[manager.workspaceGroups.firstIndex { $0.id == inner }!].parentGroupId = nil
        manager.workspaces.normalizeWorkspaceGroupContiguity()
        let flatGroups = Dictionary(uniqueKeysWithValues: manager.workspaceGroups.map { ($0.id, $0) })
        let flatMembership = SidebarWorkspaceRenderItem.effectiveGroupIdByWorkspaceId(tabs: manager.tabs, groupsById: flatGroups)
        let flat = SidebarWorkspaceRenderItem.memberWorkspaceIdsByGroupId(tabs: manager.tabs, groupsById: flatGroups, effectiveMembership: flatMembership)
        #expect(flat[outer] == manager.tabs.filter { $0.groupId == outer }.map(\.id))
    }

    @Test func theIndentIsTwelvePointsALevelAndNeverMoreThanFortyPercentOfTheWidth() {
        #expect(SidebarNestedIndent.points(levels: 0, availableWidth: 240) == 0)
        #expect(SidebarNestedIndent.points(levels: 1, availableWidth: 240) == 12)
        #expect(SidebarNestedIndent.points(levels: 3, availableWidth: 240) == 36)
        // 8 levels fit at 240 pt; deeper rows are drawn at the same indent.
        #expect(SidebarNestedIndent.points(levels: 8, availableWidth: 240) == 96)
        #expect(SidebarNestedIndent.points(levels: 12, availableWidth: 240) == 96)
        // 4 levels at the narrowest 120 pt.
        #expect(SidebarNestedIndent.points(levels: 9, availableWidth: 120) == 48)
        // One level always fits, so a flat window draws what it does today.
        #expect(SidebarNestedIndent.points(levels: 1, availableWidth: 20) == 12)
        #expect(SidebarNestedIndent.points(levels: 2, availableWidth: nil) == 24)
    }

    @Test func aWidthThatIsMissingNotFiniteOrNotPositiveIsTheDefaultWidthAndNeverTraps() {
        let defaultCap = SidebarNestedIndent.points(levels: 100, availableWidth: nil)
        #expect(defaultCap == 96)
        #expect(SidebarNestedIndent.points(levels: 100, availableWidth: .infinity) == defaultCap)
        #expect(SidebarNestedIndent.points(levels: 100, availableWidth: .nan) == defaultCap)
        #expect(SidebarNestedIndent.points(levels: 100, availableWidth: 0) == defaultCap)
        #expect(SidebarNestedIndent.points(levels: 100, availableWidth: -50) == defaultCap)
        // A real width is used: the SwiftUI list passes its own, so 120 pt caps at 4 levels, as AppKit does.
        #expect(SidebarNestedIndent.points(levels: 100, availableWidth: 120) == 48)
        #expect(SidebarNestedIndent.points(levels: 100, availableWidth: 480) == 192)
    }
}

