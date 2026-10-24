import CmuxFoundation
import SwiftUI

/// The same unread badge for section and status-group headings.
struct SidebarStatusUnreadBadge: View {
    let count: Int
    let fontScale: CGFloat
    let globalFontMagnificationPercent: Int

    var body: some View {
        let metrics = SidebarWorkspaceGroupHeaderMetrics(fontScale: fontScale)
        Text("\(count)")
            .font(.system(size: GlobalFontMagnification.scaledSize(metrics.unreadFontSize,
                percent: globalFontMagnificationPercent), weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, metrics.unreadHorizontalPadding)
            .padding(.vertical, metrics.unreadVerticalPadding)
            .background(Capsule().fill(Color.accentColor))
            .accessibilityLabel(Text(String.localizedStringWithFormat(
                String(localized: "workspaceGroup.unread.a11y", defaultValue: "%lld unread"), count
            )))
    }
}
