// cmux-rbf (#cm-73.46, #cm-73.44): Scenarios 258 and 300 on the panel: the kept report, the in-flight mark and its
// three ends, the line, the answer, and the size watch on an injected clock.
import AppKit
#if DEBUG
import CMUXDebugLog
#endif
import Foundation
import Testing
import WebKit
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("FigmaRefitPanel", .serialized)
struct FigmaRefitPanelTests {
    typealias Refit = FigmaPreviewRefit
    private static let size = CGSize(width: 800, height: 600)

    // MARK: Fixture

    /// A preview panel with a controlled document: `window.commands` records what the panel sent to cmux's page.
    private func panel(clock: SidebarTestManualClock? = nil, ready: Bool = true) async throws -> BrowserPanel {
        let p = BrowserPanel(workspaceId: UUID(), initialURL: nil, renderInitialNavigation: false, chromeVisibility: .hidden)
        if let clock {
            p.figmaRefit = FigmaRefitState(clock: clock) // the old state's observers died with it; the production bind path makes this one's
            p.bindWebView(try #require(p.webView as? CmuxWebView))
        }
        let address = try FigmaPaneURL.destination(for: URL(string: "https://www.figma.com/design/KEY/slug")!, node: "12-2").url
        p.publishObservedDocumentURL(address)
        p.installFigmaMotionBridge(on: p.webView, address: address)
        let previous = p.webView.navigationDelegate
        p.webView.navigationDelegate = nil // A controlled document; production navigation policy is tested elsewhere.
        _ = p.webView.loadSimulatedRequest(URLRequest(url: address), responseHTML: "<html><body>fixture</body></html>")
        var loaded = false
        for _ in 0..<150 {
            if !p.webView.isLoading, p.webView.url == address,
               (try? await p.webView.evaluateJavaScript("document.readyState")) as? String == "complete" { loaded = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        p.webView.navigationDelegate = previous
        try #require(loaded, "the fixture document did not load within 3 seconds")
        p.publishObservedDocumentURL(address)
        _ = try await p.webView.evaluateJavaScript("""
        window.commands=[]; window.refuse=false;
        window.__cmuxMotion={command:function(a){commands.push(a); if(a==='refit'&&window.refuse) return false; return {state:'still',report:(a==='refit'?null:window.kept)}},
          snapshot:function(){return {state:'still',report:null}}};
        window.kept=null; // what a real page's own last report would be in each reply
        """)
        if ready {
            p.noteWebViewVisibility(true, reason: "fixture")
            p.webView.frame = NSRect(origin: .zero, size: Self.size)
            report(p) // doc 1, drawn: the first drawn report of a document writes the size it was fitted at
            _ = try await p.webView.evaluateJavaScript("window.kept = {path:'/design/KEY/slug', player:false, drawn:true, doc:1}")
            p.figmaRefit.sizeCheck.cancel() // the fixture's own resize is not what a test is about
        }
        return p
    }

    /// cmux's page posts `{state, report}` with every render; this is that message.
    private func report(
        _ p: BrowserPanel, path: String? = "/design/KEY/slug", drawn: Bool = true, player: Bool = false, doc: Double? = 1
    ) {
        var body: [String: Any] = ["state": "still"]
        body["report"] = path.map { path -> [String: Any] in
            var r: [String: Any] = ["path": path, "player": player, "drawn": drawn]
            if let doc { r["doc"] = doc }
            return r
        } ?? NSNull()
        p.receiveFigmaMotionMessage(from: p.webView, mainFrame: true, address: p.currentURL, body: body)
    }

    private func commands(_ p: BrowserPanel) async -> [String] {
        ((try? await p.webView.evaluateJavaScript("commands")) as? [String]) ?? []
    }
    private func delivered(_ p: BrowserPanel, count: Int = 1, _ what: String = "refit") async throws {
        for _ in 0..<100 {
            if await commands(p).filter({ $0 == what }).count >= count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "FigmaRefitPanelTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(what) x\(count) was not delivered within 2 seconds; got \(await commands(p))"])
    }
    private func refitCount(_ p: BrowserPanel) async -> Int { await commands(p).filter { $0 == "refit" }.count }
    private func settle() async { for _ in 0..<5 { await Task.yield() } }

    // MARK: The kept report

    @Test func aSnapshotKeepsTheReportsPathPlayerAndDrawn() async throws {
        let p = try await panel(ready: false); defer { p.close() }
        report(p, path: "/design/KEY/slug", drawn: false, player: false)
        #expect(p.figmaRefit.report == Refit.Report(path: "/design/KEY/slug", player: false, drawn: false, doc: 1))
        report(p, path: "/proto/KEY/slug", drawn: true, player: true)
        #expect(p.figmaRefit.report == Refit.Report(path: "/proto/KEY/slug", player: true, drawn: true, doc: 1))
    }

    @Test func aSnapshotWithNullOrNoReportClearsIt() async throws {
        let p = try await panel(ready: false); defer { p.close() }
        report(p)
        report(p, path: nil)
        #expect(p.figmaRefit.report == nil, "report: null clears")
        report(p)
        p.receiveFigmaMotionMessage(from: p.webView, mainFrame: true, address: p.currentURL, body: ["state": "still"])
        #expect(p.figmaRefit.report == nil, "no report at all clears, as navigate's bare state does")
    }

    // MARK: The answer, from what the panel already holds

    @Test func cliOnADrawnBoardMovesSendsRefitAndSetsTheMark() async throws {
        let p = try await panel(); defer { p.close() }
        #expect(p.refitFigmaPreview(trigger: .cli) == .moved)
        try await delivered(p)
        #expect(p.figmaRefit.inFlight)
    }

    @Test func aSecondFitWhileTheFirstRedrawsAnswersRedrawingAndSendsNothingMore() async throws {
        let p = try await panel(); defer { p.close() }
        _ = p.refitFigmaPreview(trigger: .cli)
        try await delivered(p)
        report(p, path: nil) // the echo and the render of `refit` carry no report
        #expect(p.refitFigmaPreview(trigger: .cli) == .fitsItself(.redrawing))
        #expect(p.refitFigmaPreview(trigger: .key) == .fitsItself(.redrawing))
        await settle()
        #expect(await refitCount(p) == 1)
    }

    @Test func noKeptReportAnswersLoadingAndANonBoardIsRefused() async throws {
        let p = try await panel(); defer { p.close() }
        report(p, path: nil)
        #expect(p.refitFigmaPreview(trigger: .cli) == .fitsItself(.loading))
        report(p, path: "/design/KEY/slug", drawn: false)
        #expect(p.refitFigmaPreview(trigger: .cli) == .fitsItself(.loading))
        report(p, path: "/board/KEY/slug", drawn: true)
        #expect(p.refitFigmaPreview(trigger: .cli) == .refused(.notboard))
        await settle()
        #expect(await refitCount(p) == 0, "nothing is sent for any of the three")
    }

    @Test func thePlayerAndALoadOfCmuxsPageMoveNothing() async throws {
        let p = try await panel(); defer { p.close() }
        p.figmaMotionState = .playing
        #expect(p.refitFigmaPreview(trigger: .cli) == .fitsItself(.player))
        p.figmaMotionState = .still
        p.isMainFrameProvisionalNavigationActive = true
        #expect(p.refitFigmaPreview(trigger: .cli) == .fitsItself(.loading))
        await settle()
        #expect(await refitCount(p) == 0)
    }

    @Test func aDrawnBoardWhoseReportCarriesNoDocIsNeverAMatchForAnySize() async throws {
        let p = try await panel(ready: false); defer { p.close() }
        p.noteWebViewVisibility(true, reason: "fixture")
        p.webView.frame = NSRect(origin: .zero, size: Self.size)
        report(p, doc: nil) // an older cached page, or a frame without the field
        #expect(p.rememberedFigmaSize == nil)
        for trigger in [Refit.Trigger.size, .key, .cli] {
            #expect(p.refitFigmaPreview(trigger: trigger) == .fitsItself(.unloaded), "\(trigger.rawValue)")
        }
        p.webView.frame = NSRect(origin: .zero, size: CGSize(width: 500, height: 600))
        #expect(p.refitFigmaPreview(trigger: .size) == .fitsItself(.unloaded), "a different size still isn't a move")
        await settle()
        #expect(await refitCount(p) == 0)
    }

    @Test func theKeyReachesTheRefitThroughTheMessageTheScriptPosts() async throws {
        let p = try await panel(); defer { p.close() }
        p.receiveFigmaMotionMessage(from: p.webView, mainFrame: true, address: p.currentURL, body: ["action": "fit"])
        try await delivered(p)
        #expect(p.figmaRefit.inFlight)
        let foreign = try await panel(); defer { foreign.close() }
        foreign.receiveFigmaMotionMessage(from: foreign.webView, mainFrame: false, address: foreign.currentURL, body: ["action": "fit"])
        await settle()
        #expect(await refitCount(foreign) == 0, "a message from a subframe is rejected as before")
    }

    // MARK: Full screen (cm-73.52): cmux owns it only when its own call succeeded

    /// cmux's page with a stand-in for its iframe: `window.fsCalls` counts the full-screen requests it took.
    /// The fixture has no window, so a real request could never succeed.
    private func withFullscreenIframe(
        _ p: BrowserPanel, rejects: Bool = false, rejectsAfterMs: Int? = nil, perCall: String? = nil
    ) async throws {
        _ = try await p.webView.evaluateJavaScript("""
        window.fsCalls = 0; window.fsExits = 0;
        document.exitFullscreen = function () { window.fsExits++; return Promise.resolve(); };
        document.body.innerHTML = '<iframe></iframe>';
        document.querySelector('iframe').requestFullscreen = function () {
          window.fsCalls++;
          if (\(perCall != nil ? "true" : "false")) { var n = window.fsCalls; \(perCall ?? "") }
          return \(rejectsAfterMs.map { "new Promise(function (_, no) { setTimeout(function () { no(new Error('late')); }, \($0)); })" } ?? (rejects ? "Promise.reject(new Error('no'))" : "Promise.resolve()"));
        };
        0;
        """)
    }

    private func fullscreenCalls(_ p: BrowserPanel) async -> Int {
        ((try? await p.webView.evaluateJavaScript("window.fsCalls")) as? Int) ?? -1
    }

    private func fullscreenExits(_ p: BrowserPanel) async -> Int {
        ((try? await p.webView.evaluateJavaScript("window.fsExits")) as? Int) ?? -1
    }

    private func clicked(_ p: BrowserPanel, secondsAgo: TimeInterval) throws {
        try #require(p.webView as? CmuxWebView).lastLeftMouseDownUptimeForTesting = FigmaClickClock.now() - secondsAgo
    }

    @Test func aFullScreenRequestTheCallCarriedOutIsOwnedByCmux() async throws {
        let p = try await panel(); defer { p.close() }
        try await withFullscreenIframe(p)
        try clicked(p, secondsAgo: 0.1)
        p.receiveFigmaMotionMessage(from: p.webView, mainFrame: true, address: p.currentURL, body: ["action": "fullscreen", "enter": true])
        #expect(p.cmuxOwnsFullscreen, "set before the call, so a re-fit that lands while WebKit enters knows whose it is")
        for _ in 0..<100 where await fullscreenCalls(p) == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await fullscreenCalls(p) == 1)
        await settle()
        try await Task.sleep(for: .milliseconds(100))
        #expect(p.cmuxOwnsFullscreen, "a call that returned true keeps it until WebKit reports full screen off")
    }

    @Test func aRealMouseDownCountsAsAFreshClickWhateverBaseItsEventTimestampIsOn() async throws {
        let p = try await panel(); defer { p.close() }
        try await withFullscreenIframe(p)
        // An event whose timestamp is hours from `systemUptime`, as after a sleep on this Mac.
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 5, windowNumber: 0,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        try #require(p.webView as? CmuxWebView).mouseDown(with: event)
        p.requestFigmaFullscreen(enter: true)
        #expect(p.cmuxOwnsFullscreen, "the gate reads the click on the clock it was written on")
        for _ in 0..<100 where await fullscreenCalls(p) == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await fullscreenCalls(p) == 1)
    }

    @Test func aFullScreenCallThatThrowsLeavesCmuxOwningNothing() async throws {
        let p = try await panel(); defer { p.close() }
        try await withFullscreenIframe(p, rejects: true)
        try clicked(p, secondsAgo: 0.1)
        p.requestFigmaFullscreen(enter: true)
        for _ in 0..<100 where p.cmuxOwnsFullscreen { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!p.cmuxOwnsFullscreen, "a hidden window refuses; WebKit never turns on or reports off, so nothing else would clear it")
    }

    @Test func aFullScreenCallOnAPageWithNoIframeLeavesCmuxOwningNothing() async throws {
        let p = try await panel(); defer { p.close() }
        try clicked(p, secondsAgo: 0.1)
        p.requestFigmaFullscreen(enter: true)
        for _ in 0..<100 where p.cmuxOwnsFullscreen { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!p.cmuxOwnsFullscreen)
    }

    @Test func aFailedEnterAfterWebKitWentFullScreenLeavesWhatAnEarlierCallOwns() async throws {
        let p = try await panel(); defer { p.close() }
        try await withFullscreenIframe(p, rejectsAfterMs: 150)
        try clicked(p, secondsAgo: 0.1)
        p.requestFigmaFullscreen(enter: true)
        #expect(p.cmuxOwnsFullscreen)
        p.isElementFullscreenActiveForTesting = true // an earlier call's full screen is on by the time this one fails
        try await Task.sleep(for: .milliseconds(500))
        #expect(await fullscreenCalls(p) == 1)
        #expect(p.cmuxOwnsFullscreen, "a late failure drops nothing while WebKit is full screen")
    }

    @Test func aRefusedCallsLogLineCarriesWebKitsExceptionMessageAndLine() {
        let error = NSError(domain: "WKErrorDomain", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "A JavaScript exception occurred",
            "WKJavaScriptExceptionMessage": "TypeError: Fullscreen request denied",
            "WKJavaScriptExceptionLineNumber": 3
        ])
        let text = BrowserPanel.fullscreenFailureText(error)
        #expect(text.contains("A JavaScript exception occurred"))
        #expect(text.contains("message=TypeError: Fullscreen request denied"))
        #expect(text.contains("line=3"))
        #expect(BrowserPanel.fullscreenFailureText(NSError(domain: "x", code: 1)).contains("message=") == false, "no message, none invented")
    }

    // MARK: Enter retry (cm-73.52): the click that activates the app can beat WebKit's permission

    /// Calls before `failing` fail, the rest succeed. `window.fsCalls` counts them.
    private func iframeFailing(_ p: BrowserPanel, firstCalls failing: Int) async throws {
        try await withFullscreenIframe(p, perCall: "if (n <= \(failing)) { return Promise.reject(new Error('not yet')); } return Promise.resolve();")
    }

    private func waitForCalls(_ p: BrowserPanel, _ count: Int) async throws {
        for _ in 0..<100 where await fullscreenCalls(p) < count { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test(.timeLimit(.minutes(1))) func aRefusedEnterIsRetriedOnceAfterAQuarterSecondWhenTheAppIsActive() async throws {
        let clock = SidebarTestManualClock()
        let p = try await panel(clock: clock); defer { p.close() }
        p.figmaRefit.appIsActive = { true }
        try await iframeFailing(p, firstCalls: 1)
        try clicked(p, secondsAgo: 0.1)
        p.requestFigmaFullscreen(enter: true)
        try await waitForCalls(p, 1)
        guard await boundedSleeper(clock, .milliseconds(250)) else { return }
        clock.advance(by: .milliseconds(249))
        await settle()
        #expect(await fullscreenCalls(p) == 1, "249 ms: not yet")
        clock.advance(by: .milliseconds(1))
        try await waitForCalls(p, 2)
        #expect(await fullscreenCalls(p) == 2, "the retry")
        await settle()
        try await Task.sleep(for: .milliseconds(100))
        #expect(p.cmuxOwnsFullscreen, "the retry succeeded, so cmux owns the full screen it asked for")
    }

    @Test(.timeLimit(.minutes(1))) func aRefusedEnterIsRetriedOnlyOnceEvenWhenTheRetryIsRefusedToo() async throws {
        let clock = SidebarTestManualClock()
        let p = try await panel(clock: clock); defer { p.close() }
        p.figmaRefit.appIsActive = { true }
        try await iframeFailing(p, firstCalls: 99)
        try clicked(p, secondsAgo: 0.1)
        p.requestFigmaFullscreen(enter: true)
        try await waitForCalls(p, 1)
        guard await boundedSleeper(clock, .milliseconds(250)) else { return }
        clock.advance(by: .milliseconds(250))
        try await waitForCalls(p, 2)
        await settle()
        try await Task.sleep(for: .milliseconds(150))
        clock.advance(by: .seconds(5))
        await settle()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await fullscreenCalls(p) == 2, "one call, one retry, no more")
        #expect(!p.cmuxOwnsFullscreen)
    }

    @Test(.timeLimit(.minutes(1))) func theRetryNeedsTheClickToStillBeUnderASecondOld() async throws {
        let clock = SidebarTestManualClock()
        let p = try await panel(clock: clock); defer { p.close() }
        p.figmaRefit.appIsActive = { true }
        try await iframeFailing(p, firstCalls: 1)
        try clicked(p, secondsAgo: 0.1)
        p.requestFigmaFullscreen(enter: true)
        try await waitForCalls(p, 1)
        try await Task.sleep(for: .milliseconds(100))
        try clicked(p, secondsAgo: 2) // by the time the retry is due, the click is stale
        guard await boundedSleeper(clock, .milliseconds(250)) else { return }
        clock.advance(by: .milliseconds(250))
        await settle()
        try await Task.sleep(for: .milliseconds(150))
        #expect(await fullscreenCalls(p) == 1, "a stale click asks nothing")
    }

    @Test(.timeLimit(.minutes(1))) func aRefusalAfterWebKitWentFullScreenIsNotRetried() async throws {
        let clock = SidebarTestManualClock()
        let p = try await panel(clock: clock); defer { p.close() }
        p.figmaRefit.appIsActive = { true }
        try await withFullscreenIframe(p, rejectsAfterMs: 100)
        try clicked(p, secondsAgo: 0.1)
        p.requestFigmaFullscreen(enter: true)
        p.isElementFullscreenActiveForTesting = true // an earlier call's full screen is on when this one is refused
        try await Task.sleep(for: .milliseconds(300))
        clock.advance(by: .seconds(5))
        await settle()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await fullscreenCalls(p) == 1)
    }

    @Test(.timeLimit(.minutes(1))) func whenTheAppIsNotActiveYetTheRetryWaitsForItToBecomeActive() async throws {
        let clock = SidebarTestManualClock()
        let p = try await panel(clock: clock); defer { p.close() }
        p.figmaRefit.appIsActive = { false }
        try await iframeFailing(p, firstCalls: 1)
        try clicked(p, secondsAgo: 0.1)
        p.requestFigmaFullscreen(enter: true)
        try await waitForCalls(p, 1)
        try await Task.sleep(for: .milliseconds(150))
        clock.advance(by: .seconds(5))
        await settle()
        #expect(await fullscreenCalls(p) == 1, "no timer while the app isn't active")
        try clicked(p, secondsAgo: 0.1) // the click that activated the app is as fresh as the activation, however busy this host is
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        try await waitForCalls(p, 2)
        let afterActivation = await fullscreenCalls(p)
        #expect(afterActivation == 2, "the activation releases the retry; calls=\(afterActivation)")
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        await settle()
        try await Task.sleep(for: .milliseconds(150))
        #expect(await fullscreenCalls(p) == 2, "and a second activation retries nothing")
    }

    @Test func aSuccessOwnsTheFullScreenEvenWhenAnEarlierCallsLateFailureClearedTheFlag() async throws {
        let p = try await panel(); defer { p.close() }
        // Call 1 is refused after 100 ms; call 2 succeeds after 300 ms, so the failure lands first.
        try await withFullscreenIframe(p, perCall: """
        return new Promise(function (resolve, reject) { setTimeout(n === 1 ? function () { reject(new Error('cancelled')); } : resolve, n === 1 ? 100 : 300); });
        """)
        try clicked(p, secondsAgo: 0.1)
        p.requestFigmaFullscreen(enter: true)
        p.requestFigmaFullscreen(enter: true)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!p.cmuxOwnsFullscreen, "the first call's failure has landed and cleared the flag")
        p.isElementFullscreenActiveForTesting = true // WebKit went full screen for the second call before it answers
        for _ in 0..<100 where !p.cmuxOwnsFullscreen { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await fullscreenCalls(p) == 2)
        #expect(p.cmuxOwnsFullscreen, "the second call's success owns the full screen it made")
    }

    @Test func theFullScreenWindowIsKeyedOnActivationOnlyToRestoreWhatTheAppResignedWith() {
        let fullScreen = NSWindow(), main = NSWindow()
        typealias Panel = BrowserPanel
        func toKey(
            owns: Bool = true, active: Bool = true, web: NSWindow? = fullScreen, resigned: NSWindow? = fullScreen,
            key: NSWindow? = main, click: Bool = false
        ) -> NSWindow? {
            Panel.figmaFullscreenWindowToKey(
                ownsFullscreen: owns, isActive: active, webViewWindow: web, keyWindowAtResign: resigned,
                currentKeyWindow: key, activatedByClick: click
            )
        }
        #expect(toKey() === fullScreen, "it was key when the app resigned, and another window is key now")
        #expect(toKey(key: nil) === fullScreen)
        #expect(toKey(key: fullScreen) == nil, "already key")
        #expect(toKey(resigned: main) == nil, "Tom had the main window key when he left: not ours to override")
        #expect(toKey(resigned: nil) == nil, "nothing remembered")
        #expect(toKey(click: true) == nil, "a click chose the window")
        #expect(toKey(active: false) == nil, "WebKit isn't full screen")
        #expect(toKey(owns: false) == nil, "not cmux's full screen")
        #expect(toKey(web: nil, resigned: nil) == nil, "no window to key")
    }

    @Test func aPanelKeysItsFullScreenWindowOnlyWhenItHeldTheKeyAtResign() async throws {
        let p = try await panel(); defer { p.close() }
        let held = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let main = NSWindow()
        held.contentView?.addSubview(p.webView)
        p.figmaRefit.ownsFullscreen = true
        p.isElementFullscreenActiveForTesting = true
        #expect(p.figmaFullscreenWindowToKey(currentKey: main, activatedByClick: false) == nil, "the app never resigned")
        p.noteAppResigned(keyWindow: held)
        #expect(p.figmaFullscreenWindowToKey(currentKey: main, activatedByClick: false) === held)
        #expect(p.figmaFullscreenWindowToKey(currentKey: main, activatedByClick: true) == nil)
        p.noteAppResigned(keyWindow: main)
        #expect(p.figmaFullscreenWindowToKey(currentKey: held, activatedByClick: false) == nil)
        #expect(p.figmaFullscreenWindowToKey(currentKey: nil, activatedByClick: false) == nil, "main was key at this resign")
    }

    @Test func aSuccessAfterWebKitLeftFullScreenOwnsNothing() async throws {
        let p = try await panel(); defer { p.close() }
        try await withFullscreenIframe(p, perCall: """
        return new Promise(function (resolve) { setTimeout(resolve, 150); });
        """)
        try clicked(p, secondsAgo: 0.1)
        p.requestFigmaFullscreen(enter: true)
        #expect(p.cmuxOwnsFullscreen)
        p.figmaFullscreenDidChange(active: false) // WebKit reports full screen off while the call is still out
        try await Task.sleep(for: .milliseconds(500))
        #expect(await fullscreenCalls(p) == 1)
        #expect(!p.cmuxOwnsFullscreen, "a success for a full screen that is already gone must not claim the next one")
    }

    @Test func onlyACallThatReturnedTrueIsOwned() {
        typealias Panel = BrowserPanel
        #expect(Panel.ownsFullscreen(afterCall: .success(true)))
        #expect(!Panel.ownsFullscreen(afterCall: .success(false)), "returned false")
        #expect(!Panel.ownsFullscreen(afterCall: .success(NSNull())), "returned nothing")
        #expect(!Panel.ownsFullscreen(afterCall: .success("true")), "a string is not true")
        #expect(!Panel.ownsFullscreen(afterCall: .failure(NSError(domain: "x", code: 1))))
    }

    @Test func noClickOrAnOldClickAsksNothingAndOwnsNothing() async throws {
        let p = try await panel(); defer { p.close() }
        try await withFullscreenIframe(p)
        p.receiveFigmaMotionMessage(from: p.webView, mainFrame: true, address: p.currentURL, body: ["action": "fullscreen", "enter": true])
        #expect(!p.cmuxOwnsFullscreen, "no click ever")
        try clicked(p, secondsAgo: 1.5)
        p.receiveFigmaMotionMessage(from: p.webView, mainFrame: true, address: p.currentURL, body: ["action": "fullscreen", "enter": true])
        #expect(!p.cmuxOwnsFullscreen, "a click 1.5 s ago")
        await settle()
        try await Task.sleep(for: .milliseconds(150))
        #expect(await fullscreenCalls(p) == 0, "page script can post the message, but can't fake the click")
    }

    // MARK: Full screen (cm-73.52): the answer and the fallback

    @Test func aFullScreenFigmaPutThereItselfRefusesEveryFitAndSendsNothing() async throws {
        let p = try await panel(); defer { p.close() }
        p.isElementFullscreenActiveForTesting = true
        #expect(p.refitFigmaPreview(trigger: .cli) == .refused(.fullscreen))
        #expect(p.refitFigmaPreview(trigger: .key) == .refused(.fullscreen), "⇧1")
        #expect(p.refitFigmaPreview(trigger: .size) == .refused(.fullscreen), "a size change")
        await settle()
        #expect(await refitCount(p) == 0, "a redraw would end Figma's full screen")
        #expect(!p.figmaRefit.inFlight)
    }

    @Test func cmuxsOwnFullScreenStillFitsAndNoFullScreenIsAsBefore() async throws {
        let p = try await panel(); defer { p.close() }
        p.isElementFullscreenActiveForTesting = true
        p.figmaRefit.ownsFullscreen = true
        #expect(p.refitFigmaPreview(trigger: .cli) == .moved, "cmux's iframe is the full-screen element, so a redraw can't end it")
        try await delivered(p)
        let q = try await panel(); defer { q.close() }
        #expect(q.refitFigmaPreview(trigger: .cli) == .moved)
    }

    // MARK: Size re-check (cm-73.52): a size change dropped while a redraw runs is looked at again

    @Test(.timeLimit(.minutes(1))) func aSizeChangeSkippedWhileARedrawRunsIsCheckedAgainWhenItEnds() async throws {
        let clock = SidebarTestManualClock()
        let p = try await panel(clock: clock); defer { p.close() }
        try #require(p.refitFigmaPreview(trigger: .cli) == .moved)
        try await delivered(p) // the redraw started at 800x600
        p.webView.frame = NSRect(x: 0, y: 0, width: 1200, height: 600)
        await settle()
        guard await boundedSleeper(clock, .milliseconds(500)) else { return }
        clock.advance(by: .milliseconds(500)) // the half second lands inside the redraw: skipped
        await settle()
        #expect(await refitCount(p) == 1)
        report(p, path: nil) // the echo
        report(p, drawn: true, doc: 2) // the redraw ends; its document remembers 1200x600, which is not trusted
        try #require(p.figmaRefit.sizeCheck.isScheduled, "a skipped size change starts the half second afresh when the redraw ends")
        guard await boundedSleeper(clock, .milliseconds(500)) else { return }
        clock.advance(by: .milliseconds(500))
        try await delivered(p, count: 2)
        #expect(await refitCount(p) == 2, "1200 is far from the 800 the redraw started at")
    }

    @Test(.timeLimit(.minutes(1))) func theRecheckLeavesFigmasOnePointSettleAlone() async throws {
        let clock = SidebarTestManualClock()
        let p = try await panel(clock: clock); defer { p.close() }
        try #require(p.refitFigmaPreview(trigger: .cli) == .moved)
        try await delivered(p)
        p.webView.frame = NSRect(x: 0, y: 0, width: 801, height: 600) // 1 pt, as Figma settles on every entry
        await settle()
        guard await boundedSleeper(clock, .milliseconds(500)) else { return }
        clock.advance(by: .milliseconds(500))
        await settle()
        report(p, path: nil)
        report(p, drawn: true, doc: 2)
        try #require(p.figmaRefit.sizeCheck.isScheduled, "the size change was dropped, so it is checked again")
        guard await boundedSleeper(clock, .milliseconds(500)) else { return }
        clock.advance(by: .milliseconds(500))
        await settle()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await refitCount(p) == 1, "1 pt from where the redraw started is not a second redraw")
    }

    @Test(.timeLimit(.minutes(1))) func aLoadOfCmuxsPageDropsTheOwedRecheckSoTheNewPagesDrawnReportSchedulesNone() async throws {
        let clock = SidebarTestManualClock()
        let p = try await panel(clock: clock); defer { p.close() }
        try #require(p.refitFigmaPreview(trigger: .cli) == .moved)
        try await delivered(p)
        p.webView.frame = NSRect(x: 0, y: 0, width: 1200, height: 600)
        await settle()
        guard await boundedSleeper(clock, .milliseconds(500)) else { return }
        clock.advance(by: .milliseconds(500)) // dropped as redrawing: a re-check is owed
        await settle()
        try #require(p.figmaRefit.owedRecheckFrom == Self.size, "owed from where the redraw started")
        p.figmaRefitLoadDidStart() // a new page loads; the old redraw's start means nothing to it
        #expect(p.figmaRefit.owedRecheckFrom == nil)
        report(p, path: nil)
        report(p, drawn: true, doc: 2) // the new page's first drawn report ends the old in-flight mark
        #expect(!p.figmaRefit.sizeCheck.isScheduled, "no re-check against the old redraw's start")
    }

    @Test func aRedrawThatEndsWithNoSizeChangeSkippedSchedulesNoCheck() async throws {
        let p = try await panel(); defer { p.close() }
        try #require(p.refitFigmaPreview(trigger: .cli) == .moved)
        try await delivered(p)
        report(p, path: nil)
        report(p, drawn: true, doc: 2)
        #expect(!p.figmaRefit.sizeCheck.isScheduled)
        #expect(p.refitFigmaPreview(trigger: .key) == .moved, "and a later fit works as before")
    }

    // MARK: Leaving full screen around what changes the page (cm-73.52)

    @Test func cmuxOwnsNothingOnceWebKitReportsFullScreenOff() async throws {
        let p = try await panel(); defer { p.close() }
        p.isElementFullscreenActiveForTesting = true
        p.figmaRefit.ownsFullscreen = true
        p.figmaFullscreenDidChange(active: true)
        #expect(p.cmuxOwnsFullscreen, "still on")
        p.isElementFullscreenActiveForTesting = false
        p.figmaFullscreenDidChange(active: false)
        #expect(!p.cmuxOwnsFullscreen, "a flag left set would call a later full screen cmux's own, and bring the collapse back")
        #expect(p.refitFigmaPreview(trigger: .cli) == .moved)
    }

    @Test func aSwapWithNoFullScreenRunsAtOnce() async throws {
        let p = try await panel(); defer { p.close() }
        var ran = 0
        p.afterLeavingFigmaFullscreen { ran += 1 }
        #expect(ran == 1)
        #expect(p.figmaRefit.leaveRequestsForTesting == 0)
    }

    @Test func aSwapDuringFullScreenAsksWebKitToLeaveAndWaitsForItsReportOnce() async throws {
        let p = try await panel(); defer { p.close() }
        try await withFullscreenIframe(p)
        p.isElementFullscreenActiveForTesting = true
        var ran = 0
        p.afterLeavingFigmaFullscreen { ran += 1 }
        for _ in 0..<100 where await fullscreenExits(p) == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await fullscreenExits(p) == 1, "the page was asked to leave")
        #expect(ran == 0, "the swap waits until WebKit reports full screen off")
        p.figmaFullscreenDidChange(active: true)
        #expect(ran == 0, "a report that it is still on changes nothing")
        p.isElementFullscreenActiveForTesting = false
        p.figmaFullscreenDidChange(active: false)
        #expect(ran == 1)
        p.figmaFullscreenDidChange(active: false)
        #expect(ran == 1, "once")
    }

    @Test(.timeLimit(.minutes(1))) func aSwapGoesAheadAtTheCapWhenWebKitNeverReportsOff() async throws {
        let clock = SidebarTestManualClock()
        let p = try await panel(clock: clock); defer { p.close() }
        p.isElementFullscreenActiveForTesting = true
        var ran = 0
        p.afterLeavingFigmaFullscreen { ran += 1 }
        guard await boundedSleeper(clock, FigmaPreviewRefit.fullscreenExitWait) else { return }
        clock.advance(by: FigmaPreviewRefit.fullscreenExitWait - .milliseconds(1))
        await settle()
        #expect(ran == 0, "1 ms short of the cap")
        clock.advance(by: .milliseconds(1))
        await settle()
        #expect(ran == 1, "at the cap, with full screen still on")
        #expect(p.figmaRefit.afterFullscreen.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func aSecondSwapQueuedWhileWaitingDoesNotPushTheCapBack() async throws {
        let clock = SidebarTestManualClock()
        let p = try await panel(clock: clock); defer { p.close() }
        p.isElementFullscreenActiveForTesting = true
        var first = 0, second = 0
        p.afterLeavingFigmaFullscreen { first += 1 }
        guard await boundedSleeper(clock, FigmaPreviewRefit.fullscreenExitWait) else { return }
        clock.advance(by: FigmaPreviewRefit.fullscreenExitWait - .milliseconds(400))
        p.afterLeavingFigmaFullscreen { second += 1 }
        await settle()
        clock.advance(by: .milliseconds(400)) // the cap since the first
        await settle()
        #expect(first == 1 && second == 1, "both go ahead at the cap after the first, not after the second")
    }

    @Test(.timeLimit(.minutes(1))) func aSwapThatRanOutOfWaitDoesNotWaitAgainWhenItAsksForAnotherSwap() async throws {
        let clock = SidebarTestManualClock()
        let p = try await panel(clock: clock); defer { p.close() }
        p.isElementFullscreenActiveForTesting = true
        var inner = 0
        p.afterLeavingFigmaFullscreen { p.afterLeavingFigmaFullscreen { inner += 1 } }
        guard await boundedSleeper(clock, FigmaPreviewRefit.fullscreenExitWait) else { return }
        clock.advance(by: FigmaPreviewRefit.fullscreenExitWait)
        await settle()
        #expect(inner == 1, "past the wait, a swap runs without a second wait")
        #expect(!p.figmaRefit.swapPastFullscreen)
    }

    @Test func theSwitchToTheEditorDuringFullScreenSwapsWhenWebKitReportsItOff() async throws {
        let p = try await panel(ready: false); defer { p.close() }
        p.isElementFullscreenActiveForTesting = true
        let preview = p.webView
        #expect(p.switchFigmaPreviewAndEditor(), "the switch is accepted")
        #expect(p.webView === preview, "and has not detached the web view full screen holds")
        #expect(p.showsFigmaPreview)
        p.isElementFullscreenActiveForTesting = false
        p.figmaFullscreenDidChange(active: false)
        #expect(p.webView !== preview, "the swap ran once WebKit reported full screen off")
        #expect(!p.showsFigmaPreview)
    }

    @Test(.timeLimit(.minutes(1))) func theSwitchToTheEditorGoesAheadAtTheCapWithFullScreenStillOn() async throws {
        let clock = SidebarTestManualClock()
        let p = try await panel(clock: clock, ready: false); defer { p.close() }
        p.isElementFullscreenActiveForTesting = true
        let preview = p.webView
        try #require(p.switchFigmaPreviewAndEditor())
        guard await boundedSleeper(clock, FigmaPreviewRefit.fullscreenExitWait) else { return }
        clock.advance(by: FigmaPreviewRefit.fullscreenExitWait)
        await settle()
        #expect(p.webView !== preview)
        #expect(!p.showsFigmaPreview)
    }

    // cmux-rbf: changed on purpose (#cm-143): a close does not ask WebKit to leave full screen (a leave in flight frees WebKit's controller mid-exit); it still drops the waiting swaps.
    @Test func closingAFigmaPreviewDuringFullScreenDoesNotAskWebKitToLeaveAndDropsTheWaitingSwaps() async throws {
        let p = try await panel()
        p.isElementFullscreenActiveForTesting = true
        var ran = 0
        p.figmaRefit.afterFullscreen.append { ran += 1 }
        p.close()
        #expect(p.figmaRefit.leaveRequestsForTesting == 0)
        p.figmaFullscreenDidChange(active: false)
        #expect(ran == 0, "a closed pane swaps nothing")
    }

    @Test func aHiddenFigmaPreviewDuringFullScreenAsksWebKitToLeave() async throws {
        let p = try await panel(); defer { p.close() }
        p.noteWebViewVisibility(false, reason: "fixture.hide")
        #expect(p.figmaRefit.leaveRequestsForTesting == 0, "no full screen, nothing to leave")
        p.noteWebViewVisibility(true, reason: "fixture.show")
        p.isElementFullscreenActiveForTesting = true
        p.noteWebViewVisibility(false, reason: "fixture.hide")
        await settle() // cmux-rbf: changed on purpose (#cm-143): the request goes one main-queue turn after the hide
        #expect(p.figmaRefit.leaveRequestsForTesting == 1)
    }

    // cmux-rbf (#cm-143): closing a workspace hides its panes and closes them in the same turn; a leave sent in that pair crashes WebKit.
    @Test func aHideFollowedByTheCloseInTheSameTurnSendsNoLeaveRequest() async throws {
        let p = try await panel()
        p.isElementFullscreenActiveForTesting = true
        p.noteWebViewVisibility(false, reason: "portal.workspaceRetire")
        p.close()
        await settle()
        await settle()
        #expect(p.figmaRefit.leaveRequestsForTesting == 0, "a closing pane asks WebKit for nothing")
    }

    @Test func aHideAloneAsksWebKitToLeaveOneTurnLater() async throws {
        let p = try await panel(); defer { p.close() }
        p.isElementFullscreenActiveForTesting = true
        p.noteWebViewVisibility(false, reason: "portal.workspaceRetire")
        #expect(p.figmaRefit.leaveRequestsForTesting == 0, "not in the same turn as the hide")
        await settle()
        #expect(p.figmaRefit.leaveRequestsForTesting == 1)
    }

    @Test func aRepeatedHideReportDoesNotAskWebKitToLeaveAgain() async throws {
        let p = try await panel(); defer { p.close() }
        p.isElementFullscreenActiveForTesting = true
        p.noteWebViewVisibility(false, reason: "fixture.hide")
        await settle() // cmux-rbf: changed on purpose (#cm-143): the request goes one main-queue turn after the hide
        try #require(p.figmaRefit.leaveRequestsForTesting == 1)
        p.noteWebViewVisibility(false, reason: "fixture.hide.again")
        await settle()
        #expect(p.figmaRefit.leaveRequestsForTesting == 1, "the pane was already hidden; this report changes nothing")
    }

    // MARK: Esc (cm-73.52): cmux's own full screen, from the window that holds the web view

    @Test func escIsTakenOnlyFromTheWindowHoldingTheWebViewWhileCmuxOwnsAnActiveFullScreen() {
        let held = NSWindow(), other = NSWindow()
        typealias Panel = BrowserPanel
        #expect(Panel.figmaFullscreenTakesEscape(ownsFullscreen: true, isActive: true, eventWindow: held, webViewWindow: held))
        #expect(!Panel.figmaFullscreenTakesEscape(ownsFullscreen: true, isActive: true, eventWindow: other, webViewWindow: held), "another window's Esc")
        #expect(!Panel.figmaFullscreenTakesEscape(ownsFullscreen: true, isActive: true, eventWindow: nil, webViewWindow: held), "an Esc with no window")
        #expect(!Panel.figmaFullscreenTakesEscape(ownsFullscreen: true, isActive: true, eventWindow: held, webViewWindow: nil))
        #expect(!Panel.figmaFullscreenTakesEscape(ownsFullscreen: true, isActive: false, eventWindow: held, webViewWindow: held), "owned, but WebKit isn't full screen yet")
        #expect(!Panel.figmaFullscreenTakesEscape(ownsFullscreen: false, isActive: true, eventWindow: held, webViewWindow: held), "Figma's own full screen, or an ordinary pane's")
    }

    @Test func aPanelTakesEscFromItsOwnWindowOnly() async throws {
        let p = try await panel(); defer { p.close() }
        let held = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        held.contentView?.addSubview(p.webView)
        try #require(p.webView.window === held)
        p.figmaRefit.ownsFullscreen = true
        p.isElementFullscreenActiveForTesting = true
        #expect(p.figmaFullscreenTakesEscape(from: held))
        #expect(!p.figmaFullscreenTakesEscape(from: NSWindow()))
        p.isElementFullscreenActiveForTesting = false
        #expect(!p.figmaFullscreenTakesEscape(from: held))
    }

    // MARK: The mark: three ends, and the echo can't clear it

    @Test func theEchoAndAnUndrawnReportLeaveTheMarkSetAndOnlyADrawnOneClearsIt() async throws {
        let p = try await panel(); defer { p.close() }
        _ = p.refitFigmaPreview(trigger: .cli)
        try await delivered(p)
        report(p, path: nil)
        #expect(p.figmaRefit.inFlight, "the reply and the render carry report: null")
        report(p, drawn: false)
        #expect(p.figmaRefit.inFlight, "the redrawn document's first report is drawn: false")
        report(p, drawn: true)
        #expect(!p.figmaRefit.inFlight, "its canvas has painted")
        #expect(p.refitFigmaPreview(trigger: .key) == .moved, "a later key fits again")
    }

    @Test func aRefusalFromThePageEndsTheMark() async throws {
        let p = try await panel(); defer { p.close() }
        _ = try await p.webView.evaluateJavaScript("window.refuse = true")
        _ = p.refitFigmaPreview(trigger: .cli)
        try await delivered(p)
        for _ in 0..<100 where p.figmaRefit.inFlight { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!p.figmaRefit.inFlight)
    }

    @Test(.timeLimit(.minutes(1))) func fifteenSecondsEndTheMark() async throws {
        let clock = SidebarTestManualClock()
        let p = try await panel(clock: clock); defer { p.close() }
        _ = p.refitFigmaPreview(trigger: .cli)
        try await delivered(p)
        try #require(p.figmaRefit.inFlight, "the mark is set")
        guard await boundedSleeper(clock, .seconds(15)) else { return }
        clock.advance(by: .seconds(14))
        await settle()
        #expect(p.figmaRefit.inFlight, "14 s is inside the limit")
        clock.advance(by: .seconds(1))
        for _ in 0..<100 where p.figmaRefit.inFlight { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!p.figmaRefit.inFlight)
    }

    // MARK: cm-73.11's line

    @Test func theLineStartsWhenRefitIsSentAndEndsOnTheDrawnReport() async throws {
        let p = try await panel(); defer { p.close() }
        #expect(p.figmaLoadBar.editorWait == .notWaiting)
        _ = p.refitFigmaPreview(trigger: .cli)
        if case .waiting = p.figmaLoadBar.editorWait {} else { Issue.record("the line did not start: \(p.figmaLoadBar.editorWait)") }
        report(p, path: nil)
        if case .waiting = p.figmaLoadBar.editorWait {} else { Issue.record("the echo ended the line") }
        report(p, drawn: true)
        #expect(p.figmaLoadBar.editorWait == .notWaiting)
    }

    @Test(.timeLimit(.minutes(1))) func theLineEndsWithTheMarkOnARefusalAndAtFifteenSeconds() async throws {
        let refused = try await panel(); defer { refused.close() }
        _ = try await refused.webView.evaluateJavaScript("window.refuse = true")
        _ = refused.refitFigmaPreview(trigger: .cli)
        for _ in 0..<100 where refused.figmaLoadBar.editorWait != .notWaiting { try await Task.sleep(for: .milliseconds(20)) }
        #expect(refused.figmaLoadBar.editorWait == .notWaiting)

        let clock = SidebarTestManualClock()
        let slow = try await panel(clock: clock); defer { slow.close() }
        _ = slow.refitFigmaPreview(trigger: .cli)
        try #require(slow.figmaRefit.inFlight, "the mark is set")
        guard await boundedSleeper(clock, .seconds(15)) else { return }
        clock.advance(by: .seconds(15))
        for _ in 0..<100 where slow.figmaLoadBar.editorWait != .notWaiting { try await Task.sleep(for: .milliseconds(20)) }
        #expect(slow.figmaLoadBar.editorWait == .notWaiting)
    }

    // MARK: The Log in tell: the interstitial turns notboard 10 s after cmux's page finished

    /// Figma's Log in page: the frame's report is the interstitial, and cmux's page keeps saying so after each finish.
    private func showLogIn(_ p: BrowserPanel) async throws {
        _ = try await p.webView.evaluateJavaScript("""
        window.__cmuxMotion.snapshot=function(){return {state:'still',report:{path:'/embed/interstitial',player:false,drawn:false}}}; 0
        """)
        report(p, path: "/embed/interstitial", drawn: false)
    }

    @Test(.timeLimit(.minutes(1))) func theInterstitialAnswersLoadingUntilTenSecondsAfterCmuxsPageFinishedThenNotABoard() async throws {
        let clock = SidebarTestManualClock()
        let p = try await panel(clock: clock); defer { p.close() }
        try await showLogIn(p)
        p.navigationDelegate?.didFinish?(p.webView, nil)
        guard await boundedSleeper(clock, .seconds(10)) else { return }
        clock.advance(by: .milliseconds(9_900))
        await settle()
        #expect(p.refitFigmaPreview(trigger: .cli) == .fitsItself(.loading), "9.9 s: still a load")
        #expect(p.refitFigmaPreview(trigger: .key) == .fitsItself(.loading))
        clock.advance(by: .milliseconds(100))
        for _ in 0..<100 where p.figmaRefit.sinceFinish != Refit.interstitialSettle { try await Task.sleep(for: .milliseconds(20)) }
        #expect(p.refitFigmaPreview(trigger: .cli) == .refused(.notboard), "10 s: Figma's Log in page")
        #expect(p.refitFigmaPreview(trigger: .key) == .refused(.notboard), "⇧1 moves nothing")
        #expect(p.refitFigmaPreview(trigger: .size) == .refused(.notboard), "a size change moves nothing")
        await settle()
        #expect(await refitCount(p) == 0, "nothing was sent")
        p.navigationDelegate?.didFinish?(p.webView, nil) // the next load finishing starts the 10 s again
        await settle()
        #expect(p.refitFigmaPreview(trigger: .cli) == .fitsItself(.loading), "a new finish restarts the time")
    }

    @Test func aLoadStartingForgetsTheFinishSoTheInterstitialIsLoadingAgain() async throws {
        let clock = SidebarTestManualClock()
        let p = try await panel(clock: clock); defer { p.close() }
        try await showLogIn(p)
        p.navigationDelegate?.didFinish?(p.webView, nil)
        guard await boundedSleeper(clock, .seconds(10)) else { return }
        clock.advance(by: .seconds(11))
        for _ in 0..<100 where p.figmaRefit.sinceFinish != Refit.interstitialSettle { try await Task.sleep(for: .milliseconds(20)) }
        try #require(p.refitFigmaPreview(trigger: .cli) == .refused(.notboard), "stood 11 s")
        p.navigationDelegate?.didStartProvisionalNavigation?(p.webView, nil)
        p.isMainFrameProvisionalNavigationActive = false // only the finish time is under test, not the load flag
        clock.advance(by: .seconds(30))
        await settle()
        #expect(p.refitFigmaPreview(trigger: .cli) == .fitsItself(.loading), "a new load has not finished: no time counts")
    }

    // MARK: The remembered size

    // MARK: The remembered size follows the frame document (fix round 3)

    private func resize(_ p: BrowserPanel, _ width: CGFloat) {
        p.webView.frame = NSRect(origin: .zero, size: CGSize(width: width, height: 600))
        p.figmaRefit.sizeCheck.cancel() // the check is not what these tests are about
    }

    @Test func aFinishedLoadSchedulesTheHalfSecondCheckAndWritesNoSize() async throws {
        let p = try await panel(ready: false); defer { p.close() }
        p.noteWebViewVisibility(true, reason: "fixture")
        p.webView.frame = NSRect(origin: .zero, size: Self.size)
        p.figmaRefit.sizeCheck.cancel()
        p.navigationDelegate?.didFinish?(p.webView, nil)
        #expect(p.figmaRefit.sizeCheck.isScheduled, "a restore of a cached page finishes at a size its frame did not fit at")
        #expect(p.rememberedFigmaSize == nil, "finishing says nothing about what Figma fitted")
    }

    @Test func theRedrawnDocumentRemembersTheSizeAtItsFirstDrawnReportNotWhenTheRefitWasSent() async throws {
        let p = try await panel(); defer { p.close() }
        let s2 = CGSize(width: 700, height: 600)
        resize(p, 700)
        #expect(p.refitFigmaPreview(trigger: .size) == .moved)
        try await delivered(p)
        #expect(p.rememberedFigmaSize == nil, "sending remembers nothing: the new document has not drawn")
        report(p, path: nil) // the echo
        report(p, drawn: false, doc: 2)
        #expect(p.rememberedFigmaSize == nil, "an undrawn report remembers nothing")
        report(p, drawn: true, doc: 2)
        #expect(p.rememberedFigmaSize == s2)
        #expect(p.refitFigmaPreview(trigger: .size) == .fitsItself(.same))
    }

    @Test func aSizeChangeDuringARedrawIsTheSizeTheRedrawnDocumentFitsAtSoThePresentableAtItIsSame() async throws {
        let p = try await panel(); defer { p.close() }
        try #require(p.rememberedFigmaSize == Self.size, "S1 is remembered for document 1")
        #expect(p.refitFigmaPreview(trigger: .key) == .moved)
        try await delivered(p)
        resize(p, 700)
        #expect(p.refitFigmaPreview(trigger: .size) == .fitsItself(.redrawing), "the check lands while the redraw runs")
        report(p, path: nil) // the echo
        report(p, drawn: true, doc: 2) // Figma has drawn the new document, fitted at S2
        #expect(p.refitFigmaPreview(trigger: .size) == .fitsItself(.same), "S2 is what Figma fitted at; no second redraw")
        await settle()
        #expect(await refitCount(p) == 1)
    }

    @Test func aSizeChangeDuringTheLoadIsTheSizeTheFirstDrawnReportFitsAt() async throws {
        let p = try await panel(ready: false); defer { p.close() }
        let s2 = CGSize(width: 700, height: 600)
        p.noteWebViewVisibility(true, reason: "fixture")
        p.webView.frame = NSRect(origin: .zero, size: Self.size)
        p.navigationDelegate?.didFinish?(p.webView, nil)
        resize(p, 700)
        #expect(p.refitFigmaPreview(trigger: .size) == .fitsItself(.loading), "no report yet")
        report(p, drawn: false, doc: 5)
        #expect(p.rememberedFigmaSize == nil, "an undrawn report remembers nothing")
        report(p, drawn: true, doc: 5)
        #expect(p.rememberedFigmaSize == s2)
        #expect(p.refitFigmaPreview(trigger: .size) == .fitsItself(.same))
        await settle()
        #expect(await refitCount(p) == 0)
    }

    @Test func aRepeatDrawnReportOfAKnownDocumentDoesNotOverwriteSoARealResizeStillMoves() async throws {
        let p = try await panel(); defer { p.close() }
        let s3 = CGSize(width: 650, height: 600)
        _ = p.refitFigmaPreview(trigger: .key)
        try await delivered(p)
        resize(p, 700)
        report(p, path: nil)
        report(p, drawn: true, doc: 2)
        try #require(p.rememberedFigmaSize == CGSize(width: 700, height: 600))
        resize(p, 650)
        report(p, drawn: true, doc: 2) // the page re-reports on every render
        #expect(p.rememberedFigmaSize == CGSize(width: 700, height: 600), "a repeat remembers nothing")
        #expect(p.refitFigmaPreview(trigger: .size) == .moved, "S3 differs from the S2 Figma fitted at")
        try await delivered(p, count: 2)
        report(p, path: nil)
        report(p, drawn: true, doc: 3)
        #expect(p.rememberedFigmaSize == s3)
    }

    @Test func aRestoredCachedPageWhoseDocumentFitAtAnotherSizeMovesAndKeepsItsOwnSize() async throws {
        let p = try await panel(); defer { p.close() }
        // Document 1 (page A) fitted at 800; a re-fit at 500 made document 2 (what the web view shows now).
        resize(p, 500)
        _ = p.refitFigmaPreview(trigger: .size)
        try await delivered(p)
        report(p, path: nil)
        report(p, drawn: true, doc: 2)
        try #require(p.rememberedFigmaSize == CGSize(width: 500, height: 600))
        // Back: WebKit restores A at 500; cmux's page posts A's kept report.
        report(p, drawn: true, doc: 1)
        #expect(p.rememberedFigmaSize == Self.size, "A keeps the 800 it was fitted at")
        #expect(p.refitFigmaPreview(trigger: .size) == .moved, "A's frame fits 800, the pane is 500")
        try await delivered(p, count: 2)
        await settle()
        #expect(await refitCount(p) == 2, "one move for the first resize, one for the restore")
    }

    @Test func aReportClearedAndThenSentAgainWithTheOldDocumentAtANewSizeStillMoves() async throws {
        let p = try await panel(); defer { p.close() }
        resize(p, 500) // while the editor showed, say
        report(p, path: nil) // the swap back clears the report
        report(p, drawn: true, doc: 1) // the kept preview's own report comes back
        #expect(p.rememberedFigmaSize == Self.size, "not overwritten by the report coming back")
        #expect(p.refitFigmaPreview(trigger: .size) == .moved)
    }

    @Test func aReportClearedAndSentAgainAtTheSameSizeKeepsTheUsersZoom() async throws {
        let p = try await panel(); defer { p.close() }
        report(p, path: nil)
        report(p, drawn: true, doc: 1)
        #expect(p.refitFigmaPreview(trigger: .size) == .fitsItself(.same))
        await settle()
        #expect(await refitCount(p) == 0)
    }

    @Test func theWebViewKeepsTheLastEightDocumentsSizes() async throws {
        let p = try await panel(ready: false); defer { p.close() }
        p.noteWebViewVisibility(true, reason: "fixture")
        for doc in 1...9 {
            p.webView.frame = NSRect(origin: .zero, size: CGSize(width: 100 + CGFloat(doc), height: 600))
            report(p, drawn: true, doc: Double(doc))
        }
        #expect(p.webView.figmaRefitSizes.entries.count == 8)
        #expect(p.webView.figmaRefitSizes.size(forDoc: 1) == nil, "the oldest went first")
        #expect(p.webView.figmaRefitSizes.size(forDoc: 9) == CGSize(width: 109, height: 600))
    }

    // MARK: F2: the line ends on the wait that started it

    @Test(.timeLimit(.minutes(1))) func aRefitEndingAfterTheSwitchToTheEditorEndsThePreviewsLineAndLeavesTheEditorsWaitRunning() async throws {
        let clock = SidebarTestManualClock()
        let p = try await panel(clock: clock); defer { p.close() }
        _ = p.refitFigmaPreview(trigger: .cli)
        try await delivered(p)
        let previewBar = p.figmaLoadBar
        guard case .waiting(_, let lineID) = previewBar.editorWait else { Issue.record("the line did not start"); return }
        try #require(p.switchFigmaPreviewAndEditor())
        try #require(p.figmaLoadBar !== previewBar, "the editor has its own bar")
        p.webView.navigationDelegate = nil // the editor's real load starts, fails or finishes on its own time and would reset the bar mid-test
        p.figmaLoadBar.inPlaceEditorOpened() // the editor's own wait, as the move to the editor starts one
        guard case .waiting(_, let editorID) = p.figmaLoadBar.editorWait else {
            Issue.record("the editor's wait did not start: \(p.figmaLoadBar.editorWait)"); return
        }
        let editorBar = p.figmaLoadBar
        try #require(editorID == lineID, "both bars count from 1: the ids collide, which is what makes the wrong bar matter")
        guard await boundedSleeper(clock, .seconds(15)) else { return }
        clock.advance(by: .seconds(15)) // the re-fit's limit ends it
        for _ in 0..<100 where p.figmaRefit.inFlight { try await Task.sleep(for: .milliseconds(20)) }
        try #require(!p.figmaRefit.inFlight, "the re-fit ended")
        #expect(previewBar.editorWait == .notWaiting, "the line that started with the re-fit ended with it")
        if case .waiting(_, let still) = editorBar.editorWait { #expect(still == editorID) } else {
            Issue.record("the re-fit's end ended the editor's wait: \(editorBar.editorWait)")
        }
    }

#if DEBUG
    // MARK: F3: the debug lines, as `16_expected-results.md` and Scenario 261 write them

    private func debugLines(for p: BrowserPanel) -> [String] {
        // The tail only: a whole test run's lines make the file large, and this is read every 20 ms.
        guard let handle = FileHandle(forReadingAtPath: CMUXDebugLog.DebugEventLog.currentLogPath()) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        return text.split(separator: "\n").map(String.init).filter { $0.contains("surface=\(p.id.uuidString)") }
    }
    private func awaitLine(_ p: BrowserPanel, matching pattern: String) async throws -> String {
        let regex = try NSRegularExpression(pattern: pattern)
        for _ in 0..<150 {
            for line in debugLines(for: p) where regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil { return line }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "FigmaRefitPanelTests", code: 2, userInfo: [NSLocalizedDescriptionKey:
            "no log line matched /\(pattern)/ within 3 seconds; lines for this surface: \(debugLines(for: p))"])
    }

    @Test(.timeLimit(.minutes(1))) func theDebugLinesNameSizesTriggerAndWhyTheWayTheBriefWritesThem() async throws {
        let clock = SidebarTestManualClock()
        let p = try await panel(clock: clock); defer { p.close() }
        let id = p.id.uuidString
        p.webView.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
        _ = try await awaitLine(p, matching: "figma\\.refit\\.size surface=\(id) now=700x600")
        try #require(p.figmaRefit.sizeCheck.isScheduled, "a check is waiting")
        guard await boundedSleeper(clock, .milliseconds(500)) else { return }
        clock.advance(by: .milliseconds(500))
        _ = try await awaitLine(p, matching:
            "figma\\.refit surface=\(id) trigger=size loaded=800x600 now=700x600 action=move via=frame reason=differs drawn=1 path=")
        p.webView.frame = NSRect(x: 0, y: 0, width: 650, height: 600)
        await settle()
        p.navigationDelegate?.didStartProvisionalNavigation?(p.webView, nil)
        _ = try await awaitLine(p, matching: "figma\\.refit\\.cancel surface=\(id) reason=load$")
    }
#endif

    // MARK: Scenario 258: the size watch, on an injected clock

    @Test(.timeLimit(.minutes(1))) func fiveChangesATenthOfASecondApartMakeOneCheckHalfASecondAfterTheLast() async throws {
        let clock = SidebarTestManualClock()
        let p = try await panel(clock: clock); defer { p.close() }
        for (index, width) in [790.0, 780, 770, 760, 750].enumerated() {
            if index > 0 { clock.advance(by: .milliseconds(100)) }
            p.webView.frame = NSRect(x: 0, y: 0, width: width, height: 600)
            await settle()
        }
        try #require(p.figmaRefit.sizeCheck.isScheduled, "a check is waiting")
        guard await boundedSleeper(clock, .milliseconds(500)) else { return }
        clock.advance(by: .milliseconds(499))
        await settle()
        #expect(await refitCount(p) == 0, "499 ms after the last change is too soon")
        clock.advance(by: .milliseconds(1))
        try await delivered(p)
        await settle()
        #expect(await refitCount(p) == 1, "one check, one re-fit")
    }

    @Test(.timeLimit(.minutes(1))) func aChangeThatComesBackWithinTheHalfSecondMovesNothing() async throws {
        let clock = SidebarTestManualClock()
        let p = try await panel(clock: clock); defer { p.close() }
        p.webView.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
        await settle()
        p.webView.frame = NSRect(origin: .zero, size: Self.size)
        await settle()
        try #require(p.figmaRefit.sizeCheck.isScheduled, "a check is waiting")
        guard await boundedSleeper(clock, .milliseconds(500)) else { return }
        clock.advance(by: .milliseconds(500))
        await settle()
        #expect(await refitCount(p) == 0)
    }

    @Test(.timeLimit(.minutes(1))) func aLoadOfCmuxsPageStartingInTheWaitDropsTheCheck() async throws {
        let clock = SidebarTestManualClock()
        let p = try await panel(clock: clock); defer { p.close() }
        p.webView.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
        await settle()
        try #require(p.figmaRefit.sizeCheck.isScheduled, "a check is waiting")
        p.navigationDelegate?.didStartProvisionalNavigation?(p.webView, nil)
        try #require(!p.figmaRefit.sizeCheck.isScheduled, "the load dropped it")
        await clock.waitUntilIdle()
        clock.advance(by: .milliseconds(500))
        await settle()
        #expect(await refitCount(p) == 0)
    }

    @Test func thePanelGoingAwayInTheWaitDropsTheCheck() async throws {
        let clock = SidebarTestManualClock()
        let p = try await panel(clock: clock)
        p.webView.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
        await settle()
        #expect(p.figmaRefit.sizeCheck.isScheduled)
        p.close()
        #expect(!p.figmaRefit.sizeCheck.isScheduled)
    }

    @Test(.timeLimit(.minutes(1))) func aHiddenPaneSchedulesNothingForAFrameChangeAndAPaneShowingAgainStartsTheHalfSecond() async throws {
        let clock = SidebarTestManualClock()
        let p = try await panel(clock: clock); defer { p.close() }
        p.noteWebViewVisibility(false, reason: "fixture leave")
        p.webView.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
        await settle()
        #expect(!p.figmaRefit.sizeCheck.isScheduled, "a hidden pane keeps its frame")
        p.noteWebViewVisibility(true, reason: "fixture show")
        NotificationCenter.default.post(name: .browserPortalDidBecomePresentable, object: p.webView)
        try #require(p.figmaRefit.sizeCheck.isScheduled, "it is compared when it shows again")
        try #require(p.figmaRefit.sizeCheck.isScheduled, "a check is waiting")
        guard await boundedSleeper(clock, .milliseconds(500)) else { return }
        clock.advance(by: .milliseconds(500))
        try await delivered(p)
    }

    @Test func theEditorSchedulesNothing() async throws {
        let clock = SidebarTestManualClock()
        let p = try await panel(clock: clock); defer { p.close() }
        try #require(p.switchFigmaPreviewAndEditor())
        p.webView.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
        await settle()
        #expect(!p.figmaRefit.sizeCheck.isScheduled)
    }

    @Test(.timeLimit(.minutes(1))) func theWatchFollowsTheSwapBackToTheKeptPreview() async throws {
        let clock = SidebarTestManualClock()
        let p = try await panel(clock: clock); defer { p.close() }
        let preview = p.webView
        try #require(p.switchFigmaPreviewAndEditor())
        try #require(p.switchFigmaPreviewAndEditor())
        try #require(p.webView === preview, "the kept preview came back")
        p.noteWebViewVisibility(true, reason: "fixture")
        p.webView.frame = NSRect(x: 0, y: 0, width: 650, height: 600)
        await settle()
        #expect(p.figmaRefit.sizeCheck.isScheduled, "the observer was bound again with the page")
    }

    @Test func theHalfSecondAndTheOnePointAreTheDesignedConstants() {
        #expect(Refit.settle == .milliseconds(500))
        #expect(Refit.sizeThreshold == 1)
        #expect(Refit.recheckThreshold == 2) // cmux-rbf (#cm-73.52)
        #expect(Refit.inFlightSeconds == 15)
        #expect(Refit.interstitialSettle == .seconds(10))
    }
}

/// Set from the unbounded wait's task, read by the polling loop; both run on the main actor.
private final class SleeperArrived: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// `waitUntilSleeping(for:)` with a real-time bound. A change that moves or removes the sleeper the test waits on
/// would otherwise hang until the 60 s limit and restart the test host, which hides the failure. Returns false after
/// recording an issue; the caller returns.
@MainActor
private func boundedSleeper(_ clock: SidebarTestManualClock, _ duration: Duration) async -> Bool {
    let arrived = SleeperArrived()
    let waiter = Task { await clock.waitUntilSleeping(for: duration); arrived.set() }
    for _ in 0..<100 {
        if arrived.isSet { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    clock.releasePendingSleepWaitersForTesting()
    waiter.cancel()
    Issue.record("no sleeper at +\(duration) within 2 s")
    return false
}
