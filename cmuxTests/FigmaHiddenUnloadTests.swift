import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct FigmaHiddenUnloadTests {

    private static let figmaEditorURL = URL(string: "https://www.figma.com/design/KEY/a")!
    private static let ordinaryURL = URL(string: "https://example.com/")!
    private static var figmaReadViewURL: URL {
        var components = URLComponents(url: FigmaPaneURL.previewPageURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "embed", value: "https://embed.figma.com/design/KEY/a")]
        return components.url!
    }

    private func makePanel(
        url: URL,
        showsAddressBar: Bool
    ) async throws -> BrowserPanel {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: url,
            chromeVisibility: showsAddressBar ? .visible : .hidden,
            isRemoteWorkspace: false
        )
        panel.webView.navigationDelegate = nil
        panel.webView.stopLoading()
        panel.webView.loadHTMLString(
            "<!DOCTYPE html><html><body>Test</body></html>",
            baseURL: url
        )
        let deadline = Date().addingTimeInterval(10.0)
        while Date() < deadline {
            if !panel.webView.isLoading, !panel.isLoading, panel.webView.url == url {
                break
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(!panel.webView.isLoading)
        #expect(!panel.isLoading)
        #expect(panel.webView.url == url)
        return panel
    }

    // MARK: - Scenario 99

    @Test("figmaEditorPaneWithHiddenOmnibarAnswersKept")
    func figmaEditorPaneWithHiddenOmnibarAnswersKept() async throws {
        let panel = try await makePanel(url: Self.figmaEditorURL, showsAddressBar: false)
        defer { panel.close() }

        #expect(panel.isFigmaPaneForHiddenUnload)
        #expect(panel.hiddenWebViewDiscardKeepLoaded)
        #expect(!panel.keepLoaded)
    }

    @Test("figmaReadViewPaneWithHiddenOmnibarAnswersKept")
    func figmaReadViewPaneWithHiddenOmnibarAnswersKept() async throws {
        let panel = try await makePanel(url: Self.figmaReadViewURL, showsAddressBar: false)
        defer { panel.close() }

        #expect(panel.isFigmaPaneForHiddenUnload)
        #expect(panel.hiddenWebViewDiscardKeepLoaded)
        #expect(!panel.keepLoaded)
    }

    @Test("figmaEditorPaneWithVisibleOmnibarAnswersNotKept")
    func figmaEditorPaneWithVisibleOmnibarAnswersNotKept() async throws {
        let panel = try await makePanel(url: Self.figmaEditorURL, showsAddressBar: true)
        defer { panel.close() }

        #expect(!panel.isFigmaPaneForHiddenUnload)
        #expect(!panel.hiddenWebViewDiscardKeepLoaded)
        #expect(!panel.keepLoaded)
    }

    @Test("ordinaryPaneWithHiddenOmnibarAnswersNotKept")
    func ordinaryPaneWithHiddenOmnibarAnswersNotKept() async throws {
        let panel = try await makePanel(url: Self.ordinaryURL, showsAddressBar: false)
        defer { panel.close() }

        #expect(!panel.isFigmaPaneForHiddenUnload)
        #expect(!panel.hiddenWebViewDiscardKeepLoaded)
        #expect(!panel.keepLoaded)
    }

    @Test("restoredFigmaSnapshotAnswersKeptBeforeShown")
    func restoredFigmaSnapshotAnswersKeptBeforeShown() throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }

        panel.restoreSessionSnapshot(SessionBrowserPanelSnapshot(
            urlString: Self.figmaEditorURL.absoluteString,
            profileID: nil,
            shouldRenderWebView: true,
            pageZoom: 1.0,
            developerToolsVisible: false,
            chromeVisibility: .hidden,
            omnibarVisible: false,
            backHistoryURLStrings: [],
            forwardHistoryURLStrings: []
        ))

        #expect(panel.isFigmaPaneForHiddenUnload)
        #expect(panel.hiddenWebViewDiscardKeepLoaded)
        #expect(!panel.keepLoaded)
    }

    // MARK: - Scenario 100

    @Test("hiddenFigmaPaneIsKeptAcrossScheduledDiscard")
    func hiddenFigmaPaneIsKeptAcrossScheduledDiscard() async throws {
        let panel = try await makePanel(url: Self.figmaEditorURL, showsAddressBar: false)
        defer { panel.close() }

        let originalInstanceID = panel.webViewInstanceID
        panel.noteWebViewVisibility(
            false,
            reason: "test.hide",
            now: Date().addingTimeInterval(-(BrowserHiddenWebViewDiscardPolicy.hiddenDelay + 1))
        )
        panel.reevaluateHiddenWebViewDiscardScheduling(reason: "test.replan")

        #expect(panel.webViewLifecycleTopPayload()["discard_eligible"] as? Bool == true)
        #expect(!panel.hiddenWebViewDiscardManager.hasScheduledDiscard)
        #expect(panel.webViewInstanceID == originalInstanceID)
    }

    @Test("hiddenOrdinaryPaneIsDiscardedAcrossScheduledDiscard")
    func hiddenOrdinaryPaneIsDiscardedAcrossScheduledDiscard() async throws {
        let panel = try await makePanel(url: Self.ordinaryURL, showsAddressBar: false)
        defer { panel.close() }

        let originalInstanceID = panel.webViewInstanceID
        panel.noteWebViewVisibility(
            false,
            reason: "test.hide",
            now: Date().addingTimeInterval(-(BrowserHiddenWebViewDiscardPolicy.hiddenDelay + 1))
        )
        panel.reevaluateHiddenWebViewDiscardScheduling(reason: "test.replan")

        #expect(panel.webViewInstanceID != originalInstanceID)
    }

    @Test("hiddenFigmaPaneWithVisibleOmnibarIsDiscardedAcrossScheduledDiscard")
    func hiddenFigmaPaneWithVisibleOmnibarIsDiscardedAcrossScheduledDiscard() async throws {
        let panel = try await makePanel(url: Self.figmaEditorURL, showsAddressBar: true)
        defer { panel.close() }

        let originalInstanceID = panel.webViewInstanceID
        panel.noteWebViewVisibility(
            false,
            reason: "test.hide",
            now: Date().addingTimeInterval(-(BrowserHiddenWebViewDiscardPolicy.hiddenDelay + 1))
        )
        panel.reevaluateHiddenWebViewDiscardScheduling(reason: "test.replan")

        #expect(panel.webViewInstanceID != originalInstanceID)
    }

    @Test("hiddenFigmaPaneIsDiscardedForSystemMemoryPressure")
    func hiddenFigmaPaneIsDiscardedForSystemMemoryPressure() async throws {
        let panel = try await makePanel(url: Self.figmaEditorURL, showsAddressBar: false)
        defer { panel.close() }

        let originalInstanceID = panel.webViewInstanceID
        panel.noteWebViewVisibility(
            false,
            reason: "test.hide",
            now: Date().addingTimeInterval(-(BrowserHiddenWebViewDiscardPolicy.hiddenDelay + 1))
        )

        #expect(panel.discardHiddenWebViewForSystemMemoryPressure())
        #expect(panel.webViewInstanceID != originalInstanceID)
    }

    // MARK: - cm-73.40, Scenario 402's memory-pressure leg

    /// The committed document's address when it is cmux's page (titled Figma, as only cmux's own bytes are), else "".
    private func cmuxPageAddress(_ panel: BrowserPanel, seconds: Double = 10) async -> String {
        let deadline = Date().addingTimeInterval(seconds)
        var href = ""
        while Date() < deadline {
            href = (try? await panel.webView.evaluateJavaScript("document.title === 'Figma' ? location.href : ''") as? String) ?? ""
            if !href.isEmpty, !panel.webView.isLoading { return href }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return href
    }

    // cmux-rbf #cm-73.40 (Scenario 402, scope check 1 item 4): a preview discarded for memory pressure comes back on the page
    // address through the funnel's simulated load. Figma's server would answer the address with its own 404 (or nothing,
    // offline), so a document titled Figma at the page address is cmux's own bytes.
    @Test("A preview pane discarded for memory pressure comes back on the page address, as cmux's own page")
    func previewDiscardedForMemoryPressureComesBackThroughTheFunnel() async throws {
        let panel = BrowserPanel(workspaceId: UUID(), chromeVisibility: .hidden, websiteDataStore: .nonPersistent())
        defer { panel.close() }
        let page = Self.figmaReadViewURL
        panel.navigate(to: page)
        let first = await cmuxPageAddress(panel)
        try #require(URL(string: first).map { FigmaPaneURL.isSamePage($0, FigmaPaneURL.previewPageURL) } == true, "fixture: the first load committed \(first)")
        // A loading pane is never discarded, and Figma's embedded frame loads from the network after cmux's page commits.
        let settleBy = Date().addingTimeInterval(20)
        while (panel.webView.isLoading || panel.isLoading), Date() < settleBy { try await Task.sleep(nanoseconds: 50_000_000) }

        let originalInstanceID = panel.webViewInstanceID
        panel.noteWebViewVisibility(
            false,
            reason: "test.hide",
            now: Date().addingTimeInterval(-(BrowserHiddenWebViewDiscardPolicy.hiddenDelay + 1))
        )
        let blockers = panel.hiddenWebViewDiscardManager.blockers(for: panel.hiddenWebViewDiscardSnapshot, allowingRecoverableWebContentTermination: true)
        try #require(panel.discardHiddenWebViewForSystemMemoryPressure(), "fixture: the preview was not discarded; blockers \(blockers), web view loading \(panel.webView.isLoading), pane loading \(panel.isLoading)")
        try #require(panel.webViewInstanceID != originalInstanceID, "fixture: the web view was not replaced")

        #expect(panel.restoreDiscardedWebViewIfNeeded(reason: "test.reveal"), "the discarded preview did not restore")
        let restored = await cmuxPageAddress(panel)
        #expect(URL(string: restored) == page, "the restore committed \(restored.isEmpty ? "no cmux page" : restored); web view at \(String(describing: panel.webView.url))")
        #expect(panel.currentURL == page, "the pane's address is \(String(describing: panel.currentURL))")
        #expect(FigmaPreviewPageSchemeHandler.shared.requestCount(in: panel.webView) == 0, "the older scheme's handler was asked")
    }
}
