import Foundation
import JavaScriptCore
import Testing

/// Which pane `cmux figma goto` moves, what it says when it moves none, and
/// the help text. The socket is not involved: these are the rules the command
/// file only calls.
@Suite("FigmaCLIRules")
struct FigmaCLIRulesTests {

    private static let figma = URL(string: "https://www.figma.com/design/KEY/slug")!

    /// A pane showing a Figma file. `bar` is its `show_omnibar`: `false` is a
    /// pane `cmux figma open` made, `true` an ordinary one, `nil` an old app's
    /// reply that carried no such key.
    private func pane(_ number: Int, bar: Bool?, figma isFigma: Bool = true) -> FigmaGotoPicker.Pane {
        FigmaGotoPicker.Pane(
            id: "uuid-\(number)",
            handle: "surface:\(number)",
            document: isFigma ? Self.figma : nil,
            showsAddressBar: bar
        )
    }

    private func refusal(_ outcome: FigmaGotoPicker.Outcome) -> String? {
        if case .refuse(let message) = outcome { return message }
        return nil
    }

    private func moved(_ outcome: FigmaGotoPicker.Outcome) -> String? {
        if case .move(let pane) = outcome { return pane.handle }
        return nil
    }

    // MARK: - Which pane counts

    @Test("a Figma pane and an ordinary pane on a Figma file: it moves the Figma pane")
    func figmaPaneBeatsAnOrdinaryPane() {
        let outcome = FigmaGotoPicker.pick([pane(8, bar: true), pane(10, bar: false)])
        #expect(moved(outcome) == "surface:10")
    }

    @Test("a single Figma pane is moved")
    func singleFigmaPaneMoves() {
        #expect(moved(FigmaGotoPicker.pick([pane(8, bar: false)])) == "surface:8")
    }

    @Test("an ordinary pane alone is not moved, and the refusal names it")
    func ordinaryPaneAloneIsNamed() {
        let outcome = FigmaGotoPicker.pick([pane(8, bar: true)])
        #expect(refusal(outcome) == "no Figma pane is open — browser panes showing a Figma file: surface:8. Pass --surface <handle> to move one, or run `cmux figma open <url>` first")
    }

    @Test("a reply with no address-bar key counts as an ordinary pane")
    func missingKeyIsOrdinary() {
        let outcome = FigmaGotoPicker.pick([pane(8, bar: nil)])
        #expect(moved(outcome) == nil)
        #expect(refusal(outcome)?.contains("browser panes showing a Figma file: surface:8") == true)
    }

    @Test("two ordinary panes and no Figma pane: the refusal lists both, separated by a comma and a space")
    func twoOrdinaryPanesAreBothNamed() {
        let outcome = FigmaGotoPicker.pick([pane(8, bar: true), pane(10, bar: nil)])
        #expect(refusal(outcome)?.contains("browser panes showing a Figma file: surface:8, surface:10. Pass --surface") == true)
    }

    @Test("two Figma panes and one ordinary pane: the refusal lists the two and not the third")
    func tooManyListsOnlyThePanesThatCount() {
        let outcome = FigmaGotoPicker.pick([pane(8, bar: false), pane(9, bar: true), pane(10, bar: false)])
        #expect(refusal(outcome) == "more than one Figma pane is open (surface:8, surface:10) — pass --surface <handle>")
    }

    @Test("no pane shows a Figma file: the refusal names `figma open` and no pane")
    func nothingOpen() {
        for panes in [[], [pane(8, bar: false, figma: false), pane(9, bar: true, figma: false)]] {
            #expect(refusal(FigmaGotoPicker.pick(panes)) == "no Figma pane is open — run `cmux figma open <url>` first")
        }
    }

    @Test("a pane with no address bar that shows another page does not count")
    func chromeFreePaneOnAnotherPageDoesNotCount() {
        let outcome = FigmaGotoPicker.pick([pane(8, bar: false, figma: false), pane(9, bar: false)])
        #expect(moved(outcome) == "surface:9")
    }

    // MARK: - What follows the verb

    private func parsed(_ verb: String, _ args: [String]) -> FigmaArguments.Parsed? {
        try? FigmaArguments.parse(verb: verb, args: args)
    }

    private func refusal(_ verb: String, _ args: [String]) -> String? {
        do {
            _ = try FigmaArguments.parse(verb: verb, args: args)
            return nil
        } catch let failure as FigmaArguments.Failure {
            return failure.message
        } catch {
            return "\(error)"
        }
    }

    @Test("open takes one link and --workspace, and goto one frame id and --surface, in either order")
    func argumentsHappyPath() {
        #expect(parsed("open", ["LINK"]) == .init(word: "LINK", option: nil))
        #expect(parsed("open", ["LINK", "--workspace", "w"]) == .init(word: "LINK", option: "w"))
        #expect(parsed("open", ["--workspace", "w", "LINK"]) == .init(word: "LINK", option: "w"))
        #expect(parsed("goto", ["12-2", "--surface", "s"]) == .init(word: "12-2", option: "s"))
        #expect(parsed("goto", []) == .init(word: nil, option: nil))
    }

    @Test("a bare -- is refused by name")
    func bareDashDashIsRefused() {
        #expect(refusal("open", ["--"]) == "cmux figma open does not support --")
        #expect(refusal("goto", ["12-2", "--"]) == "cmux figma goto does not support --")
    }

    @Test("an option with nothing after it, or only a blank, needs a value")
    func optionNeedsAValue() {
        #expect(refusal("goto", ["12-2", "--surface"]) == "--surface requires a value")
        #expect(refusal("open", ["LINK", "--workspace"]) == "--workspace requires a value")
        #expect(refusal("goto", ["12-2", "--surface", ""]) == "--surface requires a value")
        #expect(refusal("open", ["LINK", "--workspace", "  "]) == "--workspace requires a value")
    }

    @Test("the option twice, the --flag=value form and the other verb's option are refused by name")
    func otherOptionShapesAreRefused() {
        #expect(refusal("goto", ["12-2", "--surface", "a", "--surface", "b"]) == "cmux figma goto accepts --surface only once")
        #expect(refusal("goto", ["12-2", "--surface=a"]) == "cmux figma goto does not support --surface=a")
        #expect(refusal("goto", ["12-2", "--workspace", "w"]) == "cmux figma goto does not support --workspace")
        #expect(refusal("open", ["LINK", "--surface", "s"]) == "cmux figma open does not support --surface")
    }

    @Test("a second word is refused, and a single-dash word is a word")
    func wordsAreCounted() {
        #expect(refusal("goto", ["12-2", "12-3"]) == "cmux figma goto does not take an extra argument: 12-3")
        // `-12` is not an option to this parser: it is taken as the frame id, as it is today.
        #expect(parsed("goto", ["-12"]) == .init(word: "-12", option: nil))
        #expect(refusal("goto", ["-12", "12-2"]) == "cmux figma goto does not take an extra argument: 12-2")
    }

    @Test("the value after an option is whatever word follows, even one that looks like a flag")
    func optionValueIsTheNextWord() {
        #expect(parsed("goto", ["12-2", "--surface", "--json"]) == .init(word: "12-2", option: "--json"))
    }

    @Test("fit takes --surface and no word; a word, a --workspace and a repeated --surface are refused by name")
    func fitArguments() {
        #expect(parsed("fit", []) == .init(word: nil, option: nil))
        #expect(parsed("fit", ["--surface", "s"]) == .init(word: nil, option: "s"))
        #expect(refusal("fit", ["12-2"]) == "cmux figma fit does not take an extra argument: 12-2")
        #expect(refusal("fit", ["--workspace", "w"]) == "cmux figma fit does not support --workspace")
        #expect(refusal("fit", ["--surface", "a", "--surface", "b"]) == "cmux figma fit accepts --surface only once")
        #expect(refusal("fit", ["--surface"]) == "--surface requires a value")
    }

    // MARK: - The help text

    private var lines: [String] { FigmaUsage.text.components(separatedBy: "\n") }

    private func line(containing phrase: String) -> String? { lines.first { $0.contains(phrase) } }

    @Test("the help starts with the usage line and has no --theme")
    func usageLineAndNoTheme() {
        #expect(lines.first == "Usage: cmux figma <open|goto|fit|folder> [args]")
        #expect(!FigmaUsage.text.contains("--theme"))
    }

    @Test("the help shows both shapes a frame id takes")
    func showsBothFrameIdShapes() {
        #expect(FigmaUsage.text.contains("12-2"))
        #expect(FigmaUsage.text.contains("12:2"))
    }

    @Test("the help tells agents to move the view with goto and not to use cmux browser click")
    func tellsAgentsToUseGoto() {
        let line = line(containing: "cmux browser click")
        #expect(line != nil)
        #expect(line?.contains("goto") == true)
    }

    @Test("the help says the Share button's link, node-id=0-1, opens the editor")
    func saysTheShareLinkOpensTheEditor() {
        let line = line(containing: "node-id=0-1")
        #expect(line != nil)
        #expect(line?.contains("editor") == true)
    }

    @Test("the help tells the reader to put the link in quotes, because the shell reads ? and &")
    func tellsTheReaderToQuoteTheLink() {
        let line = line(containing: "quotes")
        #expect(line != nil)
        #expect(line?.contains("?") == true)
        #expect(line?.contains("&") == true)
    }

    @Test("the help says goto counts a pane with no address bar")
    func saysWhichPanesGotoCounts() {
        let line = line(containing: "no address bar")
        #expect(line != nil)
        #expect(line?.contains("goto") == true)
    }

    @Test("the help says --surface also moves a pane goto does not count")
    func saysSurfaceMovesAnyPane() {
        let line = line(containing: "does not count")
        #expect(line != nil)
        #expect(line?.contains("--surface") == true)
    }

    @Test("the help says open takes --workspace, on a line that belongs to open")
    func saysOpenTakesWorkspace() {
        let workspaceLine = lines.firstIndex { $0.contains("--workspace") }
        let gotoLine = lines.firstIndex { $0.contains("goto <node-id>") }
        #expect(workspaceLine != nil)
        #expect(gotoLine != nil)
        if let workspaceLine, let gotoLine { #expect(workspaceLine < gotoLine) }
    }

    @Test("the four phrases sit on four different lines, so one line cannot stand in for another")
    func fourPhrasesFourLines() {
        let phrases = ["cmux browser click", "node-id=0-1", "no address bar", "does not count"]
        let found = phrases.map { phrase in lines.firstIndex { $0.contains(phrase) } }
        #expect(!found.contains(nil))
        #expect(Set(found.compactMap { $0 }).count == phrases.count)
    }

    @Test("the help describes fit between goto and folder, with the two ways and the refusals")
    func helpDescribesFit() {
        let fit = lines.firstIndex { $0.hasPrefix("  fit ") }
        let goto = lines.firstIndex { $0.contains("goto <node-id>") }
        let folder = lines.firstIndex { $0.hasPrefix("  folder ") }
        #expect(fit != nil && goto != nil && folder != nil)
        if let fit, let goto, let folder { #expect(goto < fit && fit < folder) }
        for phrase in ["Center the open Figma pane", "Shift+1", "read view", "design files only", "text field"] {
            #expect(FigmaUsage.text.contains(phrase), "\(phrase)")
        }
    }

    @Test("the help describes --motion and --play for goto")
    func helpDescribesMotionAndPlay() {
        #expect(FigmaUsage.text.contains("--motion"))
        #expect(FigmaUsage.text.contains("--play"))
    }

    @Test("goto accepts --motion and --play, in any position, and --play implies --motion")
    func gotoAcceptsMotionAndPlay() {
        #expect(parsed("goto", ["12-2", "--motion"]) == .init(word: "12-2", option: nil, motion: true, play: false))
        #expect(parsed("goto", ["--motion", "12-2"]) == .init(word: "12-2", option: nil, motion: true, play: false))
        #expect(parsed("goto", ["12-2", "--play"]) == .init(word: "12-2", option: nil, motion: true, play: true))
        #expect(parsed("goto", ["--play", "12-2", "--surface", "s"]) == .init(word: "12-2", option: "s", motion: true, play: true))
        #expect(parsed("goto", ["12-2", "--motion", "--play"]) == .init(word: "12-2", option: nil, motion: true, play: true))
        #expect(refusal("open", ["LINK", "--motion"]) == "cmux figma open does not support --motion")
        #expect(refusal("open", ["LINK", "--play"]) == "cmux figma open does not support --play")
        #expect(refusal("fit", ["--motion"]) == "cmux figma fit does not support --motion")
        #expect(refusal("fit", ["--play"]) == "cmux figma fit does not support --play")
    }
}

/// What `cmux figma fit` decides, and what the fit on a fresh open shares with it. Pure: no
/// socket and no app.
@Suite("FigmaFitRules")
struct FigmaFitRulesTests {

    private static let editor = URL(string: "https://www.figma.com/design/KEY/slug")!
    private static let read = URL(string: "https://embed.figma.com/design/KEY/slug?node-id=1-2&embed-host=cmux")!
    private static let wrapper = URL(string: "file:///Users/x/Library/Application%20Support/cmux/figma-embed.html?embed=https%3A%2F%2Fembed.figma.com%2Fdesign%2FKEY%2Fslug")!
    private static let board = URL(string: "https://www.figma.com/board/KEY/slug")!
    private static let slides = URL(string: "https://www.figma.com/slides/KEY/slug")!

    private func decide(_ address: URL, document: URL? = nil, showing: Bool = true) -> FigmaFit.Decision {
        FigmaFit.decide(
            handle: "surface:8",
            paneAddress: address,
            document: document ?? FigmaPaneURL.documentURL(fromPaneURL: address) ?? address,
            isShowing: showing
        )
    }

    // MARK: - decide

    @Test("an editor pane that is showing: press, mode editor")
    func editorShowing() {
        #expect(decide(Self.editor) == .pressFit)
        #expect(decide(Self.editor).mode == .editor)
    }

    @Test("an editor pane that is not showing is refused by name, and nothing is pressed")
    func editorHidden() {
        #expect(decide(Self.editor, showing: false)
            == .refuse("surface surface:8 is not showing, so fit sent no key"))
        #expect(decide(Self.editor, showing: false).mode == nil)
    }

    @Test("a read-view pane loads again on the node its address names, showing or not")
    func readView() {
        let onBoard = FigmaPaneURL.wrapperURL(
            FigmaPaneURL.wrapperFileURL(),
            embedding: URL(string: "https://embed.figma.com/design/KEY/slug?embed-host=cmux&node-id=12-2")!
        )
        for (address, node) in [(Self.read, "1-2"), (onBoard, "12-2")] {
            #expect(decide(address, document: Self.editor, showing: true) == .reloadNode(node), "\(address)")
            #expect(decide(address, document: Self.editor, showing: false) == .reloadNode(node), "\(address)")
            #expect(decide(address, document: Self.editor).mode == .read)
        }
    }

    @Test("a read-view pane on the whole page, or with no node it can read, loads the whole page again")
    func readViewWholePage() {
        let onPage = URL(string: "https://embed.figma.com/design/KEY/slug?embed-host=cmux&node-id=0-1")!
        for address in [onPage, Self.wrapper] {
            #expect(decide(address, document: Self.editor) == .reloadNode("0-1"), "\(address)")
        }
    }

    @Test("a FigJam board or a slide deck is refused in either view and either state")
    func notADesignFile() {
        let message = "cmux figma fit works on Figma design files only: surface surface:8 shows a FigJam board or a slide deck"
        let readSlides = URL(string: "https://embed.figma.com/slides/KEY/slug?node-id=1-2")!
        for (address, document) in [(Self.board, Self.board), (Self.slides, Self.slides), (readSlides, Self.slides)] {
            for showing in [true, false] {
                #expect(decide(address, document: document, showing: showing) == .refuse(message), "\(address) showing \(showing)")
            }
        }
    }

    @Test("an older /file/ link is a design file")
    func olderFileLink() {
        #expect(decide(URL(string: "https://www.figma.com/file/KEY/slug")!) == .pressFit)
    }

    // MARK: - isShowing

    @Test("a pane shows when it is selected in its pane and its workspace is the selected one; an unknown counts as showing")
    func showing() {
        #expect(FigmaFit.isShowing(selectedInPane: true, workspaceID: "a", selectedWorkspaceID: "a"))
        #expect(!FigmaFit.isShowing(selectedInPane: false, workspaceID: "a", selectedWorkspaceID: "a"))
        #expect(!FigmaFit.isShowing(selectedInPane: true, workspaceID: "a", selectedWorkspaceID: "b"))
        #expect(FigmaFit.isShowing(selectedInPane: nil, workspaceID: "a", selectedWorkspaceID: "a"))
        #expect(FigmaFit.isShowing(selectedInPane: true, workspaceID: nil, selectedWorkspaceID: "b"))
        #expect(FigmaFit.isShowing(selectedInPane: true, workspaceID: "a", selectedWorkspaceID: nil))
    }

    // MARK: - Which opens fit

    @Test("only a design file in the editor is a fresh open that fits")
    func opensDesignInEditor() {
        #expect(FigmaFit.opensDesignInEditor(Self.editor))
        #expect(FigmaFit.opensDesignInEditor(URL(string: "https://www.figma.com/file/KEY/slug")!))
        #expect(FigmaFit.opensDesignInEditor(URL(string: "https://www.figma.com/design/new?folder_id=1&team_id=2")!))
        for no in [Self.board, Self.slides, Self.read, Self.wrapper,
                   URL(string: "https://www.figma.com/files/recent")!,
                   URL(string: "https://example.com/design/KEY/slug")!] {
            #expect(!FigmaFit.opensDesignInEditor(no), "\(no)")
        }
        #expect(!FigmaFit.opensDesignInEditor(nil))
    }

    @Test("an in-place open fits only when the address moved from a page that is no file to a design file")
    func opensDesignInPlace() {
        let recent = URL(string: "https://www.figma.com/files/recent")!
        #expect(FigmaFit.opensDesignInPlace(from: recent, to: Self.editor))
        #expect(!FigmaFit.opensDesignInPlace(from: Self.editor, to: Self.editor))
        #expect(!FigmaFit.opensDesignInPlace(from: URL(string: "https://www.figma.com/design/OTHER/x")!, to: Self.editor))
        #expect(!FigmaFit.opensDesignInPlace(from: nil, to: Self.editor))
        #expect(!FigmaFit.opensDesignInPlace(from: recent, to: Self.board))
        #expect(!FigmaFit.opensDesignInPlace(from: recent, to: recent))
    }

    // MARK: - What is read from the page

    /// Runs the focus guard against a page whose focused element is `element` (a JS object literal, or `null`).
    private func guardAnswer(_ element: String) -> String? {
        let context = JSContext()!
        context.evaluateScript("var document = { activeElement: \(element) };")
        return context.evaluateScript(FigmaFit.focusGuardScript)?.toString()
    }

    private func field(_ tag: String, sink: Bool, editable: Bool = false) -> String {
        "{ tagName: '\(tag)', isContentEditable: \(editable), classList: { contains: function (c) { return \(sink) && c === 'focus-target'; } } }"
    }

    @Test("the guard lets Figma's keyboard sink and a page with nothing focused through")
    func guardOk() {
        #expect(guardAnswer("null") == "ok")
        #expect(guardAnswer(field("BODY", sink: false)) == "ok")
        #expect(guardAnswer(field("INPUT", sink: true)) == "ok")
        #expect(guardAnswer(field("DIV", sink: false)) == "ok")
    }

    @Test("the guard stops a text field, an editable element, and the sink once it is editable")
    func guardTyping() {
        #expect(guardAnswer(field("INPUT", sink: false)) == "typing")
        #expect(guardAnswer(field("TEXTAREA", sink: false)) == "typing")
        #expect(guardAnswer(field("SELECT", sink: false)) == "typing")
        #expect(guardAnswer(field("DIV", sink: true, editable: true)) == "typing")
        #expect(guardAnswer(field("DIV", sink: false, editable: true)) == "typing")
    }

    @Test("a guard answer other than ok counts as typing, so a script that did not run stops the press")
    func guardAnswerReading() {
        #expect(!FigmaFit.isTyping("ok"))
        #expect(FigmaFit.isTyping("typing"))
        #expect(FigmaFit.isTyping(nil))
        #expect(FigmaFit.isTyping(3))
    }

    @Test("the zoom label script reads the aria-label of the zoom button, and null when it is not there")
    func zoomLabel() {
        let context = JSContext()!
        context.evaluateScript("""
        var asked = null;
        var document = { querySelector: function (selector) {
          asked = selector;
          return { getAttribute: function (name) { return name === 'aria-label' ? '15%, zoom and view options' : null; } };
        } };
        """)
        #expect(context.evaluateScript(FigmaFit.zoomLabelScript)?.toString() == "15%, zoom and view options")
        #expect(context.evaluateScript("asked")?.toString() == "[aria-label$=\"zoom and view options\"]")
        context.evaluateScript("document = { querySelector: function () { return null; } };")
        #expect(context.evaluateScript(FigmaFit.zoomLabelScript)?.isNull == true)
    }

    @Test("fit presses the ! key, the trusted shift-1")
    func fitKey() {
        #expect(FigmaFit.fitKey == "!")
    }
}
