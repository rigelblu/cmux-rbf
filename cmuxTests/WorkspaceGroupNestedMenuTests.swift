import AppKit
import Foundation
import Testing
import CmuxWorkspaces

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Nested workspace groups (#cm-106): `Move Group to` in a header's menu and the depth in `Move to Group`.
@MainActor
@Suite("Workspace group nesting, menus", .serialized)
struct WorkspaceGroupNestedMenuTests {
    private func nestedManager() throws -> (manager: TabManager, outer: UUID, inner: UUID, other: UUID) {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        for _ in 0..<3 { manager.addWorkspace(autoWelcomeIfNeeded: false) }
        let ids = manager.tabs.map(\.id)
        let outer = try #require(manager.createWorkspaceGroup(name: "P", childWorkspaceIds: [ids[1]]))
        let inner = try #require(manager.createWorkspaceGroup(name: "Q", childWorkspaceIds: [ids[2]]))
        let other = try #require(manager.createWorkspaceGroup(name: "R", childWorkspaceIds: [ids[3]]))
        return (manager, outer, inner, other)
    }

    @Test func moveGroupToFromTheTabManagerNestsAFlatWindowAndRestoresTheTopLevel() throws {
        let (manager, outer, inner, _) = try nestedManager()
        #expect(!manager.workspaces.hasNestedWorkspaceGroup)
        #expect(manager.moveWorkspaceGroup(groupId: inner, intoParent: outer) == .moved)
        #expect(manager.workspaceGroups.first { $0.id == inner }?.parentGroupId == outer)
        #expect(manager.workspaces.hasNestedWorkspaceGroup)
        #expect(manager.moveWorkspaceGroup(groupId: inner, intoParent: outer) == .unchanged)
        #expect(manager.moveWorkspaceGroup(groupId: inner, intoParent: nil) == .moved)
        #expect(manager.workspaceGroups.first { $0.id == inner }?.parentGroupId == nil)
        #expect(!manager.workspaces.hasNestedWorkspaceGroup)
    }

    @Test func theMenuIsReadFromTheModelWhenItOpens() throws {
        let (manager, outer, inner, other) = try nestedManager()
        manager.moveWorkspaceGroup(groupId: inner, intoParent: outer)
        let menu = try #require(manager.workspaceGroupMoveMenu(for: other))
        #expect(menu.topLevelIsCurrent)
        #expect(menu.destinations.map(\.id).contains(outer))
        #expect(menu.destinations.first { $0.id == inner }?.depth == 1)
    }

    /// Builds the header's right-click menu for `groupId` the way the AppKit header does, and returns the
    /// `Move Group to` submenu with the ids picked so far.
    private func moveSubmenu(_ manager: TabManager, groupId: UUID, picked: @escaping (UUID?) -> Void) throws -> NSMenu {
        let cell = SidebarGroupHeaderTableCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        var actions = SidebarGroupHeaderRowActions(
            onToggleCollapsed: {}, onFocusAnchor: { _ in }, onTapPlus: {}, onRunResolvedItem: { _ in },
            onRename: {}, onSetColor: { _ in }, onPromptCustomColor: {}, onTogglePinned: {}, onMarkRead: {},
            onMarkUnread: {}, onClearLatestNotifications: {}, onMarkAllRead: {}, onMarkAllUnread: {},
            onUngroup: {}, onDelete: {}, onEditConfig: {}, onOpenDocs: {}
        )
        actions.onMoveGroup = picked
        actions.moveMenu = { manager.workspaceGroupMoveMenu(for: groupId) }
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })
        cell.configure(
            model: headerModel(groupId: group.id, anchor: group.anchorWorkspaceId),
            actions: actions,
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: 5, y: 5), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let menu = try #require(cell.menu(for: event))
        let parent = try #require(menu.items.first { $0.title == "Move Group to" })
        return try #require(parent.submenu)
    }

    @Test func theHeaderMenuOfAGroupInsideAnotherTicksItsParentNotTopLevelAndRunsTheChoice() throws {
        let (manager, outer, inner, _) = try nestedManager()
        manager.moveWorkspaceGroup(groupId: inner, intoParent: outer)
        var picked: [UUID?] = []
        let submenu = try moveSubmenu(manager, groupId: inner) { picked.append($0) }
        let topLevel = try #require(submenu.items.first { $0.title == "Top Level" })
        #expect(submenu.items.first === topLevel, "Top Level comes first")
        #expect(topLevel.state == .off)
        let pItem = try #require(submenu.items.first { $0.title == "P" })
        #expect(pItem.state == .on)
        #expect(pItem.indentationLevel == 0)
        _ = topLevel.target?.perform(topLevel.action, with: topLevel)
        _ = pItem.target?.perform(pItem.action, with: pItem)
        #expect(picked == [nil, outer])
    }

    @Test func theHeaderMenuOfATopLevelGroupTicksTopLevelAndIndentsEachDestinationByItsDepth() throws {
        let (manager, outer, inner, other) = try nestedManager()
        manager.moveWorkspaceGroup(groupId: inner, intoParent: outer)
        let submenu = try moveSubmenu(manager, groupId: other) { _ in }
        let topLevel = try #require(submenu.items.first { $0.title == "Top Level" })
        #expect(topLevel.state == .on)
        let pItem = try #require(submenu.items.first { $0.title == "P" })
        let qItem = try #require(submenu.items.first { $0.title == "Q" })
        #expect(pItem.state == .off && qItem.state == .off)
        #expect(pItem.indentationLevel == 0)
        #expect(qItem.indentationLevel == 1)
    }

    @Test func theDepthOfAGroupInMoveToGroupIndentsByLevelAndIsCappedAtWhatAMenuTakes() {
        typealias Item = WorkspaceGroupMenuSnapshot.Item
        #expect(Item(id: UUID(), name: "A").menuIndentationLevel == 0)
        #expect(Item(id: UUID(), name: "B", depth: 2).menuIndentationLevel == 2)
        #expect(Item(id: UUID(), name: "C", depth: 40).menuIndentationLevel == 15)
        #expect(Item(id: UUID(), name: "A").paddedTitle == "A")
        #expect(Item(id: UUID(), name: "B", depth: 2).paddedTitle == "\u{2003}\u{2003}B")
    }

    private func ungroupItemIsOffered(isPinned: Bool, memberCount: Int, holdsGroups: Bool) throws -> Bool {
        var model = headerModel(groupId: UUID(), anchor: UUID())
        model = SidebarGroupHeaderRowModel(
            groupId: model.groupId, anchorWorkspaceId: model.anchorWorkspaceId, name: "Group", iconSymbol: "folder",
            tintHex: nil, customColorHex: nil, isCollapsed: false, isPinned: isPinned, isAnchorActive: false,
            isMultiSelected: false, multiSelectionBackgroundStyle: .clear, memberCount: memberCount, anchorUnreadCount: 0,
            canMarkRead: false, canMarkUnread: false, hasLatestNotifications: false, canMarkAllRead: false,
            canMarkAllUnread: false, shortcutHintText: nil, shortcutHintXOffset: 0, shortcutHintYOffset: 0, fontScale: 1,
            globalFontMagnificationPercent: 100, cwdContextMenuItems: [], rowSpacing: 2, isFirstRow: true,
            isBeingDragged: false, topDropIndicatorVisible: false, bottomDropIndicatorVisible: false,
            colorSchemeIsDark: false, holdsGroups: holdsGroups
        )
        let cell = SidebarGroupHeaderTableCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        let actions = SidebarGroupHeaderRowActions(
            onToggleCollapsed: {}, onFocusAnchor: { _ in }, onTapPlus: {}, onRunResolvedItem: { _ in },
            onRename: {}, onSetColor: { _ in }, onPromptCustomColor: {}, onTogglePinned: {}, onMarkRead: {},
            onMarkUnread: {}, onClearLatestNotifications: {}, onMarkAllRead: {}, onMarkAllUnread: {},
            onUngroup: {}, onDelete: {}, onEditConfig: {}, onOpenDocs: {}
        )
        cell.configure(model: model, actions: actions, isPointerHovering: false, contextMenuDidOpen: {}, contextMenuDidClose: {})
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: 5, y: 5), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let menu = try #require(cell.menu(for: event))
        return menu.items.contains { $0.title == "Ungroup Workspaces" }
    }

    @Test func ungroupIsOfferedOnAPinnedGroupOnlyWhileItHoldsSomethingAndAChildGroupCounts() throws {
        // Today's rule: an unpinned group always has it; a pinned one only while it holds a workspace.
        #expect(try ungroupItemIsOffered(isPinned: false, memberCount: 0, holdsGroups: false))
        #expect(try ungroupItemIsOffered(isPinned: true, memberCount: 2, holdsGroups: false))
        #expect(try !ungroupItemIsOffered(isPinned: true, memberCount: 0, holdsGroups: false))
        // A pinned parent that holds only groups with no workspace holds something.
        #expect(try ungroupItemIsOffered(isPinned: true, memberCount: 0, holdsGroups: true))
    }

    private func headerModel(groupId: UUID, anchor: UUID) -> SidebarGroupHeaderRowModel {
        SidebarGroupHeaderRowModel(
            groupId: groupId, anchorWorkspaceId: anchor, name: "R", iconSymbol: "folder", tintHex: nil,
            customColorHex: nil, isCollapsed: false, isPinned: false, isAnchorActive: false, isMultiSelected: false,
            multiSelectionBackgroundStyle: .clear, memberCount: 1, anchorUnreadCount: 0, canMarkRead: false,
            canMarkUnread: false, hasLatestNotifications: false, canMarkAllRead: false, canMarkAllUnread: false,
            shortcutHintText: nil, shortcutHintXOffset: 0, shortcutHintYOffset: 0, fontScale: 1,
            globalFontMagnificationPercent: 100, cwdContextMenuItems: [], rowSpacing: 2, isFirstRow: true,
            isBeingDragged: false, topDropIndicatorVisible: false, bottomDropIndicatorVisible: false,
            colorSchemeIsDark: false
        )
    }
}
