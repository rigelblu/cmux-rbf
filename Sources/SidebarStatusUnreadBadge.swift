import CmuxFoundation
import SwiftUI

/// The same unread badge for section and status-group headings.
struct SidebarStatusUnreadBadge: View {
    let count: Int
    var markedUnread: Bool = false
    let fontScale: CGFloat
    let globalFontMagnificationPercent: Int
    var markColor: Color? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.sidebarContrastBackgroundHex) private var sidebarContrastBackgroundHex

    var body: some View {
        let metrics = SidebarWorkspaceGroupHeaderMetrics(fontScale: fontScale)
        if count == 0 && markedUnread {
            Circle().fill(markColor ?? defaultMarkColor)
                .frame(width: SidebarWorkspaceSlotResolution.unreadMarkDiameter(fontScale: fontScale), height: SidebarWorkspaceSlotResolution.unreadMarkDiameter(fontScale: fontScale))
                .frame(width: 16 * fontScale, height: 16 * fontScale)
        } else {
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

    private var defaultMarkColor: Color {
        let fill = sidebarContrastBackgroundHex.flatMap { NSColor(hex: $0) }
            ?? SidebarAppearanceColorResolver().resolvedColor(.windowBackgroundColor, for: colorScheme)
        return Color(nsColor: SidebarWorkspaceRowVisualPalette(isActive: false, isMultiSelected: false,
            isHovered: false, isEditing: false, customColorHex: nil, colorScheme: colorScheme,
            selectionColorHex: nil, notificationBadgeColorHex: nil, attentionTaskStatus: nil)
            .unreadMarkColor(sidebarStandIn: fill))
    }
}
