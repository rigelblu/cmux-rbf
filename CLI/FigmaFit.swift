import Foundation

/// The rules `cmux figma fit` and the fit on a fresh open share, as pure functions
/// of what is known about a pane, so a test holds them with no socket and no app.
///
/// **Compiled into the CLI, the app and the tests**, like ``FigmaFileLink``: the
/// command refuses a text field in the page with the same check the app's press
/// on a fresh open makes, and two copies of that script would drift.
///
/// **Why `fit` has two ways.** In Figma's editor, `⇧1` (the trusted key
/// `browser.press` sends for `!`) zooms to fit with no reload. The read view has
/// no zoom to fit, from anyone, so the CLI sends `figma.goto` with `purpose: fit`
/// for the node its address already names, the same board or the whole page (`0-1`),
/// and the app re-fits in place: Figma's own frame redraws, and cmux's page is not loaded again.
/// With `--node`, the preview moves inside Figma's frame when that node differs; the editor ignores it (Tom, 2026-11-01).
enum FigmaFit {

    /// Check the complete, untrimmed input before it reaches a URL or script. Both separators name the same node.
    static func normalizedNode(_ node: String) -> String? {
        guard node.range(of: "\\A[0-9]+[:-][0-9]+\\z", options: .regularExpression) != nil else { return nil }
        return node.replacingOccurrences(of: ":", with: "-")
    }

    /// Which way `fit` went, as `--json` carries it.
    enum Mode: String, Equatable {
        case editor
        case read
    }

    /// What `fit` does for a pane.
    enum Decision: Equatable {
        /// Press `⇧1` in the editor.
        case pressFit
        /// Send `figma.goto` with `purpose: fit` for this node, the one the pane's address names. The app re-fits the preview in place.
        case reloadNode(String)
        /// Do nothing, and say why.
        case refuse(String)

        var mode: Mode? {
            switch self {
            case .pressFit: return .editor
            case .reloadNode: return .read
            case .refuse: return nil
            }
        }
    }

    /// The way to fit a pane, or why not.
    ///
    /// - Parameters:
    ///   - handle: the pane's short name, `surface:8`, for the refusals.
    ///   - paneAddress: what the pane shows, as `browser.url.get` reports it. The
    ///     editor is a page on Figma's own hosts; anything else a Figma pane
    ///     shows is cmux's read view.
    ///   - document: the Figma file that address names.
    ///   - isShowing: whether the pane is on screen: selected in its pane, in the
    ///     selected workspace. A key pressed into a pane that is not showing
    ///     lands, and frames the size the hidden pane has (measured 2026-10-20).
    static func decide(handle: String, paneAddress: URL, document: URL, isShowing: Bool) -> Decision {
        // `⇧1` was measured in a design file only, and a deck or a FigJam board has
        // no zoom to fit of the same kind, so neither is pressed or reloaded.
        guard isDesignFile(document) else {
            return .refuse(
                "cmux figma fit works on Figma design files only: surface \(handle) shows a FigJam board or a slide deck"
            )
        }
        guard FigmaFileLink.isEditorLink(paneAddress) else {
            return .reloadNode(FigmaPaneURL.node(fromPaneURL: paneAddress) ?? "0-1")
        }
        guard isShowing else {
            return .refuse("surface \(handle) is not showing, so fit sent no key")
        }
        return .pressFit
    }

    /// Whether a pane is on screen, from the two things the socket reports: whether it is the
    /// selected tab of its pane, and whether its workspace is the selected one in its window.
    /// A value that is missing says nothing, so it counts as showing: a refusal that is wrong
    /// blocks the person, a press that is wrong only frames the wrong size.
    static func isShowing(selectedInPane: Bool?, workspaceID: String?, selectedWorkspaceID: String?) -> Bool {
        if selectedInPane == false { return false }
        if let workspaceID, let selectedWorkspaceID, workspaceID != selectedWorkspaceID { return false }
        return true
    }

    /// The refusal when the read view shows Figma's Log in page, an error or anything else that is not a board
    /// (`cm-73.44`): the app answers `invalid_state` with `data.reason: notboard`, and the CLI says it in English.
    static func notBoardRefusal(handle: String) -> String {
        "the Figma pane shows Figma's Log in page or an error, not a board (surface \(handle)), so fit moved nothing"
    }

    /// The `data.reason` the app puts in that `invalid_state`.
    static let notBoardReason = "notboard"

    /// The refusal when a text field in the page has focus.
    static func typingRefusal(handle: String) -> String {
        "a text field in the Figma pane has focus (surface \(handle)), so fit sent no key"
    }

    /// Whether a Figma file link is a design file: `/design/` today, `/file/` on older links.
    static func isDesignFile(_ link: URL) -> Bool {
        let path = link.path
        return path.hasPrefix("/design/") || path.hasPrefix("/file/")
    }

    /// Whether a pane address is a design file in Figma's editor, which is where a
    /// fit on a fresh open applies.
    static func opensDesignInEditor(_ address: URL?) -> Bool {
        guard let address, FigmaFileLink.isEditorLink(address) else { return false }
        return isDesignFile(address)
    }

    /// Whether an address that changed in place is a design file opened from a page that is
    /// no file (Figma's recent files, `cm-73.9`). The same file changing its address does not count, and neither does
    /// a pane with no address before: that is a page coming back, not a file being opened.
    static func opensDesignInPlace(from before: URL?, to after: URL?) -> Bool {
        guard opensDesignInEditor(after), let before else { return false }
        return !FigmaFileLink.isEditorLink(before)
    }

    // MARK: - What is read from the page

    /// `"typing"` when the focused element would take a typed `!`, else `"ok"`.
    ///
    /// **Measured 2026-10-20:** a trusted `!` types into Figma's text editing. Before
    /// any interaction `document.activeElement` is `BODY`; in the canvas it is
    /// Figma's keyboard sink, an `INPUT` with class `focus-target`, which is not
    /// typing; in text edit it becomes a `DIV.focus-target` that is editable. So
    /// the page is typing when the focused element is editable, or is a field that
    /// is not that sink.
    static let focusGuardScript = """
    (function () {
      var element = document.activeElement;
      if (!element) { return "ok"; }
      if (element.isContentEditable) { return "typing"; }
      var tag = element.tagName;
      if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") {
        var sink = element.classList && element.classList.contains("focus-target");
        return sink ? "ok" : "typing";
      }
      return "ok";
    })()
    """

    /// Whether the guard's answer says a text field has focus. Anything but `"ok"`
    /// counts, so a script that did not run as written stops the press.
    static func isTyping(_ answer: Any?) -> Bool {
        (answer as? String) != "ok"
    }

    /// Figma's zoom button carries its value in its label, `"100%, zoom and view options"`.
    /// A fit that lands changes it; that is how the press on a fresh open knows it worked.
    static let zoomLabelScript = """
    (function () {
      var button = document.querySelector('[aria-label$="zoom and view options"]');
      return button ? button.getAttribute("aria-label") : null;
    })()
    """

    /// The key `browser.press` takes for `⇧1`: `!` is the trusted path (`Digit1` with Shift
    /// carried natively), where `"Shift+1"` is not a key the parser names and goes out as
    /// an untrusted page event that answers `OK` and does nothing.
    static let fitKey = "!"
}
