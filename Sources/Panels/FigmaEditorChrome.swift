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
        guard let host = paneURL.host?.lowercased() else { return false }
        guard host == "figma.com" || host == "www.figma.com" else { return false }
        return ["/design/", "/file/", "/board/", "/slides/"]
            .contains { paneURL.path.hasPrefix($0) }
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
        (function () {
          var deadline = Date.now() + \(timeoutMilliseconds);
          function tick() {
            var control = document.querySelector('\(selector)');
            if (control) { control.click(); return; }
            if (Date.now() > deadline) {
              // Say so rather than failing silently: a control that never
              // appeared and a click that never landed look identical from
              // outside, and this pane is often not on screen.
              console.warn('[cmux] figma: no minimize control after \(timeoutMilliseconds)ms');
              return;
            }
            setTimeout(tick, \(pollMilliseconds));
          }
          tick();
        })();
        """
    }
}
