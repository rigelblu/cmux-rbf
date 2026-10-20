import AppKit
import CmuxBrowser
import CmuxCommandPalette
import CmuxSettings
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("FigmaPageSwitch", .serialized)
struct FigmaPageSwitchTests {
    private let document = URL(string: "https://www.figma.com/design/KEY/screen")!

    private func panel(on address: URL) -> BrowserPanel {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            chromeVisibility: .hidden,
            websiteDataStore: .nonPersistent()
        )
        panel.publishObservedDocumentURL(address)
        return panel
    }

    private func wrapper() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cm73-switch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("figma-embed.html")
    }

    @Test("The shared action targets the visible Figma pane from the terminal and in Design Focus")
    func switchTargetPreservesTerminalFocus() throws {
        _ = NSApplication.shared
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        defer { workspace.teardownAllPanels() }
        let terminal = try #require(workspace.focusedPanelId)
        #expect(workspace.figmaPageSwitchTarget() == nil)
        let figma = try #require(workspace.newBrowserSplit(
            from: terminal,
            orientation: .horizontal,
            url: document,
            focus: false,
            chromeVisibility: BrowserChromeVisibility(omnibarVisible: false)
        ))
        workspace.focusPanel(terminal)
        #expect(workspace.figmaPageSwitchTarget()?.id == figma.id)
        #expect(workspace.focusedPanelId == terminal)
        let second = try #require(workspace.newBrowserSplit(
            from: terminal,
            orientation: .vertical,
            url: document,
            focus: false,
            chromeVisibility: BrowserChromeVisibility(omnibarVisible: false)
        ))
        workspace.focusPanel(second.id)
        #expect(workspace.figmaPageSwitchTarget()?.id == second.id)
        workspace.focusPanel(terminal)
        #expect(workspace.figmaPageSwitchTarget()?.id == second.id)
        workspace.focusPanel(figma.id)
        workspace.focusPanel(terminal)
        #expect(workspace.figmaPageSwitchTarget()?.id == figma.id)
        try #require(manager.toggleFocusedSplitZoom())
        #expect(workspace.figmaPageSwitchTarget() == nil)
        try #require(manager.toggleFocusedSplitZoom())
        try #require(workspace.toggleDesignFocus())
        let pair = try #require(workspace.bonsplitController.pairZoomPanes)
        let pairedTab = try #require(workspace.bonsplitController.selectedTab(inPane: pair.second))
        #expect(workspace.figmaPageSwitchTarget()?.id == workspace.panelIdFromSurfaceId(pairedTab.id))
        #expect(workspace.focusedPanelId == terminal)
    }

    @Test("First switch makes the canvas on the preview's node without fitting")
    func firstCanvasUsesPreviewNodeAndDoesNotFit() throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let preview = try FigmaPaneURL.destination(for: document, node: "12-2", wrapper: page).url
        let panel = panel(on: preview)
        defer { panel.close() }
        let original = panel.webView
        try #require(panel.switchFigmaPreviewAndCanvas(wrapper: page))
        #expect(panel.webView !== original)
        #expect(panel.webView.configuration.websiteDataStore === original.configuration.websiteDataStore)
        #expect(panel.currentURL?.host == "www.figma.com")
        #expect(panel.currentURL.flatMap { FigmaPaneURL.node(fromPaneURL: $0, wrapper: page) } == "12-2")
        #expect(!panel.figmaFitMark.isPending)
    }

    @Test("Switching both ways preserves each live document and zoom")
    func bothSidesKeepDocuments() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let preview = try FigmaPaneURL.destination(for: document, node: "12-2", wrapper: page).url
        let panel = panel(on: preview)
        defer { panel.close() }
        let previewView = panel.webView
        let loader = DocumentLoader()
        try await loader.seed(previewView, value: "preview")
        panel.publishObservedDocumentURL(preview)
        previewView.pageZoom = 1.2
        try #require(panel.switchFigmaPreviewAndCanvas(wrapper: page))
        let canvasView = panel.webView
        canvasView.stopLoading()
        try await loader.seed(canvasView, value: "canvas")
        canvasView.pageZoom = 1.4
        let starts = NavigationStarts()
        let observations = [previewView, canvasView].map { view in
            view.observe(\.isLoading, options: [.new]) { _, change in
                if change.newValue == true { starts.record() }
            }
        }
        defer { observations.forEach { $0.invalidate() } }
        // Seeded local documents keep the binding separate, as WebKit URL observation does.
        panel.publishObservedDocumentURL(document)
        try #require(panel.switchFigmaPreviewAndCanvas(wrapper: page))
        #expect(panel.webView === previewView)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!panel.webView.isLoading)
        #expect(starts.count == 0, "Switch-back started a navigation")
        #expect(panel.webView.pageZoom == 1.2)
        #expect(try await panel.webView.evaluateJavaScript("window.cm73Place") as? String == "preview")
        #expect(panel.currentURL == preview)
        try #require(panel.switchFigmaPreviewAndCanvas(wrapper: page))
        #expect(panel.webView === canvasView)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!panel.webView.isLoading)
        #expect(starts.count == 0, "Switch-back started a navigation")
        #expect(panel.webView.pageZoom == 1.4)
        #expect(try await panel.webView.evaluateJavaScript("window.cm73Place") as? String == "canvas")
    }

    @Test("A canvas opened first gets the first-page preview and keeps its canvas")
    func firstPreviewUsesFirstPage() throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let panel = panel(on: document)
        defer { panel.close() }
        let canvas = panel.webView
        canvas.pageZoom = 1.7
        try #require(panel.switchFigmaPreviewAndCanvas(wrapper: page))
        #expect(panel.currentURL.flatMap { FigmaPaneURL.node(fromPaneURL: $0, wrapper: page) } == "0-1")
        try #require(panel.switchFigmaPreviewAndCanvas(wrapper: page))
        #expect(panel.webView === canvas)
        #expect(panel.webView.pageZoom == 1.7)
    }

    @Test("goto shows the requested preview and keeps a previously open canvas")
    func gotoKeepsCanvas() throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let previewAddress = try FigmaPaneURL.destination(for: document, node: "12-2", wrapper: page).url
        let panel = panel(on: previewAddress)
        defer { panel.close() }
        try #require(panel.switchFigmaPreviewAndCanvas(wrapper: page))
        let canvas = panel.webView
        canvas.pageZoom = 1.7
        try #require(panel.gotoFigmaNode("21-4", wrapper: page))
        #expect(panel.webView !== canvas)
        #expect(panel.currentURL.flatMap { FigmaPaneURL.node(fromPaneURL: $0, wrapper: page) } == "21-4")
        let preview = panel.webView
        try #require(panel.gotoFigmaNode("31-8", wrapper: page))
        #expect(panel.webView === preview)
        try #require(panel.switchFigmaPreviewAndCanvas(wrapper: page))
        #expect(panel.webView === canvas)
        #expect(panel.webView.pageZoom == 1.7)
        #expect(!panel.figmaFitMark.isPending)
    }

    @Test("Both delegate request paths survive replacement", arguments: [false, true])
    func delegateRequestsSurviveReplacement(memoryPressure: Bool) throws {
        let panel = BrowserPanel(workspaceId: UUID(), initialURL: URL(string: "https://example.com/recovery")!)
        defer { panel.close() }
        let original = panel.webView
        let delegate = try #require(original.navigationDelegate as? BrowserNavigationDelegate)
        panel.noteWebViewVisibility(false, reason: "test.hidden")
        delegate.webViewWebContentProcessDidTerminate(original)
        if memoryPressure {
            try #require(panel.discardHiddenWebViewForSystemMemoryPressure())
            panel.noteWebViewVisibility(true, reason: "test.reveal")
        } else {
            try #require(panel.recoverTerminatedWebContent(reason: "test"))
        }
        #expect(panel.webView !== original)
        let active = try #require(panel.webView.navigationDelegate as? BrowserNavigationDelegate)
        let request = try #require(active.requestNavigation)
        var started = false
        request(URLRequest(url: URL(string: "https://example.com/navigation")!), .currentTab) { started = $0 != nil }
        #expect(started, "Navigation delegate dropped the request after replacement")
        let ui = try #require(panel.webView.uiDelegate as? BrowserUIDelegate)
        let uiURL = URL(string: "https://example.com/ui-request")!
        ui.requestNavigation?(URLRequest(url: uiURL), .currentTab)
        #expect(active.lastAttemptedURL == uiURL, "UI delegate dropped the request after replacement")
    }

    @Test("Explicit ordinary-pane goto and preview fit reload keep the one view")
    func ordinaryPaneGotoAndFit() throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let panel = BrowserPanel(workspaceId: UUID(), chromeVisibility: .visible, websiteDataStore: .nonPersistent())
        defer { panel.close() }
        panel.publishObservedDocumentURL(document)
        let view = panel.webView
        #expect(panel.gotoFigmaNode("12-2", wrapper: page))
        #expect(panel.webView === view)
        #expect(panel.currentURL.flatMap { FigmaPaneURL.node(fromPaneURL: $0, wrapper: page) } == "12-2")
        #expect(panel.gotoFigmaNode("12-2", wrapper: page))
        #expect(panel.webView === view)
        #expect((view.navigationDelegate as? BrowserNavigationDelegate)?.lastAttemptedURL == panel.currentURL)
    }

    @Test("Canvas-only goto preserves native Back until cross-side Back exists")
    func canvasOnlyGotoPreservesBack() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let canvasFile = page.deletingLastPathComponent().appendingPathComponent("canvas.html")
        try "<html><body>Canvas history fixture</body></html>".write(to: canvasFile, atomically: true, encoding: .utf8)
        let panel = panel(on: document)
        defer { panel.close() }
        let canvas = panel.webView
        canvas.loadFileURL(canvasFile, allowingReadAccessTo: canvasFile.deletingLastPathComponent())
        for _ in 0..<200 {
            if canvas.url == canvasFile && !canvas.isLoading { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(canvas.url == canvasFile && !canvas.isLoading)
        panel.publishObservedDocumentURL(document)
        try #require(panel.gotoFigmaNode("12-2", wrapper: page))
        try #require(panel.webView === canvas, "Canvas-only goto discarded native Back history")
        for _ in 0..<200 {
            if canvas.backForwardList.backItem?.url == canvasFile { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(canvas.backForwardList.backItem?.url == canvasFile)
        #expect(canvas.canGoBack)
    }

    @Test("Memory pressure retains the hidden preview's last board address")
    func memoryPressureRemembersHiddenBoard() throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let preview = try FigmaPaneURL.destination(for: document, node: "47-9", wrapper: page).url
        let panel = panel(on: preview)
        defer { panel.close() }
        try #require(panel.switchFigmaPreviewAndCanvas(wrapper: page))
        panel.noteWebViewVisibility(false, reason: "test.hidden")
        let delegate = try #require(panel.webView.navigationDelegate as? BrowserNavigationDelegate)
        delegate.webViewWebContentProcessDidTerminate(panel.webView)
        try #require(panel.discardHiddenWebViewForSystemMemoryPressure())
        panel.noteWebViewVisibility(true, reason: "test.reveal")
        try #require(panel.switchFigmaPreviewAndCanvas(wrapper: page))
        #expect(panel.currentURL.flatMap { FigmaPaneURL.node(fromPaneURL: $0, wrapper: page) } == "47-9")
    }

    @Test("A preview fit reload preserves the discarded canvas address")
    func previewFitPreservesDiscardedCanvasAddress() throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let preview = try FigmaPaneURL.destination(for: document, node: "47-9", wrapper: page).url
        let panel = panel(on: preview)
        defer { panel.close() }
        try #require(panel.switchFigmaPreviewAndCanvas(wrapper: page))
        let canvasAddress = URL(string: document.absoluteString + "?node-id=99-1")!
        panel.publishObservedDocumentURL(canvasAddress)
        try #require(panel.switchFigmaPreviewAndCanvas(wrapper: page))
        panel.noteWebViewVisibility(false, reason: "test.hidden")
        let delegate = try #require(panel.webView.navigationDelegate as? BrowserNavigationDelegate)
        delegate.webViewWebContentProcessDidTerminate(panel.webView)
        try #require(panel.discardHiddenWebViewForSystemMemoryPressure())
        panel.noteWebViewVisibility(true, reason: "test.reveal")
        try #require(panel.retainedFigmaPageAddress == canvasAddress)
        // CLI preview fit reloads through this same goto action, on the same node.
        try #require(panel.gotoFigmaNode("47-9", wrapper: page))
        #expect(panel.retainedFigmaPageAddress == canvasAddress)
        try #require(panel.switchFigmaPreviewAndCanvas(wrapper: page))
        #expect(panel.currentURL.flatMap { FigmaPaneURL.node(fromPaneURL: $0, wrapper: page) } == "99-1")
    }

    @Test("Open in Figma keeps the showing view's native history until cross-side Back exists")
    func openInFigmaStaysInPlace() throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let preview = try FigmaPaneURL.destination(for: document, node: "12-2", wrapper: page).url
        let panel = panel(on: preview)
        defer { panel.close() }
        try #require(panel.gotoFigmaNode("12-2", wrapper: page))
        let view = panel.webView
        let delegate = try #require(view.navigationDelegate as? BrowserNavigationDelegate)
        var started = false
        delegate.requestNavigation?(URLRequest(url: document), .currentTab) { started = $0 != nil }
        #expect(panel.webView === view)
        #expect(started)
    }

    @Test("Workspace key and palette action switches the visible pane without moving terminal focus")
    func workspaceActionPreservesFocus() throws {
        _ = NSApplication.shared
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        defer { workspace.teardownAllPanels() }
        let terminal = try #require(workspace.focusedPanelId)
        let preview = try FigmaPaneURL.destination(for: document, node: "12-2").url
        let figma = try #require(workspace.newBrowserSplit(
            from: terminal, orientation: .horizontal, url: preview, focus: false,
            chromeVisibility: BrowserChromeVisibility(omnibarVisible: false)
        ))
        workspace.focusPanel(terminal)
        let view = figma.webView
        try #require(workspace.switchFigmaPreviewAndCanvas())
        #expect(figma.webView !== view)
        #expect(workspace.focusedPanelId == terminal)
        #expect(figma.currentURL?.host == "www.figma.com")
    }

    @Test("The palette switch row advertises its configured shortcut")
    func paletteShortcutHint() {
        #expect(ContentView.commandPaletteShortcutAction(forCommandID: "palette.switchFigmaPreviewAndCanvas") == .switchFigmaPreviewAndCanvas)
    }

    @Test("figma.goto is advertised and emits the browser navigation event")
    func capabilitiesAndNavigationEvent() throws {
        let response = TerminalController.shared.handleSocketLine(#"{"id":1,"method":"system.capabilities","params":{}}"#)
        let data = try #require(response.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try #require(object["result"] as? [String: Any])
        #expect((result["methods"] as? [String])?.contains("figma.goto") == true)
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }
        CmuxSocketEventMapper.publish(
            command: #"{"id":1,"method":"figma.goto","params":{"surface_id":"pane","node":"12-2"}}"#,
            response: #"{"id":1,"ok":true,"result":{"side":"preview","stayed":false}}"#
        )
        #expect(CmuxEventBus.shared.retainedSnapshot().last?["name"] as? String == "browser.navigation")
    }

    @Test("The configured key dispatch switches the pane and keeps terminal focus")
    func keyEntranceSwitchesPane() throws {
        _ = NSApplication.shared
        let priorDelegate = AppDelegate.shared
        let delegate = AppDelegate()
        AppDelegate.shared = delegate
        let fixture = try switchEntranceFixture()
        let windowID = delegate.registerMainWindowContextForTesting(tabManager: fixture.manager)
        delegate.tabManager = fixture.manager
        let action = KeyboardShortcutSettings.Action.switchFigmaPreviewAndCanvas
        let priorBinding = UserDefaults.standard.object(forKey: action.defaultsKey)
        let priorFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(prefix: "cm73-switch-key")
        defer {
            delegate.unregisterMainWindowContextForTesting(windowId: windowID)
            delegate.tabManager = nil
            AppDelegate.shared = priorDelegate
            KeyboardShortcutSettings.settingsFileStore = priorFileStore
            if let priorBinding { UserDefaults.standard.set(priorBinding, forKey: action.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: action.defaultsKey) }
            fixture.workspace.teardownAllPanels()
        }
        KeyboardShortcutSettings.setShortcut(action.defaultShortcut, for: action)
        let shortcut = KeyboardShortcutSettings.shortcut(for: action)
        let keyCode = try #require(shortcut.firstStroke.resolvedKeyCode())
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: shortcut.modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            characters: shortcut.menuItemKeyEquivalent ?? shortcut.key,
            charactersIgnoringModifiers: shortcut.menuItemKeyEquivalent ?? shortcut.key,
            isARepeat: false, keyCode: keyCode
        ))
        try #require(shortcut.matches(event: event))
        try #require(delegate.shortcutWhenClauseAllows(action: action, event: event))
        let original = fixture.figma.webView
        #expect(delegate.handleConfiguredShortcutKeyEquivalent(event))
        #expect(fixture.figma.webView !== original)
        #expect(fixture.figma.currentURL?.host == "www.figma.com")
        #expect(fixture.workspace.focusedPanelId == fixture.terminal)
    }

    @Test("The real palette handler switches its supplied manager, not a global manager")
    func paletteEntranceSwitchesSuppliedManager() throws {
        let intended = try switchEntranceFixture()
        let other = try switchEntranceFixture()
        let priorDelegate = AppDelegate.shared
        let delegate = AppDelegate()
        AppDelegate.shared = delegate
        delegate.tabManager = other.manager
        defer {
            delegate.tabManager = nil
            AppDelegate.shared = priorDelegate
            intended.workspace.teardownAllPanels()
            other.workspace.teardownAllPanels()
        }
        let original = intended.figma.webView
        let otherOriginal = other.figma.webView
        var registry = CommandPaletteHandlerRegistry()
        ContentView.registerFigmaPageSwitchPaletteHandler(&registry, tabManager: intended.manager)
        let handler = try #require(registry.handler(for: "palette.switchFigmaPreviewAndCanvas"))
        handler()
        #expect(intended.figma.webView !== original)
        #expect(intended.figma.currentURL?.host == "www.figma.com")
        #expect(intended.workspace.focusedPanelId == intended.terminal)
        #expect(other.figma.webView === otherOriginal)
        #expect(other.workspace.focusedPanelId == other.terminal)
    }

    @Test("Injected defaults can reject goto before the pane moves")
    func gotoRespectsInjectedDefaults() throws {
        let suite = "cm73-goto-policy-\(UUID().uuidString)"
        let defaults = try #require(FigmaForcedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: ManagedDevicePolicyKey.browserAllowLocalFiles.rawValue)
        try #require(!BrowserURLAllowlistPolicy(defaults: defaults).allowsLocalFiles)
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let panel = panel(on: document)
        defer { panel.close() }
        let address = panel.currentURL
        #expect(!panel.gotoFigmaNode("12-2", wrapper: page, defaults: defaults))
        #expect(panel.currentURL == address)
    }

    private func switchEntranceFixture() throws -> (manager: TabManager, workspace: Workspace, figma: BrowserPanel, terminal: UUID) {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let terminal = try #require(workspace.focusedPanelId)
        let preview = try FigmaPaneURL.destination(for: document, node: "12-2").url
        let figma = try #require(workspace.newBrowserSplit(
            from: terminal, orientation: .horizontal, url: preview, focus: false,
            chromeVisibility: BrowserChromeVisibility(omnibarVisible: false)
        ))
        workspace.focusPanel(terminal)
        return (manager, workspace, figma, terminal)
    }

    private final class FigmaForcedDefaults: UserDefaults, @unchecked Sendable {
        override func objectIsForced(forKey defaultName: String) -> Bool {
            defaultName == ManagedDevicePolicyKey.browserAllowLocalFiles.rawValue
        }
    }

    private final class NavigationStarts: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func record() { lock.lock(); defer { lock.unlock() }; value += 1 }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private final class DocumentLoader: NSObject, WKNavigationDelegate {
        private var completion: CheckedContinuation<Void, Error>?
        private var expectedNavigation: WKNavigation?

        func seed(_ webView: WKWebView, value: String) async throws {
            let previous = webView.navigationDelegate
            defer {
                webView.navigationDelegate = previous
                expectedNavigation = nil
            }
            webView.navigationDelegate = self
            let deadline = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                completion?.resume(throwing: URLError(.timedOut))
                completion = nil
            }
            defer { deadline.cancel() }
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                expectedNavigation = webView.loadHTMLString("<html><body>Fixture</body></html>", baseURL: nil)
            }
            // A reload must erase this state; never bake it into the document.
            _ = try await webView.evaluateJavaScript("window.cm73Place='\(value)'")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigation === expectedNavigation else { return }
            completion?.resume()
            completion = nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard navigation === expectedNavigation else { return }
            completion?.resume(throwing: error)
            completion = nil
        }
    }
}
