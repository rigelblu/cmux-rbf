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

// cmux-rbf #cm-126.3: the Agent Pane in a real Workspace.

private let agentPaneFigmaLink = "https://www.figma.com/design/KEY/name"

@MainActor
private final class AgentPaneHiddenDiscardDelegate: BrowserHiddenWebViewDiscardManagerDelegate {
    let hiddenWebViewDiscardHiddenAt: Date?
    let hiddenWebViewDiscardWebViewInstanceID = UUID()
    var hiddenWebViewDiscardKeepLoaded: Bool
    var discardRequests = 0

    init(keepLoaded: Bool, hiddenAt: Date) {
        hiddenWebViewDiscardKeepLoaded = keepLoaded
        hiddenWebViewDiscardHiddenAt = hiddenAt
    }

    var hiddenWebViewDiscardSnapshot: BrowserHiddenWebViewDiscardManager.BlockerSnapshot {
        BrowserHiddenWebViewDiscardManager.BlockerSnapshot(
            isClosing: false,
            isVisibleInUI: false,
            shouldRenderWebView: true,
            hasPendingRemoteNavigation: false,
            hasCurrentURL: true,
            isLoading: false,
            webViewIsLoading: false,
            hasActiveMainFrameProvisionalNavigation: false,
            isDownloading: false,
            activeDownloadCount: 0,
            preferredDeveloperToolsVisible: false,
            isDeveloperToolsVisible: false,
            isElementFullscreenActive: false,
            isReactGrabActive: false,
            isVisualAutomationCaptureActive: false,
            hasPopups: false,
            isCapturingMedia: false,
            isPlayingMedia: false
        )
    }

    func hiddenWebViewDiscardManagerDidRequestDiscard(
        _ manager: BrowserHiddenWebViewDiscardManager,
        reason: String
    ) {
        discardRequests += 1
    }

    func hiddenWebViewDiscardManagerPolicyDidChange(
        _ manager: BrowserHiddenWebViewDiscardManager,
        reason: String
    ) {}
}

/// The Agent Pane end to end below the socket: the app's check and apply
/// (`TerminalController`'s witness), the `Workspace` path they call, the tab's
/// mark, keep-loaded, restore, Design Focus's hold, and every entrance that
/// would add a tab to a pane holding an Agent Pane. One test per case in the brief's
/// Scenario 19 list, numbered as there.
@MainActor
@Suite("AgentPaneWorkspace", .serialized)
struct AgentPaneWorkspaceTests {

    /// A tab manager with one workspace whose terminal A has a stable id that
    /// differs from its runtime id, so a test that stored the wrong one cannot
    /// pass by luck. Browser settings come from a suite of the test's own,
    /// except where `newBrowserSplit` reads `.standard`, which is saved and put back.
    @MainActor
    private final class Rig {
        let manager = TabManager()
        let workspace: Workspace
        let terminalA: TerminalPanel
        let defaults: UserDefaults
        private let suiteName = "cm-126.3-\(UUID().uuidString)"
        private let previousBrowserOverride: Any?
        private let previousTabManager: TabManager?
        private let previousExternalOpen: DefaultBrowserOpenAction
        private var scratchFiles: [URL] = []
        private var scratchDefaultsNames: [String] = []
        var externallyOpened: [URL] = []

        init() throws {
            _ = NSApplication.shared
            defaults = try #require(UserDefaults(suiteName: suiteName))
            previousBrowserOverride = UserDefaults.standard.object(forKey: BrowserAvailabilitySettings.disabledKey)
            previousTabManager = TerminalController.shared.tabManager
            previousExternalOpen = Workspace.designFocusExternalOpen
            BrowserAvailabilitySettings.setDisabled(false, defaults: .standard)
            workspace = try #require(manager.selectedWorkspace)
            let id = try #require(workspace.focusedPanelId)
            terminalA = try #require(workspace.panels[id] as? TerminalPanel)
            terminalA.adoptStableSurfaceId(UUID())
            TerminalController.shared.setActiveTabManager(manager)
            Workspace.designFocusExternalOpen = DefaultBrowserOpenAction { [weak self] url in
                self?.externallyOpened.append(url)
                return true
            }
        }

        func cleanup() {
            Workspace.designFocusExternalOpen = previousExternalOpen
            TerminalController.shared.setActiveTabManager(previousTabManager)
            manager.tabs.forEach { $0.teardownAllPanels() }
            if let previousBrowserOverride {
                UserDefaults.standard.set(previousBrowserOverride, forKey: BrowserAvailabilitySettings.disabledKey)
            } else {
                UserDefaults.standard.removeObject(forKey: BrowserAvailabilitySettings.disabledKey)
            }
            NotificationCenter.default.post(name: BrowserAvailabilitySettings.didChangeNotification, object: nil)
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            scratchDefaultsNames.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
            scratchFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        }

        func addTerminal(beside panel: UUID? = nil) throws -> TerminalPanel {
            let terminal = try #require(workspace.newTerminalSplit(
                from: panel ?? terminalA.id, orientation: .horizontal, focus: false
            ))
            terminal.adoptStableSurfaceId(UUID())
            return terminal
        }

        func addPlainBrowser(beside panel: UUID? = nil, url: String = "https://example.net/") throws -> BrowserPanel {
            try #require(workspace.newBrowserSplit(
                from: panel ?? terminalA.id,
                orientation: .horizontal,
                url: URL(string: url),
                focus: false,
                allowsExternalBrowserFallback: false
            ))
        }

        func scratch(_ name: String, _ contents: Data) throws -> URL {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("cm-126.3-\(UUID().uuidString)-\(name)")
            try contents.write(to: file)
            scratchFiles.append(file)
            return file
        }

        func isolatedDefaults(_ label: String) throws -> UserDefaults {
            let name = "cm-126.3-\(label)-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: name))
            scratchDefaultsNames.append(name)
            return defaults
        }

        /// `agent_pane.show` below the socket: the check, then, when ready, the apply.
        func show(from terminal: TerminalPanel, _ url: URL) -> ControlAgentPaneApplied? {
            guard case .ready(let plan) = TerminalController.shared.controlAgentPaneCheck(
                surfaceID: terminal.id, url: url, defaults: defaults
            ) else { return nil }
            return TerminalController.shared.controlAgentPaneApply(plan)
        }

        func check(from surfaceID: UUID, _ url: URL, defaults: UserDefaults? = nil) -> ControlAgentPaneCheck {
            TerminalController.shared.controlAgentPaneCheck(surfaceID: surfaceID, url: url, defaults: defaults ?? self.defaults)
        }

        func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
            let request: [String: Any] = ["jsonrpc": "2.0", "id": UUID().uuidString, "method": method, "params": params]
            let line = try #require(String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8))
            let response = TerminalController.shared.handleSocketLine(line)
            return try #require(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        }

        var paneCount: Int { workspace.bonsplitController.allPaneIds.count }

        func pane(of panelId: UUID) throws -> PaneID {
            try #require(workspace.paneId(forPanelId: panelId))
        }

        func panels(in pane: PaneID) -> [UUID] {
            workspace.bonsplitController.tabs(inPane: pane).compactMap { workspace.panelIdFromSurfaceId($0.id) }
        }

        func browser(_ id: UUID?) throws -> BrowserPanel {
            let panelID = try #require(id)
            return try #require(workspace.panels[panelID] as? BrowserPanel)
        }

        var agentPaneCount: Int {
            workspace.agentPaneCandidates().filter { AgentPaneMark.isAgentPaneKind(owner: $0.owner, kind: $0.kind) }.count
        }

        private func paneNodes(in node: ExternalTreeNode) -> [ExternalPaneNode] {
            switch node {
            case .pane(let pane): return [pane]
            case .split(let split): return paneNodes(in: split.first) + paneNodes(in: split.second)
            }
        }

        func expectValidPaneTree() {
            let paneIDs = workspace.bonsplitController.allPaneIds
            let nodes = paneNodes(in: workspace.bonsplitController.treeSnapshot())
            #expect(nodes.count == Set(nodes.map(\.id)).count)
            #expect(Set(nodes.map(\.id)) == Set(paneIDs.map { $0.id.uuidString }))
            let panelIDs = paneIDs.flatMap { panels(in: $0) }
            #expect(panelIDs.count == Set(panelIDs).count)
            #expect(Set(panelIDs) == Set(workspace.panels.keys))
            for node in nodes {
                #expect(!node.tabs.isEmpty)
                if let selected = node.selectedTabId {
                    #expect(node.tabs.contains { $0.id == selected })
                }
            }
        }
    }

    private func withRig(_ body: (Rig) throws -> Void) throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try body(rig)
    }

    /// A queue barrier after the legacy Combine receive(on: .main) delivery,
    /// matching FigmaTabMarkWorkspaceTests. No sleep or polling substitutes for delivery.
    private func oneMainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private static let page1 = URL(string: "https://example.org/one")!
    private static let page2 = URL(string: "https://example.org/two")!

    // MARK: - 1 to 5: open, steer, owners, close, move

    @Test("1. the first show opens beside the caller even with a pane on its right; that pane keeps its tabs; focus stays")
    func firstShowOpensBesideTheCaller() throws {
        try withRig { rig in
            let tomsPane = try rig.addTerminal()
            let tomsPaneId = try rig.pane(of: tomsPane.id)
            let tomsTabs = rig.panels(in: tomsPaneId)
            let focusedBefore = rig.workspace.focusedPanelId
            let paneCountBefore = rig.paneCount

            let applied = try #require(rig.show(from: rig.terminalA, Self.page1))
            #expect(applied.action == .opened)
            let agentPane = try rig.browser(applied.surfaceID)
            let ownedPane = try rig.pane(of: agentPane.id)
            #expect(rig.panels(in: tomsPaneId) == tomsTabs, "right pane gained a tab")
            #expect(rig.paneCount == paneCountBefore + 1, "pane count \(rig.paneCount), expected \(paneCountBefore + 1)")
            #expect(rig.panels(in: ownedPane) == [agentPane.id])
            #expect(ownedPane != (try rig.pane(of: rig.terminalA.id)))
            #expect(rig.workspace.focusedPanelId == focusedBefore)
            #expect(agentPane.ownerTerminalSurfaceId == rig.terminalA.stableSurfaceId)
            #expect(agentPane.ownedKind == .agentPane)
            #expect(!agentPane.isOmnibarVisible)
            #expect(applied.paneID == ownedPane.id)
        }
    }

    @Test("2. a second show steers the same Agent Pane and makes no new pane")
    func secondShowNavigates() throws {
        try withRig { rig in
            let first = try #require(rig.show(from: rig.terminalA, Self.page1))
            let second = try #require(rig.show(from: rig.terminalA, Self.page2))
            #expect(second.action == .navigated)
            #expect(second.surfaceID == first.surfaceID)
            #expect(rig.paneCount == 2, "pane count \(rig.paneCount), expected 2")
            #expect(try rig.browser(second.surfaceID).currentURL == Self.page2)
        }
    }

    @Test("show steers the first of multiple owned panes, reports the others, and list counts them too")
    func multipleOwnedPanesReportOthers() throws {
        try withRig { rig in
            for _ in 0..<2 {
                _ = try #require(rig.workspace.openAgentPane(
                    beside: rig.terminalA.id, url: Self.page1, owner: rig.terminalA.stableSurfaceId
                ))
            }
            let ordered = rig.workspace.agentPanes(ownedBy: rig.terminalA.stableSurfaceId)
            #expect(ordered.count == 2)
            let shown = try #require(rig.show(from: rig.terminalA, Self.page2))
            #expect(shown.action == .navigated)
            #expect(shown.surfaceID == ordered.first)
            #expect(shown.others == 1)
            for panelID in ordered.dropFirst() {
                #expect(try rig.browser(panelID).currentURL == Self.page1)
            }
            let rows = try #require(TerminalController.shared.controlAgentPaneList(workspaceID: rig.workspace.id))
            #expect(rows.count == 2)
            #expect(rows.allSatisfy { $0.others == 1 })
        }
    }

    @Test("3. two terminals in one workspace get two panes, each steering only its own")
    func twoOwnersTwoAgentPanes() throws {
        try withRig { rig in
            let terminalB = try rig.addTerminal()
            let a = try #require(rig.show(from: rig.terminalA, Self.page1))
            let b = try #require(rig.show(from: terminalB, Self.page2))
            #expect(b.action == .opened, "B's show steered A's agentPane")
            #expect(rig.agentPaneCount == 2, "\(rig.agentPaneCount) Agent Pane(s), expected 2")
            #expect(a.surfaceID != b.surfaceID)
            #expect(try rig.browser(a.surfaceID).currentURL == Self.page1)
            #expect(try rig.browser(b.surfaceID).ownerTerminalSurfaceId == terminalB.stableSurfaceId)
        }
    }

    @Test("4. after the Agent Pane is closed, the next show opens a new one")
    func closedAgentPaneGivesANewOne() throws {
        try withRig { rig in
            let first = try #require(rig.show(from: rig.terminalA, Self.page1))
            #expect(rig.workspace.closePanel(try #require(first.surfaceID), force: true))
            let again = try #require(rig.show(from: rig.terminalA, Self.page2))
            #expect(again.action == .opened, "action \(again.action), expected opened")
            #expect(again.surfaceID != first.surfaceID)
        }
    }

    @Test("5. an Agent Pane moved into a pane left of its caller is steered there, and no second one opens")
    func movedAgentPaneIsSteeredWhereItIs() throws {
        try withRig { rig in
            let tomsPane = try #require(rig.workspace.newTerminalSplit(
                from: rig.terminalA.id, orientation: .horizontal, insertFirst: true, focus: false
            ))
            tomsPane.adoptStableSurfaceId(UUID())
            let first = try #require(rig.show(from: rig.terminalA, Self.page1))
            let agentPaneID = try #require(first.surfaceID)
            #expect(rig.workspace.moveSurface(panelId: agentPaneID, toPane: try rig.pane(of: tomsPane.id), focus: false))
            let again = try #require(rig.show(from: rig.terminalA, Self.page2))
            #expect(again.action == .navigated)
            #expect(again.surfaceID == agentPaneID)
            #expect(rig.agentPaneCount == 1, "\(rig.agentPaneCount) panes, expected 1")
        }
    }

    // MARK: - 6 to 9: keep-loaded, mark, restore

    @Test("6. an Agent Pane is kept loaded while hidden; a plain browser pane is not")
    func agentPaneIsKeptLoaded() throws {
        try withRig { rig in
            let plain = try rig.addPlainBrowser()
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            #expect(agentPane.hiddenWebViewDiscardKeepLoaded)
            #expect(!plain.hiddenWebViewDiscardKeepLoaded)
        }
    }

    @Test("an Agent Pane exempts a hidden unblocked page from scheduled discard; a plain page arms the timer")
    func agentPaneExemptsDiscardScheduling() throws {
        try withRig { rig in
            let plain = try rig.addPlainBrowser()
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            rig.defaults.set(true, forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
            rig.defaults.set(300, forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey)
            let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: rig.defaults)
            defer { manager.cancel() }
            let now = Date()
            let delegate = AgentPaneHiddenDiscardDelegate(
                keepLoaded: agentPane.hiddenWebViewDiscardKeepLoaded,
                hiddenAt: now
            )
            manager.delegate = delegate
            #expect(manager.blockers(for: delegate.hiddenWebViewDiscardSnapshot).isEmpty)
            manager.scheduleIfNeeded(reason: "agent_pane_test", now: now)
            #expect(!manager.hasScheduledDiscard, "the Agent Pane's actual keep-loaded term must suppress scheduling")
            #expect(delegate.discardRequests == 0)

            delegate.hiddenWebViewDiscardKeepLoaded = plain.hiddenWebViewDiscardKeepLoaded
            manager.scheduleIfNeeded(reason: "plain_control_test", now: now)
            #expect(manager.hasScheduledDiscard, "the same hidden, unblocked plain-page control must arm a timer")
            #expect(delegate.discardRequests == 0)
        }
    }

    @Test("7. the tab is made with the mark, before any run-loop turn, and keeps it after the subscription writes")
    func tabCarriesTheMark() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let agentPane = try #require(rig.workspace.openAgentPane(
            beside: rig.terminalA.id, url: Self.page1, owner: rig.terminalA.stableSurfaceId
        ))
        let tabId = try #require(rig.workspace.surfaceIdFromPanelId(agentPane.id))
        #expect(rig.workspace.bonsplitController.tab(tabId)?.iconImageData == AgentPaneMark.shippedPicture,
                "the tab's icon at return isn't the mark")

        // The browser subscription writes the tab's picture again a turn later, from the page's own icon; for a
        // Agent Pane it keeps the mark. (`faviconPNGData` is `private(set)`, so a page icon is AgentPaneMarkTests' case.)
        rig.workspace.bonsplitController.updateTab(tabId, iconImageData: .some(Data([7])))
        agentPane.publishObservedDocumentTitle("Page")
        await oneMainQueueTurn()
        #expect(rig.workspace.bonsplitController.tab(tabId)?.iconImageData == AgentPaneMark.shippedPicture,
                "the subscription replaced the mark")
    }

    @Test("8. a snapshot keeps the owner and kind, through the workspace and the Dock; an unknown kind restores as a plain pane")
    func snapshotKeepsOwnerAndKind() throws {
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            let saved = try #require(rig.workspace.sessionSnapshot(includeScrollback: false)
                .panels.first { $0.id == agentPane.id }?.browser)
            #expect(saved.ownerTerminalSurfaceId == rig.terminalA.stableSurfaceId)
            #expect(saved.ownedKind == "agentPane")

            let encoded = try JSONEncoder().encode(saved)
            let decoded = try JSONDecoder().decode(SessionBrowserPanelSnapshot.self, from: encoded)
            let restored = BrowserPanel(workspaceId: UUID())
            restored.restoreSessionSnapshot(decoded)
            #expect(restored.ownedKind == .agentPane)
            #expect(AgentPaneMark.isAgentPaneKind(owner: restored.ownerTerminalSurfaceId, kind: restored.ownedKind))

            var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            object["ownedKind"] = "kindFromALaterBuild"
            let future = try JSONDecoder().decode(
                SessionBrowserPanelSnapshot.self, from: JSONSerialization.data(withJSONObject: object)
            )
            let plain = BrowserPanel(workspaceId: UUID())
            plain.restoreSessionSnapshot(future)
            #expect(plain.ownedKind == nil)
            #expect(plain.ownerTerminalSurfaceId == rig.terminalA.stableSurfaceId)
        }

        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil }, browserAvailabilityProvider: { true })
        dock.hasLoadedConfiguration = true
        defer { dock.closeAllPanels() }
        let paneId = try #require(dock.bonsplitController.allPaneIds.first)
        let panelId = try #require(dock.newSurface(kind: .browser, inPane: paneId, url: Self.page1, focus: false))
        let browser = try #require(dock.panels[panelId] as? BrowserPanel)
        let owner = UUID()
        browser.ownerTerminalSurfaceId = owner
        browser.ownedKind = .agentPane
        let record = try #require(dock.sessionSnapshot(includeScrollback: false).panels.first { $0.id == panelId }?.browser)
        #expect(record.ownerTerminalSurfaceId == owner)
        #expect(record.ownedKind == "agentPane", "the Dock's record lost the Agent Pane kind")
        let fromDock = BrowserPanel(workspaceId: UUID())
        fromDock.restoreSessionSnapshot(record)
        #expect(AgentPaneMark.isAgentPaneKind(owner: fromDock.ownerTerminalSurfaceId, kind: fromDock.ownedKind))
    }

    @Test("9. after a restore, an Agent Pane still a placeholder is found by the terminal's stable id and steered")
    func placeholderIsFoundAndSteered() throws {
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            let snapshot = rig.workspace.sessionSnapshot(includeScrollback: false)
            let restored = Workspace()
            defer { restored.teardownAllPanels() }
            let remap = restored.restoreSessionSnapshot(snapshot, deferBrowserPanels: true)
            let agentPaneId = try #require(remap[agentPane.id])
            let terminalId = try #require(remap[rig.terminalA.id])
            #expect(restored.panels[agentPaneId] is DeferredBrowserPanel)
            let terminal = try #require(restored.panels[terminalId] as? TerminalPanel)

            // The steps the apply takes for a show: the lookup, the placement, then the open or the steer.
            let panes = restored.agentPanes(ownedBy: terminal.stableSurfaceId)
            switch AgentPaneMark.placement(panes: panes) {
            case .open:
                restored.openAgentPane(beside: terminal.id, url: Self.page2, owner: terminal.stableSurfaceId)
            case .navigate(let id, _):
                restored.navigateAgentPane(id, to: Self.page2)
            }
            let count = restored.agentPaneCandidates().filter { AgentPaneMark.isAgentPaneKind(owner: $0.owner, kind: $0.kind) }.count
            #expect(count == 1, "\(count) panes, expected 1")
            let shown = try #require(restored.panels[agentPaneId] as? BrowserPanel)
            #expect(shown.currentURL == Self.page2)
        }
    }

    // MARK: - 10, 11: Design Focus

    /// Turns Design Focus on with a Figma pane right of A, as the mode needs a pair.
    private func enterDesignFocus(_ rig: Rig) throws {
        _ = try #require(rig.workspace.newBrowserSplit(
            from: rig.terminalA.id,
            orientation: .horizontal,
            url: URL(string: agentPaneFigmaLink),
            focus: false,
            chromeVisibility: BrowserChromeVisibility(omnibarVisible: false)
        ))
        #expect(rig.workspace.toggleDesignFocus())
        #expect(rig.workspace.isDesignFocusActive)
    }

    @Test("10. with Design Focus on, the check plans a hold, the apply changes no pane or page, and nothing goes to the browser app")
    func designFocusHolds() throws {
        try withRig { rig in
            try enterDesignFocus(rig)
            let paneCount = rig.paneCount
            let panelCount = rig.workspace.panels.count
            guard case .ready(let plan) = rig.check(from: rig.terminalA.id, Self.page1) else {
                Issue.record("the check refused")
                return
            }
            #expect(plan.action == .hold(panelID: nil, others: 0))
            let applied = try #require(TerminalController.shared.controlAgentPaneApply(plan))
            #expect(applied.action == .heldDesignFocus)
            #expect(applied.surfaceID == nil)
            #expect(rig.paneCount == paneCount)
            #expect(rig.workspace.panels.count == panelCount)
            #expect(rig.externallyOpened.isEmpty, "the browser app was handed \(rig.externallyOpened)")
        }
    }

    @Test("11. leaving Design Focus shows the held page through the same path; an app quit applies nothing")
    func leavingDesignFocusApplies() throws {
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            try enterDesignFocus(rig)
            let held = try #require(rig.show(from: rig.terminalA, Self.page2))
            #expect(held.action == .heldDesignFocus)
            #expect(held.surfaceID == agentPane.id)
            #expect(agentPane.currentURL == Self.page1)
            rig.workspace.exitDesignFocus(reason: "test")
            #expect(agentPane.currentURL == Self.page2, "the Agent Pane still shows the old page")
            #expect(rig.agentPaneCount == 1)
        }
        try withRig { rig in
            try enterDesignFocus(rig)
            _ = try #require(rig.show(from: rig.terminalA, Self.page1))
            #expect(rig.agentPaneCount == 0)
            rig.workspace.exitDesignFocus(reason: "test")
            #expect(rig.agentPaneCount == 1, "no Agent Pane opened for the held page")
        }
        try withRig { rig in
            try enterDesignFocus(rig)
            _ = try #require(rig.show(from: rig.terminalA, Self.page1))
            rig.workspace.exitDesignFocus(reason: "appQuit")
            #expect(rig.agentPaneCount == 0, "a held page opened while the app quit")
        }
    }

    @Test("only the latest held update is shown when Design Focus ends")
    func latestHeldPageWins() throws {
        try withRig { rig in
            try enterDesignFocus(rig)
            let first = try #require(rig.show(from: rig.terminalA, Self.page1))
            let second = try #require(rig.show(from: rig.terminalA, Self.page2))
            #expect(first.action == .heldDesignFocus && second.action == .heldDesignFocus)
            #expect(rig.agentPaneCount == 0)
            rig.workspace.exitDesignFocus(reason: "test")
            let panelID = try #require(rig.workspace.agentPanes(ownedBy: rig.terminalA.stableSurfaceId).first)
            #expect(try rig.browser(panelID).currentURL == Self.page2)
            #expect(rig.agentPaneCount == 1)
        }
    }

    @Test("closing Design Focus's Figma tab applies one held update with exactly one Agent Pane and a valid tree")
    func closingDesignFocusFigmaAppliesHeldPage() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try enterDesignFocus(rig)
        let figma = try #require(rig.workspace.panels.values.compactMap { $0 as? BrowserPanel }.first)
        #expect(figma.currentURL == URL(string: agentPaneFigmaLink))
        let held = try #require(rig.show(from: rig.terminalA, Self.page2))
        #expect(held.action == .heldDesignFocus)
        #expect(rig.agentPaneCount == 0)
        #expect(rig.workspace.closePanel(figma.id, force: true))
        await oneMainQueueTurn()
        #expect(!rig.workspace.isDesignFocusActive)
        #expect(rig.workspace.lastDesignFocusLeaveReason == "bonsplitCleared")
        #expect(rig.workspace.panels[figma.id] == nil)
        let panes = rig.workspace.agentPanes(ownedBy: rig.terminalA.stableSurfaceId)
        #expect(panes.count == 1, "bonsplitCleared must apply the held page")
        #expect(rig.agentPaneCount == 1)
        if let panelID = panes.first {
            #expect(try rig.browser(panelID).currentURL == Self.page2)
        }
        rig.expectValidPaneTree()

        // A second tab keeps the Figma pane alive, so didCloseTab leaves the pair.
        let sharedRig = try Rig()
        defer { sharedRig.cleanup() }
        let sharedFigma = try #require(sharedRig.workspace.newBrowserSplit(
            from: sharedRig.terminalA.id,
            orientation: .horizontal,
            url: URL(string: agentPaneFigmaLink),
            focus: false,
            chromeVisibility: BrowserChromeVisibility(omnibarVisible: false)
        ))
        let figmaPane = try sharedRig.pane(of: sharedFigma.id)
        let plain = try #require(sharedRig.workspace.newBrowserSurface(
            inPane: figmaPane, url: URL(string: "https://example.net/"), focus: false,
            allowsExternalBrowserFallback: false
        ))
        #expect(sharedRig.panels(in: figmaPane).count == 2)
        #expect(sharedRig.workspace.toggleDesignFocus())
        #expect(sharedRig.workspace.isDesignFocusActive)
        let sharedHeld = try #require(sharedRig.show(from: sharedRig.terminalA, Self.page2))
        #expect(sharedHeld.action == .heldDesignFocus)
        #expect(sharedRig.agentPaneCount == 0)
        #expect(sharedRig.workspace.closePanel(sharedFigma.id, force: true))
        await oneMainQueueTurn()
        #expect(!sharedRig.workspace.isDesignFocusActive)
        #expect(sharedRig.workspace.lastDesignFocusLeaveReason == "pairTabClosed")
        #expect(sharedRig.workspace.panels[sharedFigma.id] == nil)
        #expect(sharedRig.workspace.panels[plain.id] != nil)
        let sharedPanes = sharedRig.workspace.agentPanes(ownedBy: sharedRig.terminalA.stableSurfaceId)
        #expect(sharedPanes.count == 1, "pairTabClosed must apply the held page")
        #expect(sharedRig.agentPaneCount == 1)
        if let panelID = sharedPanes.first {
            #expect(try sharedRig.browser(panelID).currentURL == Self.page2)
        }
        sharedRig.expectValidPaneTree()
    }

    @Test("moving the pair's Figma tab applies one held update with a valid pane tree")
    func movingDesignFocusFigmaAppliesHeldPage() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try enterDesignFocus(rig)
        let figma = try #require(rig.workspace.panels.values.compactMap { $0 as? BrowserPanel }.first)
        let terminalPane = try rig.pane(of: rig.terminalA.id)
        #expect(try rig.pane(of: figma.id) != terminalPane)
        #expect(try #require(rig.show(from: rig.terminalA, Self.page2)).action == .heldDesignFocus)
        #expect(rig.agentPaneCount == 0)
        #expect(rig.workspace.moveSurface(panelId: figma.id, toPane: terminalPane, focus: true))
        await oneMainQueueTurn()
        #expect(!rig.workspace.isDesignFocusActive)
        #expect(rig.workspace.lastDesignFocusLeaveReason == "moveSurface")
        #expect(try rig.pane(of: figma.id) == terminalPane)
        let panes = rig.workspace.agentPanes(ownedBy: rig.terminalA.stableSurfaceId)
        #expect(panes.count == 1)
        #expect(rig.agentPaneCount == 1)
        #expect(try rig.browser(panes.first).currentURL == Self.page2)
        rig.expectValidPaneTree()
    }

    @Test("attaching a detached surface into the pair applies one held update with a valid pane tree")
    func attachingDuringDesignFocusAppliesHeldPage() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let incoming = try rig.addTerminal()
        let detached = try #require(rig.workspace.detachSurface(panelId: incoming.id))
        try enterDesignFocus(rig)
        let figma = try #require(rig.workspace.panels.values.compactMap { $0 as? BrowserPanel }.first)
        let figmaPane = try rig.pane(of: figma.id)
        #expect(try #require(rig.show(from: rig.terminalA, Self.page2)).action == .heldDesignFocus)
        #expect(rig.agentPaneCount == 0)
        #expect(rig.workspace.attachDetachedSurface(detached, inPane: figmaPane, focus: true) == incoming.id)
        await oneMainQueueTurn()
        #expect(!rig.workspace.isDesignFocusActive)
        #expect(rig.workspace.lastDesignFocusLeaveReason == "attachDetachedSurface")
        #expect(try rig.pane(of: incoming.id) == figmaPane)
        let panes = rig.workspace.agentPanes(ownedBy: rig.terminalA.stableSurfaceId)
        #expect(panes.count == 1)
        #expect(rig.agentPaneCount == 1)
        #expect(try rig.browser(panes.first).currentURL == Self.page2)
        rig.expectValidPaneTree()
    }

    @Test("a new browser split exits Design Focus and applies one held update with a valid pane tree")
    func splittingDuringDesignFocusAppliesHeldPage() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try enterDesignFocus(rig)
        #expect(try #require(rig.show(from: rig.terminalA, Self.page2)).action == .heldDesignFocus)
        #expect(rig.agentPaneCount == 0)
        let plain = try #require(rig.workspace.newBrowserSplit(
            from: rig.terminalA.id, orientation: .horizontal, focus: true,
            allowsExternalBrowserFallback: false
        ))
        await oneMainQueueTurn()
        #expect(!rig.workspace.isDesignFocusActive)
        #expect(rig.workspace.lastDesignFocusLeaveReason == "newBrowserSplit")
        #expect(plain.ownedKind != .agentPane)
        let panes = rig.workspace.agentPanes(ownedBy: rig.terminalA.stableSurfaceId)
        #expect(panes.count == 1)
        #expect(rig.agentPaneCount == 1)
        #expect(try rig.browser(panes.first).currentURL == Self.page2)
        rig.expectValidPaneTree()
    }

    // MARK: - 12, 13: browser.open_split and the Figma header button

    @Test("12. browser.open_split from the agent's terminal with its Agent Pane to the right makes a split")
    func openSplitSplitsInsteadOfCovering() throws {
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            let ownedPane = try rig.pane(of: agentPane.id)
            let paneCount = rig.paneCount
            let response = try rig.call("browser.open_split", [
                "workspace_id": rig.workspace.id.uuidString,
                "surface_id": rig.terminalA.id.uuidString,
                "url": "https://example.net/",
                "focus": false
            ])
            #expect(response["ok"] as? Bool == true, "\(response)")
            #expect(rig.panels(in: ownedPane) == [agentPane.id], "Agent Pane's pane gained a tab")
            #expect(rig.paneCount == paneCount + 1)
        }
    }

    @Test("13. the Figma header button on the Agent Pane's pane makes a split")
    func figmaButtonSplitsTheAgentPane() throws {
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            let ownedPane = try rig.pane(of: agentPane.id)
            let figma = try #require(rig.workspace.newFigmaSurface(
                inPane: ownedPane, defaults: rig.defaults, openExternally: { _ in }
            ))
            #expect(rig.panels(in: ownedPane) == [agentPane.id], "Agent Pane's pane gained a Figma tab")
            #expect(try rig.pane(of: figma.id) != ownedPane)
        }
    }

    // MARK: - 14: the app's refusals

    @Test("14. the check refuses each page and caller it must, and changes no pane")
    func checkRefuses() throws {
        try withRig { rig in
            let plain = try rig.addPlainBrowser()
            let paneCount = rig.paneCount
            let a = rig.terminalA.id

            let blocked = try rig.isolatedDefaults("allow")
            blocked.set(["example.org"], forKey: BrowserURLAllowlistPolicy.userDefaultsKey)
            if case .refused(.urlBlocked) = rig.check(from: a, URL(string: "https://example.com/")!, defaults: blocked) {} else {
                Issue.record("a page the URL allowlist blocks answered \(rig.check(from: a, URL(string: "https://example.com/")!, defaults: blocked))")
            }
            #expect(rig.check(from: a, URL(string: "http://example.org/")!) == .refused(.insecureHTTP(host: "example.org")))
            #expect(rig.check(from: a, URL(string: agentPaneFigmaLink)!) == .refused(.figmaAddress))
            #expect(rig.check(from: a, FigmaPaneURL.wrapperFileURL()) == .refused(.figmaAddress))
            #expect(rig.check(from: a, URL(string: "about:blank")!) == .refused(.badScheme))

            let off = try rig.isolatedDefaults("off")
            BrowserAvailabilitySettings.setDisabled(true, defaults: off)
            #expect(rig.check(from: a, Self.page1, defaults: off) == .refused(.browserOff))

            #expect(rig.check(from: plain.id, Self.page1) == .refused(.notTerminal(surfaceID: plain.id, type: "browser")))
            let nobody = UUID()
            #expect(rig.check(from: nobody, Self.page1) == .refused(.notFound(surfaceID: nobody)))

            let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil }, browserAvailabilityProvider: { true })
            dock.hasLoadedConfiguration = true
            defer { dock.closeAllPanels() }
            let dockPane = try #require(dock.bonsplitController.allPaneIds.first)
            let dockTerminal = try #require(dock.newSurface(kind: .terminal, inPane: dockPane, url: nil, focus: false))
            #expect(rig.check(from: dockTerminal, Self.page1) == .refused(.inDock))

            #expect(rig.paneCount == paneCount)

            // Control: localhost and a listed host are ready.
            if case .ready = rig.check(from: a, URL(string: "http://localhost:8000/p.html")!) {} else {
                Issue.record("http://localhost was refused")
            }
            let listed = try rig.isolatedDefaults("listed")
            listed.set("example.org", forKey: BrowserInsecureHTTPSettings.allowlistKey)
            if case .ready = rig.check(from: a, URL(string: "http://example.org/")!, defaults: listed) {} else {
                Issue.record("a listed http host was refused")
            }
        }
    }

    // MARK: - 15 to 19: every other way a tab would land on an Agent Pane

    @Test("15. a terminal link click with the Agent Pane to the right makes a split")
    func terminalLinkSplits() throws {
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            let ownedPane = try rig.pane(of: agentPane.id)
            let paneCount = rig.paneCount
            #expect(rig.workspace.openTerminalBrowserLink(url: URL(string: "https://example.net/")!, sourcePanelId: rig.terminalA.id))
            #expect(rig.panels(in: ownedPane) == [agentPane.id], "Agent Pane's pane gained a browser tab")
            #expect(rig.paneCount == paneCount + 1)
        }
    }

    @Test("16. control for 15: a plain pane on the right gets the tab; after 15's split, the next click reuses the new pane")
    func terminalLinkControl() throws {
        try withRig { rig in
            let plain = try rig.addPlainBrowser()
            let plainPane = try rig.pane(of: plain.id)
            #expect(rig.workspace.openTerminalBrowserLink(url: URL(string: "https://example.net/a")!, sourcePanelId: rig.terminalA.id))
            #expect(rig.paneCount == 2, "pane count \(rig.paneCount), expected 2")
            #expect(rig.panels(in: plainPane).count == 2)
        }
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            #expect(rig.workspace.openTerminalBrowserLink(url: URL(string: "https://example.net/a")!, sourcePanelId: rig.terminalA.id))
            #expect(rig.workspace.openTerminalBrowserLink(url: URL(string: "https://example.net/b")!, sourcePanelId: rig.terminalA.id))
            #expect(rig.paneCount == 3, "pane count \(rig.paneCount), expected 3")
            #expect(rig.panels(in: try rig.pane(of: agentPane.id)) == [agentPane.id])
        }
    }

    @Test("17. a markdown preview with the Agent Pane to the right makes a split")
    func markdownPreviewSplits() throws {
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            let ownedPane = try rig.pane(of: agentPane.id)
            let file = try rig.scratch("note.md", Data("# note".utf8))
            let paneCount = rig.paneCount
            _ = try #require(rig.workspace.openOrFocusMarkdownSplit(from: rig.terminalA.id, filePath: file.path))
            #expect(rig.panels(in: ownedPane) == [agentPane.id], "Agent Pane's pane gained a markdown tab")
            #expect(rig.paneCount == paneCount + 1)
        }
    }

    @Test("18. a file preview with the Agent Pane to the right makes a split")
    func filePreviewSplits() throws {
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            let ownedPane = try rig.pane(of: agentPane.id)
            let png = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )?.representation(using: .png, properties: [:]))
            let file = try rig.scratch("pic.png", png)
            let paneCount = rig.paneCount
            _ = try #require(rig.workspace.openOrFocusFilePreviewSplit(from: rig.terminalA.id, filePath: file.path))
            #expect(rig.panels(in: ownedPane) == [agentPane.id], "Agent Pane's pane gained a file-preview tab")
            #expect(rig.paneCount == paneCount + 1)
        }
    }

    @Test("19. a sidebar pull-request open with the Agent Pane right-most splits the focused pane; a plain right-most pane gets the tab")
    func sidebarOpenSkipsTheAgentPane() throws {
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            let ownedPane = try rig.pane(of: agentPane.id)
            let terminalPane = try rig.pane(of: rig.terminalA.id)
            let terminalTabs = rig.panels(in: terminalPane)
            #expect(rig.workspace.topRightBrowserReusePane() == nil, "expected nil")
            let paneCount = rig.paneCount
            _ = try #require(rig.manager.openBrowser(
                inWorkspace: rig.workspace.id, url: URL(string: "https://example.net/pr")!,
                preferSplitRight: true, insertAtEnd: true
            ))
            #expect(rig.panels(in: ownedPane) == [agentPane.id], "Agent Pane's pane gained a browser tab")
            #expect(rig.panels(in: terminalPane) == terminalTabs, "the terminal's pane gained a browser tab")
            #expect(rig.paneCount == paneCount + 1)
        }
        try withRig { rig in
            let plain = try rig.addPlainBrowser()
            let plainPane = try rig.pane(of: plain.id)
            #expect(rig.workspace.topRightBrowserReusePane() == plainPane)
            _ = try #require(rig.manager.openBrowser(
                inWorkspace: rig.workspace.id, url: URL(string: "https://example.net/pr")!,
                preferSplitRight: true, insertAtEnd: true
            ))
            #expect(rig.panels(in: plainPane).count == 2)
        }
    }

    @Test("without pane bounds the sidebar reuse fallback refuses an Agent Pane and still reuses a plain pane")
    func sidebarEmptyBoundsPreservesAgentPane() throws {
        try withRig { rig in
            _ = try #require(rig.show(from: rig.terminalA, Self.page1))
            #expect(rig.workspace.topRightBrowserReusePane(normalizedPaneBounds: [:]) == nil)
        }
        try withRig { rig in
            _ = try rig.addPlainBrowser()
            let expected = rig.workspace.bonsplitController.allPaneIds.sorted { $0.id.uuidString < $1.id.uuidString }.first
            #expect(rig.workspace.topRightBrowserReusePane(normalizedPaneBounds: [:]) == expected)
        }
    }

    // MARK: - 20 to 22: the Figma pane's owner, and the owner by its live id

    @Test("20. a Figma pane the same terminal owns is never steered: show opens an Agent Pane beside it")
    func ownedFigmaPaneIsNotAnAgentPane() throws {
        try withRig { rig in
            let figma = try #require(rig.workspace.newBrowserSplit(
                from: rig.terminalA.id,
                orientation: .horizontal,
                url: URL(string: agentPaneFigmaLink),
                focus: false,
                chromeVisibility: BrowserChromeVisibility(omnibarVisible: false)
            ))
            figma.ownerTerminalSurfaceId = rig.terminalA.stableSurfaceId
            let figmaPane = try rig.pane(of: figma.id)
            let paneCount = rig.paneCount
            let applied = try #require(rig.show(from: rig.terminalA, Self.page1))
            #expect(applied.action == .opened, "action \(applied.action), expected opened")
            #expect(rig.paneCount == paneCount + 1)
            #expect(figma.currentURL == URL(string: agentPaneFigmaLink), "Figma pane URL changed")
            #expect(rig.panels(in: figmaPane) == [figma.id])
        }
    }

    @Test("21. setFigmaPaneOwner leaves an Agent Pane's owner alone, and still writes a Figma pane's")
    func figmaOwnerWriterSkipsAnAgentPane() throws {
        try withRig { rig in
            let terminalB = try rig.addTerminal()
            let agentPane = try #require(rig.workspace.newBrowserSplit(
                from: rig.terminalA.id,
                orientation: .horizontal,
                url: URL(string: agentPaneFigmaLink),
                focus: false,
                allowsExternalBrowserFallback: false,
                chromeVisibility: BrowserChromeVisibility(omnibarVisible: false),
                owner: BrowserPaneOwner(terminalStableID: rig.terminalA.stableSurfaceId, kind: .agentPane)
            ))
            #expect(!rig.workspace.setFigmaPaneOwner(figmaPanelId: agentPane.id, callerPanelId: terminalB.id, via: .goto))
            #expect(agentPane.ownerTerminalSurfaceId == rig.terminalA.stableSurfaceId, "owner is B, expected A")

            let figma = try #require(rig.workspace.newBrowserSplit(
                from: rig.terminalA.id,
                orientation: .horizontal,
                url: URL(string: agentPaneFigmaLink),
                focus: false,
                chromeVisibility: BrowserChromeVisibility(omnibarVisible: false)
            ))
            #expect(rig.workspace.setFigmaPaneOwner(figmaPanelId: figma.id, callerPanelId: terminalB.id, via: .goto))
            #expect(figma.ownerTerminalSurfaceId == terminalB.stableSurfaceId)
        }
    }

    @Test("22. the owner is named by the terminal's live id, null once it closes, and the stored id stays")
    func ownerIsNamedByItsLiveID() throws {
        try withRig { rig in
            let terminal = try rig.addTerminal()
            #expect(terminal.id != terminal.stableSurfaceId)
            let applied = try #require(rig.show(from: terminal, Self.page1))
            #expect(applied.ownerSurfaceID == terminal.id)
            #expect(applied.ownerStableID == terminal.stableSurfaceId)

            @MainActor func summary() -> ControlAgentPaneSummary? {
                TerminalController.shared.controlAgentPaneList(workspaceID: rig.workspace.id)?
                    .first { $0.surfaceID == applied.surfaceID }
            }
            #expect(summary()?.ownerSurfaceID == terminal.id, "ownerSurfaceID is nil for a live terminal")
            #expect(summary()?.ownerStableID == terminal.stableSurfaceId)

            let other = rig.manager.addWorkspace(select: false)
            let otherTerminal = try #require(other.focusedPanelId.flatMap { other.panels[$0] as? TerminalPanel })
            otherTerminal.adoptStableSurfaceId(terminal.stableSurfaceId)

            #expect(rig.workspace.closePanel(terminal.id, force: true))
            #expect(summary() != nil, "the Agent Pane is no longer listed")
            #expect(summary()?.ownerSurfaceID == nil, "expected nil after T closed")
            #expect(summary()?.ownerStableID == applied.ownerStableID)
        }
    }

    @Test("23. WebKit's title-delivery seam and a navigating show never replace the Agent Pane caption")
    func captionSurvivesPageTitleChanges() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
        let tabID = try #require(rig.workspace.surfaceIdFromPanelId(agentPane.id))
        // This is the production seam called by BrowserPanel's WebKit title observer.
        // Actual WebKit loading remains a separate tagged-app check in Scenario 15.
        agentPane.publishObservedDocumentTitle("First title")
        await oneMainQueueTurn()
        #expect(rig.workspace.bonsplitController.tab(tabID)?.title == "Agent Pane", "tab title 'First title', expected 'Agent Pane'")
        #expect(rig.workspace.panelTitles[agentPane.id] == "Agent Pane")

        agentPane.publishObservedDocumentTitle("Page")
        await oneMainQueueTurn()
        #expect(rig.workspace.bonsplitController.tab(tabID)?.title == "Agent Pane", "tab title 'Page', expected 'Agent Pane'")
        #expect(rig.workspace.panelTitles[agentPane.id] == "Agent Pane")

        // Another async suite can replace the shared manager while this test is suspended.
        TerminalController.shared.setActiveTabManager(rig.manager)
        let applied = try #require(rig.show(from: rig.terminalA, Self.page2))
        #expect(applied.action == .navigated)
        #expect(applied.surfaceID == agentPane.id)
        agentPane.publishObservedDocumentTitle("Second title")
        await oneMainQueueTurn()
        #expect(rig.workspace.bonsplitController.tab(tabID)?.title == "Agent Pane", "navigation replaced the caption")
        #expect(rig.workspace.panelTitles[agentPane.id] == "Agent Pane")

        let plain = try #require(rig.workspace.newBrowserSplit(
            from: rig.terminalA.id, orientation: .horizontal, url: nil,
            focus: false, allowsExternalBrowserFallback: false
        ))
        let plainTab = try #require(rig.workspace.surfaceIdFromPanelId(plain.id))
        plain.publishObservedDocumentTitle("First title")
        await oneMainQueueTurn()
        #expect(rig.workspace.bonsplitController.tab(plainTab)?.title == "First title")
        plain.publishObservedDocumentTitle("Page")
        await oneMainQueueTurn()
        #expect(rig.workspace.bonsplitController.tab(plainTab)?.title == "Page")
        plain.publishObservedDocumentTitle("Second title")
        await oneMainQueueTurn()
        #expect(rig.workspace.bonsplitController.tab(plainTab)?.title == "Second title")
    }

    @Test("a restored placeholder has its caption and mark before being shown")
    func restoredAgentPaneTabHasCaptionAndMark() throws {
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            var saved = rig.workspace.sessionSnapshot(includeScrollback: false)
            let index = try #require(saved.panels.firstIndex { $0.id == agentPane.id })
            saved.panels[index].title = "Saved page title"
            let restored = Workspace()
            defer { restored.teardownAllPanels() }
            let remap = restored.restoreSessionSnapshot(saved, deferBrowserPanels: true)
            let restoredID = try #require(remap[agentPane.id])
            #expect(restored.panels[restoredID] is DeferredBrowserPanel)
            let tabID = try #require(restored.surfaceIdFromPanelId(restoredID))
            #expect(restored.bonsplitController.tab(tabID)?.title == "Agent Pane", "saved title replaced the caption")
            #expect(restored.bonsplitController.tab(tabID)?.iconImageData == AgentPaneMark.shippedPicture)
            #expect(restored.panelTitles[restoredID] == "Agent Pane")
        }
    }

    @Test("an owned placeholder with no saved title restores the Agent Pane caption")
    func restoredAgentPaneWithoutSavedTitleHasCaption() throws {
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            var saved = rig.workspace.sessionSnapshot(includeScrollback: false)
            let index = try #require(saved.panels.firstIndex { $0.id == agentPane.id })
            saved.panels[index].title = nil
            let restored = Workspace()
            defer { restored.teardownAllPanels() }
            let remap = restored.restoreSessionSnapshot(saved, deferBrowserPanels: true)
            let restoredID = try #require(remap[agentPane.id])
            let tabID = try #require(restored.surfaceIdFromPanelId(restoredID))
            #expect(restored.bonsplitController.tab(tabID)?.title == "Agent Pane")
            #expect(restored.panelTitles[restoredID] == "Agent Pane")
        }
    }

    @Test("Tom's Rename Tab title still wins over the Agent Pane caption on page delivery and restore")
    func customTitleWinsOnPageDeliveryAndRestore() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
        let tabID = try #require(rig.workspace.surfaceIdFromPanelId(agentPane.id))
        #expect(rig.workspace.setPanelCustomTitle(
            panelId: agentPane.id, title: "Tom's caption", propagateToRemoteTmux: false, propagateToCloud: false
        ))
        agentPane.publishObservedDocumentTitle("Page title")
        await oneMainQueueTurn()
        #expect(rig.workspace.bonsplitController.tab(tabID)?.title == "Tom's caption")
        let restored = Workspace()
        defer { restored.teardownAllPanels() }
        let remap = restored.restoreSessionSnapshot(rig.workspace.sessionSnapshot(includeScrollback: false), deferBrowserPanels: true)
        let restoredID = try #require(remap[agentPane.id])
        let restoredTab = try #require(restored.surfaceIdFromPanelId(restoredID))
        #expect(restored.bonsplitController.tab(restoredTab)?.title == "Tom's caption")
    }

    @Test("the newly opened tab has the Agent Pane caption before any subscription delivery")
    func agentPaneCaptionIsInstalledBeforeDelivery() throws {
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            let tabID = try #require(rig.workspace.surfaceIdFromPanelId(agentPane.id))
            #expect(rig.workspace.bonsplitController.tab(tabID)?.title == "Agent Pane")
            #expect(rig.workspace.panelTitles[agentPane.id] == "Agent Pane")
        }
    }

    @Test("a workspace context reset preserves the Agent Pane caption and mark")
    func agentPaneTabSurvivesContextReset() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
        let tabID = try #require(rig.workspace.surfaceIdFromPanelId(agentPane.id))
        rig.workspace.resetBrowserPanelsForContextChange(reason: "agent-pane-test")
        #expect(rig.workspace.bonsplitController.tab(tabID)?.title == "Agent Pane")
        #expect(rig.workspace.bonsplitController.tab(tabID)?.iconImageData == AgentPaneMark.shippedPicture)
        await oneMainQueueTurn()
        #expect(rig.workspace.bonsplitController.tab(tabID)?.title == "Agent Pane")
        #expect(rig.workspace.bonsplitController.tab(tabID)?.iconImageData == AgentPaneMark.shippedPicture)
    }

    @Test("both Agent Pane socket methods are advertised")
    func agentPaneMethodsAreAdvertised() throws {
        try withRig { rig in
            let response = try rig.call("system.capabilities", [:])
            #expect(response["ok"] as? Bool == true)
            let result = try #require(response["result"] as? [String: Any])
            let methods = try #require(result["methods"] as? [String])
            #expect(methods.contains("agent_pane.show"))
            #expect(methods.contains("agent_pane.list"))
        }
    }

    @Test("the real app socket dispatch reaches the coordinator and its app witness for show and list")
    func agentPaneSocketRoundTripUsesCoordinator() throws {
        try withRig { rig in
            let shown = try rig.call("agent_pane.show", [
                "surface_id": rig.terminalA.id.uuidString, "url": Self.page1.absoluteString
            ])
            #expect(shown["ok"] as? Bool == true, "\(shown)")
            let result = try #require(shown["result"] as? [String: Any])
            #expect(result["action"] as? String == "opened")
            #expect(result["owner_surface_id"] as? String == rig.terminalA.id.uuidString)
            #expect(result["owner_stable_id"] as? String == rig.terminalA.stableSurfaceId.uuidString)
            let listed = try rig.call("agent_pane.list", ["workspace_id": rig.workspace.id.uuidString])
            #expect(listed["ok"] as? Bool == true, "\(listed)")
            let listResult = try #require(listed["result"] as? [String: Any])
            let panes = try #require(listResult["agent_panes"] as? [[String: Any]])
            #expect(panes.count == 1)
            #expect(panes.first?["surface_id"] as? String == result["surface_id"] as? String)
            #expect(rig.paneCount == 2)
        }
    }
}
