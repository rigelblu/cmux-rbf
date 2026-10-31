import AppKit
import CmuxBrowser
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// cmux-rbf #cm-73.45: a Figma pane remembers the terminal that last opened or pointed it.

private let figmaEditorLink = "https://www.figma.com/design/KEY/name"

/// Which terminal a Figma pane belongs to: who writes it (each entrance, through the
/// real socket handlers and `Workspace` methods), and that it is saved and restored.
/// Reading it back for Design Focus's pick is `DesignFocusPairTests`.
@MainActor
@Suite("FigmaPaneOwner", .serialized)
struct FigmaPaneOwnerTests {

    /// A tab manager with one workspace whose terminal A has a stable id that differs from its runtime id,
    /// so a test that stored the wrong one cannot pass by luck.
    @MainActor
    private final class Rig {
        let manager = TabManager()
        let workspace: Workspace
        let terminalA: TerminalPanel
        private let browserWasDisabled: Bool
        private var scratchFiles: [URL] = []

        init() throws {
            _ = NSApplication.shared
            browserWasDisabled = BrowserAvailabilitySettings.isDisabled(defaults: .standard)
            BrowserAvailabilitySettings.setDisabled(false, defaults: .standard)
            workspace = try #require(manager.selectedWorkspace)
            let id = try #require(workspace.focusedPanelId)
            terminalA = try #require(workspace.panels[id] as? TerminalPanel)
            terminalA.adoptStableSurfaceId(UUID())
            TerminalController.shared.setActiveTabManager(manager)
        }

        func cleanup() {
            TerminalController.shared.setActiveTabManager(nil)
            manager.tabs.forEach { $0.teardownAllPanels() }
            BrowserAvailabilitySettings.setDisabled(browserWasDisabled, defaults: .standard)
            scratchFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        }

        func addTerminal() throws -> TerminalPanel {
            let panel = try #require(workspace.newTerminalSplit(from: terminalA.id, orientation: .horizontal, focus: false))
            panel.adoptStableSurfaceId(UUID())
            return panel
        }

        func addMarkdown() throws -> MarkdownPanel {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("cm-73.45-\(UUID().uuidString).md")
            try "# note".write(to: file, atomically: true, encoding: .utf8)
            scratchFiles.append(file)
            return try #require(workspace.newMarkdownSplit(
                from: terminalA.id, orientation: .horizontal, filePath: file.path, focus: false
            ))
        }

        /// A Figma pane as `cmux figma open` makes one: no address bar, to the right of A.
        func addFigmaPane(_ address: String = figmaEditorLink) throws -> BrowserPanel {
            try #require(workspace.newBrowserSplit(
                from: terminalA.id,
                orientation: .horizontal,
                url: URL(string: address),
                focus: false,
                allowsExternalBrowserFallback: false,
                chromeVisibility: BrowserChromeVisibility(omnibarVisible: false)
            ))
        }

        func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
            let request: [String: Any] = ["jsonrpc": "2.0", "id": UUID().uuidString, "method": method, "params": params]
            let line = try #require(String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8))
            let response = TerminalController.shared.handleSocketLine(line)
            return try #require(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        }

        /// `browser.open_split` with a Figma link, as the CLI sends it; the new pane's id when it answered ok.
        func openSplit(surface: UUID?) throws -> UUID? {
            var params: [String: Any] = [
                "workspace_id": workspace.id.uuidString,
                "url": figmaEditorLink,
                "focus": false,
                "show_omnibar": false,
                "transparent_background": true
            ]
            if let surface { params["surface_id"] = surface.uuidString }
            let response = try call("browser.open_split", params)
            guard response["ok"] as? Bool == true,
                  let result = response["result"] as? [String: Any],
                  let id = (result["surface_id"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
            return id
        }

        /// `figma.goto`, as the CLI sends it. Whether the app answered ok.
        func goto(pane: BrowserPanel, caller: UUID?, purpose: String? = nil) throws -> Bool {
            var params: [String: Any] = [
                "workspace_id": workspace.id.uuidString,
                "surface_id": pane.id.uuidString,
                "node": "12-2"
            ]
            if let caller { params["caller_surface_id"] = caller.uuidString }
            if let purpose { params["purpose"] = purpose }
            return try call("figma.goto", params)["ok"] as? Bool == true
        }

        /// Tom's own click into `panelId`: a mouse event stamped now.
        func tomClicked(_ panelId: UUID) {
            workspace.recordLastTerminalTomWasIn(panelId, event: FigmaPaneOwnerTests.inputEvent(.leftMouseDown, age: 0))
        }

        func browser(_ id: UUID) throws -> BrowserPanel {
            try #require(workspace.panels[id] as? BrowserPanel)
        }

        func click(_ link: String, from source: UUID) -> Bool {
            workspace.openClickedFigmaLink(URL(string: link)!, sourcePanelId: source)
        }
    }

    /// A real `NSEvent` of `type`, `age` seconds old as of `now`. A unit test has no current event, so the
    /// record's input check is exercised with these.
    static func inputEvent(_ type: NSEvent.EventType, age: TimeInterval, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> NSEvent {
        let stamp = now - age
        switch type {
        case .keyUp, .keyDown, .flagsChanged:
            return NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: stamp, windowNumber: 0,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
            )!
        default:
            return NSEvent.mouseEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: stamp, windowNumber: 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
        }
    }

    private func withRig(_ body: (Rig) throws -> Void) throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try body(rig)
    }

    // MARK: - browser.open_split (Scenario 275)

    @Test("open_split with a Figma link and surface_id = terminal A: the new pane's owner is A's stable id, not its id")
    func openSplitFromATerminal() throws {
        try withRig { rig in
            #expect(rig.terminalA.stableSurfaceId != rig.terminalA.id)
            let pane = try rig.browser(try #require(try rig.openSplit(surface: rig.terminalA.id)))
            #expect(pane.ownerTerminalSurfaceId == rig.terminalA.stableSurfaceId)
        }
    }

    @Test("open_split with no surface_id: no owner")
    func openSplitWithNoSurfaceId() throws {
        try withRig { rig in
            let pane = try rig.browser(try #require(try rig.openSplit(surface: nil)))
            #expect(pane.ownerTerminalSurfaceId == nil)
        }
    }

    @Test("open_split with surface_id = a markdown panel: no owner")
    func openSplitFromAMarkdownPanel() throws {
        try withRig { rig in
            let markdown = try rig.addMarkdown()
            let pane = try rig.browser(try #require(try rig.openSplit(surface: markdown.id)))
            #expect(pane.ownerTerminalSurfaceId == nil)
        }
    }

    @Test("open_split with surface_id = a browser panel: no owner")
    func openSplitFromABrowserPanel() throws {
        try withRig { rig in
            let browser = try rig.addFigmaPane("https://example.com/")
            let pane = try rig.browser(try #require(try rig.openSplit(surface: browser.id)))
            #expect(pane.ownerTerminalSurfaceId == nil)
        }
    }

    // MARK: - figma.goto (Scenario 275)

    @Test("goto with caller_surface_id = terminal B on A's pane: B owns it, the last to point wins")
    func gotoMovesTheOwner() throws {
        try withRig { rig in
            let b = try rig.addTerminal()
            let pane = try rig.addFigmaPane()
            #expect(try rig.goto(pane: pane, caller: rig.terminalA.id))
            #expect(pane.ownerTerminalSurfaceId == rig.terminalA.stableSurfaceId)
            #expect(try rig.goto(pane: pane, caller: b.id))
            #expect(pane.ownerTerminalSurfaceId == b.stableSurfaceId)
        }
    }

    @Test("goto with an unknown caller_surface_id: succeeds, owner unchanged")
    func gotoWithAnUnknownCaller() throws {
        try withRig { rig in
            let pane = try rig.addFigmaPane()
            #expect(try rig.goto(pane: pane, caller: rig.terminalA.id))
            #expect(try rig.goto(pane: pane, caller: UUID()))
            #expect(pane.ownerTerminalSurfaceId == rig.terminalA.stableSurfaceId)
        }
    }

    @Test("goto with a closed terminal as caller_surface_id: succeeds, owner unchanged")
    func gotoWithAClosedCaller() throws {
        try withRig { rig in
            let b = try rig.addTerminal()
            let pane = try rig.addFigmaPane()
            #expect(try rig.goto(pane: pane, caller: rig.terminalA.id))
            let closedId = b.id
            #expect(rig.workspace.closePanel(closedId, force: true))
            #expect(try rig.goto(pane: pane, caller: closedId))
            #expect(pane.ownerTerminalSurfaceId == rig.terminalA.stableSurfaceId)
        }
    }

    @Test("goto with a markdown panel as caller_surface_id: succeeds, owner unchanged")
    func gotoWithANonTerminalCaller() throws {
        try withRig { rig in
            let markdown = try rig.addMarkdown()
            let pane = try rig.addFigmaPane()
            #expect(try rig.goto(pane: pane, caller: rig.terminalA.id))
            #expect(try rig.goto(pane: pane, caller: markdown.id))
            #expect(pane.ownerTerminalSurfaceId == rig.terminalA.stableSurfaceId)
        }
    }

    @Test("goto with no caller_surface_id: succeeds, owner unchanged")
    func gotoWithNoCaller() throws {
        try withRig { rig in
            let pane = try rig.addFigmaPane()
            #expect(try rig.goto(pane: pane, caller: rig.terminalA.id))
            #expect(try rig.goto(pane: pane, caller: nil))
            #expect(pane.ownerTerminalSurfaceId == rig.terminalA.stableSurfaceId)
        }
    }

    @Test("goto with no caller_surface_id on an unowned pane leaves it unowned")
    func gotoWithNoCallerOnAnUnownedPane() throws {
        try withRig { rig in
            let pane = try rig.addFigmaPane()
            #expect(try rig.goto(pane: pane, caller: nil))
            #expect(pane.ownerTerminalSurfaceId == nil)
        }
    }

    @Test("goto with purpose fit and a caller_surface_id: succeeds, owner unchanged, since a fit points at no new board")
    func gotoFitWithACaller() throws {
        try withRig { rig in
            let b = try rig.addTerminal()
            let pane = try rig.addFigmaPane()
            #expect(try rig.goto(pane: pane, caller: rig.terminalA.id))
            #expect(try rig.goto(pane: pane, caller: b.id, purpose: "fit"))
            #expect(pane.ownerTerminalSurfaceId == rig.terminalA.stableSurfaceId)
        }
    }

    // MARK: - a clicked Figma link (Scenario 275)

    @Test("a link clicked in terminal A that opens a new pane: A owns it")
    func clickOpenNew() throws {
        try withRig { rig in
            let before = Set(rig.workspace.panels.keys)
            #expect(rig.click("https://www.figma.com/design/NEW/name", from: rig.terminalA.id))
            let created = try #require(rig.workspace.panels.values.compactMap { $0 as? BrowserPanel }.first { !before.contains($0.id) })
            #expect(created.ownerTerminalSurfaceId == rig.terminalA.stableSurfaceId)
        }
    }

    @Test("a link clicked in terminal A that moves a pane: A owns it")
    func clickMove() throws {
        try withRig { rig in
            let pane = try rig.addFigmaPane("https://www.figma.com/design/KEY/old-name")
            #expect(pane.ownerTerminalSurfaceId == nil)
            #expect(rig.click("https://www.figma.com/design/KEY/new-name?node-id=12-2", from: rig.terminalA.id))
            #expect(pane.ownerTerminalSurfaceId == rig.terminalA.stableSurfaceId)
        }
    }

    @Test("a link clicked in terminal A that brings a pane forward: A owns it")
    func clickBringForward() throws {
        try withRig { rig in
            let pane = try rig.addFigmaPane("https://www.figma.com/design/KEY/old-name")
            #expect(pane.ownerTerminalSurfaceId == nil)
            #expect(rig.click("https://www.figma.com/design/KEY/new-name", from: rig.terminalA.id))
            #expect(pane.ownerTerminalSurfaceId == rig.terminalA.stableSurfaceId)
        }
    }

    @Test("a link clicked in a markdown panel: no owner")
    func clickFromAMarkdownPanel() throws {
        try withRig { rig in
            let markdown = try rig.addMarkdown()
            let before = Set(rig.workspace.panels.keys)
            #expect(rig.click("https://www.figma.com/design/NEW/name", from: markdown.id))
            let created = try #require(rig.workspace.panels.values.compactMap { $0 as? BrowserPanel }.first { !before.contains($0.id) })
            #expect(created.ownerTerminalSurfaceId == nil)
        }
    }

    // MARK: - the entrance that is Tom's (Scenario 275)

    @Test("newFigmaSurface, the Figma button's path: no owner")
    func newFigmaSurfaceSetsNoOwner() throws {
        try withRig { rig in
            let pane = try #require(rig.workspace.paneId(forPanelId: rig.terminalA.id))
            let created = try #require(rig.workspace.newFigmaSurface(inPane: pane, focus: false, openExternally: { _ in }))
            #expect(created.ownerTerminalSurfaceId == nil)
        }
    }

    // MARK: - moving the pane (Scenario 275)

    @Test("A's Figma pane detached and attached into another workspace: still A")
    func detachAndAttachKeepTheOwner() throws {
        try withRig { rig in
            let pane = try rig.addFigmaPane()
            #expect(try rig.goto(pane: pane, caller: rig.terminalA.id))
            let detached = try #require(rig.workspace.detachSurface(panelId: pane.id))
            let destination = Workspace()
            defer { destination.teardownAllPanels() }
            let destinationPane = try #require(destination.bonsplitController.focusedPaneId)
            #expect(destination.attachDetachedSurface(detached, inPane: destinationPane, focus: false) == pane.id)
            let moved = try #require(destination.panels[pane.id] as? BrowserPanel)
            #expect(moved.ownerTerminalSurfaceId == rig.terminalA.stableSurfaceId)
        }
    }

    // MARK: - saved and restored (Scenario 276)

    /// A workspace with terminal A and an owned Figma pane, as the saved session sees it.
    private func ownedSnapshot(_ rig: Rig) throws -> (pane: BrowserPanel, snapshot: SessionWorkspaceSnapshot) {
        let pane = try rig.addFigmaPane()
        #expect(try rig.goto(pane: pane, caller: rig.terminalA.id))
        return (pane, rig.workspace.sessionSnapshot(includeScrollback: false))
    }

    @Test("a workspace snapshot with an owned Figma pane encodes ownerTerminalSurfaceId with the terminal's stable id")
    func snapshotEncodesTheOwner() throws {
        try withRig { rig in
            let (pane, snapshot) = try ownedSnapshot(rig)
            let saved = try #require(snapshot.panels.first { $0.id == pane.id }?.browser)
            #expect(saved.ownerTerminalSurfaceId == rig.terminalA.stableSurfaceId)
            let json = try #require(String(data: try JSONEncoder().encode(saved), encoding: .utf8))
            #expect(json.contains("\"ownerTerminalSurfaceId\":\"\(rig.terminalA.stableSurfaceId.uuidString)\""))
            #expect(!json.contains(rig.terminalA.id.uuidString))
        }
    }

    @Test("restoring a snapshot gives the pane its owner, and the terminal re-adopts the stable id it names")
    func restoreGivesTheOwner() throws {
        try withRig { rig in
            let (pane, snapshot) = try ownedSnapshot(rig)
            let restored = Workspace()
            defer { restored.teardownAllPanels() }
            let remap = restored.restoreSessionSnapshot(snapshot)
            let restoredPaneId = try #require(remap[pane.id])
            let restoredTerminalId = try #require(remap[rig.terminalA.id])
            let restoredPane = try #require(restored.panels[restoredPaneId] as? BrowserPanel)
            let restoredTerminal = try #require(restored.panels[restoredTerminalId] as? TerminalPanel)
            #expect(restoredPane.ownerTerminalSurfaceId == rig.terminalA.stableSurfaceId)
            #expect(restoredTerminal.stableSurfaceId == restoredPane.ownerTerminalSurfaceId)
        }
    }

    @Test("a deferred pane keeps the owner in its snapshot, and carries it once first shown")
    func deferredPaneKeepsTheOwner() throws {
        try withRig { rig in
            let (pane, snapshot) = try ownedSnapshot(rig)
            let restored = Workspace()
            defer { restored.teardownAllPanels() }
            let remap = restored.restoreSessionSnapshot(snapshot, deferBrowserPanels: true)
            let paneId = try #require(remap[pane.id])
            let deferred = try #require(restored.panels[paneId] as? DeferredBrowserPanel)
            #expect(deferred.sessionPanelSnapshot.browser?.ownerTerminalSurfaceId == rig.terminalA.stableSurfaceId)

            // Saved again before it is shown, it still holds the owner.
            let resaved = restored.sessionSnapshot(includeScrollback: false)
            #expect(resaved.panels.first { $0.id == paneId }?.browser?.ownerTerminalSurfaceId == rig.terminalA.stableSurfaceId)

            #expect(restored.requestDeferredBrowserMaterialization(panelId: paneId, isVisibleInUI: true, reason: "test.visible"))
            let shown = try #require(restored.panels[paneId] as? BrowserPanel)
            #expect(shown.ownerTerminalSurfaceId == rig.terminalA.stableSurfaceId)
        }
    }

    @Test("a saved ownerTerminalSurfaceId decodes back from its JSON")
    func savedOwnerDecodes() throws {
        let owner = UUID()
        let saved = SessionBrowserPanelSnapshot(
            urlString: "https://www.figma.com/design/KEY/name",
            profileID: nil,
            shouldRenderWebView: true,
            pageZoom: 1,
            developerToolsVisible: false,
            backHistoryURLStrings: nil,
            forwardHistoryURLStrings: nil,
            ownerTerminalSurfaceId: owner
        )
        let decoded = try JSONDecoder().decode(SessionBrowserPanelSnapshot.self, from: JSONEncoder().encode(saved))
        #expect(decoded.ownerTerminalSurfaceId == owner)
    }

    @Test("a snapshot with no ownerTerminalSurfaceId decodes with every other field as before, and no owner")
    func oldSnapshotDecodes() throws {
        let owner = UUID()
        let original = SessionBrowserPanelSnapshot(
            urlString: "https://www.figma.com/design/KEY/name",
            profileID: nil,
            shouldRenderWebView: true,
            pageZoom: 1.25,
            developerToolsVisible: false,
            isMuted: true,
            keepLoaded: true,
            backHistoryURLStrings: ["https://example.com/a"],
            forwardHistoryURLStrings: nil,
            ownerTerminalSurfaceId: owner
        )
        var object = try #require(JSONSerialization.jsonObject(with: try JSONEncoder().encode(original)) as? [String: Any])
        #expect(object["ownerTerminalSurfaceId"] as? String == owner.uuidString)
        object.removeValue(forKey: "ownerTerminalSurfaceId")
        let decoded = try JSONDecoder().decode(
            SessionBrowserPanelSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.ownerTerminalSurfaceId == nil)
        #expect(decoded.urlString == original.urlString)
        #expect(decoded.pageZoom == 1.25)
        #expect(decoded.isMuted)
        #expect(decoded.keepLoaded)
        #expect(decoded.backHistoryURLStrings == original.backHistoryURLStrings)
    }

    @Test("the Dock's snapshot builder writes the owner too")
    func dockBuilderWritesTheOwner() throws {
        let dock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil },
            browserAvailabilityProvider: { true }
        )
        dock.hasLoadedConfiguration = true
        defer { dock.closeAllPanels() }
        let paneId = try #require(dock.bonsplitController.allPaneIds.first)
        let panelId = try #require(dock.newSurface(
            kind: .browser,
            inPane: paneId,
            url: URL(string: figmaEditorLink),
            focus: false
        ))
        let browser = try #require(dock.panels[panelId] as? BrowserPanel)
        let owner = UUID()
        browser.ownerTerminalSurfaceId = owner
        let snapshot = dock.sessionSnapshot(includeScrollback: false)
        #expect(snapshot.panels.first { $0.id == panelId }?.browser?.ownerTerminalSurfaceId == owner)
    }

    // MARK: - the terminal Tom was last in, and the pick over a live workspace (cm-73.45, Scenario 273 and 276)

    @Test("the agent's socket focus never counts as the terminal Tom was in")
    func socketFocusIsNotTomsFocus() throws {
        try withRig { rig in
            let b = try rig.addTerminal()
            // No user event is current in a unit test, as for any socket call.
            rig.workspace.focusPanel(b.id)
            rig.workspace.focusPanel(rig.terminalA.id)
            let response = try rig.call("surface.focus", [
                "workspace_id": rig.workspace.id.uuidString,
                "surface_id": b.id.uuidString
            ])
            #expect(response["ok"] as? Bool == true)
            #expect(rig.workspace.lastTerminalPanelIdTomWasIn == nil)
        }
    }

    @Test("a fresh click records the terminal, and a later click on another replaces it")
    func freshClickRecords() throws {
        try withRig { rig in
            let b = try rig.addTerminal()
            rig.tomClicked(rig.terminalA.id)
            #expect(rig.workspace.lastTerminalPanelIdTomWasIn == rig.terminalA.id)
            rig.tomClicked(b.id)
            #expect(rig.workspace.lastTerminalPanelIdTomWasIn == b.id)
        }
    }

    @Test("a key-up two seconds old does not record: the agent's focus after Tom's last key is not Tom's")
    func staleKeyUpDoesNotRecord() throws {
        try withRig { rig in
            let stale = Self.inputEvent(.keyUp, age: 2)
            rig.workspace.recordLastTerminalTomWasIn(rig.terminalA.id, event: stale)
            #expect(rig.workspace.lastTerminalPanelIdTomWasIn == nil)
            // The same event, judged when it is fresh, does record, so only its age differed.
            rig.workspace.recordLastTerminalTomWasIn(rig.terminalA.id, event: stale, now: stale.timestamp + 0.1)
            #expect(rig.workspace.lastTerminalPanelIdTomWasIn == rig.terminalA.id)
        }
    }

    @Test("a modifier-only event does not record")
    func flagsChangedDoesNotRecord() throws {
        try withRig { rig in
            rig.workspace.recordLastTerminalTomWasIn(rig.terminalA.id, event: Self.inputEvent(.flagsChanged, age: 0))
            #expect(rig.workspace.lastTerminalPanelIdTomWasIn == nil)
        }
    }

    @Test("no event does not record")
    func noEventDoesNotRecord() throws {
        try withRig { rig in
            rig.workspace.recordLastTerminalTomWasIn(rig.terminalA.id, event: nil)
            #expect(rig.workspace.lastTerminalPanelIdTomWasIn == nil)
        }
    }

    @Test("a fresh click on a markdown panel does not record")
    func nonTerminalDoesNotRecord() throws {
        try withRig { rig in
            let markdown = try rig.addMarkdown()
            rig.tomClicked(markdown.id)
            #expect(rig.workspace.lastTerminalPanelIdTomWasIn == nil)
        }
    }

    /// The tab (surface) id of a panel, as the pick sees it.
    private func tabId(_ rig: Rig, _ panelId: UUID) throws -> UUID {
        try #require(rig.workspace.surfaceIdFromPanelId(panelId)?.uuid)
    }

    @Test("over a live workspace, with the keyboard in the Figma pane, the owner is paired and not the terminal Tom was last in")
    func livePickTakesTheOwner() throws {
        try withRig { rig in
            let b = try rig.addTerminal()
            let pane = try rig.addFigmaPane()
            #expect(try rig.goto(pane: pane, caller: rig.terminalA.id))
            rig.tomClicked(b.id)
            rig.workspace.focusPanel(pane.id)
            let selection = try #require(rig.workspace.pickDesignFocusPair())
            #expect(selection.terminalTab.id == (try tabId(rig, rig.terminalA.id)))
            #expect(selection.figmaTab.id == (try tabId(rig, pane.id)))
        }
    }

    @Test("over a live workspace, a Figma pane with no owner pairs the terminal Tom was last in")
    func livePickTakesTheLastTerminal() throws {
        try withRig { rig in
            let b = try rig.addTerminal()
            let pane = try rig.addFigmaPane()
            rig.tomClicked(b.id)
            rig.workspace.focusPanel(pane.id)
            let selection = try #require(rig.workspace.pickDesignFocusPair())
            #expect(selection.terminalTab.id == (try tabId(rig, b.id)))
            rig.tomClicked(rig.terminalA.id)
            let again = try #require(rig.workspace.pickDesignFocusPair())
            #expect(again.terminalTab.id == (try tabId(rig, rig.terminalA.id)))
        }
    }

    @Test("after a restore, the candidates pair the restored Figma pane with its owner terminal")
    func restoredCandidatesMatchTheOwner() throws {
        for deferBrowserPanels in [false, true] {
            try withRig { rig in
                let (pane, snapshot) = try ownedSnapshot(rig)
                let restored = Workspace()
                defer { restored.teardownAllPanels() }
                let remap = restored.restoreSessionSnapshot(snapshot, deferBrowserPanels: deferBrowserPanels)
                let restoredPaneId = try #require(remap[pane.id])
                let restoredTerminalId = try #require(remap[rig.terminalA.id])
                let tabs = restored.designFocusCandidatePanes().flatMap(\.tabs)
                let figmaTab = try #require(tabs.first { $0.id == restored.surfaceIdFromPanelId(restoredPaneId)?.uuid })
                let terminalTab = try #require(tabs.first { $0.id == restored.surfaceIdFromPanelId(restoredTerminalId)?.uuid })
                #expect(figmaTab.isFigma)
                #expect(terminalTab.isTerminal)
                #expect(figmaTab.ownerTerminalSurfaceId == rig.terminalA.stableSurfaceId, "deferred: \(deferBrowserPanels)")
                #expect(terminalTab.stableSurfaceId == figmaTab.ownerTerminalSurfaceId, "deferred: \(deferBrowserPanels)")
            }
        }
    }
}
