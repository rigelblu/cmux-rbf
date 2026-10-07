import Foundation
import Testing
import CmuxWorkspaces

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Nested workspace groups (#cm-106): what a group header's Mark All commands and their availability read in a window that
// holds a nested group. The values come from `SidebarNestedGroupNotifications`, which the header builders call.
@MainActor
@Suite("Workspace group nesting, notification commands", .serialized)
struct WorkspaceGroupNestedNotificationTests {
    private let store = TerminalNotificationStore.shared

    /// `P` is a header-only parent holding `Q` (workspaces `q`, `q2`); `r` sits outside. `P`'s own workspace was closed.
    private func headerOnlyParent() throws -> (manager: TabManager, parent: UUID, child: UUID, inside: [UUID], outside: UUID) {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        for _ in 0..<3 { manager.addWorkspace(autoWelcomeIfNeeded: false) }
        let ids = manager.tabs.map(\.id)
        let parent = try #require(manager.createWorkspaceGroup(name: "P", childWorkspaceIds: []))
        let child = try #require(manager.createWorkspaceGroup(name: "Q", childWorkspaceIds: [ids[1], ids[2]]))
        #expect(manager.moveWorkspaceGroup(groupId: child, intoParent: parent) == .moved)
        manager.closeWorkspace(try #require(manager.workspaceGroupAnchor(for: parent)))
        let inside = manager.tabs.filter { $0.groupId == child }.map(\.id)
        #expect(manager.workspaceGroups.first { $0.id == parent }?.liveAnchorWorkspaceId == nil)
        return (manager, parent, child, inside, ids[3])
    }

    private func notifications(_ manager: TabManager, _ groupId: UUID) -> SidebarNestedGroupNotifications {
        SidebarNestedGroupNotifications(tabManager: manager, notificationStore: store, groupId: groupId)
    }

    private func cleanUp(_ ids: [UUID]) {
        for id in ids { store.markRead(forTabId: id) }
    }

    @Test func aWindowWithNoNestedGroupLeavesTheCommandsToUpstreamsClosures() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let ids = manager.tabs.map(\.id)
        let group = try #require(manager.createWorkspaceGroup(name: "F", childWorkspaceIds: [ids[1]]))
        let flat = notifications(manager, group)
        #expect(flat.state().map { _ in 1 } == nil)
        #expect(flat.markAll(read: true) == false)
        #expect(flat.markAll(read: false) == false)
    }

    @Test func aHeaderWithNoWorkspaceOfItsOwnKeepsTheMarkAllCommandsAndTurnsTheSingleOnesOff() throws {
        let (manager, parent, _, inside, outside) = try headerOnlyParent()
        defer { cleanUp(inside + [outside]) }
        cleanUp(inside + [outside])
        // Everything inside is read: Mark All as Unread is available, Mark All as Read is not.
        var state = try #require(notifications(manager, parent).state())
        #expect(!state.canMarkRead && !state.canMarkUnread && !state.hasLatestNotifications)
        #expect(!state.canMarkAllRead)
        #expect(state.canMarkAllUnread)
        // One workspace inside, two levels down, becomes unread: Mark All as Read is available.
        store.markUnread(forTabId: inside[0])
        state = try #require(notifications(manager, parent).state())
        #expect(state.canMarkAllRead)
    }

    @Test func markAllReachesEveryWorkspaceInsideAtEveryLevelAndNoneOutside() throws {
        let (manager, parent, _, inside, outside) = try headerOnlyParent()
        defer { cleanUp(inside + [outside]) }
        cleanUp(inside + [outside])
        let nested = notifications(manager, parent)
        #expect(nested.markAll(read: false))
        #expect(inside.allSatisfy { store.unreadCount(forTabId: $0) > 0 || store.workspaceIsUnread(forTabId: $0) })
        #expect(!store.workspaceIsUnread(forTabId: outside))
        #expect(nested.markAll(read: true))
        #expect(inside.allSatisfy { !store.workspaceIsUnread(forTabId: $0) })
    }

    @Test func markAllReachesAWorkspaceThreeLevelsDeepAndAvailabilityCountsIt() throws {
        // `P` (no workspace of its own) holds `Q`, which holds `S`; each of Q and S has workspaces. `r` sits outside.
        let manager = TabManager(autoWelcomeIfNeeded: false)
        for _ in 0..<5 { manager.addWorkspace(autoWelcomeIfNeeded: false) }
        let ids = manager.tabs.map(\.id)
        let parent = try #require(manager.createWorkspaceGroup(name: "P", childWorkspaceIds: []))
        let child = try #require(manager.createWorkspaceGroup(name: "Q", childWorkspaceIds: [ids[1], ids[2]]))
        #expect(manager.moveWorkspaceGroup(groupId: child, intoParent: parent) == .moved)
        let grandchild = try #require(manager.createWorkspaceGroup(name: "S", childWorkspaceIds: [ids[3], ids[4]]))
        #expect(manager.moveWorkspaceGroup(groupId: grandchild, intoParent: child) == .moved)
        manager.closeWorkspace(try #require(manager.workspaceGroupAnchor(for: parent)))
        let deep = manager.tabs.filter { $0.groupId == grandchild }.map(\.id)
        let inside = manager.tabs.filter { $0.groupId == child || $0.groupId == grandchild }.map(\.id)
        let outside = ids[5]
        #expect(deep.count >= 2 && inside.count > deep.count)
        #expect(manager.workspaceGroups.first { $0.id == parent }?.liveAnchorWorkspaceId == nil)
        defer { cleanUp(inside + [outside]) }
        cleanUp(inside + [outside])

        // Only the workspace three levels down is unread: Mark All as Read is available on the top parent.
        store.markUnread(forTabId: try #require(deep.last))
        let state = try #require(notifications(manager, parent).state())
        #expect(state.canMarkAllRead)

        cleanUp(inside + [outside])
        let nested = notifications(manager, parent)
        #expect(nested.markAll(read: false))
        #expect(deep.allSatisfy { store.workspaceIsUnread(forTabId: $0) }, "the deepest level is reached")
        #expect(inside.allSatisfy { store.workspaceIsUnread(forTabId: $0) })
        #expect(!store.workspaceIsUnread(forTabId: outside))
        #expect(nested.markAll(read: true))
        #expect(inside.allSatisfy { !store.workspaceIsUnread(forTabId: $0) })
    }

    @Test func markAllLeavesTheWorkspaceBehindTheHeadersNameToTheSingleCommands() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        for _ in 0..<2 { manager.addWorkspace(autoWelcomeIfNeeded: false) }
        let ids = manager.tabs.map(\.id)
        let parent = try #require(manager.createWorkspaceGroup(name: "P", childWorkspaceIds: [ids[1]]))
        let child = try #require(manager.createWorkspaceGroup(name: "Q", childWorkspaceIds: [ids[2]]))
        #expect(manager.moveWorkspaceGroup(groupId: child, intoParent: parent) == .moved)
        let own = try #require(manager.workspaceGroupAnchor(for: parent)).id
        let inside = manager.tabs.filter { $0.id != own && ($0.groupId == parent || $0.groupId == child) }.map(\.id)
        defer { cleanUp(inside + [own]) }
        cleanUp(inside + [own])
        #expect(notifications(manager, parent).markAll(read: false))
        #expect(inside.allSatisfy { store.workspaceIsUnread(forTabId: $0) })
        #expect(!store.workspaceIsUnread(forTabId: own), "the workspace behind the name is the Mark Group commands' business")
    }
}
