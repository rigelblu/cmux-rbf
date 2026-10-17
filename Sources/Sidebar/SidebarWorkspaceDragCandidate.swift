import Foundation

/// A sidebar drag identity and its SwiftUI geometry at the start of tracking.
struct SidebarWorkspaceDragCandidate {
    let workspaceId: UUID
    let swiftUIFrame: CGRect
    let renderItemId: SidebarWorkspaceRenderItemID? // (#cm-110.1)
    init(workspaceId: UUID, swiftUIFrame: CGRect, renderItemId: SidebarWorkspaceRenderItemID? = nil) { // (#cm-110.1)
        self.workspaceId = workspaceId // (#cm-110.1)
        self.swiftUIFrame = swiftUIFrame // (#cm-110.1)
        self.renderItemId = renderItemId // (#cm-110.1)
    } // (#cm-110.1)
}
