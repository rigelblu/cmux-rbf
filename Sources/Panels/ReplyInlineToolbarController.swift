import AppKit
import Combine
import CmuxAgentChat
import Foundation

/// One pane's Reply toolbar: shows it over a passage, keeps it only while it
/// is still true, and turns a click into a paste.
///
/// **Two states, `hidden | shown(passage)`**, kept as one optional so "shown
/// without a passage" cannot be represented. Everything that costs anything
/// per event (the window monitor, the destination observer, the selection
/// compare) exists only while a toolbar shows, so a pane without one pays
/// nothing on the keystroke path.
@MainActor
final class ReplyInlineToolbarController {
    struct Shown {
        let passage: ReplyInlinePassage
        let view: ReplyInlineToolbarView
        /// The window the toolbar shows in: the destination and the reply are read there.
        let window: NSWindow
        /// Where the button sent the passage when the toolbar showed (`cm-136.7`).
        /// The label was read for it, and a change to it takes the toolbar away.
        let destinationAtShow: ReplyInlineDestination
        let currentSelection: () -> ReplyInlineSelectionGeometry?
    }

    var environment: ReplyInlineEnvironment
    private(set) var shown: Shown?

    private weak var host: NSView?
    private var monitor: Any?
    private var destinationObservation: AnyCancellable?
    private var settingObservation: AnyCancellable?
    private var selectionTimer: Timer?

    init(host: NSView, environment: ReplyInlineEnvironment? = nil) {
        self.host = host
        self.environment = environment ?? .production
    }

    /// Whether the window monitor, the destination observer, the setting observer and
    /// the selection compare are installed: all four or none.
    var isWatching: Bool {
        monitor != nil && destinationObservation != nil && settingObservation != nil && selectionTimer != nil
    }

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

        let destinationAtShow = environment.destination(window, passage.sourcePanelID)
        let labels = Self.labels(for: destinationAtShow)
        let view = ReplyInlineToolbarView(
            title: labels.title,
            accessibilityLabel: labels.accessibilityLabel
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

        shown = Shown(
            passage: passage,
            view: view,
            window: window,
            destinationAtShow: destinationAtShow,
            currentSelection: currentSelection
        )
        // Above the terminal, below the find bar (the find field must win a click).
        if let findBar = host.subviews.first(where: { $0 is TerminalSearchOverlayHostingView }) {
            host.addSubview(view, positioned: .below, relativeTo: findBar)
        } else {
            host.addSubview(view)
        }
        startWatching(in: window, sourcePanelID: passage.sourcePanelID)
        #if DEBUG
        environment.log(
            "shown surface=\(passage.sourcePanelID.uuidString.prefix(5)) chars=\(passage.rawText.count) " +
            "rows=\(passage.bottomRow - passage.topRow + 1) placement=\(placement.edge.rawValue)"
        )
        #endif
        return true
    }

    /// The button's words for a destination: today's `Reply`, or `Add to reply`
    /// when the passage goes to the Reply panel (`cm-136.7`).
    private static func labels(for destination: ReplyInlineDestination) -> (title: String, accessibilityLabel: String) {
        switch destination {
        case .prompt:
            return (
                String(localized: "reply.inline.reply", defaultValue: "Reply"),
                String(localized: "reply.inline.reply.accessibility", defaultValue: "Reply to the selected text")
            )
        case .replyPanel:
            return (
                String(localized: "reply.inline.addToReply", defaultValue: "Add to reply"),
                String(
                    localized: "reply.inline.addToReply.accessibility",
                    defaultValue: "Add the selected text to the reply in the Reply panel"
                )
            )
        }
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
            destinationAtShow: shown.destinationAtShow
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
        if shown.destinationAtShow == .replyPanel {
            addToReplyClicked(shown)
            return
        }
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

    /// `Add to reply` (`cm-136.7`): the passage goes to the Reply panel as an
    /// add, cleaned the way Reply cleans it, and nothing is pasted.
    private func addToReplyClicked(_ shown: Shown) {
        let passage = shown.passage
        // The destination is read again, because a change that landed without
        // its observer firing must not send the passage to the wrong place.
        guard environment.destination(shown.window, passage.sourcePanelID) == .replyPanel else {
            hide(reason: .destination)
            return
        }
        guard environment.isAgentPane(passage.sourcePanelID) else {
            hide(reason: .agentGone)
            return
        }
        let cleaned = ReplyPassageQuote.cleanTerminalSelection(
            passage.rawText,
            wrapColumns: passage.wrapColumns,
            firstRowStartColumn: passage.firstRowStartColumn
        )
        // A selection that was only a marker glyph has nothing to add.
        guard !cleaned.isEmpty else {
            hide(reason: .add)
            return
        }
        let request = TerminalReplyRequest(
            seq: environment.nextReplySeq(),
            text: cleaned,
            isMultiRow: cleaned.contains(where: \.isNewline),
            sourcePanelID: passage.sourcePanelID,
            intent: .add
        )
        hide(reason: .add)
        #if DEBUG
        environment.log(
            "add surface=\(passage.sourcePanelID.uuidString.prefix(5)) chars=\(cleaned.count) " +
            "rows=\(passage.bottomRow - passage.topRow + 1)"
        )
        #endif
        environment.openReply(request, shown.window, host)
    }

    // MARK: Watching (only while shown)

    private func startWatching(in window: NSWindow, sourcePanelID: UUID) {
        monitor = environment.installMonitor { [weak self] event in
            self?.observe(event, in: window)
            return event
        }
        destinationObservation = environment.observeDestination(window, sourcePanelID) { [weak self] in
            guard let self else { return }
            self.handle(.destinationChanged(self.environment.destination(window, sourcePanelID)))
        } ?? AnyCancellable {}
        // `UserDefaults.didChangeNotification` fires for every defaults write in
        // the app, so it is held only while a toolbar shows.
        settingObservation = environment.observeSetting { [weak self] in
            guard let self else { return }
            self.handle(.settingChanged(enabled: self.environment.settingEnabled()))
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
        destinationObservation?.cancel()
        destinationObservation = nil
        settingObservation?.cancel()
        settingObservation = nil
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
