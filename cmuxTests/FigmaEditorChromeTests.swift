import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The gate on collapsing Figma's editor panels.
///
/// The interesting cases are the refusals: this fires on every finished
/// navigation in every browser pane, so the ways it must *not* fire carry more
/// risk than the way it must.
@Suite("FigmaEditorChrome")
struct FigmaEditorChromeTests {

    private func shouldMinimize(_ raw: String?, omnibarVisible: Bool = false) -> Bool {
        FigmaEditorChrome.shouldMinimizeUI(
            paneURL: raw.flatMap { URL(string: $0) },
            isOmnibarVisible: omnibarVisible
        )
    }

    @Test("a chrome-free pane showing the Figma editor gets its panels collapsed")
    func firesOnAChromeFreeEditorPane() {
        #expect(shouldMinimize("https://www.figma.com/design/KEY/cm-73---figma-native-pane"))
    }

    @Test("the live editor URL Figma leaves behind still qualifies")
    func firesOnTheURLFigmaActuallyLeaves() {
        // Measured 2026-09-08: loading a bare file URL leaves the slug and a
        // `t=` token in the bar. The gate must not be confused by either.
        #expect(shouldMinimize("https://www.figma.com/design/KEY/cm-73---figma-native-pane?t=hERjtUAfzKGDErfX-0"))
    }

    @Test("an ordinary browser pane the user navigated to Figma is left alone")
    func doesNotFireWhenTheUserIsJustBrowsing() {
        // The one that would be a genuine surprise: someone clicks a Figma
        // link in a normal pane and their panels silently vanish, with nothing
        // on screen explaining it.
        #expect(!shouldMinimize("https://www.figma.com/design/KEY/slug", omnibarVisible: true))
    }

    @Test("the embed surface is left alone — it has no panels and its chrome is not ours")
    func doesNotFireOnTheEmbed() {
        #expect(!shouldMinimize("https://embed.figma.com/design/KEY/slug?embed-host=cmux"))
        #expect(!shouldMinimize("file:///Users/x/Library/Application%20Support/cmux/figma-embed.html?theme=dark"))
    }

    @Test("non-Figma pages are left alone, including lookalike hosts")
    func doesNotFireElsewhere() {
        #expect(!shouldMinimize("https://example.com/design/KEY/slug"))
        #expect(!shouldMinimize("https://notfigma.com/design/KEY/slug"))
        #expect(!shouldMinimize("https://www.figma.com/files/recent"))
        #expect(!shouldMinimize(nil))
    }

    // MARK: - The script

    @Test("the script drives Figma's control rather than sending its shortcut")
    func scriptClicksTheControl() {
        let script = FigmaEditorChrome.minimizeUIScript()
        #expect(script.contains(FigmaEditorChrome.minimizeControlSelector))
        #expect(script.contains(".click()"))
        // Both of Figma's shortcuts were measured inert from an unfocused
        // WebView, so nothing here may quietly go back to sending a key.
        #expect(!script.contains("KeyboardEvent"))
        #expect(!script.contains("Backslash"))
    }

    @Test("the script keeps polling, because navigation-finished is before Figma has booted")
    func scriptPolls() {
        let script = FigmaEditorChrome.minimizeUIScript(timeoutMilliseconds: 9_000, pollMilliseconds: 300)
        #expect(script.contains("setTimeout"))
        #expect(script.contains("9000"))
        #expect(script.contains("300"))
    }

    @Test("the script says so when the control never appears, instead of failing silently")
    func scriptReportsGivingUp() {
        #expect(FigmaEditorChrome.minimizeUIScript().contains("console.warn"))
    }
}
