import Foundation

/// Reply's one action (`cm-136.1`): paste the quote into the agent's own
/// prompt, in the pane the selection is in, without submitting.
enum ReplyInlinePaste {
    /// One paste ending in one newline (Q2, Tom 2026-11-05), so the cursor
    /// starts on the line under the quote. No key event: Reply never submits.
    ///
    /// **Not `TextBoxSubmit.dispatchEvents`**, which runs every submission
    /// through `trimBoundaryNewlines` and would drop the newline. The newline
    /// travels inside the paste, so it can't submit while the agent's terminal
    /// has bracketed paste on.
    static func events(for quote: String) -> [TextBoxSubmit.DispatchEvent] {
        [.pasteText(quote + "\n")]
    }

    /// - Returns: whether the events were sent. `false` and nothing sent when
    ///   `target` can't resolve `sourcePanelID`.
    @discardableResult
    static func reply(quote: String, sourcePanelID: UUID, target: ReplyInlinePasteTarget) -> Bool {
        target.send(events(for: quote), toPanel: sourcePanelID)
    }
}
