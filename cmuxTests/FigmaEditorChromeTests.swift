import Foundation
import JavaScriptCore
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

    @Test("a link that is not https is left alone")
    func doesNotFireOnPlainHTTP() {
        #expect(!shouldMinimize("http://www.figma.com/design/KEY/slug"))
        #expect(!shouldMinimize("http://figma.com/design/KEY/slug"))
    }

    @Test("a path holding `..` is left alone, written plain or percent-encoded")
    func doesNotFireOnDotDotPath() {
        #expect(!shouldMinimize("https://www.figma.com/design/../community"))
        #expect(!shouldMinimize("https://www.figma.com/design/%2e%2e/community"))
    }

    @Test("all four kinds of Figma file link qualify")
    func firesOnAllFourKinds() {
        for kind in ["design", "file", "board", "slides"] {
            #expect(shouldMinimize("https://www.figma.com/\(kind)/KEY/slug"), "\(kind)")
        }
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

    @Test("the script logs the line the brief promises when the control never appears")
    func scriptLogsTheBriefsLine() throws {
        let context = try #require(JSContext())
        // No DOM: a clock the test moves, a page with no control, and a timer that queues.
        context.evaluateScript("""
        var now = 0, warned = [], queued = [];
        Date.now = function () { return now; };
        console = { warn: function (message) { warned.push(message); } };
        document = { querySelector: function () { return null; } };
        setTimeout = function (callback) { queued.push(callback); };
        """)
        context.evaluateScript("(function () { \(FigmaEditorChrome.minimizeUIScript()) })()")
        #expect(context.evaluateScript("warned.length").toInt32() == 0, "nothing is logged before the deadline")
        context.evaluateScript("now = 20001; queued.shift()();")
        #expect(
            context.evaluateScript("warned").toArray() as? [String]
                == ["[cmux] figma: no minimize control after 20000ms"]
        )
    }

    @Test("the script says so when the control never appears, instead of failing silently")
    func scriptReportsGivingUp() {
        #expect(FigmaEditorChrome.minimizeUIScript().contains("console.warn"))
    }
}

/// The fit on a fresh open (`cm-73.22`): when the one-shot mark is set and spent, and when the
/// press loop stops. The page is faked: the loop reads and presses through closures.
@Suite("FigmaFitOnLoad")
@MainActor
struct FigmaFitOnLoadTests {

    private static let design = URL(string: "https://www.figma.com/design/KEY/slug")!
    private static let recent = URL(string: "https://www.figma.com/files/recent")!

    // MARK: - The mark

    @Test("an entrance opening a design file in the editor sets the mark; a deck, a board, the read view and no address do not")
    func markIsSetOnlyForADesignInTheEditor() {
        var mark = FigmaFitMark()
        mark.opened(Self.design)
        #expect(mark.isPending)
        for no: URL? in [
            URL(string: "https://www.figma.com/board/KEY/slug"),
            URL(string: "https://www.figma.com/slides/KEY/slug"),
            URL(string: "https://embed.figma.com/design/KEY/slug?node-id=1-2"),
            URL(string: "file:///x/figma-embed.html?embed=y"),
            Self.recent,
            nil
        ] {
            var other = FigmaFitMark()
            other.opened(no)
            #expect(!other.isPending, "\(String(describing: no))")
        }
    }

    @Test("the script answering found spends the mark and owes the press once; a second answer owes none")
    func foundSpendsTheMark() {
        var mark = FigmaFitMark()
        mark.opened(Self.design)
        let owed1 = mark.minimizeScriptAnswered(found: true)
        #expect(owed1)
        #expect(!mark.isPending)
        let owed2 = mark.minimizeScriptAnswered(found: true)
        #expect(!owed2, "a reload or an unload-reload finds the mark spent")
    }

    @Test("the script timing out spends the mark and owes no press")
    func timeoutSpendsTheMark() {
        var mark = FigmaFitMark()
        mark.opened(Self.design)
        let owed3 = mark.minimizeScriptAnswered(found: false)
        #expect(!owed3)
        #expect(!mark.isPending)
        let owed4 = mark.minimizeScriptAnswered(found: true)
        #expect(!owed4)
    }

    @Test("with no mark, found owes no press: a restart restore and a reload never fit")
    func noMarkNoPress() {
        var mark = FigmaFitMark()
        let owed5 = mark.minimizeScriptAnswered(found: true)
        #expect(!owed5)
    }

    @Test("a finished navigation that starts no script clears the mark")
    func navigationWithoutScriptClears() {
        var mark = FigmaFitMark()
        mark.opened(Self.design)
        mark.navigationFinishedWithoutMinimize()
        #expect(!mark.isPending)
        let owed6 = mark.minimizeScriptAnswered(found: true)
        #expect(!owed6)
    }

    @Test("a design opened in place from Figma's recent files sets the mark; the same file changing its address does not")
    func inPlaceOpen() {
        var mark = FigmaFitMark()
        mark.openedInPlace(from: Self.recent, to: Self.design)
        #expect(mark.isPending)
        var same = FigmaFitMark()
        same.openedInPlace(from: Self.design, to: Self.design)
        #expect(!same.isPending)
        var restored = FigmaFitMark()
        restored.openedInPlace(from: nil, to: Self.design)
        #expect(!restored.isPending)
    }

    @Test("an in-place address change does not clear a mark that is already set")
    func inPlaceKeepsAPendingMark() {
        var mark = FigmaFitMark()
        mark.opened(Self.design)
        mark.openedInPlace(from: Self.design, to: Self.design)
        #expect(mark.isPending)
    }

    // MARK: - The loop

    /// A page whose zoom label is read from `labels` in order, and which counts what was done to it.
    private final class FakePage {
        var labels: [String?]
        var reads = 0
        var presses: [Int] = []
        var showing: [Bool]
        var checks = 0
        var typingAfterPresses: Int?
        var pauses = 0
        var hidesDuringTypingCheck = false

        init(labels: [String?], showing: [Bool] = [true]) {
            self.labels = labels
            self.showing = showing
        }

        func nextLabel() -> String? {
            defer { reads += 1 }
            return labels[min(reads, labels.count - 1)]
        }

        func isShowing() -> Bool {
            defer { checks += 1 }
            return showing[min(checks, showing.count - 1)]
        }

        func isTyping() -> Bool {
            if hidesDuringTypingCheck { showing = [false]; checks = 0 }
            guard let typingAfterPresses else { return false }
            return presses.count >= typingAfterPresses
        }
    }

    private func run(_ page: FakePage, maxTries: Int = FigmaFitOnLoad.maxTries) async -> FigmaFitOnLoad.Outcome {
        await FigmaFitOnLoad.run(
            maxTries: maxTries,
            isShowing: { page.isShowing() },
            isTyping: { page.isTyping() },
            zoomLabel: { page.nextLabel() },
            press: { page.presses.append($0) },
            pause: { page.pauses += 1 }
        )
    }

    private let before = "100%, zoom and view options"
    private let after = "15%, zoom and view options"

    @Test("the first press fits: one press, then it stops")
    func stopsAtTheFirstChange() async {
        let page = FakePage(labels: [before, after])
        let outcome = await run(page)
        #expect(outcome == .init(stop: .changed, tries: 1))
        #expect(page.presses == [1])
        #expect(page.pauses == 1)
    }

    @Test("a press that lands late: it repeats until the label changes, and stops at that change")
    func repeatsUntilTheLabelChanges() async {
        let page = FakePage(labels: [before, before, before, after, after])
        let outcome = await run(page)
        #expect(outcome == .init(stop: .changed, tries: 3))
        #expect(page.presses == [1, 2, 3])
    }

    @Test("a label that never changes is pressed the cap and no more")
    func stopsAtTheCap() async {
        let page = FakePage(labels: [before])
        let outcome = await run(page)
        #expect(outcome == .init(stop: .capped, tries: FigmaFitOnLoad.maxTries))
        #expect(page.presses.count == FigmaFitOnLoad.maxTries)
        #expect(FigmaFitOnLoad.maxTries == 8)
    }

    @Test("a pane that is not showing is not pressed")
    func notShowingAtTheStart() async {
        let page = FakePage(labels: [before, after], showing: [false])
        let outcome = await run(page)
        #expect(outcome == .init(stop: .notShowing, tries: 0))
        #expect(page.presses.isEmpty)
    }

    @Test("a pane that stops showing after two presses gets no third")
    func stopsShowing() async {
        let page = FakePage(labels: [before], showing: [true, true, false])
        let outcome = await run(page)
        #expect(outcome == .init(stop: .notShowing, tries: 2))
        #expect(page.presses == [1, 2])
    }

    @Test("a pane hidden while the focus check runs gets no press")
    func hiddenDuringTheFocusCheck() async {
        let page = FakePage(labels: [before, after])
        page.hidesDuringTypingCheck = true
        let outcome = await run(page)
        #expect(outcome == .init(stop: .notShowing, tries: 0))
        #expect(page.presses.isEmpty)
    }

    @Test("a text field that takes focus stops the presses before the next one")
    func stopsWhenTyping() async {
        let page = FakePage(labels: [before])
        page.typingAfterPresses = 2
        let outcome = await run(page)
        #expect(outcome == .init(stop: .typing, tries: 2))
        #expect(page.presses == [1, 2])
    }

    @Test("a text field already focused at the start means no press at all")
    func typingAtTheStart() async {
        let page = FakePage(labels: [before])
        page.typingAfterPresses = 0
        let outcome = await run(page)
        #expect(outcome == .init(stop: .typing, tries: 0))
        #expect(page.presses.isEmpty)
    }

    @Test("a label that is missing is never a change, and the first label seen becomes the baseline")
    func missingLabelIsNoChange() async {
        let absent = FakePage(labels: [nil])
        let absentOutcome = await run(absent, maxTries: 3)
        #expect(absentOutcome == .init(stop: .capped, tries: 3))

        let appears = FakePage(labels: [nil, nil, before, after])
        let appearsOutcome = await run(appears)
        #expect(appearsOutcome == .init(stop: .changed, tries: 3))
        #expect(appears.presses == [1, 2, 3])
    }

    @Test("a web view shows when it is in a window, not hidden, and not zero-sized")
    func showingRule() {
        let size = CGSize(width: 400, height: 300)
        #expect(FigmaFitOnLoad.isShowing(hasWindow: true, isHidden: false, size: size))
        #expect(!FigmaFitOnLoad.isShowing(hasWindow: false, isHidden: false, size: size))
        #expect(!FigmaFitOnLoad.isShowing(hasWindow: true, isHidden: true, size: size))
        #expect(!FigmaFitOnLoad.isShowing(hasWindow: true, isHidden: false, size: CGSize(width: 0, height: 300)))
        #expect(!FigmaFitOnLoad.isShowing(hasWindow: true, isHidden: false, size: CGSize(width: 400, height: 0)))
    }
}
