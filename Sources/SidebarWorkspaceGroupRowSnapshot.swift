import AppKit
import CmuxSettings
import CmuxWorkspaces
import Foundation

/// Immutable presentation and menu state for one workspace-group row.
///
/// Live group, notification, config, drag, and pointer models are reduced to
/// this value before the lazy-list boundary. Only action closures are bound
/// when SwiftUI realizes the row.
struct SidebarWorkspaceGroupRowSnapshot {
    let groupId: UUID
    let anchorWorkspaceId: UUID
    let name: String
    let iconSymbol: String
    /// What the band paints: `customColor ?? cwdConfig.color` (`#cm-49`).
    let tintHex: String?
    /// The group's own colour override, and nothing resolved on its behalf, so the
    /// colour menu's checkmark can mean *you picked this*. See
    /// `SidebarGroupHeaderRowModel.customColorHex`.
    let customColorHex: String?
    let isCollapsed: Bool
    let isPinned: Bool
    let isAnchorActive: Bool
    let isMultiSelected: Bool
    let multiSelectionBackgroundStyle: SidebarWorkspaceRowBackgroundStyle
    let memberCount: Int
    let anchorUnreadCount: Int
    let canMarkRead: Bool
    let canMarkUnread: Bool
    let hasLatestNotifications: Bool
    let canMarkAllRead: Bool
    let canMarkAllUnread: Bool
    let shortcutDigit: Int?
    let shortcutModifierSymbol: String?
    let showsShortcutHint: Bool
    let isPointerHovering: Bool
    let shortcutHintXOffset: Double
    let shortcutHintYOffset: Double
    let fontScale: CGFloat
    let cwdContextMenuItems: [CmuxResolvedConfigContextMenuItem]
    let newWorkspacePlacement: WorkspaceGroupNewPlacement?
    let rowSpacing: CGFloat
    let isFirstRow: Bool
    let isBeingDragged: Bool
    let topDropIndicatorVisible: Bool
    let bottomDropIndicatorVisible: Bool
    let shouldCollectWorkspaceDropTargets: Bool
    /// How many groups hold this header; 0 at the top level and in a window with no nested group (#cm-106).
    var depth: Int = 0
    /// See `SidebarHeaderOnlyLook`; false for a header with no workspace behind its name, in any window (#cm-106).
    var hasOwnWorkspace: Bool = true
    var isFoldedOverSelection: Bool = false
    /// What `Move Group to` offers this group, a value built above the lazy boundary so the header never reads the
    /// model while its body runs (#cm-106).
    var moveMenu: WorkspaceGroupMoveMenu? = nil
    /// Whether a group sits inside this one; a pinned group that holds only groups is still offered Ungroup (#cm-106).
    var holdsGroups: Bool = false
    /// The list's width, for the cap on the indent; nil outside the SwiftUI list (#cm-106).
    var listWidth: CGFloat? = nil
    /// The level a reorder drop lands at, set only on a header that draws a drop line, for the line's indent (#cm-106).
    var dropLineLevel: Int? = nil
}
