import CmuxFoundation // (cm-128.16)
import CmuxSettings
import CoreGraphics // (#cm-109.3)

/// Pure function resolving which marks the workspace row draws: the badge, the spinner, the raised hand. (#cm-109.3)
///
/// Nothing hides another mark (#cm-128.1):
/// - The badge set to the left keeps the leading slot alone.
/// - The spinner set to the left is not a slot: it draws in the agent-mark group, after the status glyph and the hand.
/// - On the right the badge takes the edge, and the spinner sits beside it when both show there.
/// - A visible close button replaces both right-hand marks. The left-hand marks stay.
struct SidebarWorkspaceSlotResolution: Equatable, Sendable {
    enum SlotContent: Equatable, Sendable {
        case none
        case spinner
        case badge
    }

    let leading: SlotContent
    let trailing: SlotContent
    /// The mark beside the title when the badge and the spinner both sit trailing: the badge is `trailing`, at the edge.
    let trailingInner: SlotContent
    /// The spinner, set to the left, draws in the agent-mark group after the status glyph and the hand.
    let markSpinner: Bool
    let showsHand: Bool // (#cm-109.3)

    init(leading: SlotContent, trailing: SlotContent, trailingInner: SlotContent = .none,
         markSpinner: Bool = false, showsHand: Bool) {
        self.leading = leading
        self.trailing = trailing
        self.trailingInner = trailingInner
        self.markSpinner = markSpinner
        self.showsHand = showsHand
    }

    static func resolve(
        showsHand: Bool,
        showsSpinner: Bool,
        unreadCount: Int,
        markedUnread: Bool = false,
        loadingSpinnerPosition: SidebarIndicatorPosition,
        notificationBadgePosition: SidebarIndicatorPosition,
        showsCloseButton: Bool = false
    ) -> SidebarWorkspaceSlotResolution {
        let showsBadge = unreadCount > 0 || markedUnread
        let trailingBadge = showsBadge && notificationBadgePosition == .trailing
        let trailingSpinner = showsSpinner && loadingSpinnerPosition == .trailing

        var trailing: SlotContent = .none
        var trailingInner: SlotContent = .none
        if !showsCloseButton {
            if trailingBadge {
                trailing = .badge
                if trailingSpinner { trailingInner = .spinner }
            } else if trailingSpinner {
                trailing = .spinner
            }
        }

        return SidebarWorkspaceSlotResolution(
            leading: showsBadge && notificationBadgePosition == .leading ? .badge : .none,
            trailing: trailing,
            trailingInner: trailingInner,
            markSpinner: showsSpinner && loadingSpinnerPosition == .leading,
            showsHand: showsHand // (#cm-109.3)
        )
    }

    /// Point size for `hand.raised.fill` inside a slot of dimension `spinnerSide`. (#cm-109.3)
    ///
    /// SF Symbol rasterization for `hand.raised.fill` rounds to integer pixel bounds whose
    /// height exceeds the requested point size (e.g. at 9.5 pt, rendered height is 12 pt).
    /// Scaling `spinnerSide * 8.5 / 12` ensures the rasterized symbol dimensions never exceed
    /// `spinnerSide` and remain at least 75% of `spinnerSide` across all sidebar font sizes (10–20 pt),
    /// keeping the glyph properly proportioned without clipping in `CmuxSystemSymbolImage`.
    static func handRaisedSymbolPointSize(spinnerSide: CGFloat) -> CGFloat { // (#cm-109.3)
        spinnerSide * 8.5 / 12.0 // (#cm-109.3)
    } // (#cm-109.3)

    /// Combined indicator scale: fontScale * magnification scale. (cm-128.16)
    static func indicatorScale(fontScale: CGFloat, magnificationPercent: Int) -> CGFloat { // (cm-128.16)
        fontScale * GlobalFontMagnification.scale(for: magnificationPercent)
    }

    /// The gap between a trailing badge and the spinner beside it, in points: the code's spinner spacing.
    static let trailingMarkGap: CGFloat = 6

    /// Diameter of a manual mark inside the unchanged sixteen-point badge slot.
    static func unreadMarkDiameter(fontScale: CGFloat) -> CGFloat { 6 * fontScale }

    /// Width the title reserves at the row's trailing edge: the trailing marks and their gap, or the close button's
    /// width when that is wider (it replaces the marks on hover, so it must fit in the same place).
    static func trailingReserve(
        trailing: SlotContent,
        trailingInner: SlotContent,
        badgeSide: CGFloat,
        spinnerSide: CGFloat,
        closeButtonWidth: CGFloat
    ) -> CGFloat {
        func width(_ content: SlotContent) -> CGFloat {
            switch content {
            case .none: 0
            case .spinner: spinnerSide
            case .badge: badgeSide
            }
        }
        let outer = width(trailing)
        let inner = width(trailingInner)
        let marks = outer + inner + (outer > 0 && inner > 0 ? trailingMarkGap : 0)
        return max(marks, closeButtonWidth)
    }
}
