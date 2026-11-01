// cmux-rbf (#cm-73.44): Scenario 300's last row. `figma.goto` with `purpose: fit` on a preview is the panel's re-fit,
// answered at once from what the panel holds, with no script evaluated for a skip and no reload of cmux's page.
import AppKit
import Bonsplit
import CmuxBrowser
import CMUXDebugLog
import Foundation
import Testing
import WebKit
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("FigmaFitRoute", .serialized)
struct FigmaFitRouteTests {
    private static let document = URL(string: "https://www.figma.com/design/KEY/slug")!

    private struct Fixture {
        let manager: TabManager
        let workspace: Workspace
        let figma: BrowserPanel
        let windowID: UUID
        let delegate: AppDelegate
        let priorDelegate: AppDelegate?
        let priorManager: TabManager?
    }

    /// A preview pane whose page is a controlled document that records the commands cmux sends it.
    private func fixture(node: String = "12-2") async throws -> Fixture {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let terminal = try #require(workspace.focusedPanelId)
        let preview = try FigmaPaneURL.destination(for: Self.document, node: node).url
        let figma = try #require(workspace.newBrowserSplit(
            from: terminal, orientation: .horizontal, url: nil, focus: false,
            chromeVisibility: BrowserChromeVisibility(omnibarVisible: false)
        ))
        workspace.focusPanel(terminal)
        let priorDelegate = AppDelegate.shared
        let priorManager = TerminalController.shared.tabManager
        let delegate = AppDelegate()
        AppDelegate.shared = delegate
        delegate.tabManager = manager
        let windowID = delegate.registerMainWindowContextForTesting(tabManager: manager)
        TerminalController.shared.setActiveTabManager(manager)

        // The pane starts blank, so no real load of cmux's page can arrive later and replace the controlled document.
        try await waitUntilQuiet(figma)
        figma.publishObservedDocumentURL(preview)
        figma.installFigmaMotionBridge(on: figma.webView, address: preview)
        let previous = figma.webView.navigationDelegate
        figma.webView.navigationDelegate = nil
        _ = figma.webView.loadSimulatedRequest(URLRequest(url: preview), responseHTML: "<html><body>fixture</body></html>")
        var loaded = false
        for _ in 0..<150 {
            if !figma.webView.isLoading, figma.webView.url == preview,
               (try? await figma.webView.evaluateJavaScript("document.readyState")) as? String == "complete" { loaded = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        figma.webView.navigationDelegate = previous
        try #require(loaded, "the fixture document did not load within 3 seconds")
        figma.publishObservedDocumentURL(preview)
        _ = try await figma.webView.evaluateJavaScript("""
        window.commands=[]; window.__loadMarker='same-document';
        window.nodes=[]; window.__cmuxMotion={command:function(a,n){commands.push(a);nodes.push(n || null); return {state:'still',report:null}}, snapshot:function(){return {state:'still',report:null}}};
        """)
        try await waitUntilQuiet(figma)
        let marker = try await figma.webView.evaluateJavaScript("window.__loadMarker") as? String
        try #require(marker == "same-document", "the controlled document is in place before any fit runs; saw \(String(describing: marker)) at \(String(describing: figma.webView.url))")
        figma.noteWebViewVisibility(true, reason: "fixture")
        figma.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        figma.receiveFigmaMotionMessage(
            from: figma.webView, mainFrame: true, address: figma.currentURL,
            body: ["state": "still", "report": ["path": "/design/KEY/slug", "player": false, "drawn": true, "doc": 1.0] as [String: Any]]
        ) // the first drawn report of document 1 writes the size it was fitted at
        return Fixture(
            manager: manager, workspace: workspace, figma: figma, windowID: windowID,
            delegate: delegate, priorDelegate: priorDelegate, priorManager: priorManager
        )
    }

    /// Not loading for 10 polls in a row (200 ms), so a late navigation can't land after the controlled document.
    private func waitUntilQuiet(_ panel: BrowserPanel) async throws {
        var quiet = 0
        for _ in 0..<250 {
            quiet = panel.webView.isLoading ? 0 : quiet + 1
            if quiet >= 10 { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "FigmaFitRouteTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "the pane kept loading for 5 seconds"])
    }

    private func tearDown(_ f: Fixture) {
        TerminalController.shared.setActiveTabManager(f.priorManager)
        f.delegate.unregisterMainWindowContextForTesting(windowId: f.windowID)
        f.delegate.tabManager = nil
        AppDelegate.shared = f.priorDelegate
        f.workspace.teardownAllPanels()
    }

    private func report(_ f: Fixture, path: String?, drawn: Bool = true) {
        var body: [String: Any] = ["state": "still"]
        body["report"] = path.map { ["path": $0, "player": false, "drawn": drawn, "doc": 1.0] as [String: Any] } ?? NSNull()
        f.figma.receiveFigmaMotionMessage(from: f.figma.webView, mainFrame: true, address: f.figma.currentURL, body: body)
    }

    /// `figma.goto` over the real socket handler, off the main actor so its `v2MainSync` can run.
    private func fit(_ f: Fixture, purpose: String = "fit", node: String? = nil) async throws -> [String: Any] {
        var params: [String: Any] = [
            "window_id": f.windowID.uuidString, "workspace_id": f.workspace.id.uuidString,
            "surface_id": f.figma.id.uuidString,
            "node": f.figma.currentURL.flatMap { FigmaPaneURL.node(fromPaneURL: $0) } ?? "12-2", "purpose": purpose
        ]
        if let node {
            if purpose == "fit" { params["fit_node"] = node }
            else { params["node"] = node }
        }
        let request: [String: Any] = ["id": 1, "method": "figma.goto", "params": params]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let response = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: TerminalController.shared.handleSocketLine(line))
            }
        }
        return try #require(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any], "\(response)")
    }

    /// Throws when the page can't answer, so "nothing was sent" can't pass on a page that is gone.
    private func commands(_ f: Fixture) async throws -> [String] {
        try #require(try await f.figma.webView.evaluateJavaScript("commands") as? [String], "the controlled document answers")
    }
    /// Once this returns, any script an earlier call queued to the page has run.
    private func flush(_ f: Fixture) async throws { _ = try await f.figma.webView.evaluateJavaScript("1") }
    private func settle() async { for _ in 0..<5 { await Task.yield() } }
    /// Waits for what the page was sent, not for a time.
    private func waitForCommands(_ f: Fixture, count: Int) async throws {
        for _ in 0..<150 where try await commands(f).count < count { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func fitOnADrawnPreviewRedrawsInPlaceAndAnswersOKWithoutLeavingThePage() async throws {
        let f = try await fixture(); defer { tearDown(f) }
        report(f, path: "/design/KEY/slug")
        let address = f.figma.currentURL
        let view = f.figma.webView
        let reply = try await fit(f)
        try #require(reply["ok"] as? Bool == true, "\(reply)")
        #expect((reply["result"] as? [String: Any])?["side"] as? String == "preview")
        try await waitForCommands(f, count: 1)
        let seen = try await commands(f)
        let probe = try? await f.figma.webView.evaluateJavaScript("[location.href, document.readyState, String(window.__loadMarker), String(typeof window.__cmuxMotion)].join(' | ')")
        #expect(seen == ["refit"], "the redraw is the page's `refit` command; saw \(seen); page: \(String(describing: probe)); loading \(f.figma.webView.isLoading)")
        #expect(f.figma.figmaRefit.inFlight)
        #expect(f.figma.webView === view && f.figma.currentURL == address, "no navigation, no new web view")
        let marker = try await f.figma.webView.evaluateJavaScript("window.__loadMarker") as? String
        #expect(marker == "same-document", "cmux's page was not reloaded")
    }

    @Test func anotherNodeUsesTheRefitLifecycleWithANodeAndSameNodeUsesPlainRefit() async throws {
        for node in ["12:2", "16:2"] {
            let f = try await fixture(); defer { tearDown(f) }
            let reply = try await fit(f, node: node)
            #expect(reply["ok"] as? Bool == true)
            try await waitForCommands(f, count: 1)
            #expect(try await commands(f) == ["refit"])
            let seen = try await f.figma.webView.evaluateJavaScript("nodes[0] === null ? 'redraw' : nodes[0]") as? String
            #expect(seen == (node == "12:2" ? "redraw" : "16-2"))
            #expect(f.figma.figmaRefit.inFlight)
            if case .waiting = f.figma.figmaLoadBar.editorWait {} else { Issue.record("the fit loading line did not start") }
            report(f, path: "/design/KEY/slug", drawn: false)
            #expect(f.figma.figmaRefit.inFlight)
            if case .waiting = f.figma.figmaLoadBar.editorWait {} else { Issue.record("an undrawn report ended the loading line") }
            report(f, path: "/design/KEY/slug")
            #expect(!f.figma.figmaRefit.inFlight)
            #expect(f.figma.figmaLoadBar.editorWait == .notWaiting)
        }
    }

    @Test func plainFitOnAnInstanceLayerStillRedrawsWithoutStrictNodeValidation() async throws {
        let f = try await fixture(node: "I123-45;67-89"); defer { tearDown(f) }
        let address = f.figma.currentURL
        let reply = try await fit(f)
        try #require(reply["ok"] as? Bool == true, "plain fit must redraw the existing instance layer: \(reply)")
        try await waitForCommands(f, count: 1)
        #expect(try await commands(f) == ["refit"])
        #expect(try await f.figma.webView.evaluateJavaScript("nodes[0] === null") as? Bool == true)
        #expect(f.figma.currentURL == address && f.figma.figmaRefit.inFlight)
    }

    @Test func socketRefusesInvalidFitNodesBeforeAnyScript() async throws {
        let f = try await fixture(); defer { tearDown(f) }
        for node in ["1-2&x=1", "1-2\n", "bad"] {
            let reply = try await fit(f, node: node)
            #expect(reply["ok"] as? Bool == false)
            #expect((reply["error"] as? [String: Any])?["code"] as? String == "invalid_params")
        }
        try await flush(f)
        #expect(try await commands(f).isEmpty)
    }

    @Test func expectedAddressRewriteKeepsTheMoveInFlightAndPublishesTheNode() async throws {
        let f = try await fixture(); defer { tearDown(f) }
        _ = try await f.figma.webView.evaluateJavaScript("""
        window.__cmuxMotion.command=function(a,n){commands.push(a); if(n){var u=new URL(location.href),e=new URL(u.searchParams.get('embed'));e.searchParams.set('node-id',n);u.searchParams.set('embed',e.href);history.replaceState(history.state,'',u.href)};return {state:'still',report:null}}; true;
        """)
        _ = try await fit(f, node: "16-2")
        try await waitForCommands(f, count: 1)
        try await flush(f)
        #expect(FigmaPaneURL.node(fromPaneURL: try #require(f.figma.currentURL)) == "16-2")
        #expect(f.figma.figmaRefit.inFlight, "replaceState is the expected completion, not a refusal")
        #expect(try await f.figma.webView.evaluateJavaScript("window.__loadMarker") as? String == "same-document")
    }

#if DEBUG
    @Test func nodeMoveDebugLineNamesTheActionAndNode() async throws {
        let f = try await fixture(); defer { tearDown(f) }
        _ = try await fit(f, node: "16:2")
        let token = "figma.refit surface=\(f.figma.id.uuidString) "
        var found = false
        for _ in 0..<100 {
            let log = (try? String(contentsOfFile: CMUXDebugLog.DebugEventLog.currentLogPath(), encoding: .utf8)) ?? ""
            found = log.components(separatedBy: "\n").contains { $0.contains(token) && $0.contains("action=goto") && $0.contains("node=16-2") }
            if found { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(found, "the Debug move line identifies its node")
    }
#endif

    @Test func fitWhileTheRedrawRunsAnswersOKAndSendsNothingMore() async throws {
        let f = try await fixture(); defer { tearDown(f) }
        report(f, path: "/design/KEY/slug")
        _ = try await fit(f)
        try await waitForCommands(f, count: 1)
        report(f, path: nil) // the echo of `refit` carries no report
        let address = f.figma.currentURL
        let second = try await fit(f, node: "16-2")
        #expect(second["ok"] as? Bool == true, "redrawing is OK to the agent: \(second)")
        await settle()
        try await flush(f)
        #expect(try await commands(f).filter { $0 == "refit" }.count == 1)
        #expect(f.figma.currentURL == address)
    }

    @Test func fitBeforeFigmaHasDrawnAnswersOKAndIsNeverTheLogInRefusal() async throws {
        let f = try await fixture(); defer { tearDown(f) }
        for path in [nil, "/design/KEY/slug"] as [String?] {
            report(f, path: path, drawn: false)
            let address = f.figma.currentURL
            let reply = try await fit(f, node: "16-2")
            #expect(reply["ok"] as? Bool == true, "\(String(describing: path)): \(reply)")
            #expect(f.figma.currentURL == address)
        }
        await settle()
        try await flush(f)
        #expect(try await commands(f).isEmpty, "a load or an undrawn board fits itself, so nothing is sent")
    }

    @Test func fitOnANonBoardIsInvalidStateWithTheReasonAndSendsNothing() async throws {
        let f = try await fixture(); defer { tearDown(f) }
        report(f, path: "/board/KEY/slug")
        let address = f.figma.currentURL
        let reply = try await fit(f, node: "16-2")
        try #require(reply["ok"] as? Bool == false, "\(reply)")
        let error = try #require(reply["error"] as? [String: Any])
        #expect(error["code"] as? String == "invalid_state")
        #expect((error["data"] as? [String: Any])?["reason"] as? String == FigmaFit.notBoardReason)
        await settle()
        try await flush(f)
        #expect(try await commands(f).isEmpty, "no script was evaluated")
        #expect(!f.figma.figmaRefit.inFlight)
        #expect(f.figma.currentURL == address)
    }

    @Test func fitOnTheEditorKeepsTodaysPathAndSendsNoRefit() async throws {
        let f = try await fixture(); defer { tearDown(f) }
        report(f, path: "/design/KEY/slug")
        try #require(f.workspace.switchFigmaPreviewAndEditor())
        let reply = try await fit(f, node: "16-2")
        #expect(reply["ok"] as? Bool == true, "\(reply)")
        #expect((reply["result"] as? [String: Any])?["side"] as? String == "editor")
        #expect(!f.figma.figmaRefit.inFlight, "the CLI presses ⇧1 in the editor; the app redraws nothing")
    }

    @Test func pointingStillNavigatesAndIsNotARefit() async throws {
        let f = try await fixture(); defer { tearDown(f) }
        report(f, path: "/design/KEY/slug")
        let reply = try await fit(f, purpose: "point")
        #expect(reply["ok"] as? Bool == true, "\(reply)")
        await settle()
        #expect(!f.figma.figmaRefit.inFlight, "only `fit` on a preview is the re-fit")
    }
}
