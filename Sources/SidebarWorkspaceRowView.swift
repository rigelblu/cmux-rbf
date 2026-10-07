import Foundation
import SwiftUI

/// Mounts one immutable workspace-row projection below the lazy-list boundary.
struct SidebarWorkspaceRowView: View {
    let snapshot: SidebarWorkspaceRowSnapshot
    let actions: SidebarWorkspaceRowActions
    let shouldCollectWorkspaceDropTargets: Bool

    var body: some View {
        TabItemView(snapshot: snapshot, actions: actions)
            .equatable()
            .id(snapshot.workspaceId)
            .accessibilityIdentifier("sidebarWorkspace.\(snapshot.workspaceId.uuidString)")
            .sidebarNestedAccessibilityValue(SidebarNestedAccessibility.value(depth: SidebarNestedAccessibility.workspaceRowDepth(depth: snapshot.depth, isGrouped: snapshot.groupId != nil))) // (#cm-106)
            .sidebarWorkspaceFrameAnchor(
                id: snapshot.workspaceId,
                isEnabled: shouldCollectWorkspaceDropTargets
            )
            .sidebarPointerFrameReporting(
                onFrameChange: actions.onPointerFrameChange,
                onDisappear: actions.onPointerFrameDisappear
            )
            .padding(
                .leading,
                SidebarNestedIndent.points(levels: snapshot.indentLevels, availableWidth: snapshot.listWidth) // (#cm-106)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}
