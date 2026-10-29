import SwiftUI
import AppKit

/// The leading slot holds the unread badge alone (cm-128.1): a spinner set to the left draws in the agent-mark group.
struct SidebarWorkspaceLeadingStatusSlot: View {
    let unreadCount: Int
    let side: CGFloat
    let badgeFont: Font
    let badgeFillColor: Color
    let badgeTextColor: Color

    var body: some View {
        ZStack {
            SidebarWorkspaceUnreadBadge(
                unreadCount: unreadCount,
                side: side,
                font: badgeFont,
                fillColor: badgeFillColor,
                textColor: badgeTextColor
            )
        }
        .frame(width: side, height: side)
        .clipped()
    }
}
