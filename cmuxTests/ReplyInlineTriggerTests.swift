import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `cm-136.1` Scenario 3: whether a left-button release brings the Reply
/// toolbar up, in the order the release hook runs the checks.
///
/// One case per refusal, because each one is a Decision in the brief and a
/// wrong answer here is either a toolbar nobody asked for or a second result
/// for a `⌘⇧` gesture that `#cm-89` already answers.
@Suite
struct ReplyInlineTriggerTests {
    private static let pane = UUID()

    /// Counts how far `decide` read, so the order is a tested fact and not a
    /// reading of the code.
    private final class Calls {
        var hasSelection = 0
        var isAgentPane = 0
        var readSelection = 0
        var grid = 0
    }

    /// `columns 80`, `cellHeight 17`, `paddingTop 4`: Scenario 4's numbers.
    private static let grid = ReplyInlineGridGeometry(columns: 80, cellHeight: 17, paddingTop: 4)

    private func selection(
        text: String = "origin-checked open tab",
        baselineY: Double = 50.5,
        offsetStart: Int = 165,
        distanceToBottomRight: Int = 170
    ) -> ReplyInlineSelectionGeometry {
        ReplyInlineSelectionGeometry(
            text: text, topLeftX: 100, baselineY: baselineY,
            offsetStart: offsetStart, distanceToBottomRight: distanceToBottomRight
        )
    }

    private func input(
        release: NSEvent.ModifierFlags = [.shift],
        press: NSEvent.ModifierFlags = [.shift],
        didDrag: Bool = true,
        clickCount: Int = 1,
        settingEnabled: Bool = true,
        hasSelection: Bool = true,
        isAgentPane: Bool = true,
        selection: ReplyInlineSelectionGeometry?? = .some(nil),
        grid: ReplyInlineGridGeometry = ReplyInlineTriggerTests.grid,
        calls: Calls = Calls()
    ) -> ReplyInlineTriggerInput {
        let read: ReplyInlineSelectionGeometry? = switch selection {
        case .some(.some(let value)): value
        case .some(.none): self.selection()
        case .none: nil
        }
        return ReplyInlineTriggerInput(
            releaseModifiers: release,
            pressModifiers: press,
            didDrag: didDrag,
            clickCount: clickCount,
            settingEnabled: settingEnabled,
            hasSelection: { calls.hasSelection += 1; return hasSelection },
            isAgentPane: { calls.isAgentPane += 1; return isAgentPane },
            readSelection: { calls.readSelection += 1; return read },
            grid: { calls.grid += 1; return grid },
            sourcePanelID: Self.pane
        )
    }

    private func decision(_ input: ReplyInlineTriggerInput) -> ReplyInlineTriggerDecision {
        ReplyInlineTrigger.decide(input)
    }

    // MARK: show

    @Test
    func aDragInAnAgentPaneShowsThePassageWhole() {
        let raw = "⏺ origin-checked open tab\n  and more  "
        let result = decision(input(selection: .some(selection(text: raw))))
        #expect(result == .show(ReplyInlinePassage(
            rawText: raw,
            sourcePanelID: Self.pane,
            topRow: 2, bottomRow: 4,
            rowTop: 38, rowBottom: 89,
            anchorX: 100,
            // The margin, 0, was measured 2026-11-05 at one pane width (99 columns); three widths are still open.
            wrapColumns: 80,
            firstRowStartColumn: 5,
            offsetStart: 165, distanceToBottomRight: 170
        )))
    }

    @Test("Rows come from the offsets, and the baseline moves neither edge")
    func rowsComeFromOffsetsNotTheBaseline() {
        let atBaseline = decision(input(selection: .some(selection(baselineY: 50.5))))
        let elsewhere = decision(input(selection: .some(selection(baselineY: 61.0))))
        #expect(atBaseline == elsewhere)
        guard case .show(let passage) = atBaseline else { Issue.record("expected show"); return }
        #expect(passage.topRow == 2 && passage.bottomRow == 4)
        #expect(passage.rowTop == 38 && passage.rowBottom == 89)
    }

    @Test("A selection clamped to the viewport's first cell is on row 0")
    func clampedSelectionStartsOnRowZero() {
        let result = decision(input(selection: .some(selection(offsetStart: 0, distanceToBottomRight: 100))))
        guard case .show(let passage) = result else { Issue.record("expected show"); return }
        #expect(passage.topRow == 0 && passage.bottomRow == 1)
        #expect(passage.rowTop == 4 && passage.rowBottom == 4 + 2 * 17)
        #expect(passage.firstRowStartColumn == 0)
    }

    @Test("The bottom row is start plus distanceToBottomRight: 80 from 0 in 80 columns is row 1, not row 0")
    func bottomRowAtTheRowBoundary() {
        let result = decision(input(selection: .some(selection(offsetStart: 0, distanceToBottomRight: 80))))
        guard case .show(let passage) = result else { Issue.record("expected show"); return }
        #expect(passage.bottomRow == 1)
    }

    @Test("A double-click, a triple-click and a ⇧-click extend each show", arguments: [
        (2, NSEvent.ModifierFlags.shift), (3, NSEvent.ModifierFlags.shift), (1, NSEvent.ModifierFlags.shift),
    ])
    func clickGesturesShow(clickCount: Int, press: NSEvent.ModifierFlags) {
        let result = decision(input(press: press, didDrag: false, clickCount: clickCount, selection: .some(selection())))
        guard case .show = result else { Issue.record("expected show for clickCount \(clickCount)"); return }
    }

    @Test("A ⌥-drag block selection shows like a drag")
    func blockSelectionShows() {
        let result = decision(input(release: [.shift, .option], press: [.shift, .option]))
        guard case .show = result else { Issue.record("expected show"); return }
    }

    @Test("A drag shows with nothing held at press: a plain drag where the agent doesn't capture the mouse")
    func plainDragShows() {
        let result = decision(input(release: [], press: [], didDrag: true, clickCount: 1))
        guard case .show = result else { Issue.record("expected show"); return }
    }

    @Test("A double-click without ⇧ shows too: the toolbar answers any selection")
    func doubleClickWithoutShiftShows() {
        let result = decision(input(press: [], didDrag: false, clickCount: 2))
        guard case .show = result else { Issue.record("expected show"); return }
    }

    // MARK: ignore, one per reason

    @Test("⌘⇧ at release is #cm-89's, even in an agent pane with a selection")
    func commandShiftAtReleaseIsIgnored() {
        #expect(decision(input(release: [.command, .shift])) == .ignore(.commandShift))
    }

    @Test("⇧ at press, ⌘ added before letting go: #cm-89 opens the panel, the toolbar stays out")
    func commandAddedMidDragIsIgnored() {
        #expect(decision(input(release: [.command, .shift], press: [.shift])) == .ignore(.commandShift))
    }

    @Test("More modifiers on top of ⌘⇧ are still #cm-89's flags, so the toolbar stays out")
    func commandShiftWithExtrasIsIgnored() {
        #expect(decision(input(release: [.command, .shift, .option])) == .ignore(.commandShift))
    }

    @Test("⌘⇧ at press, ⌘ let go first: #cm-89 ignores, the toolbar shows")
    func commandLetGoBeforeTheButtonShows() {
        let result = decision(input(release: [.shift], press: [.command, .shift]))
        guard case .show = result else { Issue.record("expected show"); return }
    }

    @Test("For every pair of flags, at most one of #cm-89 and the toolbar acts")
    func atMostOneSideActs() {
        let all: [NSEvent.ModifierFlags] = [.command, .shift, .option, .control]
        for mask in 0..<(1 << all.count) {
            var release: NSEvent.ModifierFlags = []
            for (bit, flag) in all.enumerated() where mask & (1 << bit) != 0 { release.insert(flag) }
            let toolbar = decision(input(release: release, press: release))
            var toolbarShows = false
            if case .show = toolbar { toolbarShows = true }
            // #cm-89's hook returns on its first line unless the release flags
            // contain ⌘⇧, and its decision then accepts only exactly ⌘⇧.
            let panelActs = TerminalReplyStart.decide(
                TerminalReplyStartInput(
                    modifiers: release, isAgentPane: true, selectionText: "quick brown fox",
                    didDrag: true, sidebarShowingReply: false, sourcePanelID: Self.pane
                ),
                seq: 1
            ) != .ignore(.wrongModifiers)
            #expect(!(toolbarShows && panelActs), "flags \(release.rawValue) fired both")
        }
    }

    @Test
    func settingOffIgnores() {
        #expect(decision(input(settingEnabled: false)) == .ignore(.settingOff))
    }

    @Test("A ⌘-click on a link leaves an old selection on screen and brings nothing back", arguments: [
        NSEvent.ModifierFlags.command, [], [.option],
    ])
    func singleClickWithoutShiftIsUnchanged(press: NSEvent.ModifierFlags) {
        #expect(decision(input(release: press, press: press, didDrag: false, clickCount: 1))
            == .ignore(.selectionUnchanged))
    }

    @Test
    func aReleaseWithNoClickCountIsUnchanged() {
        #expect(decision(input(press: [], didDrag: false, clickCount: 0)) == .ignore(.selectionUnchanged))
    }

    @Test
    func noSelectionIgnores() {
        #expect(decision(input(hasSelection: false)) == .ignore(.noSelection))
        #expect(decision(input(selection: .none)) == .ignore(.noSelection))
    }

    @Test
    func aPlainShellIgnores() {
        #expect(decision(input(isAgentPane: false)) == .ignore(.notAgentPane))
    }

    @Test("None of the selection in view: both pixel fields are -1")
    func offScreenIgnores() {
        #expect(decision(input(selection: .some(selection(baselineY: -1, offsetStart: 0, distanceToBottomRight: 0))))
            == .ignore(.offScreen))
    }

    @Test
    func zeroColumnsCannotBePlaced() {
        let grid = ReplyInlineGridGeometry(columns: 0, cellHeight: 17, paddingTop: 4)
        #expect(decision(input(grid: grid)) == .ignore(.noGrid))
    }

    @Test
    func whitespaceOnlyIgnores() {
        #expect(decision(input(selection: .some(selection(text: "  \n "))))
            == .ignore(.blankSelection))
    }

    // MARK: order: the cheap checks gate the expensive ones

    @Test("⌘⇧, the setting and an unchanged selection read nothing")
    func firstThreeChecksReadNothing() {
        let a = Calls(); _ = decision(input(release: [.command, .shift], calls: a))
        let b = Calls(); _ = decision(input(settingEnabled: false, calls: b))
        let c = Calls(); _ = decision(input(press: [], didDrag: false, calls: c))
        for calls in [a, b, c] {
            #expect(calls.hasSelection + calls.isAgentPane + calls.readSelection + calls.grid == 0)
        }
    }

    @Test("No selection stops before the agent lookup")
    func noSelectionStopsBeforeTheAgentLookup() {
        let calls = Calls()
        _ = decision(input(hasSelection: false, calls: calls))
        #expect(calls.hasSelection == 1)
        #expect(calls.isAgentPane + calls.readSelection + calls.grid == 0)
    }

    @Test("Not an agent pane stops before the selection and the grid are read")
    func notAgentPaneStopsBeforeReading() {
        let calls = Calls()
        _ = decision(input(isAgentPane: false, calls: calls))
        #expect(calls.hasSelection == 1 && calls.isAgentPane == 1)
        #expect(calls.readSelection + calls.grid == 0)
    }

    @Test("A release past all five checks reads the selection and the grid once")
    func showReadsEachOnce() {
        let calls = Calls()
        _ = decision(input(selection: .some(selection()), calls: calls))
        #expect(calls.hasSelection == 1 && calls.isAgentPane == 1)
        #expect(calls.readSelection == 1 && calls.grid == 1)
    }
}
