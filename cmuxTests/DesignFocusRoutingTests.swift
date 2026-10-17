// cmux-rbf #cm-73.2a
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("DesignFocusRouting")
struct DesignFocusRoutingTests {

    private let wrapper = URL(fileURLWithPath: "/tmp/cmux-figma-tests/figma-embed.html")
    private let figmaURL = URL(string: "https://www.figma.com/design/KEY123/my-file")!
    private let figmaWithNodeURL = URL(string: "https://www.figma.com/design/KEY123/my-file?node-id=12-2")!
    private let httpURL = URL(string: "https://example.com/docs")!
    private let aboutBlankURL = URL(string: "about:blank")!
    private let diffViewerURL = URL(string: "cmux-diff-viewer://review/123")!
    private let localHTMLURL = URL(string: "file:///Users/test/index.html")!

    private var readViewURL: URL {
        URL(string: "file:///tmp/cmux-figma-tests/figma-embed.html?embed=https%3A%2F%2Fwww.figma.com%2Fdesign%2FKEY123%2Fmy-file")!
    }

    // MARK: - Row 1: Figma Page

    @Test("Row 1, Col 1: Figma page, Tom asked new tab -> into Figma side, selected, keyboard to it")
    func row1Col1TomNewTab() {
        let outcome = DesignFocusRouting.decide(
            url: figmaURL,
            showsAddressBar: false,
            target: .newTab,
            asker: .user,
            wantsFocus: true,
            wrapper: wrapper
        )
        #expect(outcome == .intoFigmaSide(selectKeyboard: true))
    }

    @Test("Row 1, Col 1: Figma page, Tom asked new split -> into Figma side, never a split, keyboard to it")
    func row1Col1TomNewSplit() {
        let outcome = DesignFocusRouting.decide(
            url: figmaWithNodeURL,
            showsAddressBar: false,
            target: .newSplit,
            asker: .user,
            wantsFocus: true,
            wrapper: wrapper
        )
        #expect(outcome == .intoFigmaSide(selectKeyboard: true))
    }

    @Test("Row 1: cmux read-view page figma-embed.html counts as a Figma page")
    func row1ReadViewEmbedPage() {
        let outcome = DesignFocusRouting.decide(
            url: readViewURL,
            showsAddressBar: false,
            target: .newTab,
            asker: .user,
            wantsFocus: true,
            wrapper: wrapper
        )
        #expect(outcome == .intoFigmaSide(selectKeyboard: true))
    }

    @Test("Row 1, Col 2: Figma page, agent asked new tab -> into Figma side, keyboard stays")
    func row1Col2AgentNewTab() {
        let outcome = DesignFocusRouting.decide(
            url: figmaURL,
            showsAddressBar: false,
            target: .newTab,
            asker: .agent,
            wantsFocus: false,
            wrapper: wrapper
        )
        #expect(outcome == .intoFigmaSide(selectKeyboard: false))
    }

    @Test("Row 1, Col 2: Figma page, agent asked new split -> into Figma side, never a split, keyboard stays")
    func row1Col2AgentNewSplit() {
        let outcome = DesignFocusRouting.decide(
            url: figmaURL,
            showsAddressBar: false,
            target: .newSplit,
            asker: .agent,
            wantsFocus: false,
            wrapper: wrapper
        )
        #expect(outcome == .intoFigmaSide(selectKeyboard: false))
    }

    @Test("Row 1: Agent call asking for focus ends the mode and shows it")
    func row1AgentAsksFocus() {
        let outcome = DesignFocusRouting.decide(
            url: figmaURL,
            showsAddressBar: false,
            target: .newTab,
            asker: .agent,
            wantsFocus: true,
            wrapper: wrapper
        )
        #expect(outcome == .endModeThenAsToday)
    }

    @Test("Row 1, Col 3: Figma page, page asked new tab -> mode ends and shows it")
    func row1Col3PageNewTab() {
        let outcome = DesignFocusRouting.decide(
            url: figmaURL,
            showsAddressBar: false,
            target: .newTab,
            asker: .page,
            wantsFocus: false,
            wrapper: wrapper
        )
        #expect(outcome == .endModeThenAsToday)
    }

    @Test("Row 1, Col 4: Figma page moved into pair pane by agent -> behind, not selected")
    func row1Col4AgentMovedIn() {
        let outcome = DesignFocusRouting.decide(
            url: figmaURL,
            showsAddressBar: false,
            target: .movedIntoPairPane,
            asker: .agent,
            wantsFocus: false,
            wrapper: wrapper
        )
        #expect(outcome == .behind)
    }

    @Test("Row 1, Col 4: Figma page moved into pair pane by user (Tom's Move Surface) -> ends mode")
    func row1Col4UserMovedIn() {
        let outcome = DesignFocusRouting.decide(
            url: figmaURL,
            showsAddressBar: false,
            target: .movedIntoPairPane,
            asker: .user,
            wantsFocus: true,
            wrapper: wrapper
        )
        #expect(outcome == .endModeThenAsToday)
    }

    @Test("Row 1, Col 5: Figma page, pair tab navigated -> goes ahead (as today)")
    func row1Col5PairTabNavigated() {
        let outcome = DesignFocusRouting.decide(
            url: figmaWithNodeURL,
            showsAddressBar: false,
            target: .pairTabNavigated,
            asker: .user,
            wantsFocus: false,
            wrapper: wrapper
        )
        #expect(outcome == .asToday)
    }

    @Test("Row 1, Col 6: Figma page, hidden tab navigated -> as today")
    func row1Col6HiddenTabNavigated() {
        let outcome = DesignFocusRouting.decide(
            url: figmaURL,
            showsAddressBar: false,
            target: .hiddenTabNavigated,
            asker: .user,
            wantsFocus: false,
            wrapper: wrapper
        )
        #expect(outcome == .asToday)
    }

    // MARK: - Row 2: Non-Figma HTTP(S) Page

    @Test("Row 2, Col 1: Non-Figma http page, Tom asked new tab -> default browser")
    func row2Col1TomNewTab() {
        let outcome = DesignFocusRouting.decide(
            url: httpURL,
            showsAddressBar: false,
            target: .newTab,
            asker: .user,
            wantsFocus: true,
            wrapper: wrapper
        )
        #expect(outcome == .externalBrowser)
    }

    @Test("Row 2, Col 1: Non-Figma http page, Tom asked new split -> default browser")
    func row2Col1TomNewSplit() {
        let outcome = DesignFocusRouting.decide(
            url: httpURL,
            showsAddressBar: false,
            target: .newSplit,
            asker: .user,
            wantsFocus: true,
            wrapper: wrapper
        )
        #expect(outcome == .externalBrowser)
    }

    @Test("Row 2: Figma.com link with address bar is an ordinary browser tab -> default browser")
    func row2FigmaWithAddressBar() {
        let outcome = DesignFocusRouting.decide(
            url: figmaURL,
            showsAddressBar: true,
            target: .newTab,
            asker: .user,
            wantsFocus: true,
            wrapper: wrapper
        )
        #expect(outcome == .externalBrowser)
    }

    @Test("Row 2, Col 2: Non-Figma http page, agent asked new tab -> default browser")
    func row2Col2AgentNewTab() {
        let outcome = DesignFocusRouting.decide(
            url: httpURL,
            showsAddressBar: false,
            target: .newTab,
            asker: .agent,
            wantsFocus: false,
            wrapper: wrapper
        )
        #expect(outcome == .externalBrowser)
    }

    @Test("Row 2, Col 2: Non-Figma http page, agent asked new split -> default browser")
    func row2Col2AgentNewSplit() {
        let outcome = DesignFocusRouting.decide(
            url: httpURL,
            showsAddressBar: false,
            target: .newSplit,
            asker: .agent,
            wantsFocus: false,
            wrapper: wrapper
        )
        #expect(outcome == .externalBrowser)
    }

    @Test("Row 2, Col 3: Non-Figma http page, page asked new tab (e.g. Figma sign-in) -> ends mode and shows it")
    func row2Col3PageNewTab() {
        let outcome = DesignFocusRouting.decide(
            url: URL(string: "https://www.figma.com/login")!,
            showsAddressBar: false,
            target: .newTab,
            asker: .page,
            wantsFocus: false,
            wrapper: wrapper
        )
        #expect(outcome == .endModeThenAsToday)
    }

    @Test("Row 2, Col 4: Non-Figma http page moved in by agent -> behind, not selected")
    func row2Col4AgentMovedIn() {
        let outcome = DesignFocusRouting.decide(
            url: httpURL,
            showsAddressBar: false,
            target: .movedIntoPairPane,
            asker: .agent,
            wantsFocus: false,
            wrapper: wrapper
        )
        #expect(outcome == .behind)
    }

    @Test("Row 2, Col 5: Non-Figma http page, pair tab navigated -> default browser, pair tab unchanged")
    func row2Col5PairTabNavigated() {
        let outcome = DesignFocusRouting.decide(
            url: httpURL,
            showsAddressBar: false,
            target: .pairTabNavigated,
            asker: .user,
            wantsFocus: false,
            wrapper: wrapper
        )
        #expect(outcome == .externalBrowser)
    }

    @Test("Row 2, Col 6: Non-Figma http page, hidden tab navigated -> as today")
    func row2Col6HiddenTabNavigated() {
        let outcome = DesignFocusRouting.decide(
            url: httpURL,
            showsAddressBar: false,
            target: .hiddenTabNavigated,
            asker: .user,
            wantsFocus: false,
            wrapper: wrapper
        )
        #expect(outcome == .asToday)
    }

    // MARK: - Row 3: No URL or about:blank

    @Test("Row 3, Col 1: No URL, Tom asked new tab (cmd-T) -> mode ends and shows it")
    func row3Col1TomNewTabNoURL() {
        let outcome = DesignFocusRouting.decide(
            url: nil,
            showsAddressBar: false,
            target: .newTab,
            asker: .user,
            wantsFocus: true,
            wrapper: wrapper
        )
        #expect(outcome == .endModeThenAsToday)
    }

    @Test("Row 3, Col 1: about:blank, Tom asked new split -> mode ends and shows it")
    func row3Col1TomNewSplitBlank() {
        let outcome = DesignFocusRouting.decide(
            url: aboutBlankURL,
            showsAddressBar: false,
            target: .newSplit,
            asker: .user,
            wantsFocus: true,
            wrapper: wrapper
        )
        #expect(outcome == .endModeThenAsToday)
    }

    @Test("Row 3, Col 2: No URL, agent asked new tab -> behind, not selected")
    func row3Col2AgentNewTab() {
        let outcome = DesignFocusRouting.decide(
            url: nil,
            showsAddressBar: false,
            target: .newTab,
            asker: .agent,
            wantsFocus: false,
            wrapper: wrapper
        )
        #expect(outcome == .behind)
    }

    @Test("Row 3, Col 2: No URL, agent asked new split -> made out of sight")
    func row3Col2AgentNewSplit() {
        let outcome = DesignFocusRouting.decide(
            url: nil,
            showsAddressBar: false,
            target: .newSplit,
            asker: .agent,
            wantsFocus: false,
            wrapper: wrapper
        )
        #expect(outcome == .madeOutOfSight)
    }

    @Test("Row 3, Col 3: about:blank, page asked new tab -> mode ends and shows it")
    func row3Col3PageNewTab() {
        let outcome = DesignFocusRouting.decide(
            url: aboutBlankURL,
            showsAddressBar: false,
            target: .newTab,
            asker: .page,
            wantsFocus: false,
            wrapper: wrapper
        )
        #expect(outcome == .endModeThenAsToday)
    }

    @Test("Row 3, Col 4: No URL moved into pair pane by agent -> behind, not selected")
    func row3Col4AgentMovedIn() {
        let outcome = DesignFocusRouting.decide(
            url: nil,
            showsAddressBar: false,
            target: .movedIntoPairPane,
            asker: .agent,
            wantsFocus: false,
            wrapper: wrapper
        )
        #expect(outcome == .behind)
    }

    @Test("Row 3, Col 5: about:blank, pair tab navigated -> as today")
    func row3Col5PairTabNavigated() {
        let outcome = DesignFocusRouting.decide(
            url: aboutBlankURL,
            showsAddressBar: false,
            target: .pairTabNavigated,
            asker: .user,
            wantsFocus: false,
            wrapper: wrapper
        )
        #expect(outcome == .asToday)
    }

    // MARK: - Row 4: cmux pages & local HTML (non-figma)

    @Test("Row 4, Col 1: cmux-diff-viewer, Tom asked new tab -> mode ends and shows it")
    func row4Col1TomNewTabDiff() {
        let outcome = DesignFocusRouting.decide(
            url: diffViewerURL,
            showsAddressBar: false,
            target: .newTab,
            asker: .user,
            wantsFocus: true,
            wrapper: wrapper
        )
        #expect(outcome == .endModeThenAsToday)
    }

    @Test("Row 4, Col 1: Local HTML, Tom asked new split -> mode ends and shows it")
    func row4Col1TomNewSplitLocal() {
        let outcome = DesignFocusRouting.decide(
            url: localHTMLURL,
            showsAddressBar: false,
            target: .newSplit,
            asker: .user,
            wantsFocus: true,
            wrapper: wrapper
        )
        #expect(outcome == .endModeThenAsToday)
    }

    @Test("Row 4, Col 2: cmux-diff-viewer, agent asked new tab -> behind, not selected")
    func row4Col2AgentNewTab() {
        let outcome = DesignFocusRouting.decide(
            url: diffViewerURL,
            showsAddressBar: false,
            target: .newTab,
            asker: .agent,
            wantsFocus: false,
            wrapper: wrapper
        )
        #expect(outcome == .behind)
    }

    @Test("Row 4, Col 2: Local HTML, agent asked new split -> made out of sight")
    func row4Col2AgentNewSplit() {
        let outcome = DesignFocusRouting.decide(
            url: localHTMLURL,
            showsAddressBar: false,
            target: .newSplit,
            asker: .agent,
            wantsFocus: false,
            wrapper: wrapper
        )
        #expect(outcome == .madeOutOfSight)
    }

    @Test("Row 4, Col 3: cmux-diff-viewer, page asked new tab -> mode ends and shows it")
    func row4Col3PageNewTab() {
        let outcome = DesignFocusRouting.decide(
            url: diffViewerURL,
            showsAddressBar: false,
            target: .newTab,
            asker: .page,
            wantsFocus: false,
            wrapper: wrapper
        )
        #expect(outcome == .endModeThenAsToday)
    }

    @Test("Row 4, Col 4: Local HTML moved in by agent -> behind, not selected")
    func row4Col4AgentMovedIn() {
        let outcome = DesignFocusRouting.decide(
            url: localHTMLURL,
            showsAddressBar: false,
            target: .movedIntoPairPane,
            asker: .agent,
            wantsFocus: false,
            wrapper: wrapper
        )
        #expect(outcome == .behind)
    }

    @Test("Row 4, Col 5: cmux-diff-viewer, pair tab navigated -> as today")
    func row4Col5PairTabNavigated() {
        let outcome = DesignFocusRouting.decide(
            url: diffViewerURL,
            showsAddressBar: false,
            target: .pairTabNavigated,
            asker: .user,
            wantsFocus: false,
            wrapper: wrapper
        )
        #expect(outcome == .asToday)
    }

    // MARK: - Mode Off Behavior

    @Test("Mode off: all targets route as today")
    func modeOffRoutesAsToday() {
        let o1 = DesignFocusRouting.decide(
            url: httpURL,
            showsAddressBar: false,
            target: .newTab,
            asker: .user,
            wantsFocus: true,
            modeEnabled: false,
            wrapper: wrapper
        )
        #expect(o1 == .asToday)

        let o2 = DesignFocusRouting.decide(
            url: figmaURL,
            showsAddressBar: false,
            target: .newTab,
            asker: .user,
            wantsFocus: true,
            modeEnabled: false,
            wrapper: wrapper
        )
        #expect(o2 == .asToday)

        let o3 = DesignFocusRouting.decide(
            url: nil,
            showsAddressBar: false,
            target: .newSplit,
            asker: .agent,
            wantsFocus: false,
            modeEnabled: false,
            wrapper: wrapper
        )
        #expect(o3 == .asToday)
    }
}
