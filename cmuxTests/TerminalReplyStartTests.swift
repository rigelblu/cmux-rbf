import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `#cm-89` — whether a mouse release in a terminal starts a reply.
///
/// One case per refusal, because each refusal is a Decision in the brief and a
/// release that fires when it should not types nothing but still yanks the
/// sidebar open under the user.
@Suite
struct TerminalReplyStartTests {
    private static let pane = UUID()

    private func input(
        modifiers: NSEvent.ModifierFlags = [.command, .shift],
        isAgentPane: Bool = true,
        selectionText: String? = "quick brown fox",
        didDrag: Bool = true,
        sidebarShowingReply: Bool = false
    ) -> TerminalReplyStartInput {
        TerminalReplyStartInput(
            modifiers: modifiers,
            isAgentPane: isAgentPane,
            selectionText: selectionText,
            didDrag: didDrag,
            sidebarShowingReply: sidebarShowingReply,
            sourcePanelID: Self.pane
        )
    }

    @Test
    func oneRowInAnAgentPaneOpens() {
        #expect(TerminalReplyStart.decide(input(), seq: 7) == .open(TerminalReplyRequest(
            seq: 7, text: "quick brown fox", isMultiRow: false, sourcePanelID: Self.pane, intent: .start
        )))
    }

    /// `cm-136.7`: the `⌘⇧`-drag always asks for a search. `Add to reply` is
    /// the only route to `.add`, and it does not come through here.
    @Test
    func theDragAlwaysBuildsAStartIntent() {
        guard case .open(let request) = TerminalReplyStart.decide(input(), seq: 3) else {
            Issue.record("expected the drag to open a request")
            return
        }
        #expect(request.intent == .start)
    }

    /// Multi-row opens too — the panel says why nothing was highlighted.
    /// The text is the one the 2026-09-13 probe logged for a wrapped sentence.
    @Test
    func aWrappedSelectionOpensAsMultiRow() {
        #expect(TerminalReplyStart.decide(input(selectionText: "voluptatem\n  sequi nesciunt"), seq: 1) == .open(TerminalReplyRequest(
            seq: 1, text: "voluptatem\n  sequi nesciunt", isMultiRow: true, sourcePanelID: Self.pane, intent: .start
        )))
    }

    /// A trailing newline from dragging past the end of a line is still one row.
    @Test
    func surroundingWhitespaceIsTrimmedBeforeCountingRows() {
        #expect(TerminalReplyStart.decide(input(selectionText: "  quick brown\n"), seq: 1) == .open(TerminalReplyRequest(
            seq: 1, text: "quick brown", isMultiRow: false, sourcePanelID: Self.pane, intent: .start
        )))
    }

    @Test
    func onlyExactlyCommandShiftCounts() {
        #expect(TerminalReplyStart.decide(input(modifiers: [.command]), seq: 1) == .ignore(.wrongModifiers))
        #expect(TerminalReplyStart.decide(input(modifiers: [.shift]), seq: 1) == .ignore(.wrongModifiers))
        #expect(TerminalReplyStart.decide(input(modifiers: [.command, .shift, .option]), seq: 1) == .ignore(.wrongModifiers))
        #expect(TerminalReplyStart.decide(input(modifiers: []), seq: 1) == .ignore(.wrongModifiers))
    }

    /// Caps Lock on, or a laptop reporting `.function`, must not break the gesture.
    @Test
    func lockAndFunctionFlagsAreIgnored() {
        #expect(TerminalReplyStart.decide(input(modifiers: [.command, .shift, .capsLock, .function]), seq: 1) != .ignore(.wrongModifiers))
    }

    /// `⇧`-click extends a selection already on screen; without movement it must not fire.
    @Test
    func aClickWithoutMovementIsIgnored() {
        #expect(TerminalReplyStart.decide(input(didDrag: false), seq: 1) == .ignore(.noDrag))
    }

    @Test
    func aPaneWithoutALiveAgentIsIgnored() {
        #expect(TerminalReplyStart.decide(input(isAgentPane: false), seq: 1) == .ignore(.notAgentPane))
    }

    @Test
    func noSelectionIsIgnored() {
        #expect(TerminalReplyStart.decide(input(selectionText: nil), seq: 1) == .ignore(.noSelection))
    }

    @Test
    func aWhitespaceOnlySelectionIsIgnored() {
        #expect(TerminalReplyStart.decide(input(selectionText: " \n\t "), seq: 1) == .ignore(.blankSelection))
    }

    @Test
    func aShowingReplyPanelIsNeverDisturbed() {
        #expect(TerminalReplyStart.decide(input(sidebarShowingReply: true), seq: 1) == .ignore(.panelShowing))
    }
}

/// `#cm-89` — what the Reply view does with a request. The order is the design:
/// a reader held on an older reply is never moved, and a reply in progress is
/// never added to, whatever else is true.
@Suite
struct TerminalReplyConsumeTests {
    private func decide(
        older: Bool = false,
        highlights: Bool = false,
        writing: Bool = false,
        multiRow: Bool = false,
        intent: TerminalReplyIntent = .start
    ) -> TerminalReplyConsumeDecision {
        TerminalReplyConsume.decide(
            viewingOlderReply: older,
            newestHasHighlights: highlights,
            newestTurnWriting: writing,
            isMultiRow: multiRow,
            text: "quick brown",
            intent: intent
        )
    }

    @Test
    func anOlderReplyIsSilentWhateverElseIsTrue() {
        #expect(decide(older: true) == .silent)
        #expect(decide(older: true, highlights: false, writing: true, multiRow: true) == .silent)
    }

    @Test
    func highlightsOnTheNewestAreSilentWhateverElseIsTrue() {
        #expect(decide(highlights: true) == .silent)
        #expect(decide(highlights: true, writing: true, multiRow: true) == .silent)
    }

    @Test
    func writingIsSaidBeforeMultiRow() {
        #expect(decide(writing: true, multiRow: true) == .notice(.writing))
    }

    @Test
    func multiRowIsSaid() {
        #expect(decide(multiRow: true) == .notice(.multiRow))
    }

    @Test
    func otherwiseTheTextIsSearched() {
        #expect(decide() == .find("quick brown"))
    }

    // MARK: `.add` (cm-136.7)
    //
    // `Add to reply` adds to the reply the panel already shows, so the rules
    // that protect a reply someone is working on (highlights, multi-row) do
    // not apply to it. Older replies and replies being written still do.

    @Test
    func addWithHighlightsFinds() {
        #expect(decide(highlights: true, intent: .add) == .find("quick brown"))
    }

    @Test
    func addMultiRowFinds() {
        #expect(decide(multiRow: true, intent: .add) == .find("quick brown"))
    }

    @Test
    func addOnOlderReplyIsSilent() {
        #expect(decide(older: true, intent: .add) == .silent)
        #expect(decide(older: true, highlights: true, writing: true, multiRow: true, intent: .add) == .silent)
    }

    @Test
    func addWhileWritingNotices() {
        #expect(decide(writing: true, intent: .add) == .notice(.writing))
    }

    @Test
    func addPlainFinds() {
        #expect(decide(intent: .add) == .find("quick brown"))
    }
}

/// `cm-136.7` — the open path takes the keyboard off the pane, so keys typed
/// before the note field has the caret never reach the agent. The `⌘⇧`-drag
/// passes the terminal view; `Add to reply` passes the scroll view that holds it.
@MainActor
@Suite
struct TerminalReplyOpenerKeyboardTests {
    private let scroll = NSView()
    private let terminal = NSView()

    init() {
        scroll.addSubview(terminal)
    }

    @Test("The keyboard on the pane's own view is taken off it")
    func keyboardOnThePaneItself() {
        #expect(TerminalReplyOpener.holdsKeyboard(terminal, pane: terminal))
    }

    @Test("The keyboard on the terminal inside the pane's scroll view is taken off it")
    func keyboardOnTheTerminalInsideTheScrollView() {
        #expect(TerminalReplyOpener.holdsKeyboard(terminal, pane: scroll))
    }

    @Test("The keyboard somewhere else is left where it is")
    func keyboardElsewhereStays() {
        #expect(!TerminalReplyOpener.holdsKeyboard(NSView(), pane: scroll))
        #expect(!TerminalReplyOpener.holdsKeyboard(nil, pane: scroll))
        #expect(!TerminalReplyOpener.holdsKeyboard(terminal, pane: nil))
    }
}
