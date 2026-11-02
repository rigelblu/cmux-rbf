import SwiftUI

struct SidebarWorkspaceUnreadBadge: View {
    let unreadCount: Int
    var markedUnread: Bool = false
    var markColor: Color = .accentColor
    let side: CGFloat
    let font: Font
    let fillColor: Color
    let textColor: Color

    var body: some View {
        ZStack {
            if unreadCount > 0 {
                Circle().fill(fillColor)
                Text("\(unreadCount)")
                    .font(font)
                    .foregroundColor(textColor)
            } else if markedUnread {
                Circle().fill(markColor)
                    .frame(width: SidebarWorkspaceSlotResolution.unreadMarkDiameter(fontScale: side / 16), height: SidebarWorkspaceSlotResolution.unreadMarkDiameter(fontScale: side / 16))
            }
        }
        .frame(width: side, height: side)
    }
}
