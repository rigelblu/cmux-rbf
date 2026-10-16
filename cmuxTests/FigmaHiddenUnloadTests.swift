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
        var components = URLComponents(url: FigmaPaneURL.wrapperFileURL(), resolvingAgainstBaseURL: false)!
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
}
