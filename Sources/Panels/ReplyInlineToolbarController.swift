import AppKit
import Combine
import CmuxAgentChat
import Foundation

/// One pane's Reply toolbar: shows it over a passage, keeps it only while it
/// is still true, and turns a click into a paste.
///
/// **Two states, `hidden | shown(passage)`**, kept as one optional so "shown
/// without a passage" cannot be represented. Everything that costs anything
/// per event (the window monitor, the sidebar observer, the selection
/// compare) exists only while a toolbar shows, so a pane without one pays
/// nothing on the keystroke path.
@MainActor
final class ReplyInlineToolbarController {
    struct Shown {
        let passage: ReplyInlinePassage
        let view: ReplyInlineToolbarView
        let sidebarShowingReplyAtShow: Bool
        let currentSelection: () -> ReplyInlineSelectionGeometry?
    }

    var environment: ReplyInlineEnvironment
    private(set) var shown: Shown?

    private weak var host: NSView?
    private var monitor: Any?
    private var sidebarObservation: AnyCancellable?
    private var selectionTimer: Timer?

    init(host: NSView, environment: ReplyInlineEnvironment? = nil) {
        self.host = host
        self.environment = environment ?? .production
    }

    /// Whether the window monitor, the sidebar observer and the selection
    /// compare are installed: all three or none.
    var isWatching: Bool { monitor != nil && sidebarObservation != nil && selectionTimer != nil }

    /// The selection compare's timer, so a test can hold it and check it is
    /// invalid once the toolbar is gone (a live timer would outlive the toolbar).
    var selectionTimerForTesting: Timer? { selectionTimer }

    // MARK: Show

    /// Mounts the toolbar over `passage` inside `contentFrame` (the pane's
    /// terminal area, in the host's coordinates).
    ///
    /// - Returns: whether a toolbar is showing. `false` when the pane is
    ///   narrower than the toolbar (Q3): nothing mounts and the selection
    ///   behaves as it does today.
    @discardableResult
    func show(
        _ passage: ReplyInlinePassage,
        contentFrame: CGRect,
        in window: NSWindow,
        currentSelection: @escaping () -> ReplyInlineSelectionGeometry?
    ) -> Bool {
        guard let host else { return false }
        if shown != nil { hide(reason: .newSelection) }

        let view = ReplyInlineToolbarView(
            title: String(localized: "reply.inline.reply", defaultValue: "Reply"),
            accessibilityLabel: String(
                localized: "reply.inline.reply.accessibility",
                defaultValue: "Reply to the selected text"
            )
        )
        guard let placement = ReplyInlinePlacement.frame(
            toolbar: view.frame.size,
            rowTop: passage.rowTop,
            rowBottom: passage.rowBottom,
            anchorX: passage.anchorX,
            bounds: contentFrame.size
        ) else { return false }

        // Placement is top-left origin from the pane's top; the host is not flipped.
        view.frame = CGRect(
            x: contentFrame.minX + placement.frame.minX,
            y: contentFrame.maxY - placement.frame.minY - placement.frame.height,
            width: placement.frame.width,
            height: placement.frame.height
        )
        view.onReply = { [weak self] in self?.replyClicked() }
        view.onDetach = { [weak self] in self?.paneLeftWindow() }

        let sidebarAtShow = environment.sidebarShowingReply(window)
        shown = Shown(
            passage: passage,
            view: view,
            sidebarShowingReplyAtShow: sidebarAtShow,
            currentSelection: currentSelection
        )
        // Above the terminal, below the find bar (the find field must win a click).
        if let findBar = host.subviews.first(where: { $0 is TerminalSearchOverlayHostingView }) {
            host.addSubview(view, positioned: .below, relativeTo: findBar)
        } else {
            host.addSubview(view)
        }
        startWatching(in: window)
        #if DEBUG
        environment.log(
            "shown surface=\(passage.sourcePanelID.uuidString.prefix(5)) chars=\(passage.rawText.count) " +
            "rows=\(passage.bottomRow - passage.topRow + 1) placement=\(placement.edge.rawValue)"
        )
        #endif
        return true
    }

    // MARK: Hide

    func hide(reason: ReplyInlineDismissReason) {
        guard let current = shown else { return }
        shown = nil
        stopWatching()
        current.view.onReply = nil
        current.view.onDetach = nil
        current.view.removeFromSuperview()
        #if DEBUG
        environment.log("dismissed reason=\(reason.rawValue)")
        #endif
    }

    /// Feeds an event through the dismissal decision (Q4, R1, R2).
    func handle(_ event: ReplyInlineEvent) {
        guard let shown else { return }
        guard let reason = ReplyInlineDismissal.reason(
            for: event,
            passage: shown.passage,
            sidebarShowingReplyAtShow: shown.sidebarShowingReplyAtShow
        ) else { return }
        hide(reason: reason)
    }

    /// The selection compare: runs on a short timer, only while shown.
    func checkSelection() {
        guard let shown else { return }
        handle(.selectionChecked(shown.currentSelection()))
    }

    // MARK: Reply

    /// Cleans and frames the passage, pastes it into its own pane, and goes.
    /// The text is the passage as taken at release (Q1), whatever the screen
    /// shows now. Never submits, never writes the clipboard (Q8).
    func replyClicked() {
        guard let shown else { return }
        let passage = shown.passage
        // The agent may have exited since the toolbar came up with no key
        // pressed (a key would have dismissed it): pasting now would put the
        // quote into a shell.
        guard environment.isAgentPane(passage.sourcePanelID) else {
            hide(reason: .agentGone)
            return
        }
        let cleaned = ReplyPassageQuote.cleanTerminalSelection(
            passage.rawText,
            wrapColumns: passage.wrapColumns,
            firstRowStartColumn: passage.firstRowStartColumn
        )
        // A selection that was only a marker glyph cleans to nothing: there is
        // no passage to quote, so paste nothing.
        guard !cleaned.isEmpty else {
            hide(reason: .reply)
            return
        }
        let quote = ReplyPassageQuote.quote(cleaned)
        hide(reason: .reply)
        #if DEBUG
        let paneResolved = ReplyInlinePaste.reply(
            quote: quote,
            sourcePanelID: passage.sourcePanelID,
            target: environment.pasteTarget
        )
        environment.log(
            "reply surface=\(passage.sourcePanelID.uuidString.prefix(5)) source=terminal " +
            "chars=\(cleaned.count) fence=\(quote.hasPrefix("`") ? 1 : 0) paneResolved=\(paneResolved ? 1 : 0)"
        )
        #else
        ReplyInlinePaste.reply(
            quote: quote,
            sourcePanelID: passage.sourcePanelID,
            target: environment.pasteTarget
        )
        #endif
    }

    // MARK: Watching (only while shown)

    private func startWatching(in window: NSWindow) {
        monitor = environment.installMonitor { [weak self] event in
            self?.observe(event, in: window)
            return event
        }
        sidebarObservation = environment.observeSidebar(window) { [weak self] in
            guard let self else { return }
            self.handle(.sidebarChanged(showingReply: self.environment.sidebarShowingReply(window)))
        } ?? AnyCancellable {}
        let timer = Timer(timeInterval: environment.selectionPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSelection() }
        }
        RunLoop.main.add(timer, forMode: .common)
        selectionTimer = timer
    }

    private func stopWatching() {
        if let monitor { environment.removeMonitor(monitor) }
        monitor = nil
        sidebarObservation?.cancel()
        sidebarObservation = nil
        selectionTimer?.invalidate()
        selectionTimer = nil
    }

    /// The local monitor's body: ignore other windows' events, hide on a
    /// click that isn't on the toolbar or on any key, and never consume.
    private func observe(_ event: NSEvent, in window: NSWindow) {
        guard let shown, event.window === window else { return }
        if event.type == .keyDown {
            handle(.keyDown)
        } else {
            let point = shown.view.convert(event.locationInWindow, from: nil)
            handle(.mouseDown(onToolbar: shown.view.bounds.contains(point)))
        }
    }

    private func paneLeftWindow() {
        handle(.paneClosed)
    }
}
