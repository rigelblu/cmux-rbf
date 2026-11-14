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
