import AppKit
import CmuxSettings
import SwiftUI
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@MainActor
@Suite("Workspace Accent Strip palette")
struct SidebarWorkspaceAccentStripPaletteTests {
    @Test
    func stylePersistsWithTheApprovedRawValue() {
        #expect(WorkspaceIndicatorStyle.accentStrip.rawValue == "accentStrip")
        #expect(WorkspaceIndicatorStyle.decodeFromJSON("accentStrip") == .accentStrip)
        #expect(WorkspaceIndicatorStyle.decodeFromUserDefaults("accentStrip") == .accentStrip)
        #expect(SettingCatalog().workspaceColors.indicatorStyle.defaultValue == .leftRail)
    }

    @Test
    func customColorStateMatrixUsesOneIdentityAndStateWeightedFill() throws {
        let resting = palette(isHovered: false)
        let hovered = palette(isHovered: true)
        let multiSelected = palette(isMultiSelected: true)
        let active = palette(isActive: true)

        #expect(resting.identityColor?.hexString() == "#006B6B")
        #expect(resting.stripColor?.hexString() == "#006B6B")
        #expect(resting.backgroundStyle.color?.hexString() == "#006B6B")
        #expect(resting.backgroundStyle.opacity == 0.14)

        #expect(hovered.identityColor?.hexString() == "#006B6B")
        #expect(hovered.stripColor?.hexString() == "#006B6B")
        #expect(hovered.backgroundStyle.color?.hexString() == "#006B6B")
        #expect(hovered.backgroundStyle.opacity == 0.24)

        #expect(multiSelected.identityColor?.hexString() == "#006B6B")
        #expect(multiSelected.stripColor?.hexString() == "#006B6B")
        #expect(multiSelected.backgroundStyle.color?.hexString() == "#006B6B")
        #expect(multiSelected.backgroundStyle.opacity == 0.35)

        let activeFill = try #require(active.backgroundStyle.color)
        let activeStrip = try #require(active.stripColor)
        #expect(active.identityColor?.hexString() == "#006B6B")
        #expect(active.backgroundStyle.opacity == 1)
        #expect(active.primaryTextColor.hexString() == "#FFFFFF")
        #expect(cmuxContrastRatio(foreground: .white, background: activeFill) >= 4.5)
        #expect(cmuxContrastRatio(foreground: activeStrip, background: activeFill) >= 3)
        #expect(
            activeStrip.hexString() == NSColor.black.hexString()
                || activeStrip.hexString() == NSColor.white.hexString()
        )
    }

    @Test
    func brightIdentityDarkensOnlyTheActiveFill() throws {
        let palette = SidebarWorkspaceRowVisualPalette(
            indicatorStyle: .accentStrip,
            isActive: true,
            isMultiSelected: false,
            isHovered: false,
            isEditing: false,
            customColorHex: "#FFF200",
            colorScheme: .light,
            selectionColorHex: nil,
            notificationBadgeColorHex: nil
        )

        let fill = try #require(palette.backgroundStyle.color)
        #expect(palette.identityColor?.hexString() == "#FFF200")
        #expect(fill.hexString() != palette.identityColor?.hexString())
        #expect(cmuxContrastRatio(foreground: .white, background: fill) >= 4.5)
    }

    @Test
    func renameUsesGlobalSelectionSurfaceButKeepsCustomIdentityStrip() {
        let palette = SidebarWorkspaceRowVisualPalette(
            indicatorStyle: .accentStrip,
            isActive: true,
            isMultiSelected: false,
            isHovered: false,
            isEditing: true,
            customColorHex: "#006B6B",
            colorScheme: .light,
            selectionColorHex: "#123456",
            notificationBadgeColorHex: nil
        )

        #expect(palette.backgroundStyle.color?.hexString() == "#123456")
        #expect(palette.backgroundStyle.opacity == 1)
        #expect(palette.identityColor?.hexString() == "#006B6B")
        #expect(palette.stripColor?.hexString() == "#006B6B")
        #expect(
            cmuxContrastRatio(
                foreground: palette.primaryTextColor,
                background: palette.backgroundStyle.color ?? .clear
            ) >= 4.5
        )
    }

    @Test
    func uncoloredAccentStripKeepsExistingFallbackSelection() {
        let palette = SidebarWorkspaceRowVisualPalette(
            indicatorStyle: .accentStrip,
            isActive: true,
            isMultiSelected: false,
            isHovered: true,
            isEditing: false,
            customColorHex: nil,
            colorScheme: .light,
            selectionColorHex: "#123456",
            notificationBadgeColorHex: nil
        )

        #expect(palette.identityColor == nil)
        #expect(palette.stripColor == nil)
        #expect(palette.backgroundStyle.color?.hexString() == "#123456")
        #expect(palette.backgroundStyle.opacity == 1)
    }

    private func palette(
        isActive: Bool = false,
        isMultiSelected: Bool = false,
        isHovered: Bool = false
    ) -> SidebarWorkspaceRowVisualPalette {
        SidebarWorkspaceRowVisualPalette(
            indicatorStyle: .accentStrip,
            isActive: isActive,
            isMultiSelected: isMultiSelected,
            isHovered: isHovered,
            isEditing: false,
            customColorHex: "#006B6B",
            colorScheme: .light,
            selectionColorHex: nil,
            notificationBadgeColorHex: nil
        )
    }
}
