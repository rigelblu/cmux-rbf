import AppKit
import CmuxBrowser
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// cmux-rbf (#cm-73.39): the read view's page moves from a `file://` page in
/// Application Support to `cmux-figma://cmux/figma-embed.html`, served from
/// memory. Under the `file://` page, macOS 27.2's WebKit gave Figma's frame no
/// cookies after a granted storage-access request, so a file that needs
/// sign-in looped on Log in. Addresses an older build saved become the new one
/// where they come in.
@MainActor
@Suite("FigmaPreviewPageScheme", .serialized)
struct FigmaPreviewPageSchemeTests {
    private let newPage = URL(string: "cmux-figma://cmux/figma-embed.html")!
    private let legacyPage = FigmaPaneURL.wrapperFileURL()
    private let editor = URL(string: "https://www.figma.com/design/KEY/screen?node-id=81-3")!

    private func address(_ page: URL, node: String, motion: Bool = false) -> URL {
        let embedded = URL(string: "https://embed.figma.com/design/KEY/screen?embed-host=cmux&footer=0&page-selector=0&node-id=\(node)")!
        return FigmaPaneURL.wrapperURL(page, embedding: embedded, motion: motion)
    }

    private func query(_ url: URL?) -> String? {
        url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedQuery }
    }

    private func snapshot(
        current: String?,
        back: [String]? = nil,
        forward: [String]? = nil,
        figmaPages: SessionFigmaPagesSnapshot? = nil
    ) -> SessionBrowserPanelSnapshot {
        SessionBrowserPanelSnapshot(
            urlString: current, profileID: nil, shouldRenderWebView: false,
            pageZoom: 1.0, developerToolsVisible: false,
            chromeVisibility: .hidden, omnibarVisible: false,
            backHistoryURLStrings: back, forwardHistoryURLStrings: forward,
            figmaPages: figmaPages
        )
    }

    private func restoredPanel(_ snapshot: SessionBrowserPanelSnapshot) -> BrowserPanel {
        let panel = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false, websiteDataStore: .nonPersistent())
        panel.restoreSessionSnapshot(snapshot)
        return panel
    }

    // MARK: - The recogniser

    @Test("The new page is cmux's page, by scheme, host and path, whatever its query")
    func newPageIsRecognised() {
        #expect(FigmaPaneURL.isWrapperPage(address(newPage, node: "12-2"), wrapper: newPage))
        #expect(FigmaPaneURL.isWrapperPage(address(newPage, node: "12-2", motion: true), wrapper: newPage))
        #expect(FigmaPaneURL.node(fromPaneURL: address(newPage, node: "12-2"), wrapper: newPage) == "12-2")
        #expect(FigmaPaneURL.fileKey(fromPaneURL: address(newPage, node: "12-2"), wrapper: newPage) == "KEY")
    }

    @Test("The legacy Application Support page is still cmux's page, whatever page is passed in")
    func legacyPageIsRecognised() {
        let legacy = address(legacyPage, node: "12-2")
        #expect(FigmaPaneURL.isWrapperPage(legacy, wrapper: newPage))
        #expect(FigmaPaneURL.node(fromPaneURL: legacy, wrapper: newPage) == "12-2")
    }

    @Test("A page that differs in scheme, host, port, user or path is not cmux's page")
    func lookalikesAreNotRecognised() {
        for lookalike in [
            "cmux-figma://other/figma-embed.html?embed=x",
            "cmux-figma://cmux/other.html?embed=x",
            "cmux-figma://cmux:8080/figma-embed.html?embed=x",
            "cmux-figma://user@cmux/figma-embed.html?embed=x",
            "https://cmux/figma-embed.html?embed=x",
            "file:///tmp/cm-73-39/figma-embed.html?embed=x"
        ] {
            #expect(!FigmaPaneURL.isWrapperPage(URL(string: lookalike)!, wrapper: newPage), "\(lookalike)")
        }
    }

    // MARK: - Where the scheme is registered

    @Test("The scheme loads in the pane rather than going to an external app, and is saved like any page")
    func schemeRegistrations() {
        let page = address(newPage, node: "12-2")
        #expect(!browserShouldOpenURLExternally(page))
        #expect(!browserShouldRouteExternalNavigation(page))
        #expect(!browserIsTemporaryHistoryURL(page))
    }

    // MARK: - Restore: old addresses become new where they come in

    @Test("A restored preview's current address, Back and Forward move to the new page, queries unchanged")
    func restoreRewritesCurrentBackAndForward() {
        let panel = restoredPanel(snapshot(
            current: address(legacyPage, node: "12-2").absoluteString,
            back: [address(legacyPage, node: "1-1").absoluteString],
            forward: [address(legacyPage, node: "47-9", motion: true).absoluteString]
        ))
        defer { panel.close() }
        #expect(panel.currentURL == address(newPage, node: "12-2"))
        #expect(query(panel.currentURL) == query(address(legacyPage, node: "12-2")))
        #expect(panel.restoredHistoryCurrentURL == address(newPage, node: "12-2"))
        let history = panel.sessionNavigationHistorySnapshot()
        #expect(history.backHistoryURLStrings == [address(newPage, node: "1-1").absoluteString])
        #expect(history.forwardHistoryURLStrings == [address(newPage, node: "47-9", motion: true).absoluteString])
    }

    @Test("A restored editor's hidden preview side moves to the new page")
    func restoreRewritesTheHiddenPreviewSide() {
        let panel = restoredPanel(snapshot(
            current: editor.absoluteString,
            figmaPages: SessionFigmaPagesSnapshot(
                previewURLString: address(legacyPage, node: "12-2").absoluteString,
                editorURLString: editor.absoluteString,
                showingSide: .editor
            )
        ))
        defer { panel.close() }
        #expect(panel.currentURL == editor)
        #expect(panel.retainedFigmaPageAddress == address(newPage, node: "12-2"))
    }

    @Test("A restored file:// address that is not the legacy page is left alone")
    func restoreLeavesOtherFilesAlone() {
        for other in [
            "file:///tmp/cm-73-39/other.html?embed=x",
            "file:///tmp/cm-73-39/figma-embed.html?embed=x"
        ] {
            let panel = restoredPanel(snapshot(current: other, back: [other]))
            defer { panel.close() }
            #expect(panel.currentURL?.absoluteString == other)
            #expect(panel.sessionNavigationHistorySnapshot().backHistoryURLStrings == [other])
        }
    }

    // MARK: - The load funnel

    @Test("Navigating to the legacy address loads the new page with the same query")
    func funnelRewritesTheLegacyAddress() {
        let panel = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false, websiteDataStore: .nonPersistent())
        defer { panel.close() }
        panel.navigate(to: address(legacyPage, node: "12-2"))
        #expect(panel.navigationDelegate?.lastAttemptedURL == address(newPage, node: "12-2"))
        panel.webView.stopLoading()
    }

    // MARK: - The address

    @Test("New panes get the preview page's address, and the legacy file is only recognised")
    func newPanesGetThePreviewPage() throws {
        #expect(FigmaPaneURL.previewPageURL == newPage)
        let destination = try FigmaPaneURL.destination(for: editor)
        #expect(destination.url.absoluteString.hasPrefix("cmux-figma://cmux/figma-embed.html?embed="), "\(destination.url)")
        #expect(FigmaPaneURL.isWrapperPage(destination.url))
    }

    @Test("The rewrite moves the legacy page to the preview page with the same query, and leaves anything else alone")
    func rewriteIsPure() {
        let legacy = address(legacyPage, node: "12-2", motion: true)
        let upgraded = FigmaPaneURL.upgradingLegacyPage(legacy)
        #expect(upgraded == address(newPage, node: "12-2", motion: true))
        #expect(query(upgraded) == query(legacy))
        #expect(FigmaPaneURL.upgradingLegacyPage(string: legacy.absoluteString) == upgraded.absoluteString)
        for other in [
            "file:///tmp/cm-73-39/figma-embed.html?embed=x",
            "https://www.figma.com/design/KEY/screen?node-id=81-3",
            address(newPage, node: "12-2").absoluteString,
            "not a url %%"
        ] {
            #expect(FigmaPaneURL.upgradingLegacyPage(string: other) == other, "\(other)")
        }
    }

    // MARK: - The scheme handler

    @Test("The handler serves the page as text/html for exactly its host and path, whatever the query")
    func handlerServesOnlyThePage() throws {
        for served in [newPage, address(newPage, node: "12-2"), URL(string: "cmux-figma://CMUX/figma-embed.html")!] {
            let answer = try #require(FigmaPreviewPageSchemeHandler.answer(for: served), "\(served)")
            #expect(answer.mimeType == "text/html")
            #expect(answer.body == Data(FigmaWrapperPage.html.utf8))
        }
        for refused in [
            "cmux-figma://other/figma-embed.html",
            "cmux-figma://cmux/other.html",
            "cmux-figma://cmux/figma-embed.html/x",
            "cmux-figma://cmux:8080/figma-embed.html",
            "cmux-figma://user@cmux/figma-embed.html",
            "https://cmux/figma-embed.html"
        ] {
            #expect(FigmaPreviewPageSchemeHandler.answer(for: URL(string: refused)!) == nil, "\(refused)")
        }
        #expect(FigmaPreviewPageSchemeHandler.answer(for: nil) == nil)
    }

    @Test("Every browser web view carries the handler")
    func browserWebViewsCarryTheHandler() {
        let configuration = WKWebViewConfiguration()
        BrowserPanel.configureWebViewConfiguration(configuration, websiteDataStore: .nonPersistent())
        #expect(configuration.urlSchemeHandler(forURLScheme: "cmux-figma") === FigmaPreviewPageSchemeHandler.shared)
    }

    // MARK: - The guard

    @Test("decidePolicy lets a preview navigation through only in the main frame, as cmux's load, Back/Forward or Reload")
    func decidePolicyGuard() {
        for type in [WKNavigationType.linkActivated, .formSubmitted, .formResubmitted, .other] {
            #expect(!FigmaPreviewPageGuard.allowsNavigation(targetFrameIsMain: true, isTrustedLoad: false, navigationType: type), "\(type.rawValue)")
            #expect(FigmaPreviewPageGuard.allowsNavigation(targetFrameIsMain: true, isTrustedLoad: true, navigationType: type), "\(type.rawValue)")
        }
        #expect(FigmaPreviewPageGuard.allowsNavigation(targetFrameIsMain: true, isTrustedLoad: false, navigationType: .backForward))
        #expect(FigmaPreviewPageGuard.allowsNavigation(targetFrameIsMain: true, isTrustedLoad: false, navigationType: .reload))
        for frame in [false, nil] as [Bool?] {
            for type in [WKNavigationType.other, .backForward, .reload, .linkActivated] {
                #expect(!FigmaPreviewPageGuard.allowsNavigation(targetFrameIsMain: frame, isTrustedLoad: true, navigationType: type))
            }
        }
    }

    @Test("Page routes refuse the scheme and any page the recogniser knows, old or new; ordinary addresses pass")
    func pageRoutesRefuseThePreview() {
        for refused in [
            address(newPage, node: "12-2"),
            URL(string: "cmux-figma://other/x")!,
            address(legacyPage, node: "12-2")
        ] {
            #expect(FigmaPreviewPageGuard.refusesPageRoute(to: refused), "\(refused)")
        }
        for passed in [editor, URL(string: "https://example.com/")!, URL(string: "file:///tmp/cm-73-39/figma-embed.html?embed=x")!] {
            #expect(!FigmaPreviewPageGuard.refusesPageRoute(to: passed), "\(passed)")
        }
        #expect(!FigmaPreviewPageGuard.refusesPageRoute(to: nil))
        #expect(!FigmaPreviewPageGuard.popupAllowsNavigation(to: address(newPage, node: "12-2")))
        #expect(FigmaPreviewPageGuard.popupAllowsNavigation(to: editor))
    }

    @Test("A page's request to load the preview in its pane or a new tab goes nowhere")
    func requestNavigationRefusesThePreview() throws {
        let panel = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false, websiteDataStore: .nonPersistent())
        defer { panel.close() }
        let delegate = try #require(panel.webView.navigationDelegate as? BrowserNavigationDelegate)
        let request = try #require(delegate.requestNavigation)
        for target in [address(newPage, node: "12-2"), address(legacyPage, node: "12-2")] {
            var started: [WKNavigation?] = []
            request(URLRequest(url: target), .currentTab, { started.append($0) })
            #expect(panel.navigationDelegate?.lastAttemptedURL == nil, "\(target)")
            #expect(started.count == 1 && started.first! == nil, "\(target)")
        }
    }

    private func waitUntil(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    @Test("cmux's own load reaches the preview page in a real web view; a web page's script moving the pane there is cancelled")
    func realWebViewLoadsOnlyCmuxsOwn() async throws {
        let own = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false, websiteDataStore: .nonPersistent())
        defer { own.close() }
        let target = address(newPage, node: "12-2")
        own.navigate(to: target)
        // WebKit reports a provisional address before a load is allowed or cancelled, so read the
        // committed document: only the served page, run by the handler, answers with its own address.
        var committed: String?
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            committed = try? await own.webView.evaluateJavaScript("document.title === 'Figma' ? location.href : ''") as? String
            if committed?.hasPrefix(newPage.absoluteString + "?") == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(committed?.hasPrefix(newPage.absoluteString + "?") == true, "cmux's own load committed \(committed ?? "nothing"); web view at \(own.webView.url?.absoluteString ?? "nil")")
        #expect(FigmaPreviewPageSchemeHandler.shared.requestCount(in: own.webView) >= 1, "the handler never served cmux's own load")

        let page = try await webPage("<!doctype html><title>page</title><p>page</p>")
        defer { page.close() }
        let delegate = try #require(page.webView.navigationDelegate as? BrowserNavigationDelegate)
        _ = try? await page.webView.evaluateJavaScript("location.href = \(String(reflecting: target.absoluteString)); true")
        // The guard's own record is the signal that it decided; no sleep stands in for it.
        #expect(await waitUntil { delegate.refusedFigmaPreviewPageURLs.contains { $0.scheme == FigmaPaneURL.previewPageScheme } },
                "the guard never decided on the page's navigation")
        #expect(page.webView.url == pageBase, "a page moved the pane to \(page.webView.url?.absoluteString ?? "nil")")
        #expect(FigmaPreviewPageSchemeHandler.shared.requestCount(in: page.webView) == 0, "the handler was asked for the page")
    }

    // An https parent never gets this far: WebKit blocks a `cmux-figma:` iframe in an https page
    // itself, before asking the delegate (seen in the debug log, 2026-10-28). An about:blank parent
    // may ask, so this is the frame the guard has to stop.
    @Test("An iframe a page points at the preview page loads nothing: the guard refuses it and the handler is never asked")
    func realWebViewIframeLoadsNothing() async throws {
        let target = address(newPage, node: "12-2")
        let page = try await webPage("<!doctype html><title>page</title><iframe src=\"\(target.absoluteString)\"></iframe>", base: nil)
        defer { page.close() }
        let delegate = try #require(page.webView.navigationDelegate as? BrowserNavigationDelegate)
        #expect(await waitUntil { delegate.refusedFigmaPreviewPageURLs.contains { $0.scheme == FigmaPaneURL.previewPageScheme } },
                "the guard never decided on the iframe")
        #expect(FigmaPreviewPageSchemeHandler.shared.requestCount(in: page.webView) == 0, "a frame reached the preview page")
        #expect(page.webView.url?.scheme != FigmaPaneURL.previewPageScheme)
    }

    private let pageBase = URL(string: "https://example.com/")!

    /// A browser pane showing an ordinary web page, loaded from a string so no network is needed.
    private func webPage(_ html: String, base: URL? = URL(string: "https://example.com/")!) async throws -> BrowserPanel {
        let page = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false, websiteDataStore: .nonPersistent())
        page.webView.loadHTMLString(html, baseURL: base)
        let shown = base ?? URL(string: "about:blank")!
        let loaded = await waitUntil { page.webView.url == shown && !page.webView.isLoading }
        try #require(loaded, "fixture: \(page.webView.url?.absoluteString ?? "nil")")
        return page
    }

    // MARK: - The guard's call sites, each driven directly

    @Test("The panel's createWebViewWith opens nothing for the preview page, old or new; an ordinary link still routes")
    func panelCreateWebViewRefusesThePreview() throws {
        let panel = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false, websiteDataStore: .nonPersistent())
        defer { panel.close() }
        let ui = try #require(panel.webView.uiDelegate as? BrowserUIDelegate)
        var routed: [String] = []
        ui.requestNavigation = { request, _ in routed.append("request \(request.url?.absoluteString ?? "nil")") }
        ui.openInNewTab = { routed.append("tab \($0.absoluteString)") }
        ui.openPopup = { _, _ in routed.append("popup"); return nil }
        for target in [address(newPage, node: "12-2"), address(legacyPage, node: "12-2")] {
            let made = ui.webView(panel.webView, createWebViewWith: WKWebViewConfiguration(),
                                  for: FakeNavigationAction(target), windowFeatures: FakeWindowFeatures())
            #expect(made == nil, "\(target)")
        }
        #expect(routed.isEmpty, "\(routed)")
        // Control: the same call with an ordinary link reaches the routing the guard stands before.
        _ = ui.webView(panel.webView, createWebViewWith: WKWebViewConfiguration(),
                       for: FakeNavigationAction(URL(string: "https://example.com/next")!), windowFeatures: FakeWindowFeatures())
        #expect(!routed.isEmpty, "control: an ordinary link was not routed")
    }

    @Test("openLinkInNewTab and a page's new-tab request add no tab for the preview page, old or new; an ordinary link adds one")
    func newTabRoutesRefuseThePreview() throws {
        let app = try #require(AppDelegate.shared)
        let manager = TabManager()
        let originalManager = app.tabManager
        app.tabManager = manager
        defer { app.tabManager = originalManager }
        let workspace = try #require(manager.selectedWorkspace)
        defer { workspace.teardownAllPanels() }
        let terminal = try #require(workspace.focusedPanelId)
        let source = try #require(workspace.newBrowserSplit(
            from: terminal,
            orientation: .horizontal,
            insertFirst: false,
            url: URL(string: "https://example.com/"),
            focus: false,
            allowsExternalBrowserFallback: false,
            chromeVisibility: BrowserChromeVisibility(omnibarVisible: true)
        ))
        let delegate = try #require(source.webView.navigationDelegate as? BrowserNavigationDelegate)
        let request = try #require(delegate.requestNavigation)
        let before = workspace.panels.count
        for target in [address(newPage, node: "12-2"), address(legacyPage, node: "12-2")] {
            source.openLinkInNewTab(request: URLRequest(url: target))
            #expect(workspace.panels.count == before, "openLinkInNewTab: \(target)")
            request(URLRequest(url: target), .newTab, nil)
            #expect(workspace.panels.count == before, "requestNavigation .newTab: \(target)")
        }
        // Control: the same route adds a tab for an ordinary link, so the counts above mean something.
        source.openLinkInNewTab(request: URLRequest(url: URL(string: "https://example.com/next")!))
        #expect(workspace.panels.count == before + 1, "control: an ordinary link opened no tab")
    }

    @Test("A popup's createWebViewWith makes no window for the preview page, old or new; an ordinary scripted popup still opens")
    func popupCreateWebViewRefusesThePreview() throws {
        let opener = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false, websiteDataStore: .nonPersistent())
        defer { opener.close() }
        let popup = try #require(opener.createFloatingPopup(configuration: WKWebViewConfiguration(), windowFeatures: FakeWindowFeatures()))
        let ui = try #require(popup.uiDelegate)
        for target in [address(newPage, node: "12-2"), address(legacyPage, node: "12-2")] {
            let made = ui.webView?(popup, createWebViewWith: WKWebViewConfiguration(),
                                   for: FakeNavigationAction(target, type: .other), windowFeatures: FakeWindowFeatures(width: 640))
            #expect(made == nil, "\(target)")
        }
        // Control: the same scripted popup for an ordinary page is made.
        let control = ui.webView?(popup, createWebViewWith: WKWebViewConfiguration(),
                                  for: FakeNavigationAction(URL(string: "about:blank")!, type: .other), windowFeatures: FakeWindowFeatures(width: 640))
        #expect(control != nil, "control: no popup for an ordinary scripted open")
    }

    @Test("A popup's navigation delegate cancels the preview page; an ordinary page is allowed")
    func popupDecidePolicyRefusesThePreview() throws {
        let opener = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false, websiteDataStore: .nonPersistent())
        defer { opener.close() }
        let popup = try #require(opener.createFloatingPopup(configuration: WKWebViewConfiguration(), windowFeatures: FakeWindowFeatures()))
        let navigation = try #require(popup.navigationDelegate)
        func decide(_ url: URL) -> WKNavigationActionPolicy? {
            var policy: WKNavigationActionPolicy?
            navigation.webView?(popup, decidePolicyFor: FakeNavigationAction(url, frame: KeptFrames.main, type: .other)) { policy = $0 }
            return policy
        }
        #expect(decide(address(newPage, node: "12-2")) == .cancel)
        #expect(decide(URL(string: "about:blank")!) == .allow, "control: an ordinary page was not allowed")
    }
}

// MARK: - WebKit stand-ins for driving delegates directly

/// A navigation action with every property the delegates read set by the test.
private final class FakeNavigationAction: WKNavigationAction {
    private let fakeRequest: URLRequest
    private let fakeTargetFrame: WKFrameInfo?
    private let fakeType: WKNavigationType

    init(_ url: URL, frame: WKFrameInfo? = nil, type: WKNavigationType = .linkActivated) {
        fakeRequest = URLRequest(url: url)
        fakeTargetFrame = frame
        fakeType = type
        super.init()
    }

    override var request: URLRequest { fakeRequest }
    override var targetFrame: WKFrameInfo? { fakeTargetFrame }
    override var sourceFrame: WKFrameInfo { KeptFrames.main }
    override var navigationType: WKNavigationType { fakeType }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
    override var buttonNumber: Int { 0 }
    override var shouldPerformDownload: Bool { false }
}

/// WebKit's own `WKFrameInfo` dealloc crashes on a stand-in (seen 2026-10-28: CFRetain(NULL) in
/// `-[WKFrameInfo dealloc]`), so the one stand-in frame lives for the whole run.
@MainActor
private enum KeptFrames {
    static let main = FakeFrameInfo(main: true)
}

private final class FakeFrameInfo: WKFrameInfo {
    private let main: Bool
    init(main: Bool) {
        self.main = main
        super.init()
    }
    override var isMainFrame: Bool { main }
}

/// Window features with only a width, so a scripted open counts as a popup.
private final class FakeWindowFeatures: WKWindowFeatures {
    private let fakeWidth: NSNumber?
    init(width: NSNumber? = nil) {
        fakeWidth = width
        super.init()
    }
    override var x: NSNumber? { nil }
    override var y: NSNumber? { nil }
    override var width: NSNumber? { fakeWidth }
    override var height: NSNumber? { nil }
    override var menuBarVisibility: NSNumber? { nil }
    override var statusBarVisibility: NSNumber? { nil }
    override var toolbarsVisibility: NSNumber? { nil }
    override var allowsResizing: NSNumber? { nil }
}
