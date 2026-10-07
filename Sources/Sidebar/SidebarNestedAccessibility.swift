import SwiftUI

/// What assistive technology is told about a row's level (#cm-106). One function turns a row's depth, and for a
/// header "no workspace of its own", into one accessibility value; both renderers set it beside the label they set
/// today. Every row says its level in every window: a row in no group is `Level 1`, a row directly in a top-level
/// group `Level 2`, and so on. It is a value for assistive technology only: it draws and lays out nothing, and the
/// depth map the drawing reads stays empty in a window with no nested group.
enum SidebarNestedAccessibility {
    /// `Level 2` for a row one group deep, and for a header with no workspace behind its name also
    /// `No workspace of its own`.
    static func value(depth: Int, hasOwnWorkspace: Bool = true) -> String {
        var parts = [String.localizedStringWithFormat(
            String(localized: "workspaceGroup.level.a11y", defaultValue: "Level %lld"),
            max(0, depth) + 1
        )]
        if !hasOwnWorkspace {
            parts.append(String(localized: "workspaceGroup.noOwnWorkspace.a11y", defaultValue: "No workspace of its own"))
        }
        // Two parts are joined by the locale's own list separator, in one string the catalog can translate.
        return parts.count == 1 ? parts[0] : String.localizedStringWithFormat(
            String(localized: "workspaceGroup.a11y.joined", defaultValue: "%1$@, %2$@"),
            parts[0],
            parts[1]
        )
    }

    /// How many groups hold a workspace row, for its level: its depth in a nested window (the depth map is empty in
    /// any other), else one when it is in a group, else none.
    static func workspaceRowDepth(depth: Int, isGrouped: Bool) -> Int {
        depth > 0 ? depth : (isGrouped ? 1 : 0)
    }

    /// The AppKit disclosure level of a row: how many groups hold it (0 at the top level).
    static func disclosureLevel(forDepth depth: Int) -> Int {
        max(0, depth)
    }
}

extension View {
    /// Sets the level accessibility value (#cm-106).
    func sidebarNestedAccessibilityValue(_ value: String) -> some View {
        accessibilityValue(Text(verbatim: value))
    }
}
