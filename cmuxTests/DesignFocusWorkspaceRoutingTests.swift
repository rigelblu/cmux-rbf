// cmux-rbf #cm-73.2a
import AppKit
import Bonsplit
import CmuxBrowser
import CmuxControlSocket
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("DesignFocusWorkspaceRouting", .serialized)
struct DesignFocusWorkspaceRoutingTests {

    // cmux-rbf #cm-73.16
    @Test func headerExitLeavesDesignFocusAndDoesNotReenter() throws {
        let h = try Harness(); defer { h.cleanup() }
        try h.addFigmaSplit()
        #expect(h.workspace.toggleDesignFocus())
        #expect(h.workspace.isDesignFocusActive)
        h.workspace.bonsplitController.requestPairExit()
        #expect(!h.workspace.isDesignFocusActive)
        #expect(!h.workspace.bonsplitController.isPairZoomed)
        h.workspace.bonsplitController.requestPairExit()
        #expect(!h.workspace.isDesignFocusActive)
    }

    @MainActor
    private final class Harness {
        let manager: TabManager
        let workspace: Workspace
        let terminalPanelId: UUID
        let terminalPaneId: PaneID
        var figmaPanelId: UUID?
        var figmaPaneId: PaneID?
        var openedExternalURLs: [URL] = []

        init() throws {
            _ = NSApplication.shared
            manager = TabManager()
            workspace = try #require(manager.selectedWorkspace)
            terminalPanelId = try #require(workspace.focusedPanelId)
            terminalPaneId = try #require(workspace.paneId(forPanelId: terminalPanelId))
            Workspace.designFocusExternalOpen = DefaultBrowserOpenAction { [weak self] url in
                self?.openedExternalURLs.append(url)
                return true
            }
        }

        func addFigmaSplit() throws {
            let figmaURL = URL(string: "https://www.figma.com/design/KEY123/my-file")!
            let browser = try #require(
                workspace.newBrowserSplit(
                    from: terminalPanelId,
                    orientation: .horizontal,
                    url: figmaURL,
                    focus: false,
                    chromeVisibility: BrowserChromeVisibility(omnibarVisible: false)
                )
            )
            figmaPanelId = browser.id
            figmaPaneId = try #require(workspace.paneId(forPanelId: browser.id))
        }

        func cleanup() {
            Workspace.designFocusExternalOpen = DefaultBrowserOpenAction()
            workspace.teardownAllPanels()
        }
    }

    @Test("newBrowserSurface with non-Figma HTTP redirects to external and returns nil in Design Focus")
    func testNewBrowserSurfaceNonFigmaHTTPRedirectsToExternal() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.addFigmaSplit()

        #expect(h.workspace.toggleDesignFocus())
        #expect(h.workspace.isDesignFocusActive)

        let initialPanelsCount = h.workspace.panels.count
        let httpURL = URL(string: "https://example.com/docs")!
        let result = h.workspace.newBrowserSurface(
            inPane: h.terminalPaneId,
            url: httpURL,
            creationPolicy: .userInitiated
        )

        #expect(result == nil)
        #expect(h.openedExternalURLs == [httpURL])
        #expect(h.workspace.panels.count == initialPanelsCount)
        #expect(h.workspace.isDesignFocusActive)
    }

    @Test("newBrowserSurface with Figma URL places into Figma side pane in Design Focus")
    func testNewBrowserSurfaceFigmaPlacesIntoFigmaSide() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.addFigmaSplit()

        #expect(h.workspace.toggleDesignFocus())
        #expect(h.workspace.isDesignFocusActive)

        let newFigmaURL = URL(string: "https://www.figma.com/design/KEY456/another-file")!
        let result = try #require(
            h.workspace.newBrowserSurface(
                inPane: h.terminalPaneId,
                url: newFigmaURL,
                creationPolicy: .automationPreload,
                chromeVisibility: BrowserChromeVisibility(omnibarVisible: false)
            )
        )

        let resultPaneId = try #require(h.workspace.paneId(forPanelId: result.id))
        #expect(resultPaneId == h.figmaPaneId)
        #expect(h.workspace.isDesignFocusActive)
    }

    @Test("newBrowserSplit with Figma URL places into Figma side without making new split")
    func testNewBrowserSplitFigmaPlacesIntoFigmaSideWithoutSplit() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.addFigmaSplit()

        #expect(h.workspace.toggleDesignFocus())
        #expect(h.workspace.isDesignFocusActive)

        let initialPaneCount = h.workspace.bonsplitController.allPaneIds.count
        let newFigmaURL = URL(string: "https://www.figma.com/design/KEY789/split-test")!
        let result = try #require(
            h.workspace.newBrowserSplit(
                from: h.terminalPanelId,
                orientation: .vertical,
                url: newFigmaURL,
                focus: false,
                creationPolicy: .automationPreload,
                chromeVisibility: BrowserChromeVisibility(omnibarVisible: false)
            )
        )

        #expect(h.workspace.bonsplitController.allPaneIds.count == initialPaneCount)
        let resultPaneId = try #require(h.workspace.paneId(forPanelId: result.id))
        #expect(resultPaneId == h.figmaPaneId)
        #expect(h.workspace.isDesignFocusActive)
    }

    @Test("moveFocusedSurface ends Design Focus")
    func testMoveFocusedSurfaceEndsDesignFocus() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.addFigmaSplit()

        #expect(h.workspace.toggleDesignFocus())
        #expect(h.workspace.isDesignFocusActive)

        _ = h.workspace.moveFocusedSurface(to: .right)
        #expect(!h.workspace.isDesignFocusActive)
        #expect(h.workspace.lastDesignFocusLeaveReason == "moveFocusedSurface")
    }

    @Test("moveSurface same-workspace Move Surface by user ends Design Focus")
    func testSameWorkspaceMoveSurfaceEndsDesignFocus() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.addFigmaSplit()

        #expect(h.workspace.toggleDesignFocus())
        #expect(h.workspace.isDesignFocusActive)

        let terminalPanelId = h.terminalPanelId
        let figmaPaneId = try #require(h.figmaPaneId)
        _ = h.workspace.moveSurface(panelId: terminalPanelId, toPane: figmaPaneId, focus: true)
        #expect(!h.workspace.isDesignFocusActive)
        #expect(h.workspace.lastDesignFocusLeaveReason == "moveSurface")
    }

    @Test("Entering Design Focus keeps terminal focused if terminal was originally focused")
    func testEntryPreservesFocus() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.addFigmaSplit()

        let figmaPaneId = try #require(h.figmaPaneId)
        // Add a second tab to the Figma pane and select it
        let extraPanel = try #require(
            h.workspace.newBrowserSurface(
                inPane: figmaPaneId,
                url: URL(string: "about:blank"),
                focus: false
            )
        )
        if let extraTabId = h.workspace.surfaceIdFromPanelId(extraPanel.id) {
            h.workspace.bonsplitController.selectTab(extraTabId)
        }

        h.workspace.focusPanel(h.terminalPanelId)
        #expect(h.workspace.focusedPanelId == h.terminalPanelId)

        #expect(h.workspace.toggleDesignFocus())
        #expect(h.workspace.isDesignFocusActive)
        #expect(h.workspace.focusedPanelId == h.terminalPanelId)
    }

    @Test("Leaving Design Focus restores selected tab in each pair pane")
    func testExitRestoresSelectedTabs() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.addFigmaSplit()

        let figmaPaneId = try #require(h.figmaPaneId)
        let shellPanel = try #require(
            h.workspace.newBrowserSurface(
                inPane: figmaPaneId,
                url: URL(string: "about:blank"),
                focus: false
            )
        )
        let shellTabId = try #require(h.workspace.surfaceIdFromPanelId(shellPanel.id))
        h.workspace.bonsplitController.selectTab(shellTabId)
        #expect(h.workspace.bonsplitController.selectedTab(inPane: figmaPaneId)?.id == shellTabId)

        #expect(h.workspace.toggleDesignFocus())
        #expect(h.workspace.isDesignFocusActive)

        // Ensure focus is on terminal prior to leaving
        h.workspace.focusPanel(h.terminalPanelId)
        #expect(h.workspace.focusedPanelId == h.terminalPanelId)

        // On leave, shell tab should be selected again in figmaPaneId and terminal stays focused
        h.workspace.exitDesignFocus(reason: "test")
        #expect(!h.workspace.isDesignFocusActive)
        #expect(h.workspace.bonsplitController.selectedTab(inPane: figmaPaneId)?.id == shellTabId)
        #expect(h.workspace.focusedPanelId == h.terminalPanelId)
    }

    @Test("Leaving Design Focus with focus on Figma keeps Figma selected and focused")
    func testExitWithFocusOnFigmaKeepsFigmaSelectedAndFocused() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.addFigmaSplit()

        let figmaPaneId = try #require(h.figmaPaneId)
        let figmaPanelId = try #require(h.figmaPanelId)
        let shellPanel = try #require(
            h.workspace.newBrowserSurface(
                inPane: figmaPaneId,
                url: URL(string: "about:blank"),
                focus: false
            )
        )
        let shellTabId = try #require(h.workspace.surfaceIdFromPanelId(shellPanel.id))
        h.workspace.bonsplitController.selectTab(shellTabId)
        #expect(h.workspace.bonsplitController.selectedTab(inPane: figmaPaneId)?.id == shellTabId)

        #expect(h.workspace.toggleDesignFocus())
        #expect(h.workspace.isDesignFocusActive)

        // Focus Figma panel while in Design Focus
        h.workspace.focusPanel(figmaPanelId)
        #expect(h.workspace.focusedPanelId == figmaPanelId)

        let figmaTabId = try #require(h.workspace.surfaceIdFromPanelId(figmaPanelId))
        #expect(h.workspace.bonsplitController.selectedTab(inPane: figmaPaneId)?.id == figmaTabId)

        // On leave, since focus was on Figma pane, Figma tab stays selected and focused
        h.workspace.exitDesignFocus(reason: "test")
        #expect(!h.workspace.isDesignFocusActive)
        #expect(h.workspace.focusedPanelId == figmaPanelId)
        #expect(h.workspace.bonsplitController.selectedTab(inPane: figmaPaneId)?.id == figmaTabId)
    }

    @Test("Bonsplit clearPaneZoom triggers cmux leave path and restores moved tab")
    func testBonsplitClearPairZoomTriggersExitDesignFocus() throws {
        let h = try Harness()
        defer { h.cleanup() }

        // Stage Figma tab in the same pane as terminal
        let figmaURL = URL(string: "https://www.figma.com/design/KEY123/my-file")!
        let figmaPanel = try #require(
            h.workspace.newBrowserSurface(
                inPane: h.terminalPaneId,
                url: figmaURL,
                focus: false,
                chromeVisibility: BrowserChromeVisibility(omnibarVisible: false)
            )
        )
        let figmaTabId = try #require(h.workspace.surfaceIdFromPanelId(figmaPanel.id))

        #expect(h.workspace.bonsplitController.tabs(inPane: h.terminalPaneId).contains(where: { $0.id == figmaTabId }))

        #expect(h.workspace.toggleDesignFocus())
        #expect(h.workspace.isDesignFocusActive)
        #expect(h.workspace.designFocusMovedTab != nil)

        // Calling clearPaneZoom directly on Bonsplit
        h.workspace.bonsplitController.clearPaneZoom()

        #expect(!h.workspace.isDesignFocusActive)
        #expect(h.workspace.lastDesignFocusLeaveReason == "bonsplitCleared")
        // Check moved tab was put back in terminal pane
        #expect(h.workspace.bonsplitController.tabs(inPane: h.terminalPaneId).contains(where: { $0.id == figmaTabId }))
    }

    @Test("BrowserPanel.navigate on pair tab to non-Figma HTTP returns nil and redirects to external in Design Focus")
    func testNavigateOnPairTabNonFigmaHTTPReturnsNil() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.addFigmaSplit()

        #expect(h.workspace.toggleDesignFocus())
        #expect(h.workspace.isDesignFocusActive)

        let figmaPanel = try #require(h.workspace.panels[h.figmaPanelId!] as? BrowserPanel)
        let httpURL = URL(string: "https://example.com/docs")!
        let navResult = figmaPanel.navigate(to: httpURL)

        #expect(navResult == nil)
        #expect(h.openedExternalURLs == [httpURL])
    }

    @Test("newBrowserSurface with Figma URL and user asker focuses new Figma tab")
    func testNewBrowserSurfaceFigmaWithUserAskerFocusesFigmaTab() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.addFigmaSplit()

        #expect(h.workspace.toggleDesignFocus())
        #expect(h.workspace.isDesignFocusActive)

        let newFigmaURL = URL(string: "https://www.figma.com/design/KEY456/another-file")!
        let result = try #require(
            h.workspace.newBrowserSurface(
                inPane: h.terminalPaneId,
                url: newFigmaURL,
                creationPolicy: .automationPreload,
                chromeVisibility: BrowserChromeVisibility(omnibarVisible: false),
                designFocusAsker: .user
            )
        )

        let resultPaneId = try #require(h.workspace.paneId(forPanelId: result.id))
        #expect(resultPaneId == h.figmaPaneId)
        #expect(h.workspace.isDesignFocusActive)
        #expect(h.workspace.focusedPanelId == result.id)
    }

    @Test("newBrowserSurface with non-Figma HTTP and page asker ends Design Focus so sign-in stays in cmux")
    func testNewBrowserSurfaceNonFigmaWithPageAskerEndsDesignFocus() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.addFigmaSplit()

        #expect(h.workspace.toggleDesignFocus())
        #expect(h.workspace.isDesignFocusActive)

        let httpURL = URL(string: "https://example.com/oauth/signin")!
        let result = try #require(
            h.workspace.newBrowserSurface(
                inPane: h.terminalPaneId,
                url: httpURL,
                creationPolicy: .userInitiated,
                designFocusAsker: .page
            )
        )

        #expect(!h.workspace.isDesignFocusActive)
        #expect(h.workspace.lastDesignFocusLeaveReason == "newBrowserSurface")
        #expect(result.id != h.terminalPanelId)
    }

    @Test("newTerminalSplitOutcome with fromSocket: true preserves Design Focus, while fromSocket: false clears it")
    func testNewTerminalSplitFromSocketPreservesDesignFocus() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.addFigmaSplit()

        #expect(h.workspace.toggleDesignFocus())
        #expect(h.workspace.isDesignFocusActive)

        let outcome = h.workspace.newTerminalSplitOutcome(
            from: h.terminalPanelId,
            orientation: .vertical,
            focus: false,
            fromSocket: true
        )
        guard case .created(let newPanel) = outcome else {
            Issue.record("Expected terminal split to be created")
            return
        }

        #expect(h.workspace.isDesignFocusActive)
        #expect(h.workspace.bonsplitController.isPairZoomed)

        let userOutcome = h.workspace.newTerminalSplitOutcome(
            from: newPanel.id,
            orientation: .vertical,
            fromSocket: false
        )
        guard case .created = userOutcome else {
            Issue.record("Expected user terminal split to be created")
            return
        }

        #expect(!h.workspace.isDesignFocusActive)
        #expect(!h.workspace.bonsplitController.isPairZoomed)
    }

    @Test("v2ExternalBrowserOpenedResult formats dictionary with external placement and opened_externally")
    func testExternalBrowserOpenedResultPayload() {
        let controller = TerminalController.shared
        let url = URL(string: "https://example.com/test")!
        let wsId = UUID()
        let winId = UUID()
        let result = controller.v2ExternalBrowserOpenedResult(
            url: url,
            workspaceId: wsId,
            windowId: winId
        )
        guard case .ok(let payload) = result,
              let dict = payload as? [String: Any] else {
            Issue.record("Expected .ok dictionary payload")
            return
        }
        #expect(dict["opened_externally"] as? Bool == true)
        #expect(dict["placement_strategy"] as? String == "external")
        #expect(dict["created_split"] as? Bool == false)
        #expect(dict["url"] as? String == "https://example.com/test")
        #expect(dict["workspace_id"] as? String == wsId.uuidString)
        #expect(dict["window_id"] as? String == winId.uuidString)
    }

    @Test("openTerminalBrowserLink in Design Focus opens external URL once and reports success")
    func testOpenTerminalBrowserLinkInDesignFocusOpensOnce() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.addFigmaSplit()

        #expect(h.workspace.toggleDesignFocus())
        #expect(h.workspace.isDesignFocusActive)

        let externalURL = URL(string: "https://example.com/blog/article")!
        let handled = h.workspace.openTerminalBrowserLink(
            url: externalURL,
            sourcePanelId: h.terminalPanelId
        )

        #expect(handled == true)
        #expect(h.openedExternalURLs == [externalURL])
    }

    @Test("Socket terminal split with focus: true exits Design Focus")
    func testSocketTerminalSplitWithFocusExitsDesignFocus() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.addFigmaSplit()

        #expect(h.workspace.toggleDesignFocus())
        #expect(h.workspace.isDesignFocusActive)

        let outcome = h.workspace.newTerminalSplitOutcome(
            from: h.terminalPanelId,
            orientation: .vertical,
            focus: true,
            fromSocket: true
        )
        guard case .created = outcome else {
            Issue.record("Expected split to be created")
            return
        }

        #expect(!h.workspace.isDesignFocusActive)
        #expect(h.workspace.lastDesignFocusLeaveReason == "socketSplitFocus")
    }

    @Test("newBrowserSplit with blank URL and agent asker creates split out of sight and keeps Design Focus")
    func testNewBrowserSplitBlankAgentKeepsDesignFocus() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.addFigmaSplit()

        #expect(h.workspace.toggleDesignFocus())
        #expect(h.workspace.isDesignFocusActive)
        let initialPair = h.workspace.bonsplitController.pairZoomPanes

        let browser = h.workspace.newBrowserSplit(
            from: h.terminalPanelId,
            orientation: .vertical,
            url: nil,
            focus: false,
            creationPolicy: .automationPreload
        )

        #expect(browser != nil)
        #expect(h.workspace.isDesignFocusActive)
        #expect(h.workspace.bonsplitController.isPairZoomed)
        #expect(h.workspace.bonsplitController.pairZoomPanes?.first == initialPair?.first)
        #expect(h.workspace.bonsplitController.pairZoomPanes?.second == initialPair?.second)
    }

    @Test("newBrowserSurface with agent blank URL into unfocused pair pane is placed behind without selection")
    func testNewBrowserSurfaceBehindInUnfocusedPairPane() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.addFigmaSplit()

        #expect(h.workspace.toggleDesignFocus())
        #expect(h.workspace.isDesignFocusActive)
        let figmaPaneId = try #require(h.figmaPaneId)
        let figmaTabBefore = h.workspace.bonsplitController.selectedTab(inPane: figmaPaneId)

        // Terminal pane is focused; target the unfocused Figma pane
        let browser = try #require(
            h.workspace.newBrowserSurface(
                inPane: figmaPaneId,
                url: nil,
                creationPolicy: .automationPreload
            )
        )

        #expect(h.workspace.isDesignFocusActive)
        let figmaTabAfter = h.workspace.bonsplitController.selectedTab(inPane: figmaPaneId)
        #expect(figmaTabAfter?.id == figmaTabBefore?.id)
        let newSurfaceTabId = try #require(h.workspace.surfaceIdFromPanelId(browser.id))
        #expect(newSurfaceTabId != figmaTabAfter?.id)
    }

    @Test("moveSurface behind into unfocused pair pane places tab behind without selection")
    func testMoveSurfaceBehindInUnfocusedPairPane() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.addFigmaSplit()

        let thirdSplit = try #require(
            h.workspace.newTerminalSplit(
                from: h.terminalPanelId,
                orientation: .vertical,
                focus: false
            )
        )

        #expect(h.workspace.toggleDesignFocus())
        #expect(h.workspace.isDesignFocusActive)
        let figmaPaneId = try #require(h.figmaPaneId)
        let figmaTabBefore = h.workspace.bonsplitController.selectedTab(inPane: figmaPaneId)

        let moved = h.workspace.moveSurface(
            panelId: thirdSplit.id,
            toPane: figmaPaneId,
            focus: false
        )
        #expect(moved)
        #expect(h.workspace.isDesignFocusActive)
        let figmaTabAfter = h.workspace.bonsplitController.selectedTab(inPane: figmaPaneId)
        #expect(figmaTabAfter?.id == figmaTabBefore?.id)
    }

    @Test("attachDetachedSurface behind into unfocused pair pane places tab behind without selection")
    func testAttachDetachedSurfaceBehindInUnfocusedPairPane() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.addFigmaSplit()

        let thirdSplit = try #require(
            h.workspace.newTerminalSplit(
                from: h.terminalPanelId,
                orientation: .vertical,
                focus: false
            )
        )
        let detached = try #require(h.workspace.detachSurface(panelId: thirdSplit.id))

        #expect(h.workspace.toggleDesignFocus())
        #expect(h.workspace.isDesignFocusActive)
        let figmaPaneId = try #require(h.figmaPaneId)
        let figmaTabBefore = h.workspace.bonsplitController.selectedTab(inPane: figmaPaneId)

        let attached = h.workspace.attachDetachedSurface(
            detached,
            inPane: figmaPaneId,
            focus: false
        )
        #expect(attached != nil)
        #expect(h.workspace.isDesignFocusActive)
        let figmaTabAfter = h.workspace.bonsplitController.selectedTab(inPane: figmaPaneId)
        #expect(figmaTabAfter?.id == figmaTabBefore?.id)
    }

    @Test("toggleDesignFocus when Figma tab is focused keeps focus on Figma")
    func testEntryFocusOnFigmaPanelInSharedPaneKeepsFigmaFocus() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.addFigmaSplit()
        let figmaPanelId = try #require(h.figmaPanelId)

        let thirdSplit = try #require(
            h.workspace.newTerminalSplit(
                from: h.terminalPanelId,
                orientation: .vertical,
                focus: false
            )
        )
        _ = thirdSplit

        h.workspace.focusPanel(figmaPanelId)
        #expect(h.workspace.focusedPanelId == figmaPanelId)

        #expect(h.workspace.toggleDesignFocus())
        #expect(h.workspace.isDesignFocusActive)
        #expect(h.workspace.focusedPanelId == figmaPanelId)
    }

    @Test("newTerminalSurface from socket with focus exits Design Focus")
    func testSocketNewSurfaceWithFocusExitsDesignFocus() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.addFigmaSplit()

        #expect(h.workspace.toggleDesignFocus())
        #expect(h.workspace.isDesignFocusActive)

        let newPanel = h.workspace.newTerminalSurface(
            inPane: h.terminalPaneId,
            focus: true,
            fromSocket: true
        )
        #expect(newPanel != nil)
        #expect(!h.workspace.isDesignFocusActive)
        #expect(h.workspace.lastDesignFocusLeaveReason == "socketSurfaceFocus")
    }

    // cmux-rbf #cm-73.2a
    @Test("flipDesignFocusLayout switches orientation, pins against resize, clears pin on re-entry, and refuses outside mode")
    func testFlipDesignFocusLayoutBehavior() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.addFigmaSplit()

        // Flip outside mode returns false and does not enter mode
        #expect(!h.workspace.flipDesignFocusLayout())
        #expect(!h.workspace.isDesignFocusActive)

        // Enter mode with a wide area (e.g. 1800x1000) so ratio >= 1.0 -> .horizontal (.beside)
        #expect(h.workspace.toggleDesignFocus())
        #expect(h.workspace.isDesignFocusActive)
        h.workspace.updateDesignFocusOrientationIfNeeded(areaSize: CGSize(width: 1800, height: 1000))
        #expect(h.workspace.bonsplitController.pairZoomOrientation == .horizontal)

        // Flip in mode switches to .vertical
        #expect(h.workspace.flipDesignFocusLayout())
        #expect(h.workspace.bonsplitController.pairZoomOrientation == .vertical)

        // After flip, resize that would normally choose .horizontal (.beside) keeps the flipped side (.vertical)
        h.workspace.updateDesignFocusOrientationIfNeeded(areaSize: CGSize(width: 4880, height: 2850))
        #expect(h.workspace.bonsplitController.pairZoomOrientation == .vertical)

        // Flipping again returns to .horizontal, still pinned
        #expect(h.workspace.flipDesignFocusLayout())
        #expect(h.workspace.bonsplitController.pairZoomOrientation == .horizontal)
        h.workspace.updateDesignFocusOrientationIfNeeded(areaSize: CGSize(width: 1000, height: 2000))
        #expect(h.workspace.bonsplitController.pairZoomOrientation == .horizontal)

        // Leaving the mode clears the pin by itself (cmux-rbf #cm-73.2a, O5)
        #expect(h.workspace.isDesignFocusOrientationPinned)
        h.workspace.exitDesignFocus(reason: "test")
        #expect(!h.workspace.isDesignFocusActive)
        #expect(!h.workspace.isDesignFocusOrientationPinned)

        // Re-entry starts unpinned. The entry side comes from the test host's window, so drive both sizes
        // explicitly: an unpinned pair follows each one, a pinned pair would stay where entry left it.
        #expect(h.workspace.toggleDesignFocus())
        #expect(h.workspace.isDesignFocusActive)
        #expect(!h.workspace.isDesignFocusOrientationPinned)
        h.workspace.updateDesignFocusOrientationIfNeeded(areaSize: CGSize(width: 1800, height: 1000))
        #expect(h.workspace.bonsplitController.pairZoomOrientation == .horizontal)
        h.workspace.updateDesignFocusOrientationIfNeeded(areaSize: CGSize(width: 1000, height: 2000))
        #expect(h.workspace.bonsplitController.pairZoomOrientation == .vertical)
    }

    // cmux-rbf #cm-73.2a
    @Test("entering the mode clears a pin left behind by a pair that ended without leaving the mode")
    func testEntryClearsAStalePin() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.addFigmaSplit()
        let controller = h.workspace.bonsplitController
        let figmaPaneId = try #require(h.figmaPaneId)

        // A pair set straight on Bonsplit: the mode is "active" for the flip, but the workspace never tracked it,
        // so ending the pair does not go through exitDesignFocus and its reset.
        #expect(controller.setPairZoom(firstPane: h.terminalPaneId, secondPane: figmaPaneId, orientation: .horizontal))
        #expect(h.workspace.flipDesignFocusLayout())
        #expect(h.workspace.isDesignFocusOrientationPinned)
        #expect(controller.clearPairZoom())
        #expect(!h.workspace.isDesignFocusActive)
        #expect(h.workspace.isDesignFocusOrientationPinned)

        #expect(h.workspace.toggleDesignFocus())
        #expect(!h.workspace.isDesignFocusOrientationPinned)
        h.workspace.updateDesignFocusOrientationIfNeeded(areaSize: CGSize(width: 1800, height: 1000))
        #expect(controller.pairZoomOrientation == .horizontal)
        h.workspace.updateDesignFocusOrientationIfNeeded(areaSize: CGSize(width: 1000, height: 2000))
        #expect(controller.pairZoomOrientation == .vertical)
    }

    // cmux-rbf #cm-73.2a
    @Test("flip and 50/50 refuse while one pane is zoomed on top of the pair, and work again after it ends")
    func testFlipAndEqualizeRefuseWhileASinglePaneIsZoomed() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.addFigmaSplit()
        let controller = h.workspace.bonsplitController
        let figmaPaneId = try #require(h.figmaPaneId)

        #expect(h.workspace.toggleDesignFocus())
        h.workspace.updateDesignFocusOrientationIfNeeded(areaSize: CGSize(width: 1800, height: 1000))
        #expect(controller.pairZoomOrientation == .horizontal)
        #expect(controller.setPairZoomDividerPosition(0.7))

        // Figma fills the area alone (Toggle Pane Zoom inside the mode).
        #expect(controller.togglePaneZoom(inPane: figmaPaneId))
        #expect(controller.zoomedPaneId == figmaPaneId)
        #expect(controller.isPairZoomed)

        // Flip refuses: nothing changes and nothing is pinned.
        #expect(!h.workspace.flipDesignFocusLayout())
        #expect(controller.pairZoomOrientation == .horizontal)
        #expect(!h.workspace.isDesignFocusOrientationPinned)
        // The header's choice goes through the same path.
        h.workspace.splitTabBar(controller, didChoosePairArrangement: .vertical)
        #expect(controller.pairZoomOrientation == .horizontal)
        #expect(!h.workspace.isDesignFocusOrientationPinned)

        // 50/50 refuses: the divider stays where it was, through the workspace, Equalize Splits and the button.
        #expect(!h.workspace.equalizeDesignFocusPair())
        #expect(!h.manager.equalizeSplits(tabId: h.workspace.id))
        h.workspace.splitTabBarDidRequestEqualizePair(controller)
        #expect(abs((controller.pairZoomDividerPosition ?? 0) - 0.7) < 0.001)

        // The single-pane zoom ends: both work again.
        #expect(controller.togglePaneZoom(inPane: figmaPaneId))
        #expect(controller.zoomedPaneId == nil)
        #expect(h.workspace.equalizeDesignFocusPair())
        #expect(abs((controller.pairZoomDividerPosition ?? 0) - 0.5) < 0.001)
        #expect(h.workspace.flipDesignFocusLayout())
        #expect(controller.pairZoomOrientation == .vertical)
        #expect(h.workspace.isDesignFocusOrientationPinned)
    }

    // cmux-rbf #cm-73.2a
    @Test("equalizeSplits in Design Focus evens only the pair to 50% and preserves hidden real split dividers")
    func testEqualizeSplitsInDesignFocus() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.addFigmaSplit()

        // Start from uneven dividers: before entering, set the real layout's top divider to 0.3
        guard case .split(let rootSplit) = h.workspace.bonsplitController.treeSnapshot() else {
            Issue.record("Expected root split before entering Design Focus")
            return
        }
        guard let realSplitUUID = UUID(uuidString: rootSplit.id) else {
            Issue.record("Invalid root split id")
            return
        }
        #expect(h.workspace.bonsplitController.setDividerPosition(0.3, forSplit: realSplitUUID))
        guard case .split(let verifiedSplit) = h.workspace.bonsplitController.treeSnapshot() else {
            Issue.record("Expected root split")
            return
        }
        #expect(abs(verifiedSplit.dividerPosition - 0.3) < 0.001)

        // Enter Design Focus
        #expect(h.workspace.toggleDesignFocus())
        #expect(h.workspace.isDesignFocusActive)

        // In the mode, set the pair's divider to 0.7
        #expect(h.workspace.bonsplitController.setPairZoomDividerPosition(0.7))
        #expect(abs((h.workspace.bonsplitController.pairZoomDividerPosition ?? 0) - 0.7) < 0.001)

        // Non-matching orientation filter does nothing
        let pairOrientation = h.workspace.bonsplitController.pairZoomOrientation
        let nonMatchingFilter = (pairOrientation == .horizontal) ? "vertical" : "horizontal"
        #expect(!h.manager.equalizeSplits(tabId: h.workspace.id, orientationFilter: nonMatchingFilter))
        #expect(abs((h.workspace.bonsplitController.pairZoomDividerPosition ?? 0) - 0.7) < 0.001)

        // Run Equalize Splits -> the pair reads 0.5
        #expect(h.manager.equalizeSplits(tabId: h.workspace.id))
        #expect(abs((h.workspace.bonsplitController.pairZoomDividerPosition ?? 0) - 0.5) < 0.001)

        // Leave -> the real divider still reads 0.3
        h.workspace.exitDesignFocus(reason: "test")
        #expect(!h.workspace.isDesignFocusActive)
        guard case .split(let restoredSplit) = h.workspace.bonsplitController.treeSnapshot() else {
            Issue.record("Expected root split after leaving Design Focus")
            return
        }
        #expect(abs(restoredSplit.dividerPosition - 0.3) < 0.001)
    }

    // cmux-rbf #cm-73.2a
    /// `workspace.equalize_splits` through the app's socket context.
    private func socketEqualize(_ h: Harness, orientation: String? = nil) -> JSONValue? {
        let previous = TerminalController.shared.activeTabManagerForCallerNotification()
        TerminalController.shared.setActiveTabManager(h.manager)
        defer { TerminalController.shared.setActiveTabManager(previous) }
        var params: [String: JSONValue] = ["workspace_id": .string(h.workspace.id.uuidString)]
        if let orientation { params["orientation"] = .string(orientation) }
        let request = ControlRequest(id: .int(1), method: "workspace.equalize_splits", params: params)
        guard case .ok(let body)? = ControlCommandCoordinator(context: TerminalController.shared).handle(request) else {
            return nil
        }
        return body
    }

    // cmux-rbf #cm-73.2a
    /// The first split in the tree (depth first) whose orientation token is `orientation`.
    private func firstSplit(in node: ExternalTreeNode, orientation: String) -> ExternalSplitNode? {
        guard case .split(let split) = node else { return nil }
        if split.orientation == orientation { return split }
        return firstSplit(in: split.first, orientation: orientation)
            ?? firstSplit(in: split.second, orientation: orientation)
    }

    // cmux-rbf #cm-73.2a
    /// Stacks a teammate pane under the agent the way the CLI's `split-window` does (from the socket, unfocused),
    /// then sets the real tree's side-by-side divider and the stacked divider to 0.3. Returns both split ids.
    private func stackTeammateUnderAgent(_ h: Harness) throws -> (root: UUID, stacked: UUID) {
        let outcome = h.workspace.newTerminalSplitOutcome(
            from: h.terminalPanelId,
            orientation: .vertical,
            focus: false,
            fromSocket: true
        )
        guard case .created = outcome else {
            Issue.record("Expected the teammate split to be created")
            throw CancellationError()
        }
        let tree = h.workspace.bonsplitController.treeSnapshot()
        let root = try #require(firstSplit(in: tree, orientation: "horizontal"))
        let stacked = try #require(firstSplit(in: tree, orientation: "vertical"))
        let rootId = try #require(UUID(uuidString: root.id))
        let stackedId = try #require(UUID(uuidString: stacked.id))
        #expect(h.workspace.bonsplitController.setDividerPosition(0.3, forSplit: rootId))
        #expect(h.workspace.bonsplitController.setDividerPosition(0.3, forSplit: stackedId))
        return (rootId, stackedId)
    }

    // cmux-rbf #cm-73.2a
    private func dividerPosition(_ h: Harness, orientation: String) -> Double {
        firstSplit(in: h.workspace.bonsplitController.treeSnapshot(), orientation: orientation)?.dividerPosition ?? -1
    }

    // cmux-rbf #cm-73.2a
    @Test("the socket's workspace.equalize_splits in Design Focus evens the hidden layout under the caller's filter and leaves the pair")
    func testSocketEqualizeSplitsInDesignFocusEvensHiddenLayoutWithFilter() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.addFigmaSplit()
        let controller = h.workspace.bonsplitController

        #expect(h.workspace.toggleDesignFocus())
        _ = try stackTeammateUnderAgent(h)
        #expect(h.workspace.isDesignFocusActive)
        #expect(controller.setPairZoomDividerPosition(0.7))

        // The CLI's filter for "even the agent's stacked column": the hidden stacked divider goes to 0.5.
        let reply = try #require(socketEqualize(h, orientation: "vertical"))
        guard case .object(let body) = reply else { Issue.record("Expected an object reply"); return }
        #expect(body["equalized"] == .bool(true))
        #expect(body["workspace_id"] == .string(h.workspace.id.uuidString))
        #expect(abs(dividerPosition(h, orientation: "vertical") - 0.5) < 0.001)
        // The filter keeps the side-by-side divider out of it, and the visible pair is never touched.
        #expect(abs(dividerPosition(h, orientation: "horizontal") - 0.3) < 0.001)
        #expect(abs((controller.pairZoomDividerPosition ?? 0) - 0.7) < 0.001)
        #expect(h.workspace.isDesignFocusActive)
    }

    // cmux-rbf #cm-73.2a
    @Test("the socket's workspace.equalize_splits in Design Focus with no filter evens the whole hidden layout and leaves the pair")
    func testSocketEqualizeSplitsInDesignFocusWithoutFilterEvensHiddenLayout() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.addFigmaSplit()
        let controller = h.workspace.bonsplitController

        #expect(h.workspace.toggleDesignFocus())
        _ = try stackTeammateUnderAgent(h)
        #expect(controller.setPairZoomDividerPosition(0.7))

        let reply = try #require(socketEqualize(h))
        guard case .object(let body) = reply else { Issue.record("Expected an object reply"); return }
        #expect(body["equalized"] == .bool(true))
        #expect(abs(dividerPosition(h, orientation: "vertical") - 0.5) < 0.001)
        #expect(abs(dividerPosition(h, orientation: "horizontal") - 0.5) < 0.001)
        #expect(abs((controller.pairZoomDividerPosition ?? 0) - 0.7) < 0.001)
    }

    // cmux-rbf #cm-73.2a
    @Test("the socket's workspace.equalize_splits in Design Focus reports false when the filter matches no hidden split, and the pair stays")
    func testSocketEqualizeSplitsInDesignFocusReportsFalseWhenFilterMatchesNothing() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.addFigmaSplit()
        let controller = h.workspace.bonsplitController

        // Only the side-by-side split exists in the real tree: nothing for "vertical" to even.
        // The pair is flipped to stacked, so "vertical" would match the pair if the socket reached it.
        #expect(h.workspace.toggleDesignFocus())
        #expect(h.workspace.flipDesignFocusLayout())
        #expect(controller.pairZoomOrientation == .vertical)
        #expect(controller.setPairZoomDividerPosition(0.7))
        let reply = try #require(socketEqualize(h, orientation: "vertical"))
        guard case .object(let body) = reply else { Issue.record("Expected an object reply"); return }
        #expect(body["equalized"] == .bool(false))
        #expect(abs((controller.pairZoomDividerPosition ?? 0) - 0.7) < 0.001)
    }

    // cmux-rbf #cm-73.2a
    @Test("the socket's workspace.equalize_splits outside Design Focus still evens the real layout under the caller's filter")
    func testSocketEqualizeSplitsOutsideDesignFocusUnchanged() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.addFigmaSplit()
        _ = try stackTeammateUnderAgent(h)
        #expect(!h.workspace.isDesignFocusActive)

        let filtered = try #require(socketEqualize(h, orientation: "vertical"))
        guard case .object(let filteredBody) = filtered else { Issue.record("Expected an object reply"); return }
        #expect(filteredBody["equalized"] == .bool(true))
        #expect(abs(dividerPosition(h, orientation: "vertical") - 0.5) < 0.001)
        #expect(abs(dividerPosition(h, orientation: "horizontal") - 0.3) < 0.001)

        let unfiltered = try #require(socketEqualize(h))
        guard case .object(let unfilteredBody) = unfiltered else { Issue.record("Expected an object reply"); return }
        #expect(unfilteredBody["equalized"] == .bool(true))
        #expect(abs(dividerPosition(h, orientation: "horizontal") - 0.5) < 0.001)
    }

    // cmux-rbf #cm-73.2a
    @Test("the header's arrangement choice flips only when it differs from the showing arrangement")
    func testPairArrangementChoiceFlipsOnlyWhenDifferent() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.addFigmaSplit()
        let controller = h.workspace.bonsplitController

        // Outside the mode the choice does nothing.
        h.workspace.splitTabBar(controller, didChoosePairArrangement: .vertical)
        #expect(!h.workspace.isDesignFocusActive)

        #expect(h.workspace.toggleDesignFocus())
        h.workspace.updateDesignFocusOrientationIfNeeded(areaSize: CGSize(width: 1800, height: 1000))
        #expect(controller.pairZoomOrientation == .horizontal)

        // The selected arrangement does nothing, and does not pin: a resize still re-decides.
        h.workspace.splitTabBar(controller, didChoosePairArrangement: .horizontal)
        #expect(controller.pairZoomOrientation == .horizontal)
        h.workspace.updateDesignFocusOrientationIfNeeded(areaSize: CGSize(width: 1000, height: 2000))
        #expect(controller.pairZoomOrientation == .vertical)

        // The other arrangement flips through the same path as the key, which pins.
        h.workspace.splitTabBar(controller, didChoosePairArrangement: .horizontal)
        #expect(controller.pairZoomOrientation == .horizontal)
        h.workspace.updateDesignFocusOrientationIfNeeded(areaSize: CGSize(width: 1000, height: 2000))
        #expect(controller.pairZoomOrientation == .horizontal)

        // Choosing the showing arrangement again leaves it as it is.
        h.workspace.splitTabBar(controller, didChoosePairArrangement: .horizontal)
        #expect(controller.pairZoomOrientation == .horizontal)
    }

    // cmux-rbf #cm-73.2a
    @Test("the header's 50/50 button leaves the pair at 0.5 and refuses outside the mode")
    func testPairEqualizeButtonEvensThePair() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.addFigmaSplit()
        let controller = h.workspace.bonsplitController

        // Outside the mode the real layout is untouched.
        guard case .split(let rootSplit) = controller.treeSnapshot(), let splitUUID = UUID(uuidString: rootSplit.id) else {
            Issue.record("Expected root split")
            return
        }
        #expect(controller.setDividerPosition(0.3, forSplit: splitUUID))
        h.workspace.splitTabBarDidRequestEqualizePair(controller)
        guard case .split(let untouched) = controller.treeSnapshot() else {
            Issue.record("Expected root split")
            return
        }
        #expect(abs(untouched.dividerPosition - 0.3) < 0.001)

        #expect(h.workspace.toggleDesignFocus())
        #expect(controller.setPairZoomDividerPosition(0.7))
        h.workspace.splitTabBarDidRequestEqualizePair(controller)
        #expect(abs((controller.pairZoomDividerPosition ?? 0) - 0.5) < 0.001)
    }
}
