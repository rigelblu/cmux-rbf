import Foundation
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

    // MARK: - The help text

    private var lines: [String] { FigmaUsage.text.components(separatedBy: "\n") }

    private func line(containing phrase: String) -> String? { lines.first { $0.contains(phrase) } }

    @Test("the help starts with the usage line and has no --theme")
    func usageLineAndNoTheme() {
        #expect(lines.first == "Usage: cmux figma <open|goto> [args]")
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
}
