import AppKit
import Foundation

/// What the terminal knows when a left button comes up. Gathered by the
/// release hook, judged by ``ReplyInlineTrigger``.
///
/// **The four closures are the cost order.** `decide` calls them only as far
/// as it needs to, cheapest first, so a release that is not a selection never
/// reads a selection (`CLAUDE.md`: typing latency). The caller passes
/// closures over the live surface; a test passes counters.
struct ReplyInlineTriggerInput {
    /// `event.modifierFlags` at mouse-up: the flags `#cm-89`'s hook reads.
    let releaseModifiers: NSEvent.ModifierFlags
    /// The flags held at mouse-down; `[]` if the gesture didn't complete.
    let pressModifiers: NSEvent.ModifierFlags
    /// The pointer moved between press and release (`pendingLeftMouseDidDrag`).
    let didDrag: Bool
    /// The press's `clickCount`.
    let clickCount: Int
    /// The cached setting. `cm-136.1` has none, so the caller passes `true`.
    let settingEnabled: Bool
    /// `ghostty_surface_has_selection`.
    let hasSelection: () -> Bool
    /// `registry.liveSession(surfaceID:) != nil`.
    let isAgentPane: () -> Bool
    /// `ghostty_surface_read_selection`; `nil` when it reads nothing.
    let readSelection: () -> ReplyInlineSelectionGeometry?
    /// `ghostty_surface_grid_metrics`.
    let grid: () -> ReplyInlineGridGeometry
    /// `TerminalPanel.id`, which is its surface's id.
    let sourcePanelID: UUID
}
