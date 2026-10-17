import SwiftUI
import AppKit

struct SidebarWorkspaceLeadingStatusSlot: View {
    let showsBadge: Bool
    let showsSpinner: Bool
    let unreadCount: Int
    let side: CGFloat
    let spinnerSide: CGFloat
    let badgeFont: Font
    let badgeFillColor: Color
    let badgeTextColor: Color
    let spinnerColor: NSColor
    let spinnerTooltip: String

    var body: some View {
        ZStack {
            if showsBadge {
                SidebarWorkspaceUnreadBadge(
                    unreadCount: unreadCount,
                    side: side,
                    font: badgeFont,
                    fillColor: badgeFillColor,
                    textColor: badgeTextColor
                )
                // (#cm-109.3) upstream's `.opacity(showsSpinner ? 0 : 1)` is removed: one resolution never asks for the badge and the spinner together
            }
            if showsSpinner {
                SidebarWorkspaceLoadingSpinner(
                    side: spinnerSide,
                    color: spinnerColor,
                    tooltip: spinnerTooltip
                )
            }
        }
        .frame(width: side, height: side)
        .clipped()
    }
}
