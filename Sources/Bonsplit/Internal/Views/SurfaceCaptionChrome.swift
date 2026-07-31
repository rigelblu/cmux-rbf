import AppKit
import SwiftUI

/// Resolved colors shared by a caption's surface, content, and focus rule.
struct SurfaceCaptionChrome {
    let surfaceColor: NSColor
    let resolvedBackgroundColor: NSColor
    let activeTextColor: Color
    let inactiveTextColor: Color
    let hoveredBackgroundColor: Color

    init(
        style: SurfaceCaptionBackgroundStyle,
        appearance: BonsplitConfiguration.Appearance
    ) {
        switch style {
        case .tabBar:
            surfaceColor = TabBarColors.nsColorBarBackground(for: appearance)
            resolvedBackgroundColor = TabBarColors.nsColorResolvedBarBackground(for: appearance)
        case .chrome:
            surfaceColor = TabBarColors.nsColorChromeBackground(for: appearance)
            resolvedBackgroundColor = TabBarColors.nsColorResolvedChromeBackground(for: appearance)
        case .transparentOverChrome:
            surfaceColor = .clear
            resolvedBackgroundColor = TabBarColors.nsColorResolvedChromeBackground(
                for: appearance
            )
        }

        activeTextColor = Color(
            nsColor: TabBarColors.nsColorPrimaryText(over: resolvedBackgroundColor)
        )
        inactiveTextColor = Color(
            nsColor: TabBarColors.nsColorSecondaryText(over: resolvedBackgroundColor)
        )
        hoveredBackgroundColor = Color(
            nsColor: TabBarColors.nsColorHoverBackground(over: resolvedBackgroundColor)
        )
    }
}
