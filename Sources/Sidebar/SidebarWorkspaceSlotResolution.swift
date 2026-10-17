import CmuxSettings
import CoreGraphics // (#cm-109.3)

/// Pure function resolving which indicator (spinner, badge, or none) appears
/// in the leading and trailing workspace row slots, and whether the raised hand shows. (#cm-109.3)
///
/// Priority:
/// - Raised hand draws after the status glyph; when active, both slots resolve to `.none`. // (#cm-109.3)
/// - When hand is not active, spinner beats badge. // (#cm-109.3)
/// - On trailing, a visible close button suppresses spinner and badge. // (#cm-109.3)
struct SidebarWorkspaceSlotResolution: Equatable, Sendable {
    enum SlotContent: Equatable, Sendable {
        case none
        case spinner
        case badge
    }

    let leading: SlotContent
    let trailing: SlotContent
    let showsHand: Bool // (#cm-109.3)

    static func resolve(
        showsHand: Bool,
        showsSpinner: Bool,
        unreadCount: Int,
        loadingSpinnerPosition: SidebarIndicatorPosition,
        notificationBadgePosition: SidebarIndicatorPosition,
        showsCloseButton: Bool = false
    ) -> SidebarWorkspaceSlotResolution {
        if showsHand { // (#cm-109.3)
            return SidebarWorkspaceSlotResolution(leading: .none, trailing: .none, showsHand: true) // (#cm-109.3)
        } // (#cm-109.3)

        let badgeCandidate = unreadCount > 0
        let leadingBadgeCandidate = badgeCandidate && notificationBadgePosition == .leading
        let trailingBadgeCandidate = badgeCandidate && notificationBadgePosition == .trailing

        let leadingSpinner = showsSpinner && loadingSpinnerPosition == .leading
        let trailingSpinner = showsSpinner && loadingSpinnerPosition == .trailing && !showsCloseButton

        let leadingContent: SlotContent
        if leadingSpinner {
            leadingContent = .spinner
        } else if leadingBadgeCandidate {
            leadingContent = .badge
        } else {
            leadingContent = .none
        }

        let trailingContent: SlotContent
        if showsCloseButton {
            trailingContent = .none
        } else if trailingSpinner {
            trailingContent = .spinner
        } else if trailingBadgeCandidate {
            trailingContent = .badge
        } else {
            trailingContent = .none
        }

        return SidebarWorkspaceSlotResolution(leading: leadingContent, trailing: trailingContent, showsHand: false) // (#cm-109.3)
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

    /// Leading slot width in points. Matches upstream: // (#cm-109.4)
    /// if an unread badge is configured on the leading side, the slot reserves // (#cm-109.4)
    /// the badge width (16·s) even when an active spinner is showing, avoiding // (#cm-109.4)
    /// title shifts as agents start and stop. (#cm-109.4)
    static func leadingSlotSide( // (#cm-109.4)
        leadingBadgeCandidate: Bool, // (#cm-109.3)
        scaledUnreadBadgeSize: CGFloat, // (#cm-109.4)
        scaledLoadingSpinnerSize: CGFloat // (#cm-109.4)
    ) -> CGFloat { // (#cm-109.4)
        leadingBadgeCandidate ? scaledUnreadBadgeSize : scaledLoadingSpinnerSize // (#cm-109.3)
    } // (#cm-109.4)
}
