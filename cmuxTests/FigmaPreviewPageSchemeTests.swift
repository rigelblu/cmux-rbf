import AppKit
import CmuxBrowser
import CmuxSettings
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
    private let newPage = FigmaPaneURL.previewPageURL
    private let legacyServedPage = FigmaPaneURL.legacyServedPageURL
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
        figmaPages: SessionFigmaPagesSnapshot? = nil,
        render: Bool = false
    ) -> SessionBrowserPanelSnapshot {
        SessionBrowserPanelSnapshot(
            urlString: current, profileID: nil, shouldRenderWebView: render,
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

    // cmux-rbf #cm-73.40 (Scenario 403, scope check 1 item 5): the older served form, as well as the file, in every saved place.
    @Test("A pane saved at the cmux-figma:// address moves to the new page in its address, Back, Forward and both sides of figmaPages")
    func restoreUpgradesTheServedFormEverywhere() {
        let previewSide = restoredPanel(snapshot(
            current: address(legacyServedPage, node: "12-2").absoluteString,
            back: [address(legacyServedPage, node: "1-1").absoluteString],
            forward: [address(legacyServedPage, node: "47-9", motion: true).absoluteString],
            figmaPages: SessionFigmaPagesSnapshot(
                previewURLString: address(legacyServedPage, node: "12-2").absoluteString,
                editorURLString: editor.absoluteString,
                showingSide: .preview
            )
        ))
        defer { previewSide.close() }
        #expect(previewSide.currentURL == address(newPage, node: "12-2"))
        let history = previewSide.sessionNavigationHistorySnapshot()
        #expect(history.backHistoryURLStrings == [address(newPage, node: "1-1").absoluteString])
        #expect(history.forwardHistoryURLStrings == [address(newPage, node: "47-9", motion: true).absoluteString])
        // The pair is kept only when the saved preview side matches the address the pane shows, so both must have moved.
        let pages = previewSide.figmaPagesSessionSnapshot()
        #expect(pages?.previewURLString == address(newPage, node: "12-2").absoluteString, "\(String(describing: pages))")
        #expect(pages?.editorURLString == editor.absoluteString, "\(String(describing: pages))")

        let editorSide = restoredPanel(snapshot(
            current: editor.absoluteString,
            figmaPages: SessionFigmaPagesSnapshot(
                previewURLString: address(legacyServedPage, node: "12-2").absoluteString,
                editorURLString: editor.absoluteString,
                showingSide: .editor
            )
        ))
        defer { editorSide.close() }
        #expect(editorSide.currentURL == editor)
        #expect(editorSide.retainedFigmaPageAddress == address(newPage, node: "12-2"))
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
        #expect(destination.url.absoluteString.hasPrefix("https://www.figma.com/cmux-preview/figma-embed.html?embed="), "\(destination.url)")
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
        for served in [legacyServedPage, address(legacyServedPage, node: "12-2"), URL(string: "cmux-figma://CMUX/figma-embed.html")!] {
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
            "https://cmux/figma-embed.html",
            newPage.absoluteString
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
        #expect(FigmaPreviewPageSchemeHandler.shared.requestCount(in: own.webView) == 0, "the handler was asked for the simulated load")

        let page = try await webPage("<!doctype html><title>page</title><p>page</p>")
        defer { page.close() }
        let delegate = try #require(page.webView.navigationDelegate as? BrowserNavigationDelegate)
        _ = try? await page.webView.evaluateJavaScript("location.href = \(String(reflecting: target.absoluteString)); true")
        // The guard's own record is the signal that it decided; no sleep stands in for it.
        #expect(await waitUntil { delegate.refusedFigmaPreviewPageURLs.contains { FigmaPaneURL.isWrapperPage($0) || $0.scheme == FigmaPaneURL.previewPageScheme } },
                "the guard never decided on the page's navigation")
        #expect(page.webView.url == pageBase, "a page moved the pane to \(page.webView.url?.absoluteString ?? "nil")")
        #expect(FigmaPreviewPageSchemeHandler.shared.requestCount(in: page.webView) == 0, "the handler was asked for the page")
    }

    // An https parent never gets this far: WebKit blocks a `cmux-figma:` iframe in an https page
    // itself, before asking the delegate (seen in the debug log, 2026-10-28). An about:blank parent
    // may ask, so this is the frame the guard has to stop.
    @Test("An iframe a page points at the older preview scheme loads nothing: the guard refuses it and the handler is never asked")
    func realWebViewIframeOfOlderSchemeLoadsNothing() async throws {
        let target = address(legacyServedPage, node: "12-2")
        let page = try await webPage("<!doctype html><title>page</title><iframe src=\"\(target.absoluteString)\"></iframe>", base: nil)
        defer { page.close() }
        let delegate = try #require(page.webView.navigationDelegate as? BrowserNavigationDelegate)
        #expect(await waitUntil { delegate.refusedFigmaPreviewPageURLs.contains { $0.scheme == FigmaPaneURL.previewPageScheme } },
                "the guard never decided on the iframe")
        #expect(FigmaPreviewPageSchemeHandler.shared.requestCount(in: page.webView) == 0, "a frame reached the preview page")
        #expect(page.webView.url?.scheme != FigmaPaneURL.previewPageScheme)
    }

    // cmux-rbf #cm-73.40: the https address in a subframe is Figma's own 404, not cmux's page, and cmux reads only main frames.
    @Test("An iframe a page points at the https address is left alone: nothing is refused and the pane stays where it was")
    func realWebViewIframeOfTheHTTPSAddressIsLeftAlone() async throws {
        let target = address(newPage, node: "12-2")
        let page = try await webPage("<!doctype html><title>page</title><iframe src=\"\(target.absoluteString)\"></iframe>", base: nil)
        defer { page.close() }
        let delegate = try #require(page.webView.navigationDelegate as? BrowserNavigationDelegate)
        _ = await waitUntil(3) { false } // an offline iframe has no end signal; give its navigation time to reach the delegate
        #expect(delegate.refusedFigmaPreviewPageURLs.isEmpty, "\(delegate.refusedFigmaPreviewPageURLs)")
        #expect(delegate.lastAttemptedURL == nil, "\(String(describing: delegate.lastAttemptedURL))")
        #expect(page.currentURL == nil || !FigmaPaneURL.isWrapperPage(page.currentURL!))
        #expect(FigmaPreviewPageSchemeHandler.shared.requestCount(in: page.webView) == 0)
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

    // MARK: - cm-73.40: the guard's one rule, and each entrance that loads the page

    // cmux-rbf #cm-73.40: `FigmaPreviewPageGuard.verdict` is what `decidePolicy` applies.
    @Test("The verdict: main frame by type and by where the history entry started, a subframe of the https address not guarded, the older scheme's subframe refused")
    func verdictTable() {
        let page = address(newPage, node: "12-2")
        func verdict(_ url: URL, frame: Bool?, trusted: Bool = false, entry: Bool = true, _ type: WKNavigationType) -> FigmaPreviewPageGuard.Verdict {
            FigmaPreviewPageGuard.verdict(for: url, targetFrameIsMain: frame, isTrustedLoad: trusted, navigationType: type, entryStartedAtPage: entry)
        }
        for url in [page, address(legacyServedPage, node: "12-2"), address(legacyPage, node: "12-2")] {
            #expect(verdict(url, frame: true, trusted: true, entry: false, .other) == .allow, "cmux's own load does not consult the entry: \(url)")
            #expect(verdict(url, frame: true, .backForward) == .allow, "\(url)")
            #expect(verdict(url, frame: true, .reload) == .reloadThroughFunnel, "\(url)")
            // cmux-rbf #cm-73.40 (code review 2, R4): a site's reload or Back its server redirects to the address.
            #expect(verdict(url, frame: true, entry: false, .backForward) == .refuse, "Back/Forward on a site's entry: \(url)")
            #expect(verdict(url, frame: true, entry: false, .reload) == .refuse, "Reload of a site's entry: \(url)")
            #expect(verdict(url, frame: true, trusted: true, entry: false, .reload) == .reloadThroughFunnel, "cmux's own marked load is unchanged: \(url)")
            for type in [WKNavigationType.linkActivated, .formSubmitted, .formResubmitted, .other] {
                #expect(verdict(url, frame: true, type) == .refuse, "\(url) \(type.rawValue)")
                #expect(verdict(url, frame: true, entry: false, type) == .refuse, "\(url) \(type.rawValue)")
            }
            #expect(verdict(url, frame: nil, trusted: true, .other) == .refuse, "a new window: \(url)")
        }
        for type in [WKNavigationType.reload, .backForward, .linkActivated, .other] {
            #expect(verdict(page, frame: false, type) == .notGuarded, "a subframe of the https address: \(type.rawValue)")
            #expect(verdict(address(legacyServedPage, node: "12-2"), frame: false, type) == .refuse, "a subframe of the older scheme: \(type.rawValue)")
        }
        #expect(verdict(editor, frame: true, .linkActivated) == .notGuarded, "control: Figma's own editor is not the page")
        #expect(verdict(URL(string: "https://www.figma.com/cmux-preview/other.html")!, frame: true, .linkActivated) == .notGuarded)
        #expect(verdict(URL(string: "https://example.com/cmux-preview/figma-embed.html")!, frame: true, .linkActivated) == .notGuarded, "a page off www.figma.com is never the preview")
    }

    // cmux-rbf #cm-73.40 (code review 2, R4): what `decidePolicy` and the commit pass as `entryStartedAtPage`.
    @Test("An entry started at the page when its start address is any of the page's addresses; no entry, or any other start, did not")
    func entryStartedAtPageTable() {
        for url in [address(newPage, node: "12-2"), address(legacyServedPage, node: "12-2"), address(legacyPage, node: "12-2")] {
            #expect(FigmaPreviewPageGuard.entryStartedAtPage(url), "\(url)")
        }
        #expect(!FigmaPreviewPageGuard.entryStartedAtPage(nil), "a brand-new web view has no entry")
        for url in [pageBase, editor, URL(string: "https://example.com/cmux-preview/figma-embed.html")!, URL(string: "http://127.0.0.1:8000/x")!] {
            #expect(!FigmaPreviewPageGuard.entryStartedAtPage(url), "\(url)")
        }
    }

    @Test("decidePolicy applies the verdict: a main-frame link is cancelled and recorded, Back/Forward on the page's entry goes on, a subframe is not touched")
    func decidePolicyAppliesTheVerdict() async throws {
        let page = address(newPage, node: "12-2")
        /// One decision on a fresh pane, or on one that really loaded the page so its history entry started there:
        /// the policy, the guard's record, and where the pane was sent.
        func decide(_ frame: WKFrameInfo, _ type: WKNavigationType, onPage: Bool = false) async throws -> (policy: WKNavigationActionPolicy?, refused: [URL], attempted: URL?, current: URL?) {
            let panel = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false, websiteDataStore: .nonPersistent())
            defer { panel.close() }
            let delegate = try #require(panel.webView.navigationDelegate as? BrowserNavigationDelegate)
            if onPage { try await settledOnPage(panel, page) }
            var policy: WKNavigationActionPolicy?
            // goBack, goForward and the funnel set the user agent for the target first; without it the delegate restarts the navigation.
            panel.webView.applyBrowserUserAgentPolicy(for: page)
            delegate.webView(panel.webView, decidePolicyFor: FakeNavigationAction(page, frame: frame, type: type)) { policy = $0 }
            return (policy, delegate.refusedFigmaPreviewPageURLs, delegate.lastAttemptedURL, panel.currentURL)
        }
        let backForward = try await decide(KeptFrames.main, .backForward, onPage: true)
        #expect(backForward.policy == .allow, "Back/Forward: \(backForward)")
        #expect(backForward.refused.isEmpty, "\(backForward.refused)")

        // A subframe of the https address: Figma's server answers it with its own 404; cmux does nothing.
        for type in [WKNavigationType.reload, .linkActivated] {
            let sub = try await decide(KeptFrames.sub, type)
            #expect(sub.policy == .allow, "a subframe \(type.rawValue) was not left alone: \(String(describing: sub))")
            #expect(sub.refused.isEmpty, "\(sub.refused)")
            #expect(sub.current == nil, "a subframe \(type.rawValue) moved the pane to \(String(describing: sub.current))")
        }

        // Control: the same link in the main frame is cancelled and recorded.
        let link = try await decide(KeptFrames.main, .linkActivated)
        #expect(link.policy == .cancel)
        #expect(link.refused == [page], "\(link.refused)")
    }

    @Test("WebKit's own Reload of the page is cancelled and the panel loads the same address through its funnel")
    func webKitReloadIsCancelledAndRedoneThroughTheFunnel() async throws {
        let panel = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false, websiteDataStore: .nonPersistent())
        defer { panel.close() }
        let delegate = try #require(panel.webView.navigationDelegate as? BrowserNavigationDelegate)
        let page = address(newPage, node: "12-2")
        try await settledOnPage(panel, page)
        #expect(delegate.lastAttemptedURL == nil)
        var policy: WKNavigationActionPolicy?
        delegate.webView(panel.webView, decidePolicyFor: FakeNavigationAction(page, frame: KeptFrames.main, type: .reload)) { policy = $0 }
        #expect(policy == .cancel)
        #expect(delegate.lastAttemptedURL == page, "the funnel was not asked to load the page again")
        #expect(delegate.refusedFigmaPreviewPageURLs.isEmpty)
    }

    /// cmux-rbf #cm-73.40 (code review 2, R4): loads the page through the funnel and waits until it is settled, so the web
    /// view's history entry started at the page, as every preview entry does. WebKit's own Reload and Back/Forward, and the
    /// repair, act on that entry; a fresh web view has none.
    private func settledOnPage(_ panel: BrowserPanel, _ page: URL) async throws {
        let delegate = try #require(panel.webView.navigationDelegate as? BrowserNavigationDelegate)
        panel.navigate(to: page)
        let committed = try await loadedPage(panel)
        try #require(committed.hasPrefix(newPage.absoluteString + "?"), "fixture: \(committed)")
        let settled = await waitUntil { delegate.lastAttemptedURL == nil && !panel.webView.isLoading }
        try #require(settled, "fixture: the load left \(String(describing: delegate.lastAttemptedURL))")
        let started = panel.webView.backForwardList.currentItem?.initialURL
        try #require(started.map { FigmaPaneURL.isWrapperPage($0) } == true, "fixture: the entry started at \(String(describing: started))")
    }

    /// Loads the page in a real web view through the funnel and waits for the committed document.
    private func loadedPage(_ panel: BrowserPanel, node: String? = nil) async throws -> String {
        let expected = newPage.absoluteString + "?"
        var committed = ""
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            committed = (try? await panel.webView.evaluateJavaScript("document.title === 'Figma' ? location.href : ''") as? String) ?? ""
            if committed.hasPrefix(expected),
               node == nil || FigmaPaneURL.node(fromPaneURL: URL(string: committed) ?? newPage) == node { return committed }
            try await Task.sleep(for: .milliseconds(50))
        }
        return committed
    }

    @Test("A navigation cmux funnels to the page address loads cmux's own bytes there (goto, fit --node, history, open)")
    func navigateToPreviewAddressLoadsSimulatedRequest() async throws {
        let panel = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false, websiteDataStore: .nonPersistent())
        defer { panel.close() }
        let target = address(newPage, node: "12-2")
        panel.navigate(to: target)
        let committed = try await loadedPage(panel)
        #expect(committed.hasPrefix(newPage.absoluteString + "?"), "committed \(committed); web view at \(panel.webView.url?.absoluteString ?? "nil")")
        #expect(panel.currentURL == target)
    }

    // cmux-rbf #cm-73.40 (the funnel trace after the conduct check, 2026-11-09): with the page on `https`, "Open Current Page
    // in Default Browser" would hand cmux's page address to the system browser, which Figma answers with a 404. It hands over
    // Figma's own link for the file and frame, as the Figma button's menu does (Tom's form, 2026-11-09).
    @Test("Open Current Page in Default Browser on a preview hands over Figma's own link, never cmux's page address")
    func defaultBrowserGetsFigmasOwnLink() async throws {
        let panel = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false, websiteDataStore: .nonPersistent())
        defer { panel.close() }
        panel.navigate(to: address(newPage, node: "12-2"))
        _ = try await loadedPage(panel)
        let handed = try #require(panel.currentDefaultBrowserURL(), "no address for the default browser")
        #expect(!FigmaPaneURL.isWrapperPage(handed), "handed cmux's page address: \(handed.absoluteString)")
        #expect(handed.absoluteString == "https://www.figma.com/design/KEY/screen?node-id=12-2", "handed \(handed.absoluteString)")
    }

    @Test("A typed address, or cmux browser navigate, on the page becomes the preview")
    func navigateToTypedPreviewAddressBecomesPreview() async throws {
        let panel = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false, websiteDataStore: .nonPersistent())
        defer { panel.close() }
        let typed = address(newPage, node: "40-1")
        panel.navigate(to: typed, recordTypedNavigation: true)
        let committed = try await loadedPage(panel)
        #expect(committed.hasPrefix(newPage.absoluteString + "?"), "committed \(committed)")
        #expect(FigmaPaneURL.node(fromPaneURL: URL(string: committed)!) == "40-1")
    }

    @Test("goto on a pane showing the preview loads the new place through the funnel")
    func gotoLoadsThePlaceThroughTheFunnel() async throws {
        let panel = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false, websiteDataStore: .nonPersistent())
        defer { panel.close() }
        panel.navigate(to: address(newPage, node: "12-2"))
        _ = try await loadedPage(panel)
        try #require(panel.gotoFigmaNode("31-4"))
        let committed = try await loadedPage(panel, node: "31-4")
        #expect(FigmaPaneURL.node(fromPaneURL: URL(string: committed) ?? newPage) == "31-4", "committed \(committed)")
    }

    @Test("cmux's Reload and hard Reload of the page go through the funnel, not WebKit's reload", arguments: [false, true])
    func cmuxReloadGoesThroughTheFunnel(hard: Bool) async throws {
        let panel = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false, websiteDataStore: .nonPersistent())
        defer { panel.close() }
        let delegate = try #require(panel.webView.navigationDelegate as? BrowserNavigationDelegate)
        let target = address(newPage, node: "12-2")
        panel.navigate(to: target)
        let first = try await loadedPage(panel)
        try #require(first.hasPrefix(newPage.absoluteString + "?"), "fixture: \(first)")
        let settled = await waitUntil { delegate.lastAttemptedURL == nil && !panel.webView.isLoading }
        try #require(settled, "fixture: the first load left \(String(describing: delegate.lastAttemptedURL))")
        let stepsBefore = panel.webView.backForwardList.backList.count
        if hard { panel.hardReload() } else { panel.reload() }
        // Only the funnel records an attempt synchronously; WebKit's own reload reaches the delegate later. This tells the
        // two paths apart by timing alone (code review 1, N3): cut the panel's branch and WebKit's reload still ends on the
        // page, through the guard's `.reloadThroughFunnel`. What it does not cover is WebKit's Reload meeting a managed
        // allowlist's block page first, which `02_decisions.md` accepts; no test sets the allowlist in the test host.
        #expect(delegate.lastAttemptedURL == target, "Reload did not go through the funnel")
        let again = try await loadedPage(panel)
        #expect(again.hasPrefix(newPage.absoluteString + "?"), "after Reload: \(again)")
        #expect(panel.webView.backForwardList.backList.count == stepsBefore, "Reload added a Back step")
    }

    @Test("A server answer for the page after Back or Forward is repaired at the commit, through the funnel")
    func traversalRepairReloadsPageAddressWhenServerAnswers() async throws {
        let panel = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false, websiteDataStore: .nonPersistent())
        defer { panel.close() }
        let delegate = try #require(panel.webView.navigationDelegate as? BrowserNavigationDelegate)
        let page = address(newPage, node: "12-2")
        try await settledOnPage(panel, page)
        func answer(_ url: URL, main: Bool) {
            delegate.webView(panel.webView, decidePolicyFor: FakeNavigationResponse(url, main: main)) { _ in }
        }
        // Controls: a subframe's answer, an answer for Figma's editor, and an answer with no commit repair nothing.
        answer(page, main: false)
        delegate.webView(panel.webView, didCommit: nil)
        answer(editor, main: true)
        delegate.webView(panel.webView, didCommit: nil)
        answer(page, main: true)
        #expect(delegate.lastAttemptedURL == nil, "the answer alone must not load")
        delegate.webView(panel.webView, didCommit: nil)
        #expect(delegate.lastAttemptedURL == page, "the commit did not load the page again through the funnel")
        // A repair is spent once.
        delegate.webView(panel.webView, didCommit: nil)
        #expect(delegate.pendingFigmaTraversalRepairURL == nil)
    }

    @Test("A restored pane saved at an older address loads the preview at the new one, and its Back and Forward do too")
    func restoredPaneAndItsHistoryLoadThroughTheFunnel() async throws {
        let current = address(legacyServedPage, node: "2-2")
        let back = address(legacyPage, node: "1-1")
        let forward = address(legacyServedPage, node: "3-3")
        let panel = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false, websiteDataStore: .nonPersistent())
        defer { panel.close() }
        panel.restoreSessionSnapshot(snapshot(current: current.absoluteString, back: [back.absoluteString], forward: [forward.absoluteString], render: true))
        // The pane waits for its first show; the show is what loads it.
        try #require(panel.restoreDiscardedWebViewIfNeeded(reason: "test.reveal"), "fixture: the restored pane did not load on show")
        let restored = try await loadedPage(panel, node: "2-2")
        #expect(restored.hasPrefix(newPage.absoluteString + "?"), "restored to \(restored)")

        try #require(panel.canGoBack, "fixture: no restored Back")
        panel.goBack()
        let backed = try await loadedPage(panel, node: "1-1")
        #expect(FigmaPaneURL.node(fromPaneURL: URL(string: backed) ?? newPage) == "1-1", "Back loaded \(backed)")
        try #require(panel.canGoForward, "fixture: no restored Forward")
        panel.goForward()
        let forwarded = try await loadedPage(panel, node: "2-2")
        #expect(FigmaPaneURL.node(fromPaneURL: URL(string: forwarded) ?? newPage) == "2-2", "Forward loaded \(forwarded)")
    }

    // cmux-rbf #cm-73.40 (code review 1, C6): the old case called `publishObservedDocumentURL` and asserted the guard
    // recorded nothing, which no guard could fail. What `publishObservedDocumentURL` itself owes the page is this: while
    // cmux's own load of the page is pending, WebKit clearing its URL does not clear the pane's address.
    @Test("While cmux's load of the page is pending, WebKit clearing its URL keeps the pane's address on the page")
    func aClearedWebViewURLKeepsThePendingPageAddress() throws {
        let panel = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false, websiteDataStore: .nonPersistent())
        defer { panel.close() }
        let target = address(newPage, node: "172-310")
        panel.navigate(to: target)
        try #require(panel.currentURL == target, "fixture: the funnel did not set the pane's address")
        panel.publishObservedDocumentURL(nil)
        #expect(panel.currentURL == target, "the pending page address was cleared: \(String(describing: panel.currentURL))")
        // Control: a real address from the web view replaces it.
        panel.publishObservedDocumentURL(editor)
        #expect(panel.currentURL == editor)
    }

    // MARK: - Code review 1 (cm-73.40)

    /// Whether a web view shows cmux's page (its document is titled Figma), waiting for it to commit.
    private func showsCmuxPage(_ view: WKWebView, seconds: Double = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let href = (try? await view.evaluateJavaScript("document.title === 'Figma' ? location.href : ''") as? String) ?? ""
            if href.hasPrefix(newPage.absoluteString + "?") { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// A pane showing the editor with the preview held behind it, as Tom's switch leaves it. Each web view keeps its own
    /// delegate and every one has this pane as its owner. The held web view really loaded the page, so its history entry
    /// started there (code review 2, R4); its document is then retitled, so only a fresh load of the page reads as Figma's.
    private func paneHoldingThePreview(node: String) async throws -> (pane: BrowserPanel, held: WKWebView, heldDelegate: BrowserNavigationDelegate, editorView: WKWebView, editorDelegate: BrowserNavigationDelegate) {
        let pane = BrowserPanel(workspaceId: UUID(), chromeVisibility: .hidden, websiteDataStore: .nonPersistent())
        pane.figmaPageWrapper = newPage
        try await settledOnPage(pane, address(newPage, node: node))
        _ = try await pane.webView.evaluateJavaScript("document.title = 'held'; true")
        try #require(!(await showsCmuxPage(pane.webView, seconds: 0.5)), "fixture: the held document was not retitled")
        pane.publishObservedDocumentURL(address(newPage, node: node))
        let held = pane.webView
        let heldDelegate = try #require(held.navigationDelegate as? BrowserNavigationDelegate)
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: newPage), "fixture: the switch did not run")
        let editorView = pane.webView
        try #require(editorView !== held, "fixture: the editor did not get its own web view")
        editorView.stopLoading()
        pane.publishObservedDocumentURL(editor)
        let editorDelegate = try #require(editorView.navigationDelegate as? BrowserNavigationDelegate)
        try #require(editorDelegate !== heldDelegate, "fixture: both sides share one delegate")
        return (pane, held, heldDelegate, editorView, editorDelegate)
    }

    @Test("A Reload the held preview asks for loads the page again in the held web view; the editor on show stays the editor")
    func heldPreviewReloadStaysInTheHeldWebView() async throws {
        let shown = try await paneHoldingThePreview(node: "12-2")
        defer { shown.pane.close() }
        let page = address(newPage, node: "12-2")
        var policy: WKNavigationActionPolicy?
        shown.heldDelegate.webView(shown.held, decidePolicyFor: FakeNavigationAction(page, frame: KeptFrames.main, type: .reload)) { policy = $0 }
        #expect(policy == .cancel)
        #expect(await showsCmuxPage(shown.held), "the held preview did not load the page again")
        #expect(shown.pane.webView === shown.editorView)
        #expect(shown.editorDelegate.lastAttemptedURL != page, "the editor's web view was asked to load the page")
        #expect(shown.editorView.url?.path != newPage.path, "the editor's web view turned into the preview: \(String(describing: shown.editorView.url))")
        #expect(shown.pane.currentURL == editor, "the pane's address moved to \(String(describing: shown.pane.currentURL))")
    }

    @Test("A server answer for the page in the held preview is repaired in the held web view; the editor on show stays the editor")
    func heldPreviewRepairStaysInTheHeldWebView() async throws {
        let shown = try await paneHoldingThePreview(node: "12-2")
        defer { shown.pane.close() }
        let page = address(newPage, node: "12-2")
        shown.heldDelegate.webView(shown.held, decidePolicyFor: FakeNavigationResponse(page, main: true)) { _ in }
        shown.heldDelegate.webView(shown.held, didCommit: nil)
        #expect(shown.heldDelegate.pendingFigmaTraversalRepairURL == nil, "the repair was not spent")
        #expect(await showsCmuxPage(shown.held), "the held preview was not repaired")
        #expect(shown.pane.webView === shown.editorView)
        #expect(shown.editorDelegate.lastAttemptedURL != page, "the editor's web view was asked to load the page")
        #expect(shown.editorView.url?.path != newPage.path, "the editor's web view turned into the preview: \(String(describing: shown.editorView.url))")
        #expect(shown.pane.currentURL == editor, "the pane's address moved to \(String(describing: shown.pane.currentURL))")
    }

    @Test("A repair noted for one navigation is dropped when the next navigation starts")
    func pendingRepairIsDroppedAtTheNextNavigationStart() throws {
        let panel = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false, websiteDataStore: .nonPersistent())
        defer { panel.close() }
        let delegate = try #require(panel.webView.navigationDelegate as? BrowserNavigationDelegate)
        let page = address(newPage, node: "12-2")
        delegate.webView(panel.webView, decidePolicyFor: FakeNavigationResponse(page, main: true)) { _ in }
        try #require(delegate.pendingFigmaTraversalRepairURL == page, "fixture: the answer did not note a repair")
        // The answer never commits (cancelled, or turned into a download); the next navigation starts and commits.
        delegate.webView(panel.webView, didStartProvisionalNavigation: nil)
        #expect(delegate.pendingFigmaTraversalRepairURL == nil, "the stale repair survived the next navigation's start")
        delegate.webView(panel.webView, didCommit: nil)
        #expect(delegate.lastAttemptedURL == nil, "the next commit loaded the page: \(String(describing: delegate.lastAttemptedURL))")
    }

    // MARK: - Code review 2 (cm-73.40), R4: a site's reload or Back that its server redirects to the page address

    // cmux-rbf #cm-73.40 (code review 2, R4): WebKit reports the redirect to `decidePolicy` with the type of the
    // navigation it belongs to, and the history entry still started at the site's address (measured in a
    // throwaway WebKit app with a redirecting server, code review 2 and its fix round).
    // A real web view showing an ordinary page gives that entry; no stand-in for WebKit's history is needed.

    /// A pane showing an ordinary page, its history entry checked to have started there, and the pane's address.
    private func ordinaryPagePane() async throws -> (panel: BrowserPanel, delegate: BrowserNavigationDelegate, shown: URL?) {
        let panel = try await webPage("<!doctype html><title>site</title><p>site</p>")
        let delegate = try #require(panel.webView.navigationDelegate as? BrowserNavigationDelegate)
        let started = panel.webView.backForwardList.currentItem?.initialURL
        try #require(started == pageBase, "fixture: the entry started at \(String(describing: started))")
        return (panel, delegate, panel.currentURL)
    }

    @Test("A site's Reload that its server redirects to the page address is cancelled and recorded, and loads nothing")
    func aSitesReloadRedirectedToThePageIsRefused() async throws {
        let site = try await ordinaryPagePane()
        defer { site.panel.close() }
        let page = address(newPage, node: "12-2")
        var policy: WKNavigationActionPolicy?
        site.panel.webView.applyBrowserUserAgentPolicy(for: page)
        site.delegate.webView(site.panel.webView, decidePolicyFor: FakeNavigationAction(page, frame: KeptFrames.main, type: .reload)) { policy = $0 }
        #expect(policy == .cancel)
        #expect(site.delegate.refusedFigmaPreviewPageURLs == [page], "the guard did not refuse it: \(site.delegate.refusedFigmaPreviewPageURLs)")
        #expect(site.delegate.lastAttemptedURL == nil, "the funnel was asked to load \(String(describing: site.delegate.lastAttemptedURL))")
        #expect(site.panel.currentURL == site.shown, "the pane's address moved to \(String(describing: site.panel.currentURL))")
    }

    @Test("A site's Back or Forward that its server redirects to the page address is cancelled and recorded, and loads nothing")
    func aSitesBackForwardRedirectedToThePageIsRefused() async throws {
        let site = try await ordinaryPagePane()
        defer { site.panel.close() }
        let page = address(newPage, node: "12-2")
        var policy: WKNavigationActionPolicy?
        site.panel.webView.applyBrowserUserAgentPolicy(for: page)
        site.delegate.webView(site.panel.webView, decidePolicyFor: FakeNavigationAction(page, frame: KeptFrames.main, type: .backForward)) { policy = $0 }
        #expect(policy == .cancel, "the redirect went on: \(String(describing: policy?.rawValue))")
        #expect(site.delegate.refusedFigmaPreviewPageURLs == [page], "the guard did not refuse it: \(site.delegate.refusedFigmaPreviewPageURLs)")
        #expect(site.delegate.lastAttemptedURL == nil, "the funnel was asked to load \(String(describing: site.delegate.lastAttemptedURL))")
        #expect(site.panel.currentURL == site.shown, "the pane's address moved to \(String(describing: site.panel.currentURL))")
    }

    @Test("A server answer at the page address on a site's history entry is not repaired at the commit")
    func aServerAnswerOnASitesEntryIsNotRepaired() async throws {
        let site = try await ordinaryPagePane()
        defer { site.panel.close() }
        let page = address(newPage, node: "12-2")
        site.delegate.webView(site.panel.webView, decidePolicyFor: FakeNavigationResponse(page, main: true)) { _ in }
        site.delegate.webView(site.panel.webView, didCommit: nil)
        #expect(site.delegate.lastAttemptedURL == nil, "the commit loaded the page: \(String(describing: site.delegate.lastAttemptedURL))")
        #expect(site.delegate.pendingFigmaTraversalRepairURL == nil, "the repair was kept for a later commit")
        #expect(site.panel.currentURL == site.shown, "the pane's address moved to \(String(describing: site.panel.currentURL))")
    }

    // cmux-rbf #cm-73.40 (code review 3, C1): while WebKit decides a navigation to the page address, `webView.url` already
    // reads that address, though the document and its history entry are still the site's (measured in a throwaway WebKit
    // app: a site's reload loop redirected to the page kept `webView.url` there for a few milliseconds at a time, and
    // `currentItem.url` never). A direct `load()` opens the same window synchronously, before the delegate is asked.
    @Test("cmux's Reload and hard Reload, pressed while a navigation to the page address is still being decided, reload the site", arguments: [false, true])
    func cmuxReloadDuringAPendingPageNavigationReloadsTheSite(hard: Bool) async throws {
        let site = try await ordinaryPagePane()
        defer { site.panel.close() }
        let page = address(newPage, node: "12-2")
        site.panel.webView.load(URLRequest(url: page))
        try #require(site.panel.webView.url == page, "fixture: webView.url reads \(String(describing: site.panel.webView.url))")
        try #require(site.panel.webView.backForwardList.currentItem?.url == pageBase, "fixture: the entry is \(String(describing: site.panel.webView.backForwardList.currentItem?.url))")
        // A direct `load()` publishes its target before WebKit reports the navigation started, so the pane's address may
        // already read the page here; a site's redirect, by contrast, is published only during the navigation, which the pane
        // ignores. What Reload must not do is load the page; the address must be the site's again once WebKit has decided.
        let addressBeforeReload = site.panel.currentURL
        if hard { site.panel.hardReload() } else { site.panel.reload() }
        #expect(site.delegate.lastAttemptedURL != page, "the funnel was asked to load the page")
        #expect(!(await showsCmuxPage(site.panel.webView, seconds: 1)), "the pane became cmux's preview")
        #expect(site.panel.webView.url == pageBase, "the web view is at \(String(describing: site.panel.webView.url))")
        #expect(site.panel.currentURL == site.shown, "the pane's address is \(String(describing: site.panel.currentURL)), before Reload \(String(describing: addressBeforeReload))")
    }

    // MARK: - Scope check 1 (cm-73.40): the page-address seam, Scenario 405's www.figma.com leg, Scenario 409

    // cmux-rbf #cm-73.40: the seam changes nothing when nobody sets it. Every other test in this file runs with the property nil
    // and loads the constant (`navigateToPreviewAddressLoadsSimulatedRequest` is the direct one); this pins the resolver itself.
    @Test("With no test address set, a pane's page address is the https constant; a plain WKWebView's and no web view's too")
    func thePageAddressIsTheConstantUnlessATestSetsIt() throws {
        let panel = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false, websiteDataStore: .nonPersistent())
        defer { panel.close() }
        let view = try #require(panel.webView as? CmuxWebView)
        #expect(view.figmaPreviewPageAddressForTesting == nil)
        #expect(FigmaPreviewPageGuard.pageAddress(for: view) == FigmaPaneURL.previewPageURL)
        #expect(FigmaPreviewPageGuard.pageAddress(for: WKWebView()) == FigmaPaneURL.previewPageURL)
        #expect(FigmaPreviewPageGuard.pageAddress(for: nil) == FigmaPaneURL.previewPageURL)
        let standIn = URL(string: "http://127.0.0.1:47555/cmux-preview/figma-embed.html")!
        view.figmaPreviewPageAddressForTesting = standIn
        #expect(FigmaPreviewPageGuard.pageAddress(for: view) == standIn, "control: the property is read")
    }

    /// Records each address the allowlist blocks in this delegate, then lets the panel's own handler show its block page.
    /// `activePolicyBlockedURL` alone is cleared again as soon as the block page starts loading.
    private final class BlockedAddresses { var all: [URL] = [] }
    private func recordBlocks(_ delegate: BrowserNavigationDelegate) -> BlockedAddresses {
        let blocked = BlockedAddresses()
        let panelHandler = delegate.handleBlockedURLAllowlistNavigation
        delegate.handleBlockedURLAllowlistNavigation = { url, view in
            blocked.all.append(url)
            panelHandler?(url, view)
        }
        return blocked
    }

    /// Suite-named defaults holding an allowlist that names only example.com; never `.standard`, which other suites share.
    private func exampleOnlyAllowlist() throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: "cm-73.40.allowlist.\(UUID().uuidString)"))
        defaults.set(["example.com"], forKey: BrowserURLAllowlistPolicy.userDefaultsKey)
        try #require(BrowserURLAllowlistPolicy(defaults: defaults).isActive, "fixture: the allowlist is not active")
        try #require(!BrowserURLAllowlistPolicy(defaults: defaults).allows(address(newPage, node: "12-2")), "fixture: the list allows the page address")
        return defaults
    }

    // cmux-rbf #cm-73.40 (Scenario 409, scope check 1 item 3): beside 405's. With an allowlist naming only example.com,
    // cmux's own load of the page address is allowed, and a page's move to it is not. The accepted gap is recorded too:
    // WebKit's own Reload and Back/Forward of a preview meet the allowlist before the guard and get its block page
    // (`02_decisions.md` 2026-11-05, cold review 1 finding 5). If that changes, this test says so.
    // What it covers: the delegate's allowlist gates only, through `urlAllowlistDefaults`. The panel's own checks on the
    // `navigate` path (`BrowserPanel` `navigateWithoutInsecureHTTPPrompt`, `allowsTrustedInternalURL`) read `.standard`,
    // which holds no list in the test host; only the package's `BrowserURLAllowlistPolicyTests` cover them (code review 4, C1).
    @Test("With an allowlist naming only example.com: cmux's own load of the page goes on, a page's move to it is blocked, and WebKit's Reload or Back of a preview gets the block page")
    func anAllowlistWithoutFigmaStillLetsCmuxsPreviewLoad() async throws {
        let page = address(newPage, node: "12-2")

        let own = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false, websiteDataStore: .nonPersistent())
        defer { own.close() }
        let ownDelegate = try #require(own.navigationDelegate)
        ownDelegate.urlAllowlistDefaults = try exampleOnlyAllowlist()
        let ownBlocks = recordBlocks(ownDelegate)
        own.navigate(to: page)
        let committed = try await loadedPage(own)
        #expect(committed.hasPrefix(newPage.absoluteString + "?"), "cmux's own load committed \(committed); web view at \(String(describing: own.webView.url))")
        #expect(ownBlocks.all.isEmpty, "cmux's own load was blocked: \(ownBlocks.all)")

        let site = try await ordinaryPagePane()
        defer { site.panel.close() }
        site.delegate.urlAllowlistDefaults = try exampleOnlyAllowlist()
        let siteBlocks = recordBlocks(site.delegate)
        _ = try? await site.panel.webView.evaluateJavaScript("location.href = \(String(reflecting: page.absoluteString)); true")
        let decided = await waitUntil { !siteBlocks.all.isEmpty || !site.delegate.refusedFigmaPreviewPageURLs.isEmpty }
        #expect(decided, "nothing stopped the page's move")
        #expect(siteBlocks.all == [page], "the allowlist did not block the page's move: blocked \(siteBlocks.all), refused \(site.delegate.refusedFigmaPreviewPageURLs)")
        #expect(!(await showsCmuxPage(site.panel.webView, seconds: 1)), "a page's move made the pane cmux's preview")

        // The accepted gap: on a preview whose entry started at the page, WebKit's own Reload and Back/Forward are blocked.
        for type in [WKNavigationType.reload, .backForward] {
            let preview = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false, websiteDataStore: .nonPersistent())
            defer { preview.close() }
            try await settledOnPage(preview, page)
            let delegate = try #require(preview.navigationDelegate)
            delegate.urlAllowlistDefaults = try exampleOnlyAllowlist()
            let blocks = recordBlocks(delegate)
            preview.webView.applyBrowserUserAgentPolicy(for: page)
            var policy: WKNavigationActionPolicy?
            delegate.webView(preview.webView, decidePolicyFor: FakeNavigationAction(page, frame: KeptFrames.main, type: type)) { policy = $0 }
            #expect(policy == .cancel, "\(type.rawValue): \(String(describing: policy?.rawValue))")
            #expect(blocks.all == [page], "\(type.rawValue): the block page was not shown; the gap changed: \(blocks.all)")
            #expect(delegate.refusedFigmaPreviewPageURLs.isEmpty, "\(type.rawValue): the guard decided first: \(delegate.refusedFigmaPreviewPageURLs)")
        }
    }

    // MARK: - Round 5 (cm-73.40): the profile switch reads the history entry in the page-address window

    /// A rendered pane on a temporary profile (a profile switch needs a persistent store), plus a second temporary
    /// profile to switch to. Both go into the shared profile store, so each test deletes both in its `defer`; never the
    /// built-in default profile, whose store other suites share (code review 4, C2).
    private func twoProfilePane() async throws -> (panel: BrowserPanel, source: BrowserProfileDefinition, target: BrowserProfileDefinition) {
        let source = try #require(BrowserProfileStore.shared.createProfile(named: "cm-73.40 from \(UUID().uuidString)"))
        let target = try #require(BrowserProfileStore.shared.createProfile(named: "cm-73.40 switch \(UUID().uuidString)"))
        let panel = BrowserPanel(workspaceId: UUID(), profileID: source.id)
        panel.shouldRenderWebView = true
        return (panel, source, target)
    }

    // cmux-rbf #cm-73.40 (round 5, item 1): the profile switch picked its restore address from `webView.url`, which during a
    // navigation still being decided already reads its target. A direct `load()` opens that window synchronously
    // (`fix3/probe/window.log`), as a site's refused redirect does for a few milliseconds.
    @Test("A profile switch while a navigation to the page address is still being decided restores the site, not a preview")
    func profileSwitchDuringAPendingPageNavigationRestoresTheSite() async throws {
        let (panel, source, target) = try await twoProfilePane()
        defer { panel.close(); _ = BrowserProfileStore.shared.deleteProfile(id: target.id); _ = BrowserProfileStore.shared.deleteProfile(id: source.id) }
        panel.webView.loadHTMLString("<!doctype html><title>site</title><p>site</p>", baseURL: pageBase)
        let loaded = await waitUntil { panel.webView.url == pageBase && !panel.webView.isLoading }
        try #require(loaded, "fixture: \(String(describing: panel.webView.url))")
        let page = address(newPage, node: "12-2")
        panel.webView.load(URLRequest(url: page))
        try #require(panel.webView.url == page, "fixture: webView.url reads \(String(describing: panel.webView.url))")
        try #require(panel.webView.backForwardList.currentItem?.url == pageBase, "fixture: the entry is \(String(describing: panel.webView.backForwardList.currentItem?.url))")

        try #require(panel.switchToProfile(target.id), "fixture: the profile switch did not run")
        #expect(panel.currentURL == pageBase, "the switch restored \(String(describing: panel.currentURL))")
        #expect(panel.navigationDelegate?.lastAttemptedURL == pageBase, "the restore loaded \(String(describing: panel.navigationDelegate?.lastAttemptedURL))")
        #expect(!(await showsCmuxPage(panel.webView, seconds: 1)), "the profile switch made the pane cmux's preview")
    }

    // Control: a real preview still comes back as the preview after a profile switch.
    @Test("A preview pane switched to another profile restores the same preview")
    func profileSwitchOnAPreviewRestoresThePreview() async throws {
        let (panel, source, target) = try await twoProfilePane()
        defer { panel.close(); _ = BrowserProfileStore.shared.deleteProfile(id: target.id); _ = BrowserProfileStore.shared.deleteProfile(id: source.id) }
        let page = address(newPage, node: "12-2")
        panel.navigate(to: page)
        let first = try await loadedPage(panel)
        try #require(first == page.absoluteString, "fixture: \(first)")
        try #require(panel.switchToProfile(target.id), "fixture: the profile switch did not run")
        #expect(panel.currentURL == page, "the switch restored \(String(describing: panel.currentURL))")
        let restored = try await loadedPage(panel)
        #expect(restored == page.absoluteString, "after the switch the pane shows \(restored.isEmpty ? "no cmux page" : restored)")
    }

    // MARK: - Round 6 (code review 4, R1): every reader that can feed a trusted load or a saved address

    /// An ordinary pane in the page-address window: `webView.url` reads the page address while the entry is the site's.
    private func paneInTheWindow() async throws -> (panel: BrowserPanel, page: URL) {
        let site = try await ordinaryPagePane()
        let page = address(newPage, node: "12-2")
        site.panel.webView.load(URLRequest(url: page))
        try #require(site.panel.webView.url == page, "fixture: webView.url reads \(String(describing: site.panel.webView.url))")
        try #require(site.panel.webView.backForwardList.currentItem?.url == pageBase, "fixture: the entry is \(String(describing: site.panel.webView.backForwardList.currentItem?.url))")
        return (site.panel, page)
    }

    // cmux-rbf #cm-73.40 (round 6, code review 4 R1): Duplicate Tab opens a new pane on `currentURLForTabDuplication`
    // through the funnel, which makes cmux's page of any page address.
    @Test("Duplicate Tab in the page-address window duplicates the site, not a preview")
    func duplicateTabInTheWindowDuplicatesTheSite() async throws {
        let (panel, page) = try await paneInTheWindow()
        defer { panel.close() }
        #expect(panel.currentURLForTabDuplication == pageBase, "Duplicate Tab would open \(String(describing: panel.currentURLForTabDuplication)); the window shows \(page)")
        #expect(panel.resolvedCurrentSessionHistoryURL() == pageBase, "\(String(describing: panel.resolvedCurrentSessionHistoryURL()))")
    }

    // cmux-rbf #cm-73.40 (round 6, code review 4 R1): the 8 s autosave and the save at quit store this as the pane's
    // address, and a restore loads a saved page address as cmux's preview (Scenario 403).
    @Test("A session snapshot taken in the page-address window saves the site's address")
    func sessionSnapshotInTheWindowSavesTheSite() async throws {
        let (panel, page) = try await paneInTheWindow()
        defer { panel.close() }
        #expect(panel.preferredURLStringForSessionSnapshot() == pageBase.absoluteString, "the snapshot would save \(String(describing: panel.preferredURLStringForSessionSnapshot())); the window shows \(page)")
    }

    // cmux-rbf #cm-73.40 (round 6, code review 4 R1 and its "Unproven" items): the profile switch's restored-history
    // current entry, and CLI reload's `.urlOnly` target, read the same live address.
    @Test("In the page-address window, the restored-history current and CLI reload's target are the site")
    func otherLiveReadersInTheWindowReadTheSite() async throws {
        let (panel, page) = try await paneInTheWindow()
        defer { panel.close() }
        #expect(panel.preferredURLStringForOmnibar() == pageBase.absoluteString, "the restored-history current would be \(String(describing: panel.preferredURLStringForOmnibar())); the window shows \(page)")
        #expect(panel.automationReloadTargetURL() == pageBase, "CLI reload would load \(String(describing: panel.automationReloadTargetURL()))")
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
    static let sub = FakeFrameInfo(main: false)
}

/// A navigation response with only what the delegate reads. Like `WKFrameInfo`, a stand-in must outlive
/// the run: its dealloc crashes the test host, so every one made is kept.
@MainActor
private enum KeptResponses {
    static var all: [WKNavigationResponse] = []
}

private final class FakeNavigationResponse: WKNavigationResponse {
    private let fakeResponse: URLResponse
    private let main: Bool
    init(_ url: URL, main: Bool) {
        fakeResponse = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"])!
        self.main = main
        super.init()
        MainActor.assumeIsolated { KeptResponses.all.append(self) }
    }
    override var response: URLResponse { fakeResponse }
    override var isForMainFrame: Bool { main }
    override var canShowMIMEType: Bool { true }
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
