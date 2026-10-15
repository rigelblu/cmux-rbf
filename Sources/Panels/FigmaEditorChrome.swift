import Foundation

/// Collapsing Figma's editor panels in a cmux Figma pane, on every load.
///
/// **Why this exists.** At pane width the Figma editor is almost entirely
/// panels — left rail ~48pt, Pages/Layers ~282pt, right inspector ~240pt, all
/// fixed width — so the canvas is `pane width − ~570pt`. Measured in a normal
/// cmux split that leaves roughly a 40pt strip and the design is not visible at
/// all. Collapsing them is what makes the editor-by-default surface usable, so
/// it is required rather than cosmetic.
///
/// **Why it runs on every load rather than once.** The collapsed state is
/// client-side page state, not a Figma account setting, so it dies with the
/// document. cmux's own 300s hidden-discard reloads the pane, which would
/// otherwise return you to the 40pt strip with nothing saying why.
enum FigmaEditorChrome {

    // MARK: - Whether this pane wants it

    /// Figma's own control for this, found by sweeping the DOM for it.
    ///
    /// Its action is `⇧⌘\`; Figma's separate `⌘\` hides all UI. **Neither
    /// shortcut is usable from here** — see ``minimizeUIScript``.
    static let minimizeControlSelector = #"[aria-label="Minimize UI"]"#

    /// Whether a finished navigation should collapse Figma's panels.
    ///
    /// Two conditions, and the second is the one that keeps this from being a
    /// surprise:
    /// - the pane is showing Figma's **editor** — the embed has no panels to
    ///   collapse, and its chrome is Embed Kit's, which this does not govern;
    /// - the pane is **chrome-free**, i.e. cmux opened it as a Figma pane
    ///   rather than the user browsing to Figma in an ordinary browser pane.
    ///
    /// Without the second, clicking any Figma link would silently collapse the
    /// panels of someone who just wanted to look at a file, and nothing on
    /// screen would explain it. Both conditions read state the pane already
    /// has, so this adds no persisted field.
    static func shouldMinimizeUI(paneURL: URL?, isOmnibarVisible: Bool) -> Bool {
        guard !isOmnibarVisible, let paneURL else { return false }
        return FigmaFileLink.isEditorLink(paneURL)
    }

    /// Whether an address that changed with no page load should collapse Figma's
    /// panels. Figma opens a file from its file list by changing the address in
    /// place, so the finished-load hook never runs for it (`cm-73.9`).
    ///
    /// The same two conditions as ``shouldMinimizeUI(paneURL:isOmnibarVisible:)``
    /// for the new address, plus two more:
    /// - the address before was not a link to the **same file**: a frame added to
    ///   the file already open leaves the panels as the person left them, and a
    ///   second collapse would undo an expand;
    /// - **no load is in progress**: WebKit also changes the address as a load
    ///   starts, in the page being left, and the finished load collapses on its own.
    static func shouldMinimizeUI(
        afterAddressChangeFrom before: URL?,
        to after: URL?,
        isOmnibarVisible: Bool,
        loadInProgress: Bool = false
    ) -> Bool {
        guard !loadInProgress,
              shouldMinimizeUI(paneURL: after, isOmnibarVisible: isOmnibarVisible),
              let key = fileKey(of: after) else { return false }
        return fileKey(of: before) != key
    }

    /// The file key in `/design/<key>/<name>` (or `/file/`, `/board/`, `/slides/`) on
    /// the editor's hosts, or `nil` for any other address.
    private static func fileKey(of url: URL?) -> String? {
        guard let url, FigmaFileLink.isEditorLink(url) else { return nil }
        let parts = url.path.split(separator: "/")
        return parts.count >= 2 ? String(parts[1]) : nil
    }

    // MARK: - How it is done

    /// Click Figma's own control, rather than sending its keyboard shortcut.
    ///
    /// **Measured 2026-09-08, and this is the opposite of what the design
    /// assumed.** `browser press --key "Meta+Backslash"` and
    /// `"Shift+Meta+Backslash"` both return `OK` and both leave the layout
    /// untouched, on a pane where `focus-webview` refuses with
    /// `invalid_state: WebView is hidden`. Clicking the control works from the
    /// same state: the canvas goes 450pt → 1021pt in a 1021pt viewport.
    /// Synthetic clicks reach Figma's buttons; synthetic key events do not
    /// reach its shortcut handler, which is what an unfocused WebView with no
    /// focused element predicts.
    ///
    /// Driving the button is also better than the shortcut on its own terms —
    /// it needs no focus, it does not depend on Figma's shortcut table, and it
    /// is *verifiable*, because the selector's presence reports the state.
    ///
    /// **Why it polls.** The control does not exist until Figma's app has
    /// booted, and page load is not that signal: `wait --load-state complete`
    /// returns while the editor is still blank. A press sent then goes nowhere
    /// and nothing reports it.
    static func minimizeUIScript(
        selector: String = minimizeControlSelector,
        timeoutMilliseconds: Int = 20_000,
        pollMilliseconds: Int = 250
    ) -> String {
        """
        return new Promise(function (resolve) {
          var deadline = Date.now() + \(timeoutMilliseconds);
          function tick() {
            var control = document.querySelector('\(selector)');
            if (control) {
              control.click();
              resolve("found");
              return;
            }
            if (Date.now() > deadline) {
              // Say so rather than failing silently: a control that never
              // appeared and a click that never landed look identical from
              // outside, and this pane is often not on screen.
              console.warn('[cmux] figma: no minimize control after \(timeoutMilliseconds)ms');
              resolve("timeout");
              return;
            }
            setTimeout(tick, \(pollMilliseconds));
          }
          tick();
        });
        """
    }
}
