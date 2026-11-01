import SwiftUI
import AppKit

struct SidebarWorkspaceTrailingStatusSlot: View {
    /// A spinner on the right, at the edge or beside the badge. (cm-128.1)
    let showsSpinner: Bool
    let showsBadge: Bool
    let unreadCount: Int
    let side: CGFloat
    let spinnerSide: CGFloat
    /// The slot's width: both trailing marks and their gap, never less than the close button. (#cm-128.1)
    let slotWidth: CGFloat
    /// The close button's own width.
    let closeButtonWidth: CGFloat
    let height: CGFloat
    let badgeFont: Font
    let badgeFillColor: Color
    let badgeTextColor: Color
    let spinnerColor: NSColor
    let spinnerTooltip: String
    let canCloseWorkspace: Bool
    let showsCloseButton: Bool
    let closeButtonTooltip: String
    let closeButtonColor: Color
    let closeButtonFontSize: CGFloat
    let closeAction: () -> Void
    /// Done dims the badge and close button, while the activity spinner stays undimmed. (#cm-128.3)
    var contentAlpha: Double = 1

    var body: some View {
        ZStack(alignment: .trailing) {
            // cm-128.1: the badge takes the edge; the spinner sits beside it, or alone at the edge.
            HStack(spacing: SidebarWorkspaceSlotResolution.trailingMarkGap) {
                if showsSpinner {
                    SidebarWorkspaceLoadingSpinner(side: spinnerSide, color: spinnerColor, tooltip: spinnerTooltip)
                }
                if showsBadge {
                    SidebarWorkspaceUnreadBadge(
                        unreadCount: unreadCount,
                        side: side,
                        font: badgeFont,
                        fillColor: badgeFillColor,
                        textColor: badgeTextColor
                    )
                    .opacity(contentAlpha)
                }
            }
            .opacity(canCloseWorkspace && showsCloseButton ? 0 : 1)
            .transition(.opacity)
            if canCloseWorkspace {
                Button(action: closeAction) {
                    CmuxSystemSymbolImage(magnified: "xmark", pointSize: closeButtonFontSize, weight: .medium, tint: closeButtonColor)
                        .frame(width: closeButtonWidth, height: height, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .safeHelp(closeButtonTooltip)
                .opacity(showsCloseButton ? contentAlpha : 0)
                .allowsHitTesting(showsCloseButton)
                .accessibilityHidden(!showsCloseButton)
            }
        }
        .frame(width: slotWidth, height: height, alignment: .trailing)
    }
}
