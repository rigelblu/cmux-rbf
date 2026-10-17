import AppKit
import CmuxAppKitSupportUI
import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Tests for the 3:1 status glyph contrast floor and waiting agent hand outline (#cm-109.7).
@MainActor
@Suite("Workspace status contrast and hand outline", .serialized)
struct WorkspaceStatusContrastTests {
    private func hexColor(_ hex: String) -> NSColor {
        let clean = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard let value = Int(clean, radix: 16) else { return .black }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0,
            alpha: 1.0
        )
    }

    private func hueOf(_ color: NSColor) -> CGFloat {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        srgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return h * 360.0
    }

    /// On the Light sidebar stand-in #C3B9CE, #00C65F comes back at 3.00 to 3.05:1 and within 1 degree of its input's hue.
    @Test func colorUnderThreeToOneIsFlooredKeepingHue() {
        let input = hexColor("#00C65F")
        let bg = hexColor("#C3B9CE")
        let result = cmuxColor(input, against: bg)
        let ratio = cmuxContrastRatio(foreground: cmuxCompositedNSColor(result, over: bg), background: bg)
        #expect(ratio >= 3.00 && ratio <= 3.05)
        let hueDiff = abs(hueOf(input) - hueOf(result))
        #expect(hueDiff <= 1.0 || hueDiff >= 359.0)
    }

    /// #196F3D on #BAB5C7 (3.11:1) comes back unchanged.
    @Test func colorClearingThreeToOneIsLeftAlone() {
        let input = hexColor("#196F3D")
        let bg = hexColor("#BAB5C7")
        let result = cmuxColor(input, against: bg)
        #expect(result == input)
    }

    /// On Dark Upcoming row #333647, #146DD2 (2.35:1) comes back brighter, at 3.00 to 3.05:1.
    @Test func darkRowColorComesBackBrighterAtFloor() {
        let input = hexColor("#146DD2")
        let bg = hexColor("#333647")
        let initialRatio = cmuxContrastRatio(foreground: cmuxCompositedNSColor(input, over: bg), background: bg)
        #expect(initialRatio < 2.40)
        let result = cmuxColor(input, against: bg)
        let ratio = cmuxContrastRatio(foreground: cmuxCompositedNSColor(result, over: bg), background: bg)
        #expect(ratio >= 3.00 && ratio <= 3.05)
        let srgbInput = input.usingColorSpace(.sRGB) ?? input
        let srgbResult = result.usingColorSpace(.sRGB) ?? result
        #expect(srgbResult.brightnessComponent > srgbInput.brightnessComponent)
    }

    /// On a Done row's wash #BCB4C8 with drawnAt: 0.6, #3E4B5E comes back darker, and 0.6 of it composited over #BCB4C8 is at 3.00:1 or more.
    @Test func dimmedDoneRowColorMeasuresAsDrawnAndClearsFloor() {
        let input = hexColor("#3E4B5E")
        let bg = hexColor("#BCB4C8")
        let result = cmuxColor(input, against: bg, drawnAt: 0.6)
        let drawn = cmuxCompositedNSColor(result.withAlphaComponent(0.6), over: bg)
        let ratio = cmuxContrastRatio(foreground: drawn, background: bg)
        #expect(ratio >= 3.00)
        let srgbInput = input.usingColorSpace(.sRGB) ?? input
        let srgbResult = result.usingColorSpace(.sRGB) ?? result
        #expect(srgbResult.brightnessComponent < srgbInput.brightnessComponent)
    }

    /// handNeedsOutline is true on light rows and selected fills under 3:1, false on dark rows.
    @Test func handNeedsOutlineRule() {
        var lightYellow: NSColor = .clear
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            lightYellow = NSColor.systemYellow.usingColorSpace(.sRGB) ?? NSColor.systemYellow
        }
        var darkYellow: NSColor = .clear
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            darkYellow = NSColor.systemYellow.usingColorSpace(.sRGB) ?? NSColor.systemYellow
        }

        #expect(handNeedsOutline(yellow: lightYellow, on: hexColor("#BAB5CB")) == true)
        #expect(handNeedsOutline(yellow: lightYellow, on: hexColor("#008942")) == true)
        #expect(handNeedsOutline(yellow: lightYellow, on: hexColor("#0088FF")) == true)
        #expect(handNeedsOutline(yellow: darkYellow, on: hexColor("#0091FF")) == true)
        #expect(handNeedsOutline(yellow: darkYellow, on: hexColor("#333846")) == false)
        #expect(handNeedsOutline(yellow: darkYellow, on: hexColor("#8F7408")) == false)
    }

    /// A Done row's dim is part of what the hand is judged by (#cm-109.7). Dark's yellow on `#606068` is 4.4:1
    /// plain and 2.6:1 at 0.6, so only the dimmed reading needs the outline.
    @Test func handNeedsOutlineIsJudgedAsDrawnAfterTheRowsDim() {
        var darkYellow: NSColor = .clear
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            darkYellow = NSColor.systemYellow.usingColorSpace(.sRGB) ?? NSColor.systemYellow
        }
        let row = hexColor("#606068")
        #expect(handNeedsOutline(yellow: darkYellow, on: row) == false)
        #expect(handNeedsOutline(yellow: darkYellow, on: row, drawnAt: 1) == false)
        #expect(handNeedsOutline(yellow: darkYellow, on: row, drawnAt: 0.6) == true)
    }

    /// How many hosted symbol views a `WaitingHandView` builds: 1 is the yellow hand alone, 9 the yellow hand with
    /// its eight ink copies.
    private func hostedHandCount(colorScheme: ColorScheme, rowBackground: NSColor?, drawnAlpha: CGFloat = 1) -> Int {
        let view = WaitingHandView(pointSize: 8.5, colorScheme: colorScheme, rowBackground: rowBackground, drawnAlpha: drawnAlpha)
        let host = NSHostingView(rootView: view.frame(width: 12, height: 12))
        host.frame = NSRect(x: 0, y: 0, width: 12, height: 12)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func count(_ v: NSView) -> Int {
            (v is CmuxResolvedIconImageView ? 1 : 0) + v.subviews.reduce(0) { $0 + count($1) }
        }
        return count(host)
    }

    /// Scenario 81 (#cm-109.7), the SwiftUI row's hand: ink copies on a light row, none on a dark one, and the
    /// row's dim decides it too.
    @Test func theSwiftUIHandDrawsItsInkCopiesOnlyWhereYellowAloneIsUnderThreeToOne() {
        #expect(hostedHandCount(colorScheme: .light, rowBackground: hexColor("#C2C0CB")) == 9)
        #expect(hostedHandCount(colorScheme: .dark, rowBackground: hexColor("#333846")) == 1)
        #expect(hostedHandCount(colorScheme: .dark, rowBackground: hexColor("#606068"), drawnAlpha: 1) == 1)
        #expect(hostedHandCount(colorScheme: .dark, rowBackground: hexColor("#606068"), drawnAlpha: 0.6) == 9)
        #expect(hostedHandCount(colorScheme: .light, rowBackground: nil) == 1)
    }

    // MARK: - The stand-in's route (#cm-109.7)

    private func resolvedWindowBackground(dark: Bool) -> NSColor {
        var out: NSColor = .clear
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            out = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? NSColor.windowBackgroundColor
        }
        return out
    }

    private func blended(_ top: NSColor, alpha: CGFloat, over bottom: NSColor) -> NSColor {
        let t = top.usingColorSpace(.sRGB)!
        let b = bottom.usingColorSpace(.sRGB)!
        return NSColor(
            srgbRed: t.redComponent * alpha + b.redComponent * (1 - alpha),
            green: t.greenComponent * alpha + b.greenComponent * (1 - alpha),
            blue: t.blueComponent * alpha + b.blueComponent * (1 - alpha),
            alpha: 1
        )
    }

    private func isSame(_ a: NSColor, _ b: NSColor, tolerance: CGFloat = 0.01) -> Bool {
        guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < tolerance
            && abs(a.greenComponent - b.greenComponent) < tolerance
            && abs(a.blueComponent - b.blueComponent) < tolerance
    }

    /// The sidebar stand-in is the chrome color when surfaces are unified, else the sidebar's tint over the window
    /// background of the sidebar's own scheme.
    @Test func theSidebarStandInIsTheChromeWhenUnifiedElseTheTintOverTheWindowBackground() {
        let chrome = hexColor("#102030")
        let tint = hexColor("#907AA9").withAlphaComponent(0.45)
        #expect(isSame(
            sidebarContrastStandIn(unifySurfaceBackdrops: true, chromeBackground: chrome, contentColorScheme: .light, tint: tint),
            chrome
        ))
        for dark in [false, true] {
            let standIn = sidebarContrastStandIn(
                unifySurfaceBackdrops: false, chromeBackground: chrome, contentColorScheme: dark ? .dark : .light, tint: tint
            )
            let expected = blended(hexColor("#907AA9"), alpha: 0.45, over: resolvedWindowBackground(dark: dark))
            #expect(isSame(standIn, expected), "dark: \(dark)")
            #expect(!isSame(standIn, chrome), "dark: \(dark)")
        }
    }

    /// The row's own background is the stand-in under the row's wash: the stand-in itself on a resting row, the
    /// opaque selection fill over it on the selected one.
    @Test func aRowsContrastBackgroundIsTheStandInUnderItsWash() {
        let standIn = hexColor("#333846")
        func palette(isActive: Bool) -> SidebarWorkspaceRowVisualPalette {
            SidebarWorkspaceRowVisualPalette(
                isActive: isActive, isMultiSelected: false, isHovered: false, isEditing: false, customColorHex: nil,
                colorScheme: .dark, selectionColorHex: nil, notificationBadgeColorHex: nil, attentionTaskStatus: nil
            )
        }
        let resting = palette(isActive: false)
        #expect(isSame(resting.contrastBackground(sidebarStandIn: standIn), standIn))

        let selected = palette(isActive: true)
        let style = selected.backgroundStyle
        let fill = style.color!
        let expected = blended(fill, alpha: style.opacity * fill.alphaComponent, over: standIn)
        let background = selected.contrastBackground(sidebarStandIn: standIn)
        #expect(isSame(background, expected))
        #expect(!isSame(background, standIn))
        #expect(background.alphaComponent == 1)
    }

    /// The table's environment snapshot carries the stand-in, so a row is rebuilt when only the stand-in changes.
    @Test func theTableEnvironmentIsNotEquivalentWhenOnlyTheStandInDiffers() {
        func snapshot(_ hex: String?) -> SidebarWorkspaceTableEnvironmentSnapshot {
            #if DEBUG
            SidebarWorkspaceTableEnvironmentSnapshot(
                colorScheme: .light, globalFontMagnificationPercent: 100, sidebarContrastBackgroundHex: hex,
                lazyContractProbe: SidebarLazyContractProbe()
            )
            #else
            SidebarWorkspaceTableEnvironmentSnapshot(
                colorScheme: .light, globalFontMagnificationPercent: 100, sidebarContrastBackgroundHex: hex
            )
            #endif
        }
        #expect(snapshot("#C3B9CE").hasEquivalentPresentation(to: snapshot("#C3B9CE")))
        #expect(!snapshot("#C3B9CE").hasEquivalentPresentation(to: snapshot("#C2B9CE")))
        #expect(!snapshot("#C3B9CE").hasEquivalentPresentation(to: snapshot(nil)))
    }

    /// The SwiftUI glyph takes Done's check tick from the same floor the AppKit glyph does: on a brightened fill the
    /// tick is the row's own color, not white. Dark Done in `#7699CB` on `#383847`, drawn at Done's 0.6.
    @Test func theSwiftUICheckTickTakesTheRowsColorOnABrightenedFill() throws {
        let background = hexColor("#383847")
        let glyph = SidebarWorkspaceTaskStatusGlyph(
            status: .done, hasOverride: true, usesMonochrome: false, monochromeColor: .primary, neutralColor: .secondary,
            fontScale: 6, contrastBackground: background, drawnAlpha: 0.6, icon: nil, colorHex: "#7699CB"
        )
        let renderer = ImageRenderer(content: glyph.environment(\EnvironmentValues.colorScheme, .dark))
        renderer.scale = 2
        let cgImage = try #require(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: cgImage)
        var whitePixels = 0
        var backgroundPixels = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.9 else { continue }
                if c.redComponent > 0.95, c.greenComponent > 0.95, c.blueComponent > 0.95 { whitePixels += 1 }
                if isSame(c, background, tolerance: 0.08) { backgroundPixels += 1 }
            }
        }
        #expect(whitePixels == 0, "a white tick on a brightened fill")
        #expect(backgroundPixels > 3, "the tick in the row's color")
    }
}
