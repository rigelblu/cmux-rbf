import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// What assistive technology is told about a nested row (#cm-106): the level, and for a header with no workspace of
// its own, that. One pure function produces the text; the AppKit header sets it beside its label.
@MainActor
@Suite("Workspace group nesting, accessibility", .serialized)
struct WorkspaceGroupNestedAccessibilityTests {
    @Test func everyRowSaysItsLevelAsLevelAndANumberFromOne() {
        #expect(SidebarNestedAccessibility.value(depth: 0) == "Level 1")
        #expect(SidebarNestedAccessibility.value(depth: -1) == "Level 1")
        #expect(SidebarNestedAccessibility.value(depth: 1) == "Level 2")
        #expect(SidebarNestedAccessibility.value(depth: 3) == "Level 4")
    }

    @Test func aWorkspaceRowInAGroupOfAWindowWithNoNestedGroupIsOneLevelDeeperThanOneInNoGroup() {
        // The drawing's depth map is empty in such a window, so depth is 0 for every row; membership decides.
        #expect(SidebarNestedAccessibility.workspaceRowDepth(depth: 0, isGrouped: false) == 0)
        #expect(SidebarNestedAccessibility.workspaceRowDepth(depth: 0, isGrouped: true) == 1)
        #expect(SidebarNestedAccessibility.workspaceRowDepth(depth: 3, isGrouped: true) == 3)
    }

    @Test func aHeaderWithNoWorkspaceOfItsOwnSaysSoAfterItsLevel() {
        #expect(SidebarNestedAccessibility.value(depth: 0, hasOwnWorkspace: false) == "Level 1, No workspace of its own")
        #expect(SidebarNestedAccessibility.value(depth: 2, hasOwnWorkspace: false) == "Level 3, No workspace of its own")
        #expect(SidebarNestedAccessibility.value(depth: 2, hasOwnWorkspace: true) == "Level 3")
    }

    @Test func theDisclosureLevelIsTheNumberOfGroupsAboveTheRow() {
        #expect(SidebarNestedAccessibility.disclosureLevel(forDepth: 0) == 0)
        #expect(SidebarNestedAccessibility.disclosureLevel(forDepth: 4) == 4)
        #expect(SidebarNestedAccessibility.disclosureLevel(forDepth: -2) == 0)
    }

    private func model(depth: Int, hasOwnWorkspace: Bool, isCollapsed: Bool) -> SidebarGroupHeaderRowModel {
        SidebarGroupHeaderRowModel(
            groupId: UUID(), anchorWorkspaceId: UUID(), name: "Group", iconSymbol: "folder", tintHex: nil,
            customColorHex: nil, isCollapsed: isCollapsed, isPinned: false, isAnchorActive: false, isMultiSelected: false,
            multiSelectionBackgroundStyle: .clear, memberCount: 1, anchorUnreadCount: 0, canMarkRead: false,
            canMarkUnread: false, hasLatestNotifications: false, canMarkAllRead: false, canMarkAllUnread: false,
            shortcutHintText: nil, shortcutHintXOffset: 0, shortcutHintYOffset: 0, fontScale: 1,
            globalFontMagnificationPercent: 100, cwdContextMenuItems: [], rowSpacing: 2, isFirstRow: true,
            isBeingDragged: false, topDropIndicatorVisible: false, bottomDropIndicatorVisible: false,
            colorSchemeIsDark: false, depth: depth, hasOwnWorkspace: hasOwnWorkspace
        )
    }

    private func cell(_ model: SidebarGroupHeaderRowModel) -> SidebarGroupHeaderTableCellView {
        let cell = SidebarGroupHeaderTableCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        cell.configurePresentation(model: model)
        return cell
    }

    @Test func theAppKitHeaderSetsTheValueTheDisclosureLevelAndWhetherItIsOpen() {
        let nested = cell(model(depth: 2, hasOwnWorkspace: false, isCollapsed: true))
        #expect(nested.accessibilityValue() as? String == "Level 3, No workspace of its own")
        #expect(nested.accessibilityDisclosureLevel() == 2)
        #expect(nested.isAccessibilityExpanded() == false)
        let top = cell(model(depth: 0, hasOwnWorkspace: true, isCollapsed: false))
        #expect(top.accessibilityValue() as? String == "Level 1")
        #expect(top.accessibilityDisclosureLevel() == 0)
        #expect(top.isAccessibilityExpanded() == true)
    }

    @Test func theAppKitHeaderWithNoWorkspaceOfItsOwnSaysThatAClickFoldsItAndOneWithAWorkspaceSaysNothing() {
        #expect(cell(model(depth: 0, hasOwnWorkspace: false, isCollapsed: false)).accessibilityHelp() == "Fold or unfold the group")
        #expect(cell(model(depth: 1, hasOwnWorkspace: false, isCollapsed: true)).accessibilityHelp() == "Fold or unfold the group")
        #expect(cell(model(depth: 0, hasOwnWorkspace: true, isCollapsed: false)).accessibilityHelp() == nil)
    }

    @Test func aReusedHeaderCellDropsTheHelpOfItsPreviousRow() {
        let reused = cell(model(depth: 0, hasOwnWorkspace: false, isCollapsed: false))
        #expect(reused.accessibilityHelp() == "Fold or unfold the group")
        reused.configurePresentation(model: model(depth: 0, hasOwnWorkspace: true, isCollapsed: false))
        #expect(reused.accessibilityHelp() == nil)
    }

    @Test func aReusedHeaderCellDropsTheValueOfItsPreviousRow() {
        let reused = cell(model(depth: 3, hasOwnWorkspace: false, isCollapsed: false))
        #expect(reused.accessibilityValue() as? String == "Level 4, No workspace of its own")
        reused.configurePresentation(model: model(depth: 0, hasOwnWorkspace: true, isCollapsed: false))
        #expect(reused.accessibilityValue() as? String == "Level 1")
        #expect(reused.accessibilityDisclosureLevel() == 0)
    }
}
