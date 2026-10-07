import Foundation
import SwiftUI
import Testing
import CmuxWorkspaces

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Nested workspace groups (#cm-106): the Sidebar table's rows that a nested window changes.
@MainActor
@Suite("Workspace group nesting, sidebar table rows", .serialized)
struct WorkspaceGroupNestedTableRowsTests {
    /// A header-only parent `P` holding `Q`: `P`'s own workspace was closed while it held a group.
    private func headerOnlyParent() throws -> (manager: TabManager, parent: UUID, child: UUID) {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let ids = manager.tabs.map(\.id)
        let parent = try #require(manager.createWorkspaceGroup(name: "P", childWorkspaceIds: []))
        let child = try #require(manager.createWorkspaceGroup(name: "Q", childWorkspaceIds: [ids[1]]))
        #expect(manager.moveWorkspaceGroup(groupId: child, intoParent: parent) == .moved)
        let ownWorkspace = try #require(manager.workspaceGroupAnchor(for: parent))
        manager.closeWorkspace(ownWorkspace)
        let group = try #require(manager.workspaceGroups.first { $0.id == parent })
        #expect(group.liveAnchorWorkspaceId == nil, "P is header-only")
        return (manager, parent, child)
    }

    private func click(_ manager: TabManager, _ groupId: UUID, modifiers: NSEvent.ModifierFlags = []) {
        VerticalTabsSidebar.focusWorkspaceGroupAnchor(
            groupId: groupId,
            modifiers: modifiers,
            tabManager: manager,
            selectedTabIds: .constant([]),
            lastSidebarSelectionIndex: .constant(nil)
        )
    }

    @Test func aClickOnTheNameOfAHeaderWithNoWorkspaceFoldsAndUnfoldsIt() throws {
        let (manager, parent, _) = try headerOnlyParent()
        let selectedBefore = manager.selectedTabId
        func folded() -> Bool { manager.workspaceGroups.first { $0.id == parent }?.isCollapsed == true }
        #expect(!folded())
        click(manager, parent)
        #expect(folded())
        #expect(manager.selectedTabId == selectedBefore, "after the first click, which folds")
        click(manager, parent)
        #expect(!folded())
        #expect(manager.selectedTabId == selectedBefore, "after the second click, which unfolds")
    }

    @Test func aCommandOrShiftClickOnThatNameStillDoesNothing() throws {
        let (manager, parent, _) = try headerOnlyParent()
        func isOpen() -> Bool { manager.workspaceGroups.first { $0.id == parent }?.isCollapsed == false }
        // Each click is checked on its own: two folds in a row would cancel and read as "open".
        click(manager, parent, modifiers: .command)
        #expect(isOpen(), "after the command click")
        click(manager, parent, modifiers: .shift)
        #expect(isOpen(), "after the shift click")
    }

    @Test func aClickOnAHeaderWithAWorkspaceStillOpensThatWorkspaceAndDoesNotFold() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let ids = manager.tabs.map(\.id)
        let group = try #require(manager.createWorkspaceGroup(name: "G", childWorkspaceIds: [ids[1]]))
        let anchor = try #require(manager.workspaceGroupAnchor(for: group))
        manager.selectWorkspace(manager.tabs[0])
        click(manager, group)
        #expect(manager.selectedTabId == anchor.id)
        #expect(manager.workspaceGroups.first { $0.id == group }?.isCollapsed == false)
    }

    @Test func aClickOnTheNameOfAnEmptyHeaderFoldsAndUnfoldsItInAWindowWithNoNestedGroup() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let group = try #require(manager.createWorkspaceGroup(name: "E", childWorkspaceIds: []))
        manager.toggleWorkspaceGroupPinned(groupId: group)
        let anchor = try #require(manager.workspaceGroupAnchor(for: group))
        manager.closeWorkspace(anchor)
        #expect(manager.workspaceGroups.first { $0.id == group }?.liveAnchorWorkspaceId == nil)
        #expect(!manager.workspaces.hasNestedWorkspaceGroup)
        let selectedBefore = manager.selectedTabId
        func folded() -> Bool { manager.workspaceGroups.first { $0.id == group }?.isCollapsed == true }
        #expect(!folded())
        click(manager, group)
        #expect(folded())
        #expect(manager.selectedTabId == selectedBefore, "after the first click, which folds")
        click(manager, group)
        #expect(!folded())
        #expect(manager.selectedTabId == selectedBefore, "after the second click, which unfolds")
    }

    @Test func aWorkspaceUnderAFoldedAncestorCarriesNoNumber() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        for _ in 0..<3 { manager.addWorkspace(autoWelcomeIfNeeded: false) }
        let ids = manager.tabs.map(\.id)
        let outer = try #require(manager.createWorkspaceGroup(name: "P", childWorkspaceIds: [ids[1]]))
        let inner = try #require(manager.createWorkspaceGroup(name: "Q", childWorkspaceIds: [ids[2]]))
        #expect(manager.moveWorkspaceGroup(groupId: inner, intoParent: outer) == .moved)
        func numbered(_ id: UUID) -> Bool {
            let eligibility = WorkspaceShortcutEligibility.resolve(
                workspaces: manager.tabs, groups: manager.workspaceGroups, todoControlsEnabled: false
            )
            guard let index = manager.tabs.firstIndex(where: { $0.id == id }) else { return false }
            return eligibility.position(forFlatIndex: index) != nil
        }
        #expect(numbered(ids[2]), "open: the workspace in Q has a number")
        let innerIndex = try #require(manager.workspaceGroups.firstIndex { $0.id == inner })
        let outerIndex = try #require(manager.workspaceGroups.firstIndex { $0.id == outer })
        // Q folded: its own members are hidden.
        manager.workspaceGroups[innerIndex].isCollapsed = true
        #expect(!numbered(ids[2]))
        // Q open, P folded: Q's members are hidden by the ancestor.
        manager.workspaceGroups[innerIndex].isCollapsed = false
        manager.workspaceGroups[outerIndex].isCollapsed = true
        #expect(!numbered(ids[2]), "folded ancestor")
        #expect(!numbered(ids[1]), "P's own member")
        manager.workspaceGroups[outerIndex].isCollapsed = false
        #expect(numbered(ids[2]))
    }
}
