import CmuxAppKitSupportUI
import CmuxFoundation
import SwiftUI

/// Value-only SwiftUI environment forwarded into each independently hosted table cell.
struct SidebarWorkspaceTableEnvironmentSnapshot {
    let colorScheme: ColorScheme
    let globalFontMagnificationPercent: Int
    var sidebarContrastBackgroundHex: String? = nil // (#cm-109.7)
#if DEBUG
    let lazyContractProbe: SidebarLazyContractProbe
#endif
    /// macOS Display accessibility settings the AppKit rows paint with.
    var displayAccessibility: DisplayAccessibilityOptions = .standard
    /// Hex of the opaque terminal-matched backdrop, or `nil` over material.
    var readabilityBackdropHex: String? = nil

    func hasEquivalentPresentation(to other: Self) -> Bool {
        colorScheme == other.colorScheme
            && globalFontMagnificationPercent == other.globalFontMagnificationPercent
            && sidebarContrastBackgroundHex == other.sidebarContrastBackgroundHex // (#cm-109.7)
            && displayAccessibility == other.displayAccessibility
            && readabilityBackdropHex == other.readabilityBackdropHex
    }

    @ViewBuilder
    func apply<Content: View>(to content: Content) -> some View {
#if DEBUG
        content
            .environment(\.colorScheme, colorScheme)
            .environment(\.cmuxGlobalFontMagnificationPercent, globalFontMagnificationPercent)
            .environment(\.sidebarContrastBackgroundHex, sidebarContrastBackgroundHex) // (#cm-109.7)
            .environment(\.sidebarLazyContractProbe, lazyContractProbe)
#else
        content
            .environment(\.colorScheme, colorScheme)
            .environment(\.cmuxGlobalFontMagnificationPercent, globalFontMagnificationPercent)
            .environment(\.sidebarContrastBackgroundHex, sidebarContrastBackgroundHex) // (#cm-109.7)
#endif
    }
}
