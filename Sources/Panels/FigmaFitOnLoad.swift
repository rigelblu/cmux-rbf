import CmuxBrowser
import Foundation
import WebKit

/// The fit on a fresh Figma open (`cm-73.22`): the one-shot mark that says a pane was just
/// opened, and the press that retries until Figma's zoom changes.
///
/// **Why a mark, and not "every editor load".** cmux clicks Figma's "Minimize UI" after
/// every editor load (``FigmaEditorChrome``), so that moment also follows a restart
/// restore, a reload and the reload after memory pressure. Tom's rule (2026-10-20,
/// Q1): fit a design that was opened, never one that came back, so it keeps his view.
/// Only the entrances that open a file set the mark, and it lives in memory, so a
/// restart restore has none.
struct FigmaFitMark: Equatable {

    private(set) var isPending = false

    /// An entrance opened `address`: pending when it is a design file in Figma's editor.
    /// FigJam boards, slide decks and the read view's page are not.
    mutating func opened(_ address: URL?) {
        isPending = FigmaFit.opensDesignInEditor(address)
    }

    /// Figma's recent files opened a file in place (`cm-73.9`): pending when the address
    /// moved from a page that is no file to a design file.
    mutating func openedInPlace(from before: URL?, to after: URL?) {
        if FigmaFit.opensDesignInPlace(from: before, to: after) { isPending = true }
    }

    /// The "Minimize UI" script answered. The mark is spent either way, and the press
    /// is owed only when the control was `found`: on `timeout` Figma never booted.
    mutating func minimizeScriptAnswered(found: Bool) -> Bool {
        defer { isPending = false }
        return isPending && found
    }

    /// A finished navigation that does not start the script (not the editor, or an
    /// ordinary browser pane): a later reload must not fit.
    mutating func navigationFinishedWithoutMinimize() {
        isPending = false
    }
}

/// The press on a fresh open, as a loop over closures so a test fakes the page.
///
/// **Measured 2026-10-20:** a `⇧1` pressed the moment "Minimize UI" is found lands
/// before Figma can fit (the view stays at 100% with no board); the same press
/// seconds later fits. So the press is repeated until Figma's zoom label changes, a
/// few times over a few seconds. A fit is idempotent, so a repeat is harmless.
@MainActor
enum FigmaFitOnLoad {

    static let maxTries = 8

    /// Why the loop ended.
    enum Stop: Equatable {
        /// The zoom label changed: the fit landed.
        case changed
        /// `maxTries` presses, and the label never changed.
        case capped
        /// The pane was not showing before a press: a hidden press frames the wrong size.
        case notShowing
        /// A text field had focus before a press: a `!` would type into the file.
        case typing
    }

    struct Outcome: Equatable {
        let stop: Stop
        let tries: Int
        var changed: Bool { stop == .changed }
    }

    /// Whether a web view is on screen: in a window, not hidden, and not zero-sized.
    static func isShowing(hasWindow: Bool, isHidden: Bool, size: CGSize) -> Bool {
        hasWindow && !isHidden && size.width > 0 && size.height > 0
    }

    /// Press until the label changes or the cap passes.
    ///
    /// The label read before the first press is the baseline. Each read after a press is
    /// compared with the last label seen; a read of `nil` (the button is not there yet)
    /// is never a change, and does not replace the baseline.
    static func run(
        maxTries: Int = FigmaFitOnLoad.maxTries,
        isShowing: () -> Bool,
        isTyping: () async -> Bool,
        zoomLabel: () async -> String?,
        press: (_ attempt: Int) -> Void,
        pause: () async -> Void
    ) async -> Outcome {
        var baseline = await zoomLabel()
        var tries = 0
        while tries < maxTries {
            if await isTyping() { return Outcome(stop: .typing, tries: tries) }
            // After the focus check, right before the press: the pane can be hidden while that script runs.
            guard isShowing() else { return Outcome(stop: .notShowing, tries: tries) }
            tries += 1
            press(tries)
            await pause()
            let label = await zoomLabel()
            if let label {
                if let baseline, label != baseline { return Outcome(stop: .changed, tries: tries) }
                baseline = label
            }
        }
        return Outcome(stop: .capped, tries: tries)
    }
}

extension BrowserPanel {

    /// An entrance opened a file in this pane: set the one-shot mark if it is a design file
    /// in Figma's editor. Called where a pane is made for a Figma request with no address bar
    /// (`BrowserSplitContainer`, which covers `cmux figma open` and a clicked link that opens a
    /// new pane) and where the Figma button's menu opens a file (`Workspace.newFigmaSurface`).
    func markFigmaFitOnOpen(for address: URL?) {
        figmaFitMark.opened(address)
    }

    /// Press `⇧1` until Figma fits, after "Minimize UI" answered `found` on a fresh open.
    ///
    /// **Runs in the app, not through the socket:** the socket's trusted key path refuses the main
    /// thread (`invalid_dispatch`), and the script's answer arrives on it. See ``FigmaFitOnLoad``
    /// for why it repeats, and for when it stops.
    func fitFigmaDesignAfterOpen(in webView: WKWebView) {
#if DEBUG
        let surface = id.uuidString
#endif
        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else { return }
            // Explicitly on the main actor: a local async function does not inherit it, and `evaluateJavaScript` must run there.
            @MainActor func evaluate(_ script: String) async -> String? {
                await withCheckedContinuation { continuation in
                    webView.evaluateJavaScript(script) { value, _ in
                        continuation.resume(returning: value as? String)
                    }
                }
            }
            let outcome = await FigmaFitOnLoad.run(
                isShowing: { [weak self, weak webView] in
                    guard let self, let webView, self.webView === webView else { return false }
                    return FigmaFitOnLoad.isShowing(
                        hasWindow: webView.window != nil,
                        isHidden: webView.isHiddenOrHasHiddenAncestor,
                        size: webView.bounds.size
                    )
                },
                isTyping: { FigmaFit.isTyping(await evaluate(FigmaFit.focusGuardScript)) },
                zoomLabel: { await evaluate(FigmaFit.zoomLabelScript) },
                press: { attempt in
                    guard let event = BrowserKeyboardEvent(rawKey: FigmaFit.fitKey) else { return }
                    webView.replayBrowserKeyboardEvent(event, action: .press)
#if DEBUG
                    cmuxDebugLog("figma.fit.onLoad press surface=\(surface) try=\(attempt)")
#endif
                },
                pause: { try? await Task.sleep(nanoseconds: 600_000_000) }
            )
#if DEBUG
            cmuxDebugLog(
                "figma.fit.onLoad done surface=\(surface) changed=\(outcome.changed) tries=\(outcome.tries)"
            )
#endif
        }
    }
}
