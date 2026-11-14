import AppKit
import Foundation

/// Whether a left-button release brings the Reply toolbar up.
///
/// **Decision order, which is also the cost order:** `⌘⇧` held at release →
/// setting off → the release didn't make or change the selection → no
/// selection → not an agent pane → selection not in view → blank → show.
/// Only a release past the agent-pane check reads the selection and the grid.
enum ReplyInlineTrigger {
    /// The right margin Claude Code leaves, in columns, subtracted from the
    /// pane's columns to get `wrapColumns`. Measured 2026-11-05 at one pane
    /// width (99 columns): 0. Three widths are still open (*Known Unknowns →
    /// Checks a build can run*).
    static let agentWrapMargin = 0

    static func decide(_ input: ReplyInlineTriggerInput) -> ReplyInlineTriggerDecision {
        // `#cm-89` owns `⌘⇧`. This is the expression its hook tests on the
        // same release flags (`startReplyFromTerminalIfRequested`), so for any
        // release at most one of the two can act.
        if input.releaseModifiers.contains([.command, .shift]) { return .ignore(.commandShift) }
        guard input.settingEnabled else { return .ignore(.settingOff) }
        guard madeOrChangedSelection(input) else { return .ignore(.selectionUnchanged) }
        guard input.hasSelection() else { return .ignore(.noSelection) }
        guard input.isAgentPane() else { return .ignore(.notAgentPane) }
        guard let selection = input.readSelection() else { return .ignore(.noSelection) }
        guard selection.baselineY >= 0 else { return .ignore(.offScreen) }
        let grid = input.grid()
        guard grid.columns > 0 else { return .ignore(.noGrid) }
        guard !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .ignore(.blankSelection)
        }

        let topRow = selection.offsetStart / grid.columns
        let bottomRow = (selection.offsetStart + selection.distanceToBottomRight) / grid.columns
        return .show(ReplyInlinePassage(
            rawText: selection.text,
            sourcePanelID: input.sourcePanelID,
            topRow: topRow,
            bottomRow: bottomRow,
            rowTop: grid.paddingTop + Double(topRow) * grid.cellHeight,
            rowBottom: grid.paddingTop + Double(bottomRow + 1) * grid.cellHeight,
            anchorX: selection.topLeftX,
            wrapColumns: grid.columns - agentWrapMargin,
            firstRowStartColumn: selection.offsetStart % grid.columns,
            offsetStart: selection.offsetStart,
            distanceToBottomRight: selection.distanceToBottomRight
        ))
    }

    /// "This release made or changed the selection": the input `#cm-89` needed
    /// as `didDrag`. A drag (including `⌥` block selection), a double- or
    /// triple-click, or a `⇧`-click that extends. Anything else leaves the
    /// selection as it was, so a `⌘`-click on a link with an old selection on
    /// screen must not bring the old passage back.
    private static func madeOrChangedSelection(_ input: ReplyInlineTriggerInput) -> Bool {
        input.didDrag
            || input.clickCount >= 2
            || (input.clickCount == 1 && input.pressModifiers.contains(.shift))
    }
}
