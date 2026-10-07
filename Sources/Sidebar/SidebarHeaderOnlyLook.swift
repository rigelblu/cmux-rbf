import AppKit
import SwiftUI

/// The look of a group header with no workspace of its own (#cm-106): never active, a dot in the group's tint where
/// the icon was, and its name in the band's own colour. And the tint a folded header takes while the selected
/// workspace is inside it. Both sidebar renderers read these answers.
enum SidebarHeaderOnlyLook {
    /// The dot's diameter in points. Fixed, like the color group header's dot; it does not follow the font scale.
    static let dotDiameter: CGFloat = 8

    /// The dot's colour for a group's tint, by the function the color group header's dot uses; nil when the group has
    /// no tint or the tint does not parse. The caller then draws the dot in its own secondary colour.
    static func dotTint(tintHex: String?, colorScheme: ColorScheme) -> NSColor? {
        tintHex.flatMap { WorkspaceTabColorSettings.displayNSColor(hex: $0, colorScheme: colorScheme) }
    }

    /// A filled circle `dotDiameter` across, for an image view that tints it (template). Built once.
    @MainActor static let dotImage: NSImage = {
        let side = NSSize(width: dotDiameter, height: dotDiameter)
        let image = NSImage(size: side, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

extension SidebarHeaderOnlyLook {
    /// The two yes-or-no values a header's model carries, worked out once by the builders both renderers share.
    /// The look is drawn in every window, flat or nested: an empty pinned header takes it wherever it stands. A folded
    /// header takes the accent tint only when no workspace stands behind its name, since a fold moves the selection to
    /// that workspace when there is one.
    struct Answer: Equatable {
        let hasOwnWorkspace: Bool
        let isFoldedOverSelection: Bool

        init(hasLiveAnchor: Bool, isCollapsed: Bool, selectedWorkspaceIsInside: Bool) {
            hasOwnWorkspace = hasLiveAnchor
            isFoldedOverSelection = !hasLiveAnchor && isCollapsed && selectedWorkspaceIsInside
        }
    }
}
