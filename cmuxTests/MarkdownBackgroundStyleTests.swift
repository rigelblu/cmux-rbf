import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `cm-15.3` — what the markdown viewer paints its page on.
///
/// These assert against `MarkdownWebTheme.resolve`, which is the single place
/// the decision is made. The panel container, the web view's backing layer and
/// the CSS canvas all derive from its output, so an invariant proven here holds
/// for all three — which is the property the resize flash violated.
@MainActor
@Suite
struct MarkdownBackgroundStyleTests {
    /// A terminal background that is unambiguously light, and one that is not,
    /// so `isDark` is derived rather than assumed.
    private static let lightTerminal = NSColor(srgbRed: 0.97, green: 0.92, blue: 0.91, alpha: 1)
    private static let darkTerminal = NSColor(srgbRed: 0.05, green: 0.06, blue: 0.09, alpha: 1)

    @Test
    func terminalStyleLeavesTheCanvasTransparent() {
        let theme = MarkdownWebTheme.resolve(
            backgroundColor: Self.lightTerminal,
            style: .terminal
        )
        #expect(theme.background == "transparent")
        // nil is load-bearing: MarkdownPanelView falls back to the terminal's
        // own colour when there is no canvas, which is the pre-existing look.
        #expect(theme.canvasColor == nil)
    }

    @Test
    func solidStylePaintsTheStylesheetsOwnCanvas() {
        let light = MarkdownWebTheme.resolve(backgroundColor: Self.lightTerminal, style: .solid)
        #expect(light.background == "rgba(255, 255, 255, 1.000)")
        #expect(light.canvasColor != nil)

        let dark = MarkdownWebTheme.resolve(backgroundColor: Self.darkTerminal, style: .solid)
        // #0d1117 — the canvas github-markdown.css pairs with dark.
        #expect(dark.background == "rgba(13, 17, 23, 1.000)")
        #expect(dark.canvasColor != nil)
    }

    /// The resize-flash precondition — and note what this does NOT prove.
    ///
    /// The flash had one cause: `MarkdownPanelView` painted the terminal colour
    /// behind the web view, so a relayout showed it before the page repainted.
    /// (An earlier note here claimed a second cause in `MarkdownWebRenderer`'s
    /// `pendingTheme`; that was retracted — every read of it is
    /// `lastTheme ?? pendingTheme` and `lastTheme` is set unconditionally.)
    ///
    /// This test asserts only the *precondition*: that a `solid` canvas exists
    /// and is opaque, so there is something to paint behind the page.
    /// `colourBehindPageIsTheCanvasNotTheTerminal` below covers the decision.
    /// Neither can observe *where* the view puts it — that is a SwiftUI
    /// view-tree property with no unit-test seam, and it stays dogfood-verified.
    @Test
    func solidCanvasIsFullyOpaqueSoNothingCanShowThroughDuringLayout() throws {
        for terminal in [Self.lightTerminal, Self.darkTerminal] {
            let theme = MarkdownWebTheme.resolve(backgroundColor: terminal, style: .solid)
            let canvas = try #require(theme.canvasColor, "solid must supply a canvas to paint behind the page")
            // MarkdownWebRenderer.applyBackground gates layer opacity on
            // `alphaComponent >= 0.999`; below that the layer stays see-through.
            #expect(canvas.alphaComponent >= 0.999)
        }
    }

    /// Flipping the canvas must not flip light/dark. A dark-theme reader
    /// switching to `solid` should get the dark canvas, never a white page.
    @Test
    func appearanceStillFollowsTheTerminalInBothStyles() {
        #expect(MarkdownWebTheme.resolve(backgroundColor: Self.darkTerminal, style: .solid).isDark)
        #expect(MarkdownWebTheme.resolve(backgroundColor: Self.darkTerminal, style: .terminal).isDark)
        #expect(!MarkdownWebTheme.resolve(backgroundColor: Self.lightTerminal, style: .solid).isDark)
        #expect(!MarkdownWebTheme.resolve(backgroundColor: Self.lightTerminal, style: .terminal).isDark)
    }

    /// Under `solid` the overlay-derived colours must be computed against the
    /// canvas, not the terminal — otherwise borders and muted fills are tuned
    /// for a background that is no longer visible.
    @Test
    func derivedColoursFollowTheCanvasNotTheTerminal() {
        let solid = MarkdownWebTheme.resolve(backgroundColor: Self.lightTerminal, style: .solid)
        let terminal = MarkdownWebTheme.resolve(backgroundColor: Self.lightTerminal, style: .terminal)
        // Same terminal colour, same appearance — so any difference here proves
        // the overlay base actually changed with the style.
        #expect(solid.isDark == terminal.isDark)
        #expect(solid.border != terminal.border || solid.neutralMutedBackground != terminal.neutralMutedBackground)
    }

    /// The decision the resize-flash fix turns on: what colour goes behind the
    /// page. Under `solid` it must be the canvas — returning the terminal's
    /// colour here is precisely the defect, and this fails if it comes back.
    @Test
    func colourBehindPageIsTheCanvasNotTheTerminal() throws {
        let terminalColour = Self.lightTerminal

        let solid = MarkdownWebTheme.resolve(backgroundColor: terminalColour, style: .solid)
        let behindSolid = MarkdownBackgroundStyle.colourBehindPage(
            theme: solid, panelContent: terminalColour
        )
        let canvas = try #require(solid.canvasColor)
        #expect(behindSolid == canvas)
        // The whole point: it must NOT be the terminal's colour, or a relayout
        // shows the terminal behind a white page for the length of the layout.
        #expect(behindSolid != terminalColour)

        // Under `terminal` there is no canvas and the panel's own colour is
        // correct — the fix must be a no-op there, not a second behaviour.
        let plain = MarkdownWebTheme.resolve(backgroundColor: terminalColour, style: .terminal)
        #expect(
            MarkdownBackgroundStyle.colourBehindPage(theme: plain, panelContent: terminalColour)
                == terminalColour
        )
    }

    @Test
    func unknownRawValuesFallBackToTerminalRatherThanSolid() {
        // A typo in cmux.json must leave the panel as it was, not repaint it.
        #expect(MarkdownBackgroundStyle(rawValueOrTerminal: nil) == .terminal)
        #expect(MarkdownBackgroundStyle(rawValueOrTerminal: "") == .terminal)
        #expect(MarkdownBackgroundStyle(rawValueOrTerminal: "Solid") == .terminal)
        #expect(MarkdownBackgroundStyle(rawValueOrTerminal: "opaque") == .terminal)
        // ...and the two real values still resolve.
        #expect(MarkdownBackgroundStyle(rawValueOrTerminal: "solid") == .solid)
        #expect(MarkdownBackgroundStyle(rawValueOrTerminal: "terminal") == .terminal)
    }

    @Test
    func theDefaultIsTerminalSoAnUpgradeChangesNothing() {
        let defaults = UserDefaults(suiteName: "cmux.tests.markdown.background.\(UUID().uuidString)")!
        defer { defaults.removeSuite(named: defaults.description) }

        #expect(MarkdownBackgroundSettings.resolvedDefault(defaults: defaults) == .terminal)

        MarkdownBackgroundSettings.setDefault(.solid, defaults: defaults)
        #expect(MarkdownBackgroundSettings.resolvedDefault(defaults: defaults) == .solid)

        MarkdownBackgroundSettings.resetDefault(defaults: defaults)
        #expect(MarkdownBackgroundSettings.resolvedDefault(defaults: defaults) == .terminal)
    }
}
