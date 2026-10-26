import CoreGraphics

/// How far a row is drawn in, by its level (#cm-106). One step is the member indent a row already has, 12 pt.
/// The drawn indent never takes more than 40% of the sidebar's width: a row deeper than that is drawn at the
/// same indent as the deepest level that fits. One level always fits, so a flat window draws what it draws today.
enum SidebarNestedIndent {
    /// The share of the sidebar's width the indent may take (a first number, which can be tuned).
    static let maxShareOfWidth: CGFloat = 0.4
    /// The width the SwiftUI list assumes, which cannot read its own width below the lazy boundary: the default 240 pt.
    static let assumedWidth: CGFloat = 240

    static func points(levels: Int, availableWidth: CGFloat?) -> CGFloat {
        guard levels > 0 else { return 0 }
        let step = SidebarWorkspaceGroupingMetrics.memberIndent
        // A width that is missing, not finite or not positive is the default width.
        let width = availableWidth.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? assumedWidth
        let fittingLevels = max(1, Int((width * maxShareOfWidth) / step))
        return CGFloat(min(levels, fittingLevels)) * step
    }
}

/// The one level the rows under the `Pinned` and `Workspaces` headers sit in at, the way status groups sit under
/// `Statuses` (#cm-110.12). It is part of a row's `depth`, so both renderers draw it from the same number. A window
/// with no section headers (no status list in use, or Workspace Todo Controls off) has none and draws what it drew.
extension SidebarNestedIndent {
    static let sectionLevels = 1 // (#cm-110.12)

    /// Every row drawn under a `Pinned` or `Workspaces` header: what follows one of those headers, up to the next
    /// `Statuses` or status group header. `Statuses` and the rows under it are not in it. (#cm-110.12)
    @MainActor
    static func sectionIndentedItemIds(in items: [SidebarWorkspaceRenderItem]) -> Set<SidebarWorkspaceRenderItemID> {
        var ids = Set<SidebarWorkspaceRenderItemID>()
        var underASection = false
        for item in items {
            switch item {
            case .pinnedHeader, .workspacesHeader: underASection = true
            case .statusesHeader, .statusGroupHeader: underASection = false
            case .groupHeader, .colorSectionHeader, .workspace: if underASection { ids.insert(item.id) }
            }
        }
        return ids
    }

    /// `sectionLevels` when the list shows section headers, else 0. (#cm-110.12)
    @MainActor
    static func sectionIndent(in items: [SidebarWorkspaceRenderItem]) -> Int {
        items.contains { if case .workspacesHeader = $0 { return true } else { return false } } ? sectionLevels : 0
    }
}
