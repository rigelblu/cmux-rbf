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

    private var indicatorScale: CGFloat { // (cm-128.16)
        SidebarWorkspaceSlotResolution.indicatorScale( // (cm-128.16)
            fontScale: fontScale, // (cm-128.16)
            magnificationPercent: globalFontMagnificationPercent // (cm-128.16)
        ) // (cm-128.16)
    } // (cm-128.16)

    private var markDiameter: CGFloat { // (cm-128.16)
        SidebarWorkspaceSlotResolution.unreadMarkDiameter(fontScale: indicatorScale) // (cm-128.16)
    } // (cm-128.16)

    private var slotSize: CGFloat { // (cm-128.16)
        16 * indicatorScale // (cm-128.16)
    } // (cm-128.16)

    var body: some View {
        let metrics = SidebarWorkspaceGroupHeaderMetrics(fontScale: fontScale)
        if count == 0 && markedUnread {
            Circle().fill(markColor ?? defaultMarkColor)
                .frame(width: markDiameter, height: markDiameter) // (cm-128.16)
                .frame(width: slotSize, height: slotSize) // (cm-128.16)
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

#if DEBUG // (cm-128.16)
    var markDiameterForTesting: CGFloat { markDiameter } // (cm-128.16)
    var slotSizeForTesting: CGFloat { slotSize } // (cm-128.16)
#endif // (cm-128.16)
}
