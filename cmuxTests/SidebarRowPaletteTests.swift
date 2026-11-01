import AppKit
import SwiftUI
import Testing
@testable import cmux_DEV

@Suite
@MainActor
struct SidebarRowPaletteTests {
    @Test(arguments: ["#777777", "#0088FF"], [ColorScheme.light, .dark])
    func selectedAgentMarksReachThreeToOneAfterEightBitRounding(fill: String, colorScheme: ColorScheme) throws {
        let palette = SidebarWorkspaceRowVisualPalette(isActive: true, isMultiSelected: false, isHovered: false,
            isEditing: false, customColorHex: nil, colorScheme: colorScheme, selectionColorHex: fill,
            notificationBadgeColorHex: nil, attentionTaskStatus: nil)
        let background = try #require(palette.backgroundStyle.color)
        let composite = cmuxCompositedNSColor(palette.agentActivityColor(), over: background)
        let rounded = try eightBitColor(composite)
        #expect(cmuxContrastRatio(foreground: rounded, background: background) >= 3,
            "8-bit composite on \(fill) must clear 3:1")
    }

    private func eightBitColor(_ color: NSColor) throws -> NSColor {
        let rgb = try #require(color.usingColorSpace(.sRGB))
        return NSColor(srgbRed: (rgb.redComponent * 255).rounded() / 255,
            green: (rgb.greenComponent * 255).rounded() / 255,
            blue: (rgb.blueComponent * 255).rounded() / 255, alpha: 1)
    }

    @Test(arguments: [false, true], [ColorScheme.light, .dark])
    func selectedAgentMarkUsesTheFirstPassingEightBitAlphaStep(isDone: Bool, colorScheme: ColorScheme) throws {
        let palette = SidebarWorkspaceRowVisualPalette(isActive: true, isMultiSelected: false, isHovered: false,
            isEditing: false, customColorHex: "#777777", colorScheme: colorScheme, selectionColorHex: nil,
            notificationBadgeColorHex: nil, attentionTaskStatus: nil)
        let background = try #require(palette.backgroundStyle.color)
        let rowAlpha = SidebarWorkspaceRowVisualPalette.contentAlpha(taskStatus: isDone ? .done : nil)
        let current = palette.agentActivityColor()
        // Activity marks bypass the Done dim, while ordinary content retains it.
        #expect(rowAlpha == (isDone ? 0.6 : 1))
        let drawn = cmuxCompositedNSColor(current, over: background)
        let maximum = cmuxCompositedNSColor(palette.primaryTextColor.withAlphaComponent(rowAlpha), over: background)
        let maximumRatio = cmuxContrastRatio(foreground: maximum, background: background)
        if isDone {
            #expect(maximumRatio < 3, "control: the ordinary Done dim cannot meet the mark's contrast bar")
        }
        let ratio = cmuxContrastRatio(foreground: drawn, background: background)
        #expect(ratio >= 3, "selected mark contrast is \(ratio):1")
        let pixelBackground = try eightBitColor(background)
        #expect(cmuxContrastRatio(foreground: try eightBitColor(drawn), background: pixelBackground) >= 3)
        let lower = cmuxCompositedNSColor(current.withAlphaComponent(current.alphaComponent - 1 / 255), over: background)
        let lowerPixelRatio = cmuxContrastRatio(foreground: try eightBitColor(lower), background: pixelBackground)
        #expect(cmuxContrastRatio(foreground: lower, background: background) < 3 || lowerPixelRatio < 3)
    }

    @Test func unselectedAgentMarksKeepTheSystemSecondaryLabelColor() {
        for scheme in [ColorScheme.light, .dark] {
            let palette = SidebarWorkspaceRowVisualPalette(isActive: false, isMultiSelected: false, isHovered: false,
                isEditing: false, customColorHex: "#777777", colorScheme: scheme, selectionColorHex: nil,
                notificationBadgeColorHex: nil, attentionTaskStatus: nil)
            #expect(palette.agentActivityColor() == NSColor.secondaryLabelColor)
        }
    }

    @Test(arguments: [false, true])
    func rowPaletteSemanticColorsFollowRowSchemeAcrossAppearances(colorSchemeIsDark: Bool) throws {
        let lightAppearance = try #require(NSAppearance(named: .aqua))
        let darkAppearance = try #require(NSAppearance(named: .darkAqua))
        let semanticColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? .white
                : .black
        }
        let palette = SidebarRowPalette(model: SidebarAppKitRowCellTests.makeModel(colorSchemeIsDark: colorSchemeIsDark))
        // cmux's theme can differ from AppKit's appearance when the row is configured or drawn.
        let constructionAppearance = colorSchemeIsDark ? lightAppearance : darkAppearance
        var colors: [(NSColor, CGFloat)] = []
        constructionAppearance.performAsCurrentDrawingAppearance {
            colors = [
                (palette.semantic(semanticColor), 1),
                (palette.semantic(semanticColor, opacity: 0.6), 0.6),
            ]
        }
        let expectedComponent: CGFloat = colorSchemeIsDark ? 1 : 0
        let expectedColor = NSColor(
            srgbRed: expectedComponent,
            green: expectedComponent,
            blue: expectedComponent,
            alpha: 1
        )

        for (color, expectedAlpha) in colors {
            let light = try SidebarAppKitRowCellTests.resolvedColor(color, in: lightAppearance)
            let dark = try SidebarAppKitRowCellTests.resolvedColor(color, in: darkAppearance)

            #expect(SidebarAppKitRowCellTests.distance(light, expectedColor) < 0.001)
            #expect(SidebarAppKitRowCellTests.distance(dark, expectedColor) < 0.001)
            #expect(abs(light.alphaComponent - expectedAlpha) < 0.001)
            #expect(abs(dark.alphaComponent - expectedAlpha) < 0.001)
        }
    }
}
