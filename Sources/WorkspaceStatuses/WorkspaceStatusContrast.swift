import AppKit
import CmuxAppKitSupportUI
import SwiftUI

/// Floors a glyph color to at least `minimum` contrast ratio against `background`,
/// blending toward whichever end (black or white) reaches the minimum with the smaller
/// blend fraction, preserving the hue.
///
/// Both `color` and `background` are opaque sRGB colors. If `drawnAt` < 1, the color's
/// drawn alpha is composited over `background` before measuring contrast.
func cmuxColor(
    _ color: NSColor,
    clearing minimum: CGFloat = 3,
    against background: NSColor,
    drawnAt alpha: CGFloat = 1
) -> NSColor {
    let opaqueColor = (color.usingColorSpace(.sRGB) ?? color).withAlphaComponent(1)
    let opaqueBg = (background.usingColorSpace(.sRGB) ?? background).withAlphaComponent(1)
    let effectiveAlpha = max(0, min(alpha, 1))

    func drawn(_ c: NSColor) -> NSColor {
        cmuxCompositedNSColor(c.withAlphaComponent(effectiveAlpha), over: opaqueBg)
    }

    func ratio(_ c: NSColor) -> CGFloat {
        cmuxContrastRatio(foreground: drawn(c), background: opaqueBg)
    }

    if ratio(opaqueColor) >= minimum {
        return color
    }

    var cr: CGFloat = 0
    var cg: CGFloat = 0
    var cb: CGFloat = 0
    var ca: CGFloat = 0
    opaqueColor.getRed(&cr, green: &cg, blue: &cb, alpha: &ca)

    func blendColor(toward targetVal: CGFloat, fraction: CGFloat) -> NSColor {
        NSColor(
            srgbRed: cr * (1 - fraction) + targetVal * fraction,
            green: cg * (1 - fraction) + targetVal * fraction,
            blue: cb * (1 - fraction) + targetVal * fraction,
            alpha: 1
        )
    }

    var bestFraction: CGFloat?
    var bestColor: NSColor?

    for targetVal: CGFloat in [0, 1] {
        let targetColor = NSColor(srgbRed: targetVal, green: targetVal, blue: targetVal, alpha: 1)
        if ratio(targetColor) >= minimum {
            var lo: CGFloat = 0
            var hi: CGFloat = 1
            for _ in 0..<24 {
                let mid = (lo + hi) / 2
                let cand = blendColor(toward: targetVal, fraction: mid)
                if ratio(cand) >= minimum {
                    hi = mid
                } else {
                    lo = mid
                }
            }
            if bestFraction == nil || hi < bestFraction! {
                bestFraction = hi
                bestColor = blendColor(toward: targetVal, fraction: hi)
            }
        }
    }

    if let best = bestColor {
        return best
    }

    let blackRatio = ratio(NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    let whiteRatio = ratio(NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    return blackRatio >= whiteRatio
        ? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
}

/// Returns true when the yellow hand requires a dark ink outline because its contrast
/// ratio on `background` is under 3:1, judged as drawn: the yellow at `alpha` (a Done row's
/// dim) composited over the background.
func handNeedsOutline(yellow: NSColor, on background: NSColor, drawnAt alpha: CGFloat = 1) -> Bool {
    let y = (yellow.usingColorSpace(.sRGB) ?? yellow).withAlphaComponent(1)
    let bg = (background.usingColorSpace(.sRGB) ?? background).withAlphaComponent(1)
    let drawn = cmuxCompositedNSColor(y.withAlphaComponent(max(0, min(alpha, 1))), over: bg)
    return cmuxContrastRatio(foreground: drawn, background: bg) < 3
}

/// The waiting hand's color: `systemYellow` resolved for the row's scheme, never adjusted.
func waitingHandYellow(for colorScheme: ColorScheme) -> NSColor {
    WindowAppearanceSnapshot.resolvedColor(.systemYellow, for: colorScheme)
}

/// The dark ink the waiting hand's outline is drawn in.
let waitingHandOutlineInk = NSColor(srgbRed: 0x2B / 255, green: 0x24 / 255, blue: 0, alpha: 1)

/// The outline is the hand drawn eight more times under the yellow one, each copy 0.5 pt away.
let waitingHandOutlineOffsets: [CGSize] = [
    CGSize(width: -0.5, height: 0), CGSize(width: 0.5, height: 0),
    CGSize(width: 0, height: -0.5), CGSize(width: 0, height: 0.5),
    CGSize(width: -0.5, height: -0.5), CGSize(width: 0.5, height: 0.5),
    CGSize(width: -0.5, height: 0.5), CGSize(width: 0.5, height: -0.5)
]

/// The hand's outline in the AppKit row: eight image views holding the hand's image in ink, each
/// `waitingHandOutlineOffsets` away from the view's bounds, drawn by the same image view the yellow hand
/// is drawn by, so each copy is fitted into the slot exactly as the hand is.
final class WaitingHandOutlineView: NSView {
    private let copies: [NSImageView]

    var image: NSImage? {
        didSet { copies.forEach { $0.image = image } }
    }

    override init(frame frameRect: NSRect) {
        copies = waitingHandOutlineOffsets.map { _ in
            let view = NSImageView()
            view.imageScaling = .scaleProportionallyDown
            view.contentTintColor = waitingHandOutlineInk
            return view
        }
        super.init(frame: frameRect)
        copies.forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        for (view, offset) in zip(copies, waitingHandOutlineOffsets) {
            view.frame = bounds.offsetBy(dx: offset.width, dy: offset.height)
        }
    }
}

/// The waiting hand in the SwiftUI row: the yellow hand, with the eight ink copies under it where the
/// yellow alone, as drawn at `drawnAlpha` on `rowBackground`, is under 3:1.
struct WaitingHandView: View {
    let pointSize: CGFloat
    let colorScheme: ColorScheme
    let rowBackground: NSColor?
    let drawnAlpha: CGFloat

    var body: some View {
        let yellow = waitingHandYellow(for: colorScheme)
        let outlined = rowBackground.map { handNeedsOutline(yellow: yellow, on: $0, drawnAt: drawnAlpha) } ?? false
        ZStack {
            if outlined {
                ForEach(0..<waitingHandOutlineOffsets.count, id: \.self) { index in
                    CmuxSystemSymbolImage(
                        systemName: "hand.raised.fill",
                        pointSize: pointSize,
                        tint: Color(nsColor: waitingHandOutlineInk)
                    )
                    .offset(
                        x: waitingHandOutlineOffsets[index].width,
                        y: waitingHandOutlineOffsets[index].height
                    )
                }
            }
            CmuxSystemSymbolImage(
                systemName: "hand.raised.fill",
                pointSize: pointSize,
                tint: Color(nsColor: yellow)
            )
        }
    }
}

/// What every status glyph draws, from one place: `base` resolved for `colorScheme`, composited
/// over `background`, floored to 3:1 as drawn at `drawnAlpha` (`fill`), and Done's check tick
/// (`tick`): white, or the row's own color where flooring brightened the fill.
func cmuxFlooredGlyphColors(
    base: NSColor,
    colorScheme: ColorScheme,
    background: NSColor,
    drawnAlpha: CGFloat
) -> (fill: NSColor, tick: NSColor) {
    let resolved = WindowAppearanceSnapshot.resolvedColor(base, for: colorScheme)
    let composited = cmuxCompositedNSColor(resolved, over: background)
    let fill = cmuxColor(composited, clearing: 3, against: background, drawnAt: drawnAlpha)
    let tick = cmuxFillWasBrightened(fill: fill, unfloored: composited)
        ? (background.usingColorSpace(.sRGB) ?? background).withAlphaComponent(1)
        : NSColor.white
    return (fill, tick)
}

/// What the sidebar's backdrop looks like under its rows, as an opaque color: the chrome color
/// when surfaces are unified, else the window background under the sidebar's tint. A stand-in,
/// since the real backdrop can be translucent.
func sidebarContrastStandIn(
    unifySurfaceBackdrops: Bool,
    chromeBackground: NSColor,
    contentColorScheme: ColorScheme,
    tint: NSColor
) -> NSColor {
    if unifySurfaceBackdrops {
        return chromeBackground
    }
    let windowBackground = WindowAppearanceSnapshot.resolvedColor(.windowBackgroundColor, for: contentColorScheme)
    return cmuxCompositedNSColor(tint, over: windowBackground)
}

extension SidebarWorkspaceRowVisualPalette {
    /// The color a row's marks sit on, for the contrast floors: the sidebar stand-in under the
    /// row's own wash (selection fill, color tint), composited.
    func contrastBackground(sidebarStandIn: NSColor) -> NSColor {
        let style = backgroundStyle
        if let styleColor = style.color, style.opacity > 0 {
            let wash = styleColor.withAlphaComponent(style.opacity * styleColor.alphaComponent)
            return cmuxCompositedNSColor(wash, over: sidebarStandIn)
        }
        return sidebarStandIn
    }
}

/// Relative luminance (WCAG) of `color` in sRGB. A copy of `cmuxRelativeLuminance` in
/// `SidebarAppearanceSupport.swift`, which is private to that upstream file; copying it keeps
/// this feature out of upstream's file.
func cmuxColorRelativeLuminance(_ color: NSColor) -> CGFloat {
    let srgb = color.usingColorSpace(.sRGB) ?? color
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    srgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    _ = alpha

    func linearized(_ component: CGFloat) -> CGFloat {
        component <= 0.03928
            ? component / 12.92
            : CGFloat(pow(Double((component + 0.055) / 1.055), 2.4))
    }

    return 0.2126 * linearized(red)
        + 0.7152 * linearized(green)
        + 0.0722 * linearized(blue)
}

/// True when flooring lightened `unfloored` into `fill`: the cue for Done's check tick to
/// take the row's color instead of white, since white on a brightened fill loses contrast.
func cmuxFillWasBrightened(fill: NSColor, unfloored: NSColor) -> Bool {
    cmuxColorRelativeLuminance(fill) > cmuxColorRelativeLuminance(unfloored) + 1e-4
}

private struct SidebarContrastBackgroundHexKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var sidebarContrastBackgroundHex: String? {
        get { self[SidebarContrastBackgroundHexKey.self] }
        set { self[SidebarContrastBackgroundHexKey.self] = newValue }
    }
}
