import AppKit
import Bonsplit
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

    @Test("The pair control reads the showing side and focuses Figma from either header")
    func pairControlSwitchesAndFocusesFigma() throws {
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
        let controller = workspace.bonsplitController
        #expect(controller.pairFigmaPage() == nil)
        workspace.focusPanel(terminal)
        try #require(workspace.toggleDesignFocus())
        #expect(controller.pairFigmaPage() == .preview)
        let previewView = figma.webView
        controller.requestFigmaPage(.editor)
        #expect(controller.pairFigmaPage() == .editor)
        #expect(figma.webView !== previewView)
        #expect(workspace.focusedPanelId == figma.id)
        let editorView = figma.webView
        workspace.focusPanel(terminal)
        controller.requestFigmaPage(.editor)
        #expect(figma.webView === editorView)
        #expect(workspace.focusedPanelId == terminal, "selected-half click must do nothing")
        controller.requestFigmaPage(.preview)
        #expect(figma.webView === previewView)
        #expect(controller.pairFigmaPage() == .preview)
        #expect(workspace.focusedPanelId == figma.id)
        try #require(workspace.toggleDesignFocus())
        controller.requestFigmaPage(.editor)
        #expect(figma.webView === previewView)
        #expect(controller.pairFigmaPage() == nil)
    }

    @Test("Hover control rechecks a key switch before deciding whether its choice changes the pane")
    func pairControlUsesLiveSideAfterKeySwitch() throws {
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
        try #require(workspace.toggleDesignFocus())
        let controller = workspace.bonsplitController
        let previewView = figma.webView
        try #require(workspace.switchFigmaPreviewAndEditor())
        #expect(controller.pairFigmaPage() == .editor)
        controller.requestFigmaPage(.editor)
        #expect(figma.webView !== previewView)
        #expect(workspace.focusedPanelId == terminal)
        controller.requestFigmaPage(.preview)
        #expect(figma.webView === previewView)
        #expect(workspace.focusedPanelId == figma.id)
    }

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

    @Test("First switch makes the editor on the preview's node without fitting")
    func firstEditorUsesPreviewNodeAndDoesNotFit() throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let preview = try FigmaPaneURL.destination(for: document, node: "12-2", wrapper: page).url
        let panel = panel(on: preview)
        defer { panel.close() }
        let original = panel.webView
        try #require(panel.switchFigmaPreviewAndEditor(wrapper: page))
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
        try #require(panel.switchFigmaPreviewAndEditor(wrapper: page))
        let editorView = panel.webView
        editorView.stopLoading()
        try await loader.seed(editorView, value: "editor")
        editorView.pageZoom = 1.4
        let starts = NavigationStarts()
        let observations = [previewView, editorView].map { view in
            view.observe(\.isLoading, options: [.new]) { _, change in
                if change.newValue == true { starts.record() }
            }
        }
        defer { observations.forEach { $0.invalidate() } }
        // Seeded local documents keep the binding separate, as WebKit URL observation does.
        panel.publishObservedDocumentURL(document)
        try #require(panel.switchFigmaPreviewAndEditor(wrapper: page))
        #expect(panel.webView === previewView)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!panel.webView.isLoading)
        #expect(starts.count == 0, "Switch-back started a navigation")
        #expect(panel.webView.pageZoom == 1.2)
        #expect(try await panel.webView.evaluateJavaScript("window.cm73Place") as? String == "preview")
        #expect(panel.currentURL == preview)
        try #require(panel.switchFigmaPreviewAndEditor(wrapper: page))
        #expect(panel.webView === editorView)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!panel.webView.isLoading)
        #expect(starts.count == 0, "Switch-back started a navigation")
        #expect(panel.webView.pageZoom == 1.4)
        #expect(try await panel.webView.evaluateJavaScript("window.cm73Place") as? String == "editor")
    }

    @Test("A editor opened first gets the first-page preview and keeps its editor")
    func firstPreviewUsesFirstPage() throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let panel = panel(on: document)
        defer { panel.close() }
        let editor = panel.webView
        editor.pageZoom = 1.7
        try #require(panel.switchFigmaPreviewAndEditor(wrapper: page))
        #expect(panel.currentURL.flatMap { FigmaPaneURL.node(fromPaneURL: $0, wrapper: page) } == "0-1")
        try #require(panel.switchFigmaPreviewAndEditor(wrapper: page))
        #expect(panel.webView === editor)
        #expect(panel.webView.pageZoom == 1.7)
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

    @Test("Memory pressure retains the hidden preview's last board address")
    func memoryPressureRemembersHiddenBoard() throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let preview = try FigmaPaneURL.destination(for: document, node: "47-9", wrapper: page).url
        let panel = panel(on: preview)
        defer { panel.close() }
        try #require(panel.switchFigmaPreviewAndEditor(wrapper: page))
        panel.noteWebViewVisibility(false, reason: "test.hidden")
        let delegate = try #require(panel.webView.navigationDelegate as? BrowserNavigationDelegate)
        delegate.webViewWebContentProcessDidTerminate(panel.webView)
        try #require(panel.discardHiddenWebViewForSystemMemoryPressure())
        panel.noteWebViewVisibility(true, reason: "test.reveal")
        try #require(panel.switchFigmaPreviewAndEditor(wrapper: page))
        #expect(panel.currentURL.flatMap { FigmaPaneURL.node(fromPaneURL: $0, wrapper: page) } == "47-9")
    }

    @Test("A preview fit reload preserves the discarded editor address")
    func previewFitPreservesDiscardedEditorAddress() throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let preview = try FigmaPaneURL.destination(for: document, node: "47-9", wrapper: page).url
        let panel = panel(on: preview)
        defer { panel.close() }
        try #require(panel.switchFigmaPreviewAndEditor(wrapper: page))
        let editorAddress = URL(string: document.absoluteString + "?node-id=99-1")!
        panel.publishObservedDocumentURL(editorAddress)
        try #require(panel.switchFigmaPreviewAndEditor(wrapper: page))
        panel.noteWebViewVisibility(false, reason: "test.hidden")
        let delegate = try #require(panel.webView.navigationDelegate as? BrowserNavigationDelegate)
        delegate.webViewWebContentProcessDidTerminate(panel.webView)
        try #require(panel.discardHiddenWebViewForSystemMemoryPressure())
        panel.noteWebViewVisibility(true, reason: "test.reveal")
        try #require(panel.retainedFigmaPageAddress == editorAddress)
        // CLI preview fit reloads through this same goto action, on the same node.
        try #require(panel.gotoFigmaNode("47-9", wrapper: page, purpose: .fit))
        #expect(panel.retainedFigmaPageAddress == editorAddress)
        try #require(panel.switchFigmaPreviewAndEditor(wrapper: page))
        #expect(panel.currentURL.flatMap { FigmaPaneURL.node(fromPaneURL: $0, wrapper: page) } == "99-1")
    }

    @Test("Open in Figma opens the editor beside the preview and reports its navigation start")
    func openInFigmaOpensEditorBesidePreview() throws {
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
        #expect(panel.webView !== view)
        #expect(panel.currentURL == document)
        #expect(panel.retainedFigmaPageAddress.map { FigmaPaneURL.isWrapperPage($0, wrapper: page) } == true)
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
        try #require(workspace.switchFigmaPreviewAndEditor())
        #expect(figma.webView !== view)
        #expect(workspace.focusedPanelId == terminal)
        #expect(figma.currentURL?.host == "www.figma.com")
    }

    @Test("The palette switch row advertises its configured shortcut")
    func paletteShortcutHint() {
        #expect(ContentView.commandPaletteShortcutAction(forCommandID: "palette.switchFigmaPreviewAndEditor") == .switchFigmaPreviewAndEditor)
    }

    // cmux-rbf (#cm-73.32)
    @Test("The palette motion row advertises its configured shortcut")
    func paletteMotionShortcutHint() {
        #expect(ContentView.commandPaletteShortcutAction(forCommandID: "palette.toggleFigmaMotion") == .toggleFigmaMotion)
    }

    // cmux-rbf (#cm-73.32)
    @Test("The row motion button visibility rule evaluates as a pure decision")
    func rowMotionButtonVisibilityRule() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        defer { workspace.teardownAllPanels() }
        let terminal = try #require(workspace.focusedPanelId)
        let controller = workspace.bonsplitController

        // 1. Marked design file preview in Design Focus: still when not playing, playing when playing
        let markedPreview = try FigmaPaneURL.destination(for: document, node: "12-2", motion: true).url
        let figma = try #require(workspace.newBrowserSplit(
            from: terminal, orientation: .horizontal, url: markedPreview, focus: false,
            chromeVisibility: BrowserChromeVisibility(omnibarVisible: false)
        ))
        try #require(workspace.toggleDesignFocus())
        #expect(controller.pairFigmaMotionState() == .still)
        figma.isFigmaMotionPlaying = true
        #expect(controller.pairFigmaMotionState() == .playing)
        figma.isFigmaMotionPlaying = false
        #expect(controller.pairFigmaMotionState() == .still)

        // 2. Editor side: hidden even with motion mark on preview
        try #require(figma.switchFigmaPreviewAndEditor())
        #expect(controller.pairFigmaMotionState() == .hidden)
        try #require(figma.switchFigmaPreviewAndEditor())
        #expect(controller.pairFigmaMotionState() == .still)

        // 3. Unmarked design file preview: hidden
        let unmarkedPreview = try FigmaPaneURL.destination(for: document, node: "12-2", motion: false).url
        figma.navigate(to: unmarkedPreview)
        #expect(controller.pairFigmaMotionState() == .hidden)

        // 4. FigJam board preview with motion mark: hidden
        let boardDoc = URL(string: "https://www.figma.com/board/KEY/whiteboard")!
        let boardPreview = try FigmaPaneURL.destination(for: boardDoc, node: "12-2", motion: true).url
        figma.navigate(to: boardPreview)
        #expect(controller.pairFigmaMotionState() == .hidden)

        // 5. Slide deck preview with motion mark: hidden
        let slidesDoc = URL(string: "https://www.figma.com/slides/KEY/deck")!
        let slidesPreview = try FigmaPaneURL.destination(for: slidesDoc, node: "12-2", motion: true).url
        figma.navigate(to: slidesPreview)
        #expect(controller.pairFigmaMotionState() == .hidden)
    }

    // cmux-rbf (#cm-73.32)
    @Test("The motion button's tooltip names a shortcut only once one is bound")
    func motionTooltipNamesShortcutOnlyWhenBound() {
        #expect(Workspace.figmaMotionTooltip("Play motion", shortcut: .unbound) == "Play motion")
        #expect(Workspace.figmaMotionTooltip("Show still", shortcut: .unbound) == "Show still")
        let bound = StoredShortcut(key: "m", command: true, shift: true, option: true, control: false)
        let tooltip = Workspace.figmaMotionTooltip("Play motion", shortcut: bound)
        #expect(tooltip == "Play motion (\(bound.displayString))")
        // The row's own tooltips go through it while the action ships with no key.
        let rowTooltips = Workspace.currentSplitButtonTooltips()
        #expect(rowTooltips.figmaPlayMotion == "Play motion")
        #expect(rowTooltips.figmaShowStill == "Show still")
    }

    // cmux-rbf (#cm-73.32)
    @Test("The palette motion availability rule and title follow state")
    func paletteMotionAvailabilityAndTitle() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        defer { workspace.teardownAllPanels() }
        let terminal = try #require(workspace.focusedPanelId)

        let contribution = ContentView.figmaMotionCommandContribution()

        // 1. Unmarked design file preview: available in or out of Design Focus
        let unmarkedPreview = try FigmaPaneURL.destination(for: document, node: "12-2", motion: false).url
        let figma = try #require(workspace.newBrowserSplit(
            from: terminal, orientation: .horizontal, url: unmarkedPreview, focus: false,
            chromeVisibility: BrowserChromeVisibility(omnibarVisible: false)
        ))
        #expect(workspace.figmaMotionTarget() === figma)
        var snapshot = CommandPaletteContextSnapshot()
        snapshot.setBool(CommandPaletteContextKeys.hasWorkspace, true)
        let motionTarget = workspace.figmaMotionTarget()
        snapshot.setBool(CommandPaletteContextKeys.workspaceCanToggleFigmaMotion, motionTarget != nil)
        snapshot.setBool(CommandPaletteContextKeys.workspaceFigmaMotionIsPlaying, motionTarget?.isFigmaMotionPlaying == true)
        #expect(contribution.enablement(snapshot))
        #expect(contribution.title(snapshot) == "Figma: Play Motion")

        // When playing:
        figma.isFigmaMotionPlaying = true
        snapshot.setBool(CommandPaletteContextKeys.workspaceFigmaMotionIsPlaying, figma.isFigmaMotionPlaying)
        #expect(contribution.title(snapshot) == "Figma: Show Still")
        figma.isFigmaMotionPlaying = false

        // 2. Editor: unavailable
        try #require(figma.switchFigmaPreviewAndEditor())
        #expect(workspace.figmaMotionTarget() == nil)
        snapshot.setBool(CommandPaletteContextKeys.workspaceCanToggleFigmaMotion, workspace.figmaMotionTarget() != nil)
        #expect(!contribution.enablement(snapshot))

        // 3. FigJam board or slide deck: unavailable
        try #require(figma.switchFigmaPreviewAndEditor())
        let boardDoc = URL(string: "https://www.figma.com/board/KEY/whiteboard")!
        let boardPreview = try FigmaPaneURL.destination(for: boardDoc, node: "12-2", motion: true).url
        figma.navigate(to: boardPreview)
        #expect(workspace.figmaMotionTarget() == nil)
        snapshot.setBool(CommandPaletteContextKeys.workspaceCanToggleFigmaMotion, workspace.figmaMotionTarget() != nil)
        #expect(!contribution.enablement(snapshot))
    }

    // cmux-rbf (#cm-73.32)
    @Test("The real palette motion handler toggles motion on its manager")
    func paletteMotionEntranceTogglesSuppliedManager() throws {
        let intended = try switchEntranceFixture()
        defer { intended.workspace.teardownAllPanels() }
        let other = try switchEntranceFixture()
        defer { other.workspace.teardownAllPanels() }

        var registry = CommandPaletteHandlerRegistry()
        ContentView.registerFigmaMotionPaletteHandler(&registry, tabManager: intended.manager)
        let handler = try #require(registry.handler(for: "palette.toggleFigmaMotion"))
        #expect(intended.figma.figmaPlayRequestCount == 0)
        #expect(other.figma.figmaPlayRequestCount == 0)

        handler()

        #expect(intended.figma.figmaPlayRequestCount == 1)
        #expect(other.figma.figmaPlayRequestCount == 0)
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
            response: #"{"id":1,"ok":true,"result":{"side":"preview"}}"#
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
        let action = KeyboardShortcutSettings.Action.switchFigmaPreviewAndEditor
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
        let handler = try #require(registry.handler(for: "palette.switchFigmaPreviewAndEditor"))
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

    @Test("Pointing releases the old Editor from either side", arguments: [false, true], ["12-2", "81-9"])
    func pointingReleasesEditor(showEditor: Bool, node: String) throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let preview = try FigmaPaneURL.destination(for: document, node: "12-2", wrapper: page).url
        let pane = panel(on: preview)
        defer { pane.close() }
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        let oldEditor = pane.webView
        if !showEditor { try #require(pane.switchFigmaPreviewAndEditor(wrapper: page)) }
        try #require(pane.gotoFigmaNode(node, wrapper: page))
        let pointed = try #require(pane.currentURL)
        #expect(FigmaPaneURL.isWrapperPage(pointed, wrapper: page))
        #expect(FigmaPaneURL.node(fromPaneURL: pointed, wrapper: page) == node)
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        #expect(pane.webView !== oldEditor)
        #expect(FigmaPaneURL.node(fromPaneURL: try #require(pane.currentURL), wrapper: page) == node)
    }

    @Test("A link-click move releases the old Editor and opens the pointed node next")
    func linkPointingReleasesEditor() throws {
        let fixture = try switchEntranceFixture()
        defer { fixture.workspace.teardownAllPanels() }
        try #require(fixture.workspace.switchFigmaPreviewAndEditor())
        let oldEditor = fixture.figma.webView
        let target = URL(string: document.absoluteString + "?node-id=83-7")!
        try #require(fixture.workspace.openClickedFigmaLink(target, sourcePanelId: fixture.terminal))
        #expect(FigmaPaneURL.isWrapperPage(try #require(fixture.figma.currentURL)))
        #expect(FigmaPaneURL.node(fromPaneURL: try #require(fixture.figma.currentURL)) == "83-7")
        try #require(fixture.workspace.switchFigmaPreviewAndEditor())
        #expect(fixture.figma.webView !== oldEditor)
        #expect(FigmaPaneURL.node(fromPaneURL: try #require(fixture.figma.currentURL)) == "83-7")
    }

    @Test("Pointing reports Preview without a stayed field")
    func pointingSocketReportsPreview() async throws {
        let fixture = try switchEntranceFixture()
        let priorDelegate = AppDelegate.shared
        let priorManager = TerminalController.shared.tabManager
        let delegate = AppDelegate()
        AppDelegate.shared = delegate
        delegate.tabManager = fixture.manager
        let windowID = delegate.registerMainWindowContextForTesting(tabManager: fixture.manager)
        TerminalController.shared.setActiveTabManager(fixture.manager)
        defer {
            TerminalController.shared.setActiveTabManager(priorManager)
            delegate.unregisterMainWindowContextForTesting(windowId: windowID)
            delegate.tabManager = nil
            AppDelegate.shared = priorDelegate
            fixture.workspace.teardownAllPanels()
        }
        try #require(fixture.workspace.switchFigmaPreviewAndEditor())
        let editor = fixture.figma.webView
        let request: [String: Any] = ["id": 1, "method": "figma.goto", "params": [
            "window_id": windowID.uuidString, "workspace_id": fixture.workspace.id.uuidString,
            "surface_id": fixture.figma.id.uuidString, "node": "61-3"
        ]]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let response = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: TerminalController.shared.handleSocketLine(line))
            }
        }
        let object = try #require(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        try #require(object["ok"] as? Bool == true, "\(response)")
        let result = try #require(object["result"] as? [String: Any])
        #expect(result["side"] as? String == "preview")
        #expect(result["stayed"] == nil)
        #expect(ObjectIdentifier(fixture.figma.webView) != ObjectIdentifier(editor))
        #expect(fixture.workspace.focusedPanelId == fixture.terminal)
    }

    @Test("Unknown goto purpose is rejected before the pane moves")
    func unknownPointingPurposeIsRejected() async throws {
        let fixture = try switchEntranceFixture()
        let priorDelegate = AppDelegate.shared
        let priorManager = TerminalController.shared.tabManager
        let delegate = AppDelegate()
        AppDelegate.shared = delegate
        delegate.tabManager = fixture.manager
        let windowID = delegate.registerMainWindowContextForTesting(tabManager: fixture.manager)
        TerminalController.shared.setActiveTabManager(fixture.manager)
        defer {
            TerminalController.shared.setActiveTabManager(priorManager)
            delegate.unregisterMainWindowContextForTesting(windowId: windowID)
            delegate.tabManager = nil
            AppDelegate.shared = priorDelegate
            fixture.workspace.teardownAllPanels()
        }
        try #require(fixture.workspace.switchFigmaPreviewAndEditor())
        let editor = fixture.figma.webView
        let request: [String: Any] = ["id": 1, "method": "figma.goto", "params": [
            "window_id": windowID.uuidString, "workspace_id": fixture.workspace.id.uuidString,
            "surface_id": fixture.figma.id.uuidString, "node": "61-3", "purpose": "unknown"
        ]]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let response = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: TerminalController.shared.handleSocketLine(line))
            }
        }
        let object = try #require(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        try #require(object["ok"] as? Bool == false, "\(response)")
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "invalid_params")
        #expect(fixture.figma.webView === editor)
        #expect(fixture.workspace.focusedPanelId == fixture.terminal)
    }

    @Test("A nil WebKit URL cannot erase the pending pointed Preview")
    func pendingPreviewSurvivesNilObservedURL() throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let pane = BrowserPanel(
            workspaceId: UUID(), initialURL: document, renderInitialNavigation: false,
            chromeVisibility: .hidden, websiteDataStore: .nonPersistent()
        )
        defer { pane.close() }
        let expected = try FigmaPaneURL.destination(for: document, node: "31-4", wrapper: page).url
        try #require(pane.gotoFigmaNode("31-4", wrapper: page))
        pane.publishObservedDocumentURL(nil)
        #expect(pane.currentURL == expected)
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        #expect(FigmaPaneURL.node(fromPaneURL: try #require(pane.currentURL), wrapper: page) == "31-4")
        let other = URL(string: "https://example.com/")!
        pane.publishObservedDocumentURL(other)
        #expect(pane.currentURL == other)
        #expect(!pane.switchFigmaPreviewAndEditor(wrapper: page))
        pane.publishObservedDocumentURL(nil)
        #expect(pane.currentURL == nil, "ordinary nil observations still clear the displayed address")
    }

    @Test("Pointing unhooks and deallocates the Editor from either side", arguments: [false, true])
    func pointingReleasesEditorFromEitherSide(showEditor: Bool) async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let preview = try FigmaPaneURL.destination(for: document, node: "12-2", wrapper: page).url
        let pane = BrowserPanel(
            workspaceId: UUID(), initialURL: preview, renderInitialNavigation: false,
            chromeVisibility: .hidden, websiteDataStore: .nonPersistent()
        )
        defer { pane.close() }
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        weak var weakEditor: WKWebView?
        weak var weakNav: BrowserNavigationDelegate?
        do {
            let editor = pane.webView
            weakEditor = editor
            weakNav = editor.navigationDelegate as? BrowserNavigationDelegate
            try #require(weakNav != nil)
            if !showEditor { try #require(pane.switchFigmaPreviewAndEditor(wrapper: page)) }
            try #require(pane.gotoFigmaNode("31-4", wrapper: page))
            #expect(editor.navigationDelegate == nil, "nav delegate still set")
            #expect(editor.uiDelegate == nil, "ui delegate still set")
            #expect(pane.webView !== editor)
            #expect(pane.retainedFigmaPageAddress == nil, "a held page or address survived pointing")
        }
        for _ in 0..<60 { if weakEditor == nil && weakNav == nil { break }; try await Task.sleep(for: .milliseconds(50)) }
        #expect(weakNav == nil, "navigation delegate leaked")
        #expect(weakEditor == nil, "released Editor web view leaked")
        // Next switch must not crash and must build a fresh Editor on 31-4.
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        #expect(pane.currentURL.flatMap { FigmaPaneURL.node(fromPaneURL: $0, wrapper: page) } == "31-4")
        #expect(pane.webView.navigationDelegate != nil, "fresh Editor has no navigation delegate")
    }

    @Test("Socket fit keeps the Editor and the showing side", arguments: [false, true])
    func socketFitKeepsEditorAndSide(showEditor: Bool) async throws {
        let fixture = try switchEntranceFixture()
        let priorDelegate = AppDelegate.shared
        let priorManager = TerminalController.shared.tabManager
        let delegate = AppDelegate()
        AppDelegate.shared = delegate
        delegate.tabManager = fixture.manager
        let windowID = delegate.registerMainWindowContextForTesting(tabManager: fixture.manager)
        TerminalController.shared.setActiveTabManager(fixture.manager)
        defer {
            TerminalController.shared.setActiveTabManager(priorManager)
            delegate.unregisterMainWindowContextForTesting(windowId: windowID)
            delegate.tabManager = nil
            AppDelegate.shared = priorDelegate
            fixture.workspace.teardownAllPanels()
        }
        try #require(fixture.workspace.switchFigmaPreviewAndEditor())
        let editor = fixture.figma.webView
        if !showEditor { try #require(fixture.workspace.switchFigmaPreviewAndEditor()) }
        let before = fixture.figma.currentURL
        let request: [String: Any] = ["id": 1, "method": "figma.goto", "params": [
            "window_id": windowID.uuidString, "workspace_id": fixture.workspace.id.uuidString,
            "surface_id": fixture.figma.id.uuidString, "node": "12-2", "purpose": "fit"
        ]]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let response = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: TerminalController.shared.handleSocketLine(line))
            }
        }
        let object = try #require(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        try #require(object["ok"] as? Bool == true, "\(response)")
        let result = try #require(object["result"] as? [String: Any])
        #expect(result["side"] as? String == (showEditor ? "editor" : "preview"), "side changed: \(result)")
        if showEditor {
            #expect(fixture.figma.webView === editor, "fit on Editor moved the pane")
            #expect(fixture.figma.currentURL == before)
        } else {
            try #require(fixture.workspace.switchFigmaPreviewAndEditor())
            #expect(fixture.figma.webView === editor, "preview fit released the Editor")
        }
    }


    @Test("Pointing with the address bar revealed releases the held Editor")
    func pointWithRevealedAddressBarReleasesEditor() throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let preview = try FigmaPaneURL.destination(for: document, node: "12-2", wrapper: page).url
        let pane = panel(on: preview)
        defer { pane.close() }
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        let editor = pane.webView
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        let previewView = pane.webView
        try #require(pane.setOmnibarVisible(true))
        try #require(pane.gotoFigmaNode("31-4", wrapper: page))
        #expect(pane.webView === previewView)
        #expect(pane.retainedFigmaPageAddress == nil)
        #expect(editor.navigationDelegate == nil)
        #expect(editor.uiDelegate == nil)
        #expect(pane.currentURL.flatMap { FigmaPaneURL.node(fromPaneURL: $0, wrapper: page) } == "31-4")
    }

    @Test("Open in Figma moves a held Editor to the board and keeps the clicked Preview behind")
    func openInFigmaMovesHeldEditorAndKeepsPreview() throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let preview = try FigmaPaneURL.destination(for: document, node: "12-2", wrapper: page).url
        let pane = panel(on: preview)
        defer { pane.close() }
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        let heldEditor = pane.webView
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        let clickedView = pane.webView
        let delegate = try #require(clickedView.navigationDelegate as? BrowserNavigationDelegate)
        let destination = URL(string: document.absoluteString + "?node-id=55-6")!
        var started = false
        delegate.requestNavigation?(URLRequest(url: destination), .currentTab) { started = $0 != nil }
        try #require(started)
        #expect(pane.webView === heldEditor)
        #expect(pane.currentURL == destination)
        #expect(pane.retainedFigmaPageAddress.map { FigmaPaneURL.isWrapperPage($0, wrapper: page) } == true)
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        #expect(pane.webView === clickedView)
        let address = try #require(pane.currentURL)
        #expect(FigmaPaneURL.isWrapperPage(address, wrapper: page))
        #expect(FigmaPaneURL.node(fromPaneURL: address, wrapper: page) == "12-2")
    }

    @Test("An Editor moving to another file releases the previous file's Preview")
    func editorFileChangeReleasesPreviousPreview() async throws {
        let page = try wrapper()
        defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }
        let preview = try FigmaPaneURL.destination(for: document, node: "12-2", wrapper: page).url
        let pane = panel(on: preview)
        defer { pane.close() }
        let oldPreview = pane.webView
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        let editor = pane.webView
        let otherFile = URL(string: "https://www.figma.com/design/OTHER/another-screen?node-id=81-9")!
        editor.stopLoading()
        try await DocumentLoader().seed(editor, value: "other-file", baseURL: otherFile)
        try #require(editor.url == otherFile)
        pane.publishObservedDocumentURL(otherFile)
        #expect(pane.webView === editor)
        #expect(pane.currentURL == otherFile)
        #expect(pane.retainedFigmaPageAddress == nil)
        #expect(oldPreview.navigationDelegate == nil)
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        #expect(pane.webView !== oldPreview)
        let address = try #require(pane.currentURL)
        #expect(FigmaPaneURL.isWrapperPage(address, wrapper: page))
        #expect(FigmaPaneURL.fileKey(fromPaneURL: address, wrapper: page) == "OTHER")
        try #require(pane.switchFigmaPreviewAndEditor(wrapper: page))
        #expect(pane.webView === editor)
        #expect(pane.currentURL == otherFile)
    }

    // cmux-rbf (#cm-73.3 step 5): this test opens and closes a main window through AppDelegate.shared, so it
    // lives in this serialized suite beside the socket tests that swap AppDelegate.shared; in another suite it ran
    // alongside them and the socket answered "TabManager not available".
#if DEBUG
    @Test("⌘[ and ⌘] cross sides through the same path")
    func keysCrossSides() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }
        let window = try #require(NSApp.windows.first { $0.identifier?.rawValue == "cmux.main.\(windowId.uuidString)" })
        let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
        let workspace = try #require(manager.selectedWorkspace)
        let terminal = try #require(workspace.focusedPanelId)
        let previewA = try FigmaPaneURL.destination(for: document, node: "12-2").url
        let figma = try #require(workspace.newBrowserSplit(
            from: terminal, orientation: .horizontal, url: previewA, focus: true,
            chromeVisibility: BrowserChromeVisibility(omnibarVisible: false)
        ))
        let previewView = figma.webView
        try #require(figma.switchFigmaPreviewAndEditor())
        let editorView = figma.webView
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        try #require(window.makeFirstResponder(editorView))
        #expect(Self.dispatch(.browserBack, in: window, using: appDelegate))
        #expect(figma.webView === previewView, "⌘[ did not cross to the preview")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        _ = window.makeFirstResponder(figma.webView)
        #expect(Self.dispatch(.browserForward, in: window, using: appDelegate))
        #expect(figma.webView === editorView, "⌘] did not cross to the editor")
    }

    private static func dispatch(_ action: KeyboardShortcutSettings.Action, in window: NSWindow, using appDelegate: AppDelegate) -> Bool {
        let shortcut = KeyboardShortcutSettings.shortcut(for: action)
        guard !shortcut.isUnbound, !shortcut.hasChord,
              let keyCode = shortcut.firstStroke.resolvedKeyCode(),
              let event = NSEvent.keyEvent(
                  with: .keyDown, location: .zero, modifierFlags: shortcut.modifierFlags,
                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                  characters: shortcut.menuItemKeyEquivalent ?? shortcut.key,
                  charactersIgnoringModifiers: shortcut.menuItemKeyEquivalent ?? shortcut.key,
                  isARepeat: false, keyCode: keyCode
              ) else { return false }
        return appDelegate.debugHandleCustomShortcut(event: event)
    }

    private func closeWindow(withId windowId: UUID) {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "cmux.main.\(windowId.uuidString)" }) else { return }
        let appDelegate = AppDelegate.shared
        let original = appDelegate?.debugCloseMainWindowConfirmationHandler
        appDelegate?.debugCloseMainWindowConfirmationHandler = { _ in true }
        defer { appDelegate?.debugCloseMainWindowConfirmationHandler = original }
        window.animationBehavior = .none
        window.orderOut(nil)
        window.close()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
#endif

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

        func seed(_ webView: WKWebView, value: String, baseURL: URL? = nil) async throws {
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
                expectedNavigation = webView.loadHTMLString("<html><body>Fixture</body></html>", baseURL: baseURL)
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
