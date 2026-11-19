// cmux-rbf (#cm-73.46, #cm-73.44): the panel's side of the re-fit. One method for three entrances.
import AppKit
import CmuxFoundation
import Combine
import ObjectiveC
import WebKit

/// What a Figma preview's panel holds between two re-fits. One object, so `BrowserPanel`
/// (upstream's file) carries a single stored property for the whole slice.
@MainActor
final class FigmaRefitState {
    /// The top Figma frame's last report, exactly as the last snapshot carried it.
    var report: FigmaPreviewRefit.Report?
    /// Set when `refit` is sent; cleared by the redrawn document's own drawn report, a refusal, or 15 s.
    fileprivate(set) var inFlight = false
    /// `cm-73.11`'s line, started with the re-fit and ended with it.
    fileprivate var lineWaitID: Int?
    /// The bar that line is on. A switch to the editor swaps the panel's bar, and its wait ids count from 1 too,
    /// so the end must go to this one, not to whichever bar the panel holds by then.
    fileprivate var lineBar: FigmaLoadBarState?
    /// The half second a size must hold still.
    let sizeCheck: MainActorDeferredActionScheduler
    /// The 15 s a re-fit may stay in flight.
    let flightLimit: MainActorDeferredActionScheduler
    /// The web view's size and presentation observers; replaced at each bind, dropped at each detach.
    var observers: [AnyCancellable] = []
    /// cm-73.52: true from the moment cmux asks for full screen on Figma's behalf until WebKit reports full screen off,
    /// or the call fails. A full screen that Figma's own page asked for (this stays false) can't be redrawn safely.
    var ownsFullscreen = false
    /// cm-73.52: the key window when the app last resigned, for the one re-key on activation.
    weak var keyWindowAtResign: NSWindow?
    /// cm-73.52: the size the web view had when the redraw in flight was sent.
    fileprivate(set) var redrawStartSize: CGSize?
    /// cm-73.52: set when a size change is dropped as `redrawing`, to the size that redraw started at. When the redraw
    /// ends, the half second starts afresh; the next size check compares with this, not with the size the redrawn
    /// document remembers, and clears it. A load of cmux's page clears it too.
    var owedRecheckFrom: CGSize?
    /// cm-73.52: swaps the panel owes its page, held until WebKit reports full screen off or `fullscreenWait` runs out.
    var afterFullscreen: [@MainActor () -> Void] = []
    /// cm-73.52: true while those swaps run, so a swap that ran out of wait goes ahead and does not wait again.
    var swapPastFullscreen = false
    /// cm-73.52: how many times the panel asked WebKit to leave full screen; for tests.
    var leaveRequestsForTesting = 0
    /// The wait for WebKit's report that full screen is off.
    let fullscreenWait: MainActorDeferredActionScheduler
    /// cm-73.52: the pause before an enter call's one retry, and the observer that waits for the app to become active.
    let fullscreenRetry: MainActorDeferredActionScheduler
    var retryActivationObserver: NSObjectProtocol?
    /// Whether the app is active; replaced by tests, since the test host isn't.
    var appIsActive: () -> Bool = { NSApplication.shared.isActive }

    /// The Log in tell's time, counted by the injected clock like the other two: set when cmux's page finishes
    /// loading, due `interstitialSettle` later, dropped when the next load starts.
    let interstitialTimer: MainActorDeferredActionScheduler
    private var finished = false
    private var stood = false

    /// How long cmux's page has been finished, as far as the decision needs it: nil before a finish and after a load
    /// starts, `.zero` while the interstitial may still be a load, `interstitialSettle` once it has stood that long.
    var sinceFinish: Duration? {
        guard finished else { return nil }
        return stood ? FigmaPreviewRefit.interstitialSettle : .zero
    }

    func markPageFinished() {
        finished = true
        stood = false
        interstitialTimer.schedule(after: FigmaPreviewRefit.interstitialSettle) { [weak self] in self?.stood = true }
    }

    func markLoadStarted() {
        finished = false
        stood = false
        interstitialTimer.cancel()
    }

    init(clock: any Clock<Duration> = ContinuousClock()) {
        sizeCheck = MainActorDeferredActionScheduler(clock: clock)
        flightLimit = MainActorDeferredActionScheduler(clock: clock)
        interstitialTimer = MainActorDeferredActionScheduler(clock: clock)
        fullscreenWait = MainActorDeferredActionScheduler(clock: clock)
        fullscreenRetry = MainActorDeferredActionScheduler(clock: clock)
    }
}

/// The one clock the full-screen click gate reads and writes (cm-73.52). `NSEvent.timestamp` is not it: on this Mac it
/// differed from `systemUptime` by hours (a sleep), which made every real click look stale.
enum FigmaClickClock {
    static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

private var figmaRefitSizesKey: UInt8 = 0

/// The sizes Figma fitted its documents at, newest last. A box, so the web view carries one associated object.
final class FigmaRefitSizes {
    /// A web view keeps this many documents' sizes; the oldest goes first.
    static let capacity = 8
    private(set) var entries: [(doc: Double, size: CGSize)] = []

    func size(forDoc doc: Double) -> CGSize? { entries.first { $0.doc == doc }?.size }

    /// Written once per document: the first drawn report of a document the web view has not met before.
    func rememberIfNew(_ size: CGSize, forDoc doc: Double) {
        guard self.size(forDoc: doc) == nil else { return }
        entries.append((doc, size))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }
}

extension WKWebView {
    /// What Figma fitted each of this web view's frame documents at, keyed by the document's `performance.timeOrigin`.
    /// A document keeps its key through a back-forward restore and through the swap back to a kept preview, and a
    /// re-fit's redraw is a new document: the size follows the document Figma fitted, not the page showing it.
    var figmaRefitSizes: FigmaRefitSizes {
        if let box = objc_getAssociatedObject(self, &figmaRefitSizesKey) as? FigmaRefitSizes { return box }
        let box = FigmaRefitSizes()
        objc_setAssociatedObject(self, &figmaRefitSizesKey, box, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return box
    }
}

extension BrowserPanel {
    /// Whether the panel shows the preview (cmux's served page), not the editor.
    var showsFigmaPreview: Bool {
        guard let address = currentURL ?? webView.url else { return false }
        return FigmaPaneURL.isWrapperPage(address, wrapper: figmaPageWrapper)
    }

    /// The size Figma fitted the frame document the last report came from, or nil: no report, a report with no `doc`
    /// (an older cached page, or a frame without the field), or a document this web view never saw drawn.
    var rememberedFigmaSize: CGSize? {
        guard let doc = figmaRefit.report?.doc else { return nil }
        return webView.figmaRefitSizes.size(forDoc: doc)
    }

    /// The one re-fit: `.size` after the half second, `.key` for `⇧1`, `.cli` for `cmux figma fit`.
    /// Decided from what the panel already holds, so it answers at once and never waits on cmux's page.
    @discardableResult
    func refitFigmaPreview(
        trigger: FigmaPreviewRefit.Trigger, node: String? = nil, recheckFrom: CGSize? = nil
    ) -> FigmaPreviewRefit.Answer {
        let requestedNode = node.flatMap { FigmaFit.normalizedNode($0) }
        let shownNode = (currentURL ?? webView.url).flatMap { FigmaPaneURL.node(fromPaneURL: $0, wrapper: figmaPageWrapper) }
            .flatMap { FigmaFit.normalizedNode($0) }
        let moveNode = requestedNode == shownNode ? nil : requestedNode
        let decision = FigmaPreviewRefit.decide(
            trigger: trigger,
            remembered: recheckFrom ?? rememberedFigmaSize,
            now: webView.bounds.size,
            isPreview: showsFigmaPreview,
            isShowing: isWebViewVisibleInUI,
            motion: figmaMotionState,
            isLoading: isMainFrameProvisionalNavigationActive,
            lastReport: figmaRefit.report,
            refitInFlight: figmaRefit.inFlight,
            sinceFinish: figmaRefit.sinceFinish,
            fullscreen: .init(isActive: isElementFullscreenActive, cmuxOwns: cmuxOwnsFullscreen),
            sizeRule: recheckFrom == nil ? .settled : .recheck
        )
        if trigger == .size, decision == .skip(.redrawing) { figmaRefit.owedRecheckFrom = figmaRefit.redrawStartSize }
#if DEBUG
        let report = figmaRefit.report
        // `path=` goes last: the log redacts a `path` value and everything after it up to the next field it knows.
        cmuxDebugLog(
            "figma.refit surface=\(id.uuidString) trigger=\(trigger.rawValue) " +
            "loaded=\(Self.figmaRefitSizeText(rememberedFigmaSize)) now=\(Self.figmaRefitSizeText(webView.bounds.size)) " +
            "action=\(decision.moves ? (moveNode == nil ? "move" : "goto") : "none")\(moveNode.map { " node=\($0)" } ?? "") via=frame reason=\(decision.reason.rawValue) " +
            "drawn=\(report.map { $0.drawn ? "1" : "0" } ?? "none") path=\(report?.path ?? "none")"
        )
#endif
        if decision.moves { sendFigmaRefit(node: moveNode) }
        return FigmaPreviewRefit.answer(for: decision)
    }

#if DEBUG
    private static func figmaRefitSizeText(_ size: CGSize?) -> String {
        size.map { "\(Int($0.width.rounded()))x\(Int($0.height.rounded()))" } ?? "none"
    }
#endif

    private func sendFigmaRefit(node: String?) {
        let state = figmaRefit
        state.inFlight = true
        state.redrawStartSize = webView.bounds.size
        figmaLoadBar.inPlaceEditorOpened()
        state.lineWaitID = figmaLoadBar.currentWaitID
        state.lineBar = figmaLoadBar
        state.flightLimit.schedule(after: .seconds(FigmaPreviewRefit.inFlightSeconds)) { [weak self] in
            self?.endFigmaRefit(because: "timeout")
        }
        sendFigmaMotionCommand(.refit, node: node) { [weak self] accepted in
            guard !accepted else { return }
#if DEBUG
            if let self {
                cmuxDebugLog("figma.refit surface=\(self.id.uuidString) action=move page=refused")
            }
#endif
            self?.endFigmaRefit(because: "refused")
        }
    }

    /// The in-flight mark and `cm-73.11`'s line end together: on the redrawn document's drawn report, a refusal, or 15 s.
    private func endFigmaRefit(because why: String) {
        let state = figmaRefit
        guard state.inFlight else { return }
        state.inFlight = false
        state.flightLimit.cancel()
        if let waitID = state.lineWaitID { state.lineBar?.scriptAnswered(waitID: waitID) }
        state.lineWaitID = nil
        state.lineBar = nil
#if DEBUG
        cmuxDebugLog("figma.refit.end surface=\(id.uuidString) why=\(why)")
#endif
        // cmux-rbf (#cm-73.52): a size change dropped during the redraw is looked at again, against where the redraw started.
        if let start = state.owedRecheckFrom {
            scheduleFigmaSizeCheck()
#if DEBUG
            cmuxDebugLog(
                "figma.refit.recheck surface=\(id.uuidString) start=\(Self.figmaRefitSizeText(start)) " +
                "now=\(Self.figmaRefitSizeText(webView.bounds.size))"
            )
#endif
        }
    }

    /// Keep exactly the report a snapshot carries (`report: null`, or none, clears it). Only a drawn report ends a re-fit:
    /// the echo of `refit` carries no report, and the old document sends nothing until the redrawn one does.
    func noteFigmaRefitReport(from snapshot: [String: Any]) {
        let report = FigmaPreviewRefit.Report(snapshot: snapshot)
        figmaRefit.report = report
        // Figma has drawn a document and fitted it at the size the web view has now. Written once per document, on
        // its first drawn report: a later report of the same document (a repeat, a restore, the swap back to a kept
        // preview) must not overwrite it, or a real resize since would read `same`.
        if let report, report.drawn, let doc = report.doc, showsFigmaPreview {
            webView.figmaRefitSizes.rememberIfNew(webView.bounds.size, forDoc: doc)
        }
        if report?.drawn == true { endFigmaRefit(because: "drawn") }
    }

    // MARK: Size watch

    /// Every change in the size the page lays out at, and every time the pane shows again, starts the half second afresh.
    func bindFigmaRefitObservers(on webView: WKWebView) {
        figmaRefit.observers.removeAll()
        webView.postsFrameChangedNotifications = true
        NotificationCenter.default.publisher(for: NSView.frameDidChangeNotification, object: webView)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.figmaPreviewSizeMayHaveChanged(because: "frame", needsOnScreen: true) }
            }
            .store(in: &figmaRefit.observers)
        NotificationCenter.default.publisher(for: .browserPortalDidBecomePresentable, object: webView)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.figmaPreviewSizeMayHaveChanged(because: "presentable", needsOnScreen: false) }
            }
            .store(in: &figmaRefit.observers)
    }

    func unbindFigmaRefitObservers() {
        figmaRefit.observers.removeAll()
    }

    func figmaPreviewSizeMayHaveChanged(because why: String, needsOnScreen: Bool) {
        guard showsFigmaPreview, !needsOnScreen || isWebViewVisibleInUI else { return }
        scheduleFigmaSizeCheck()
#if DEBUG
        cmuxDebugLog("figma.refit.size surface=\(id.uuidString) now=\(Self.figmaRefitSizeText(webView.bounds.size)) because=\(why)")
#endif
    }

    /// The half second afresh, then one size check: a re-check from where a redraw started, if one is owed.
    private func scheduleFigmaSizeCheck() {
        figmaRefit.sizeCheck.schedule(after: FigmaPreviewRefit.settle) { [weak self] in
            guard let self else { return }
            let recheckFrom = self.figmaRefit.owedRecheckFrom
            self.figmaRefit.owedRecheckFrom = nil
            self.refitFigmaPreview(trigger: .size, recheckFrom: recheckFrom)
        }
    }

    /// A load of cmux's page drops a pending check: that load fits.
    func figmaRefitLoadDidStart() {
        figmaRefit.owedRecheckFrom = nil
        figmaRefit.markLoadStarted()
        guard figmaRefit.sizeCheck.isScheduled else { return }
        figmaRefit.sizeCheck.cancel()
#if DEBUG
        cmuxDebugLog("figma.refit.cancel surface=\(id.uuidString) reason=load")
#endif
    }

    func figmaRefitPanelDidClose() {
        // cmux-rbf (#cm-73.52): a closing pane goes ahead; the swaps it owed are dropped.
        // cmux-rbf (#cm-143): It does not ask WebKit to leave full screen: close() detaches the web view in this same call, and a leave in flight then frees WebKit's controller mid-exit (beganExitFullScreen, EXC_BREAKPOINT). A detach alone ends full screen, as on a plain page. Reject a revert of this hunk on upstream sync.
        figmaRefit.afterFullscreen = []
        figmaRefit.fullscreenWait.cancel()
        cancelFigmaFullscreenRetry()
        figmaRefit.sizeCheck.cancel()
        figmaRefit.flightLimit.cancel()
        figmaRefit.interstitialTimer.cancel()
        figmaRefit.observers.removeAll()
    }

    // MARK: Full screen (cm-73.52)

    /// Whether the full screen WebKit is in was asked for by cmux, not by Figma's own page.
    var cmuxOwnsFullscreen: Bool { figmaRefit.ownsFullscreen }

    /// Whether an Esc that arrived in `eventWindow` is cmux's to take: this panel's own full screen is on, and the key was
    /// pressed in the window that holds the web view (WebKit's full-screen window, while full screen is on).
    func figmaFullscreenTakesEscape(from eventWindow: NSWindow?) -> Bool {
        Self.figmaFullscreenTakesEscape(
            ownsFullscreen: cmuxOwnsFullscreen, isActive: isElementFullscreenActive,
            eventWindow: eventWindow, webViewWindow: webView.window
        )
    }

    /// The app is about to resign: remember which window was key, so activation can give the key back to it and to nothing else.
    func noteAppResigned(keyWindow: NSWindow?) {
        figmaRefit.keyWindowAtResign = keyWindow
    }

    /// The window to make key when the app becomes active: WebKit's full-screen window, restored only. It was the key
    /// window when the app resigned, it isn't key now, and the activation didn't read as a click (a real click usually
    /// doesn't: see `AppDelegate.applicationDidBecomeActive`). Esc is taken
    /// only from that window, so after ⌘-Tab or the Dock, back into full screen, it must hold the key again.
    func figmaFullscreenWindowToKey(currentKey: NSWindow?, activatedByClick: Bool) -> NSWindow? {
        Self.figmaFullscreenWindowToKey(
            ownsFullscreen: cmuxOwnsFullscreen, isActive: isElementFullscreenActive,
            webViewWindow: webView.window, keyWindowAtResign: figmaRefit.keyWindowAtResign,
            currentKeyWindow: currentKey, activatedByClick: activatedByClick
        )
    }

    static func figmaFullscreenWindowToKey(
        ownsFullscreen: Bool, isActive: Bool, webViewWindow: NSWindow?, keyWindowAtResign: NSWindow?,
        currentKeyWindow: NSWindow?, activatedByClick: Bool
    ) -> NSWindow? {
        guard ownsFullscreen, isActive, !activatedByClick, let webViewWindow,
              webViewWindow === keyWindowAtResign, webViewWindow !== currentKeyWindow else { return nil }
        return webViewWindow
    }

    static func figmaFullscreenTakesEscape(
        ownsFullscreen: Bool, isActive: Bool, eventWindow: NSWindow?, webViewWindow: NSWindow?
    ) -> Bool {
        guard ownsFullscreen, isActive, let eventWindow else { return false }
        return eventWindow === webViewWindow
    }

    /// Whether cmux still owns a full screen once its call is back: only a call that returned `true`. A hidden window
    /// refuses full screen, so WebKit never turns on and never reports off; a flag left set would claim a later full
    /// screen that cmux didn't ask for, and a re-fit would redraw Figma's own full screen away.
    static func ownsFullscreen(afterCall result: Result<Any, Error>) -> Bool {
        guard case .success(let value) = result else { return false }
        return value as? Bool == true
    }

    /// What a refused call says, for the log: WebKit's own words for a page exception (`WKJavaScriptExceptionMessage`, and the
    /// line when it has one), not just "A JavaScript exception occurred".
    static func fullscreenFailureText(_ error: Error) -> String {
        let info = (error as NSError).userInfo
        var text = error.localizedDescription
        if let message = info["WKJavaScriptExceptionMessage"] { text += " message=\(message)" }
        if let line = info["WKJavaScriptExceptionLineNumber"] { text += " line=\(line)" }
        return text
    }

    /// Figma's full-screen request, passed up by its frame: cmux puts its own iframe full screen in its place.
    /// Entering needs Tom's click in this web view within the last second; leaving needs nothing.
    func requestFigmaFullscreen(enter: Bool, isRetry: Bool = false) {
        let clickAge = (webView as? CmuxWebView)?.lastLeftMouseDownUptime.map { FigmaClickClock.now() - $0 }
        let clicked = clickAge.map { $0 < 1 } ?? false
#if DEBUG
        cmuxDebugLog(
            "figma.fullscreen surface=\(id.uuidString) enter=\(enter ? 1 : 0) active=\(isElementFullscreenActive ? 1 : 0) " +
            "click=\(clickAge.map { String(format: "%.2f", $0) } ?? "none")"
        )
#endif
        guard enter != isElementFullscreenActive else { return }
        guard !enter || clicked else { return }
        if enter { figmaRefit.ownsFullscreen = true } else { figmaRefit.leaveRequestsForTesting += 1 }
        let script = enter
            ? "await document.querySelector('iframe').requestFullscreen(); return true"
            : "await document.exitFullscreen(); return true"
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                if enter {
                    if Self.ownsFullscreen(afterCall: result) {
                        // A success owns the full screen it made, even if an earlier call's late failure cleared the flag;
                        // but not one WebKit has already left, which nothing would ever clear again.
                        if self.isElementFullscreenActive { self.figmaRefit.ownsFullscreen = true }
                    } else if !self.isElementFullscreenActive {
                        // A failure after WebKit went full screen (an earlier call's) must not drop what that call owns.
                        self.figmaRefit.ownsFullscreen = false
                        // The click that activates the app can reach the page before WebKit allows full screen: try once more.
                        if !isRetry { self.retryFigmaFullscreenEnterOnce() }
                    }
                }
#if DEBUG
                let outcome: String
                switch result {
                case .success(let value): outcome = "ok=\(String(describing: value))"
                case .failure(let error): outcome = "error=\(Self.fullscreenFailureText(error))"
                }
                cmuxDebugLog("figma.fullscreen.done surface=\(self.id.uuidString) enter=\(enter ? 1 : 0) \(outcome)")
#endif
            }
        }
    }

    /// One more enter call after a refused one, once the app is active: at once-and-a-bit when it already is, else on
    /// `didBecomeActive`. The retry goes through `requestFigmaFullscreen`, so it still needs a click under a second old and
    /// WebKit not already full screen, and it never retries again.
    private func retryFigmaFullscreenEnterOnce() {
        let state = figmaRefit
        cancelFigmaFullscreenRetry()
        let retry: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.cancelFigmaFullscreenRetry()
            self.requestFigmaFullscreen(enter: true, isRetry: true)
        }
#if DEBUG
        cmuxDebugLog("figma.fullscreen.retry surface=\(id.uuidString) waiting=\(state.appIsActive() ? "delay" : "activation")")
#endif
        if state.appIsActive() {
            state.fullscreenRetry.schedule(after: FigmaPreviewRefit.fullscreenRetryDelay, retry)
        } else {
            state.retryActivationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { retry() } }
        }
    }

    private func cancelFigmaFullscreenRetry() {
        figmaRefit.fullscreenRetry.cancel()
        if let observer = figmaRefit.retryActivationObserver {
            NotificationCenter.default.removeObserver(observer)
            figmaRefit.retryActivationObserver = nil
        }
    }

    // MARK: Leaving full screen around what changes the page (cm-73.52)

    /// Whether WebKit's full-screen window holds this page and a swap must wait for it to leave.
    var figmaFullscreenHoldsPage: Bool { isElementFullscreenActive && !figmaRefit.swapPastFullscreen }

    /// Runs `action` at once, or, while full screen holds the page, asks WebKit to leave and runs it when WebKit reports
    /// full screen off, at most `fullscreenExitWait` later, then anyway. For the panel's own swaps, which detach the web
    /// view and so should run only once WebKit's full-screen window has let go of it; the cap is the fallback.
    func afterLeavingFigmaFullscreen(_ action: @escaping @MainActor () -> Void) {
        guard figmaFullscreenHoldsPage else { action(); return }
        let nothingWaiting = figmaRefit.afterFullscreen.isEmpty
        figmaRefit.afterFullscreen.append(action)
        requestFigmaFullscreen(enter: false)
        // The cap runs from the first swap that waited; a later one must not push it back.
        guard nothingWaiting else { return }
        figmaRefit.fullscreenWait.schedule(after: FigmaPreviewRefit.fullscreenExitWait) { [weak self] in
            self?.runAfterFullscreenActions()
        }
    }

    /// WebKit's full-screen state changed: cmux owns nothing once it is off, and the swaps that waited go ahead.
    func figmaFullscreenDidChange(active: Bool) {
        guard !active else { return }
        figmaRefit.ownsFullscreen = false
        runAfterFullscreenActions()
    }

    private func runAfterFullscreenActions() {
        let actions = figmaRefit.afterFullscreen
        figmaRefit.afterFullscreen = []
        figmaRefit.fullscreenWait.cancel()
        figmaRefit.swapPastFullscreen = true
        defer { figmaRefit.swapPastFullscreen = false }
        for action in actions { action() }
    }

    /// A hidden pane asks WebKit to leave full screen and lets the hiding go ahead: a workspace switch, Design Focus, or
    /// another Figma tab coming to the front.
    func leaveFigmaFullscreenWhenHidden(reason: String) {
        guard isElementFullscreenActive, showsFigmaPreview else { return }
#if DEBUG
        cmuxDebugLog("figma.fullscreen.leaveOnHide surface=\(id.uuidString) reason=\(reason)")
#endif
        // cmux-rbf (#cm-143): The request waits one main-queue turn. Closing a workspace hides its panes and then closes them in the same turn, and close() detaches the web view: a leave sent in that pair frees WebKit's controller mid-exit (beganExitFullScreen, EXC_BREAKPOINT). isClosingWebViewLifecycle is set only after the hide, so the check has to run later. Reject a revert of this hunk on upstream sync.
        let hiddenPage = ObjectIdentifier(webView)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let skip: String?
                if self.isClosingWebViewLifecycle {
                    skip = "closing"
                } else if ObjectIdentifier(self.webView) != hiddenPage {
                    skip = "webViewReplaced"
                } else if !self.isElementFullscreenActive || !self.showsFigmaPreview {
                    skip = "notFullscreen"
                } else {
                    skip = nil
                }
                if let skip {
#if DEBUG
                    cmuxDebugLog("figma.fullscreen.leaveOnHide.skipped surface=\(self.id.uuidString) reason=\(skip)")
#endif
                    return
                }
                self.requestFigmaFullscreen(enter: false)
            }
        }
    }
}
