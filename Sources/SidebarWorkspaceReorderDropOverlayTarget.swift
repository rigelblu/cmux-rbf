import CoreGraphics
import Foundation

struct SidebarWorkspaceReorderDropOverlayTarget: Equatable {
    let workspaceId: UUID
    let groupId: UUID?
    let isGroupHeader: Bool
    let frame: CGRect
    var renderItemId: SidebarWorkspaceRenderItemID? = nil // (#cm-110.1)
    var statusContentFrame: CGRect? = nil // (#cm-110.1)
}
