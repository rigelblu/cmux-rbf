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
    }
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
    func refitFigmaPreview(trigger: FigmaPreviewRefit.Trigger, node: String? = nil) -> FigmaPreviewRefit.Answer {
        let requestedNode = node.flatMap { FigmaFit.normalizedNode($0) }
        let shownNode = (currentURL ?? webView.url).flatMap { FigmaPaneURL.node(fromPaneURL: $0, wrapper: figmaPageWrapper) }
            .flatMap { FigmaFit.normalizedNode($0) }
        let moveNode = requestedNode == shownNode ? nil : requestedNode
        let decision = FigmaPreviewRefit.decide(
            trigger: trigger,
            remembered: rememberedFigmaSize,
            now: webView.bounds.size,
            isPreview: showsFigmaPreview,
            isShowing: isWebViewVisibleInUI,
            motion: figmaMotionState,
            isLoading: isMainFrameProvisionalNavigationActive,
            lastReport: figmaRefit.report,
            refitInFlight: figmaRefit.inFlight,
            sinceFinish: figmaRefit.sinceFinish
        )
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
        figmaRefit.sizeCheck.schedule(after: FigmaPreviewRefit.settle) { [weak self] in
            self?.refitFigmaPreview(trigger: .size)
        }
#if DEBUG
        cmuxDebugLog("figma.refit.size surface=\(id.uuidString) now=\(Self.figmaRefitSizeText(webView.bounds.size)) because=\(why)")
#endif
    }

    /// A load of cmux's page drops a pending check: that load fits.
    func figmaRefitLoadDidStart() {
        figmaRefit.markLoadStarted()
        guard figmaRefit.sizeCheck.isScheduled else { return }
        figmaRefit.sizeCheck.cancel()
#if DEBUG
        cmuxDebugLog("figma.refit.cancel surface=\(id.uuidString) reason=load")
#endif
    }

    func figmaRefitPanelDidClose() {
        figmaRefit.sizeCheck.cancel()
        figmaRefit.flightLimit.cancel()
        figmaRefit.interstitialTimer.cancel()
        figmaRefit.observers.removeAll()
    }
}
