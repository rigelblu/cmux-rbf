// cmux-rbf #cm-73.15
import AppKit
import Bonsplit
import CmuxBrowser
import CmuxSettings
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct FigmaTabToRightWorkspaceTests {
    @Test(arguments: [0, 1, 2])
    func insertsRightOfClickedTab(index: Int) throws {
        _ = NSApplication.shared
        let workspace = Workspace(); defer { workspace.teardownAllPanels() }
        let controller = workspace.bonsplitController
        let pane = try #require(controller.allPaneIds.first)
        _ = try #require(workspace.newBrowserSurface(inPane: pane))
        _ = try #require(workspace.newBrowserSurface(inPane: pane))
        let before = controller.tabs(inPane: pane).map(\.id)
        controller.requestTabContextAction(.newFigmaToRight, for: before[index], inPane: pane)
        let after = controller.tabs(inPane: pane).map(\.id)
        try #require(after.count == before.count + 1, "context action added no Figma tab")
        let newTab = after[index + 1]
        #expect(after.filter { $0 != newTab } == before)
        let id = try #require(workspace.panelIdFromSurfaceId(newTab))
        let panel = try #require(workspace.browserPanel(for: id))
        checkFigma(panel)
        #expect(workspace.focusedPanelId == id)
        #expect(controller.focusedPaneId == pane)
    }

    @Test func designFocusKeepsDestinationInsertionOrder() throws {
        _ = NSApplication.shared
        let workspace = Workspace(); defer { workspace.teardownAllPanels() }
        let controller = workspace.bonsplitController
        let terminal = try #require(workspace.focusedPanelId)
        let sourcePane = try #require(workspace.paneId(forPanelId: terminal))
        let figma = try #require(workspace.newBrowserSplit(from: terminal, orientation: .horizontal,
            url: Workspace.figmaRecentFilesURL, focus: false,
            chromeVisibility: BrowserChromeVisibility(omnibarVisible: false)))
        let destination = try #require(workspace.paneId(forPanelId: figma.id))
        #expect(workspace.toggleDesignFocus())
        _ = try #require(workspace.newFigmaSurface(inPane: destination, focus: true))
        _ = try #require(workspace.newFigmaSurface(inPane: destination, focus: true))
        let before = controller.tabs(inPane: destination).map(\.id)
        let anchor = try #require(workspace.surfaceIdFromPanelId(terminal))
        controller.requestTabContextAction(.newFigmaToRight, for: anchor, inPane: sourcePane)
        let after = controller.tabs(inPane: destination).map(\.id)
        try #require(after.count == before.count + 1, "Design Focus action added no Figma tab")
        #expect(Array(after.prefix(before.count)) == before, "routed tab must retain the destination's append order")
        #expect(controller.tabs(inPane: sourcePane).map(\.id) == [anchor])
        #expect(controller.selectedTab(inPane: destination)?.id == after.last)
    }

    @Test(arguments: [0, 1, 2])
    func dockInsertsRightOfClickedTab(index: Int) throws {
        _ = NSApplication.shared
        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        defer { dock.retire() }
        let controller = dock.bonsplitController
        let pane = try #require(controller.allPaneIds.first)
        for _ in 0..<3 { _ = try #require(dock.newSurface(kind: .browser, inPane: pane)) }
        let before = controller.tabs(inPane: pane).map(\.id)
        controller.requestTabContextAction(.newFigmaToRight, for: before[index], inPane: pane)
        let after = controller.tabs(inPane: pane).map(\.id)
        try #require(after.count == before.count + 1, "Dock action added no Figma tab")
        let newTab = after[index + 1]
        #expect(after.filter { $0 != newTab } == before)
        let id = try #require(dock.surfaceIdToPanelId[newTab])
        let panel = try #require(dock.browserPanel(for: id))
        checkFigma(panel)
        #expect(controller.selectedTab(inPane: pane)?.id == newTab)
    }

    @Test(arguments: ["disabled", "blocked", "allowed"])
    func workspaceCreationGates(mode: String) throws {
        let suite = "figma-to-right-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(mode == "disabled", forKey: BrowserAvailabilitySettings.disabledKey)
        defaults.set(mode == "allowed" ? "www.figma.com" : "localhost", forKey: BrowserURLAllowlistPolicy.userDefaultsKey)
        let workspace = Workspace(); defer { workspace.teardownAllPanels() }
        let controller = workspace.bonsplitController
        let pane = try #require(controller.allPaneIds.first)
        let anchor = try #require(controller.tabs(inPane: pane).first?.id)
        let before = controller.allTabIds.count
        var external: [URL] = []
        workspace.createFigmaToRight(of: anchor, inPane: pane, defaults: defaults, openExternally: { external.append($0) })
        #expect(controller.allTabIds.count == before + (mode == "allowed" ? 1 : 0))
        #expect(external == (mode == "blocked" ? [Workspace.figmaRecentFilesURL] : []))
    }

    @Test(arguments: ["disabled", "blocked", "allowed", "providerOff"])
    func dockCreationGates(mode: String) throws {
        let suite = "figma-dock-to-right-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(mode == "disabled", forKey: BrowserAvailabilitySettings.disabledKey)
        defaults.set(mode == "allowed" ? "www.figma.com" : "localhost", forKey: BrowserURLAllowlistPolicy.userDefaultsKey)
        var browserOn = true
        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil }, browserAvailabilityProvider: { browserOn })
        defer { dock.retire() }
        let controller = dock.bonsplitController
        let pane = try #require(controller.allPaneIds.first)
        let original = try #require(dock.newSurface(kind: .browser, inPane: pane))
        let anchor = try #require(dock.surfaceId(forPanelId: original))
        browserOn = mode != "providerOff"
        let before = controller.allTabIds.count
        var external: [URL] = []
        dock.createDockContextSurfaceToRight(kind: .figma, anchorTabId: anchor, paneId: pane,
            defaults: defaults, openExternally: { external.append($0) })
        #expect(controller.allTabIds.count == before + (mode == "allowed" ? 1 : 0))
        #expect(external == (mode == "blocked" ? [Workspace.figmaRecentFilesURL] : []))
    }

    // cmux-rbf #cm-73.15: a private browser anchor must not make Recents private or unsaved.
    @Test func privateDockAnchorMakesPersistentFigmaAndPublishesSnapshot() throws {
        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        defer { dock.retire() }
        let controller = dock.bonsplitController
        let pane = try #require(controller.allPaneIds.first)
        let ephemeral = WKWebsiteDataStore.nonPersistent()
        let anchorID = try #require(dock.newSurface(kind: .browser, inPane: pane, websiteDataStore: ephemeral))
        let anchor = try #require(dock.surfaceId(forPanelId: anchorID))
        let original = try #require(dock.browserPanel(for: anchorID))
        try #require(original.explicitEphemeralWebsiteDataStoreForSibling === ephemeral)
        try #require(!original.shouldPersistSessionSnapshot())
        let store = TerminalController.shared.socketReadSnapshotStore
        let generation = store.read().generation
        controller.requestTabContextAction(.newFigmaToRight, for: anchor, inPane: pane)
        let tab = try #require(controller.tabs(inPane: pane).last { $0.id != anchor })
        let figma = try #require(dock.panel(for: tab.id) as? BrowserPanel)
        checkFigma(figma)
        #expect(figma.explicitEphemeralWebsiteDataStoreForSibling == nil)
        #expect(figma.shouldPersistSessionSnapshot())
        #expect(store.read().generation != generation)
    }

    private func checkFigma(_ panel: BrowserPanel) {
        #expect((panel.navigationDelegate?.lastAttemptedURL ?? panel.currentURL) == Workspace.figmaRecentFilesURL)
        #expect(!panel.isOmnibarVisible)
        #expect(panel.sessionSnapshotTransparentBackground)
        #expect(panel.hiddenWebViewDiscardKeepLoaded)
    }
}
