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

@MainActor
@Suite("FigmaPageSessionRestore", .serialized)
struct FigmaPageSessionRestoreTests {
    private let document = URL(string: "https://www.figma.com/design/KEY/screen")!
    private let editorAddress = URL(string: "https://www.figma.com/design/KEY/screen?page-id=88%3A9&node-id=81-3")!

    @Test("Restart preserves both addresses and the showing side", arguments: [false, true])
    func bothSidesRoundTrip(showingPreview: Bool) async throws {
        let source = try await fixture(showingPreview: showingPreview)
        defer { source.workspace.teardownAllPanels() }
        let snapshot = try roundTrip(source.workspace.sessionSnapshot(includeScrollback: false))
        let browser = try browserRecord(snapshot, id: source.panel.id)
        #expect(browser.urlString == (showingPreview ? source.preview : editorAddress).absoluteString)
        let restored = try restore(snapshot, sourceID: source.panel.id)
        defer { restored.workspace.teardownAllPanels() }
        try assertBothSides(restored.panel, preview: source.preview, showingPreview: showingPreview)
        #expect(restored.workspace.customTitle == "Restart fixture")
    }

    @Test("Saving a deferred pane before its first reveal preserves both sides", arguments: [false, true])
    func deferredResaveKeepsBothSides(showingPreview: Bool) async throws {
        let source = try await fixture(showingPreview: showingPreview)
        defer { source.workspace.teardownAllPanels() }
        let snapshot = try roundTrip(source.workspace.sessionSnapshot(includeScrollback: false))
        let deferredWorkspace = Workspace()
        defer { deferredWorkspace.teardownAllPanels() }
        let map = deferredWorkspace.restoreSessionSnapshot(snapshot, deferBrowserPanels: true)
        let deferredID = try #require(map[source.panel.id])
        #expect(deferredWorkspace.panels[deferredID] is DeferredBrowserPanel)
        let resaved = try roundTrip(deferredWorkspace.sessionSnapshot(includeScrollback: false))
        let restored = try restore(resaved, sourceID: deferredID)
        defer { restored.workspace.teardownAllPanels() }
        try assertBothSides(restored.panel, preview: source.preview, showingPreview: showingPreview)
    }

    @Test("An Editor released by pointing stays released across restart", arguments: [false, true])
    func pointedEditorStaysReleased(showingPreview: Bool) async throws {
        let source = try await fixture(showingPreview: showingPreview)
        defer { source.workspace.teardownAllPanels() }
        try #require(source.panel.gotoFigmaNode("31-4"))
        try #require(source.panel.retainedFigmaPageAddress == nil)
        let snapshot = try roundTrip(source.workspace.sessionSnapshot(includeScrollback: false))
        let restored = try restore(snapshot, sourceID: source.panel.id)
        defer { restored.workspace.teardownAllPanels() }
        #expect(restored.panel.retainedFigmaPageAddress == nil)
        #expect(restored.panel.currentURL.flatMap { FigmaPaneURL.node(fromPaneURL: $0) } == "31-4")
        try #require(restored.panel.switchFigmaPreviewAndEditor())
        #expect(restored.panel.currentURL.flatMap { FigmaPaneURL.node(fromPaneURL: $0) } == "31-4")
        #expect(restored.panel.currentURL != editorAddress)
        #expect(!restored.panel.figmaFitMark.isPending)
    }

    @Test("A point after restart still shows Preview and releases the restored Editor", arguments: [false, true])
    func pointingAfterRestartDropsEditor(showingPreview: Bool) async throws {
        let source = try await fixture(showingPreview: showingPreview)
        defer { source.workspace.teardownAllPanels() }
        let restored = try restore(try roundTrip(source.workspace.sessionSnapshot(includeScrollback: false)), sourceID: source.panel.id)
        defer { restored.workspace.teardownAllPanels() }
        try #require(restored.panel.gotoFigmaNode("31-4"))
        let address = try #require(restored.panel.currentURL)
        #expect(FigmaPaneURL.isWrapperPage(address))
        #expect(FigmaPaneURL.node(fromPaneURL: address) == "31-4")
        #expect(restored.panel.retainedFigmaPageAddress == nil)
        try #require(restored.panel.switchFigmaPreviewAndEditor())
        #expect(restored.panel.currentURL.flatMap { FigmaPaneURL.node(fromPaneURL: $0) } == "31-4")
        #expect(!restored.panel.figmaFitMark.isPending)
    }

    @Test("Memory-pressure-released documents retain both addresses across restart", arguments: [false, true])
    func discardedPagesRoundTrip(showingPreview: Bool) async throws {
        let source = try await fixture(showingPreview: showingPreview)
        defer { source.workspace.teardownAllPanels() }
        source.panel.noteWebViewVisibility(false, reason: "test.step4.memory")
        let delegate = try #require(source.panel.webView.navigationDelegate as? BrowserNavigationDelegate)
        delegate.webViewWebContentProcessDidTerminate(source.panel.webView)
        try #require(source.panel.discardHiddenWebViewForSystemMemoryPressure())
        let snapshot = try roundTrip(source.workspace.sessionSnapshot(includeScrollback: false))
        let restored = try restore(snapshot, sourceID: source.panel.id)
        defer { restored.workspace.teardownAllPanels() }
        try assertBothSides(restored.panel, preview: source.preview, showingPreview: showingPreview)
    }

    @Test("An old reader keeps the showing URL and its next save drops only the other side", arguments: [false, true])
    func oldReaderKeepsShowingSide(showingPreview: Bool) async throws {
        let source = try await fixture(showingPreview: showingPreview)
        defer { source.workspace.teardownAllPanels() }
        var snapshot = try roundTrip(source.workspace.sessionSnapshot(includeScrollback: false))
        let index = try #require(snapshot.panels.firstIndex { $0.id == source.panel.id })
        let browser = try #require(snapshot.panels[index].browser)
        let old = try JSONDecoder().decode(OldBrowserRecord.self, from: JSONEncoder().encode(browser))
        let expected = showingPreview ? source.preview : editorAddress
        #expect(old.urlString == expected.absoluteString)
        snapshot.panels[index].browser = try JSONDecoder().decode(SessionBrowserPanelSnapshot.self, from: JSONEncoder().encode(old))
        let restored = try restore(snapshot, sourceID: source.panel.id)
        defer { restored.workspace.teardownAllPanels() }
        #expect(restored.panel.currentURL == expected)
        #expect(restored.panel.retainedFigmaPageAddress == nil)
        #expect(restored.workspace.customTitle == "Restart fixture")
        try assertLegacyFirstSwitch(restored.panel, wasPreview: showingPreview)
    }

    @Test("Older one-URL records restore as before", arguments: [false, true])
    func legacyOneURLRecord(showingPreview: Bool) async throws {
        let source = try await fixture(showingPreview: showingPreview)
        defer { source.workspace.teardownAllPanels() }
        var snapshot = source.workspace.sessionSnapshot(includeScrollback: false)
        let index = try #require(snapshot.panels.firstIndex { $0.id == source.panel.id })
        let expected = showingPreview ? source.preview : editorAddress
        let oldJSON: [String: Any] = [
            "urlString": expected.absoluteString, "shouldRenderWebView": true,
            "pageZoom": 1.0, "developerToolsVisible": false,
            "chromeVisibility": "hidden", "omnibarVisible": false
        ]
        snapshot.panels[index].browser = try JSONDecoder().decode(
            SessionBrowserPanelSnapshot.self,
            from: JSONSerialization.data(withJSONObject: oldJSON)
        )
        let restored = try restore(try roundTrip(snapshot), sourceID: source.panel.id)
        defer { restored.workspace.teardownAllPanels() }
        #expect(restored.panel.currentURL == expected)
        #expect(restored.panel.retainedFigmaPageAddress == nil)
        try assertLegacyFirstSwitch(restored.panel, wasPreview: showingPreview)
    }

    @Test("Ordinary browser records gain no Figma side")
    func ordinaryBrowserStillRestores() throws {
        let address = URL(string: "https://example.com/path")!
        let old = SessionBrowserPanelSnapshot(
            urlString: address.absoluteString, profileID: nil, shouldRenderWebView: true,
            pageZoom: 1.0, developerToolsVisible: false,
            backHistoryURLStrings: nil, forwardHistoryURLStrings: nil
        )
        let panel = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false, websiteDataStore: .nonPersistent())
        defer { panel.close() }
        panel.restoreSessionSnapshot(try roundTrip(old))
        #expect(panel.currentURL == address)
        #expect(panel.retainedFigmaPageAddress == nil)
        #expect(!panel.switchFigmaPreviewAndEditor())
        #expect(panel.webView.url == nil)
        #expect(!panel.figmaFitMark.isPending)
    }

    @Test("Malformed future pair data preserves the showing page", arguments: [false, true], [false, true])
    func malformedPairKeepsShowingSide(showingPreview: Bool, unknownSide: Bool) async throws {
        let source = try await fixture(showingPreview: showingPreview)
        defer { source.workspace.teardownAllPanels() }
        var snapshot = source.workspace.sessionSnapshot(includeScrollback: false)
        let index = try #require(snapshot.panels.firstIndex { $0.id == source.panel.id })
        let record = try #require(snapshot.panels[index].browser)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        var pages = try #require(json["figmaPages"] as? [String: Any])
        if unknownSide { pages["showingSide"] = "canvas" }
        else { pages.removeValue(forKey: "editorURLString") }
        json["figmaPages"] = pages
        let decoded = try JSONDecoder().decode(SessionBrowserPanelSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.figmaPages == nil)
        snapshot.panels[index].browser = decoded
        let restored = try restore(try roundTrip(snapshot), sourceID: source.panel.id)
        defer { restored.workspace.teardownAllPanels() }
        #expect(restored.panel.currentURL == (showingPreview ? source.preview : editorAddress))
        #expect(restored.panel.retainedFigmaPageAddress == nil)
        #expect(restored.workspace.customTitle == "Restart fixture")
        #expect(restored.panel.webView.url == nil)
    }

    @Test("Invalid pair addresses drop the hidden side", arguments: [0, 1, 2, 3, 4, 5])
    func tamperedPairDropsHiddenSide(kind: Int) async throws {
        let source = try await fixture(showingPreview: true)
        defer { source.workspace.teardownAllPanels() }
        var snapshot = try roundTrip(source.workspace.sessionSnapshot(includeScrollback: false))
        let index = try #require(snapshot.panels.firstIndex { $0.id == source.panel.id })
        var browser = try #require(snapshot.panels[index].browser)
        var pages = try #require(browser.figmaPages)
        switch kind {
        case 0: pages.editorURLString = "https://evil.example/design/KEY/screen?node-id=1-1"
        case 1: pages.editorURLString = "file:///etc/passwd"
        case 2:
            let preview = pages.previewURLString
            pages.previewURLString = pages.editorURLString
            pages.editorURLString = preview
        case 3: pages.editorURLString = "https://www.figma.com/design/OTHER/screen?node-id=1-1"
        case 4: pages.showingSide = .editor
        default: pages.editorURLString = "https://embed.figma.com/design/KEY/screen?node-id=1-1"
        }
        browser.figmaPages = pages
        snapshot.panels[index].browser = browser
        let restored = try restore(try roundTrip(snapshot), sourceID: source.panel.id)
        defer { restored.workspace.teardownAllPanels() }
        #expect(restored.panel.currentURL == source.preview)
        #expect(restored.panel.retainedFigmaPageAddress == nil)
        #expect(restored.panel.webView.url == nil)
        try #require(restored.panel.switchFigmaPreviewAndEditor())
        let editor = try #require(restored.panel.currentURL)
        #expect(FigmaFileLink.isEditorLink(editor))
        #expect(FigmaPaneURL.fileKey(fromPaneURL: editor) == "KEY")
        #expect(FigmaPaneURL.node(fromPaneURL: editor) == "12-2")
    }

    @Test("Saving uses the hidden document's live address after it navigates")
    func hiddenLiveAddressWins() async throws {
        let source = try await fixture(showingPreview: false)
        defer { source.workspace.teardownAllPanels() }
        let hiddenEditor = source.panel.webView
        try #require(source.panel.switchFigmaPreviewAndEditor())
        try #require(source.panel.retainedFigmaPageAddress == editorAddress)
        let liveEditor = URL(string: "https://www.figma.com/design/KEY/screen?page-id=99%3A7&node-id=91-8")!
        try await FixtureDocumentLoader().load(hiddenEditor, baseURL: liveEditor)
        try #require(hiddenEditor.url == liveEditor)
        #expect(source.panel.retainedFigmaPageAddress == editorAddress)
        let snapshot = try roundTrip(source.workspace.sessionSnapshot(includeScrollback: false))
        let record = try browserRecord(snapshot, id: source.panel.id)
        #expect(record.figmaPages?.editorURLString == liveEditor.absoluteString)
        let restored = try restore(snapshot, sourceID: source.panel.id)
        defer { restored.workspace.teardownAllPanels() }
        #expect(restored.panel.currentURL == source.preview)
        #expect(restored.panel.retainedFigmaPageAddress == liveEditor)
        try #require(restored.panel.switchFigmaPreviewAndEditor())
        #expect(restored.panel.currentURL == liveEditor)
    }

    private func assertBothSides(_ panel: BrowserPanel, preview: URL, showingPreview: Bool) throws {
        let expected = showingPreview ? preview : editorAddress
        let hidden = showingPreview ? editorAddress : preview
        #expect(panel.currentURL == expected)
        #expect(panel.retainedFigmaPageAddress == hidden)
        // A materialized hidden pane restores metadata, without loading either page.
        panel.noteWebViewVisibility(false, reason: "test.step4.hidden")
        #expect(panel.webView.url == nil)
        #expect(!panel.shouldRenderWebView)
        #expect(panel.hiddenWebViewDiscardKeepLoaded)
        #expect(!panel.figmaFitMark.isPending)
        try #require(panel.switchFigmaPreviewAndEditor())
        #expect(panel.currentURL == hidden)
        #expect(!panel.figmaFitMark.isPending)
        try #require(panel.switchFigmaPreviewAndEditor())
        #expect(panel.currentURL == expected)
        #expect(!panel.figmaFitMark.isPending)
    }

    private func assertLegacyFirstSwitch(_ panel: BrowserPanel, wasPreview: Bool) throws {
        try #require(panel.switchFigmaPreviewAndEditor())
        let address = try #require(panel.currentURL)
        #expect(FigmaPaneURL.isWrapperPage(address) != wasPreview)
        #expect(FigmaPaneURL.node(fromPaneURL: address) == (wasPreview ? "12-2" : "0-1"))
        #expect(!panel.figmaFitMark.isPending)
    }

    private func fixture(showingPreview: Bool) async throws -> (workspace: Workspace, panel: BrowserPanel, preview: URL) {
        _ = NSApplication.shared
        let workspace = Workspace()
        workspace.setCustomTitle("Restart fixture")
        do {
            let terminal = try #require(workspace.focusedPanelId)
            let preview = try FigmaPaneURL.destination(for: document, node: "12-2").url
            let panel = try #require(workspace.newBrowserSplit(
                from: terminal, orientation: .horizontal, url: preview, focus: false,
                allowsExternalBrowserFallback: false, chromeVisibility: .hidden,
                websiteDataStore: .default()
            ))
            let loader = FixtureDocumentLoader()
            panel.webView.stopLoading()
            try await loader.load(panel.webView, baseURL: nil)
            panel.publishObservedDocumentURL(preview)
            try #require(panel.switchFigmaPreviewAndEditor())
            panel.webView.stopLoading()
            try await loader.load(panel.webView, baseURL: editorAddress)
            try #require(panel.webView.url == editorAddress)
            panel.publishObservedDocumentURL(editorAddress)
            if showingPreview { try #require(panel.switchFigmaPreviewAndEditor()) }
            workspace.focusPanel(terminal)
            return (workspace, panel, preview)
        } catch {
            workspace.teardownAllPanels()
            throw error
        }
    }

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private func browserRecord(_ snapshot: SessionWorkspaceSnapshot, id: UUID) throws -> SessionBrowserPanelSnapshot {
        let record = try #require(snapshot.panels.first { $0.id == id })
        return try #require(record.browser)
    }

    private func restore(_ snapshot: SessionWorkspaceSnapshot, sourceID: UUID) throws -> (workspace: Workspace, panel: BrowserPanel) {
        let workspace = Workspace()
        do {
            let map = workspace.restoreSessionSnapshot(snapshot, deferBrowserPanels: true)
            let id = try #require(map[sourceID])
            let deferred = try #require(workspace.panels[id] as? DeferredBrowserPanel)
            let panel = try #require(workspace.materializeDeferredBrowserPanel(deferred))
            return (workspace, panel)
        } catch {
            workspace.teardownAllPanels()
            throw error
        }
    }

    // Frozen pre-step-4 browser schema: unknown future keys are ignored, and the
    // older encoder cannot carry the hidden side into its next save.
    private struct OldBrowserRecord: Codable {
        var urlString: String?
        var profileID: UUID?
        var shouldRenderWebView: Bool
        var pageZoom: Double
        var developerToolsVisible: Bool
        var isMuted: Bool?
        var keepLoaded: Bool?
        var chromeVisibility: BrowserChromeVisibility?
        var omnibarVisible: Bool?
        var backHistoryURLStrings: [String]?
        var forwardHistoryURLStrings: [String]?
        var transparentBackground: Bool?
        var diffViewerToken: String?
        var diffViewerRequestPath: String?
    }

    private final class FixtureDocumentLoader {
        func load(_ view: WKWebView, baseURL: URL?) async throws {
            view.loadHTMLString("<html><body>Restart fixture</body></html>", baseURL: baseURL)
            for _ in 0..<200 {
                try await Task.sleep(for: .milliseconds(50))
                if !view.isLoading, baseURL == nil || view.url == baseURL { return }
            }
            throw NSError(domain: "FigmaSessionFixture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Local document did not settle: expected=\(baseURL?.absoluteString ?? "blank") actual=\(view.url?.absoluteString ?? "nil") loading=\(view.isLoading) delegate=\(String(describing: view.navigationDelegate))"
            ])
        }
    }
}
