import AppKit
import Bonsplit
import CmuxBrowser
import CmuxControlSocket
import CmuxSettings
import CmuxTerminal
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
        /// cm-126.14: where this rig's workspace writes cleared pages, never Tom's Application Support.
        let clearedFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cm-126.14-cleared-\(UUID().uuidString)", isDirectory: true)

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
            workspace.agentPaneClearedFolderOverride = clearedFolder
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
            try? FileManager.default.removeItem(at: clearedFolder)
        }

        /// `clear`'s check and apply, as the socket runs them.
        func clear(from terminal: TerminalPanel) -> ControlAgentPaneApplied? {
            guard case .ready(let plan) = TerminalController.shared.controlAgentPaneClearCheck(
                surfaceID: terminal.id, defaults: defaults
            ) else { return nil }
            return TerminalController.shared.controlAgentPaneApply(plan)
        }

        func clearCheck(from surfaceID: UUID, defaults: UserDefaults? = nil) -> ControlAgentPaneCheck {
            TerminalController.shared.controlAgentPaneClearCheck(surfaceID: surfaceID, defaults: defaults ?? self.defaults)
        }

        func clearedPage(of panelID: UUID) -> URL {
            AgentPaneMark.clearedPageURL(panelID: panelID, in: clearedFolder)
        }

        func clearedPageText(of panelID: UUID) -> String? {
            try? String(contentsOf: clearedPage(of: panelID), encoding: .utf8)
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

        /// `show` with the agent the CLI read from `CMUX_AGENT_LAUNCH_KIND` (cmux-rbf #cm-126.15).
        func show(from terminal: TerminalPanel, _ url: URL, agent: String?) -> ControlAgentPaneApplied? {
            guard case .ready(let plan) = TerminalController.shared.controlAgentPaneCheck(
                surfaceID: terminal.id, url: url, agent: agent, defaults: defaults
            ) else { return nil }
            return TerminalController.shared.controlAgentPaneApply(plan)
        }

        /// The caption the tab shows, with the workspace's own record of it checked to agree.
        func caption(_ panelID: UUID) -> String? {
            let tab = workspace.surfaceIdFromPanelId(panelID).flatMap { workspace.bonsplitController.tab($0)?.title }
            if let tab, let recorded = workspace.panelTitles[panelID], tab != recorded, workspace.panelCustomTitles[panelID] == nil {
                return "tab \(tab) / panelTitles \(recorded)"
            }
            return tab
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

    // cmux-rbf (#cm-126.3, #cm-142.1): review-b D1. A show that a `cmux ssh` workspace queues until its proxy is up sets
    // the pane's address and loads nothing, so the web view still holds the last page; the steer must not publish it back.
    @Test("a show queued in a remote workspace whose proxy is not up keeps the address it asked for")
    func queuedRemoteShowKeepsItsAddress() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let remoteWorkspaceId = UUID()
        let pane = BrowserPanel(workspaceId: remoteWorkspaceId, isRemoteWorkspace: true, remoteWebsiteDataStoreIdentifier: remoteWorkspaceId)
        defer { rig.workspace.panels[pane.id] = nil; pane.close() }
        // The page the proxy showed before it dropped: loaded from a string, so no network and no proxy. The user agent
        // goes on first, as the funnel sets it; without it the delegate restarts the load as a request, and this pane queues it.
        pane.webView.applyBrowserUserAgentPolicy(for: Self.page1)
        pane.webView.loadHTMLString("<html><body>one</body></html>", baseURL: Self.page1)
        let deadline = Date().addingTimeInterval(5)
        while pane.webView.url != Self.page1 || pane.webView.isLoading || pane.isMainFrameProvisionalNavigationActive, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(pane.webView.url == Self.page1 && !pane.webView.isLoading, "fixture: the web view did not settle on page 1")
        await oneMainQueueTurn()
        rig.workspace.panels[pane.id] = pane
        try #require(rig.workspace.navigateAgentPane(pane.id, to: Self.page2) === pane)
        try #require(pane.webView.url == Self.page1, "fixture: the show loaded instead of queueing: \(String(describing: pane.webView.url))")
        #expect(pane.currentURL == Self.page2, "the steer published the old page: \(String(describing: pane.currentURL))")
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
            // cmux-rbf: changed on purpose (#cm-142.1): upstream's default mode is now the memory budget, which arms no
            // countdown; this checks the timer path, so it asks for timer mode.
            rig.defaults.set("timer", forKey: BrowserHiddenWebViewDiscardPolicy.modeKey)
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

    // cmux-rbf (#cm-142.1): under upstream's default mode, the memory budget, a hidden Agent Pane is never picked; the same
    // hidden page of a plain pane is (the control).
    @Test("an Agent Pane is never eligible for the hidden-page memory budget; a plain page is")
    func agentPaneExemptFromMemoryBudget() throws {
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
                hiddenAt: now.addingTimeInterval(-301)
            )
            manager.delegate = delegate
            #expect(manager.blockers(for: delegate.hiddenWebViewDiscardSnapshot).isEmpty)
            #expect(!manager.isEligibleForMemoryBudgetDiscard(now: now), "the Agent Pane's keep-loaded term must exempt it")

            delegate.hiddenWebViewDiscardKeepLoaded = plain.hiddenWebViewDiscardKeepLoaded
            #expect(manager.isEligibleForMemoryBudgetDiscard(now: now), "the same hidden plain page must be eligible")
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

    // Cold review, 2026-11-18: only a show into an open pane recorded its post, so a pane opened by its first post had no
    // record, and a clear on a page that then failed to load (about:blank) linked nothing.
    @Test("the first show, which opens the Agent Pane, records its post as the clear's last post")
    func theShowThatOpensThePaneRecordsItsPost() throws {
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            #expect(agentPane.agentPaneLastPostURL == Self.page1, "the opening show recorded no post")
        }
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
            #expect(methods.contains("agent_pane.clear"))
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

    // MARK: - cmux-rbf #cm-126.14: Answer state, Return flag, and caption refresh

    @Test("clear sets the cleared flag and leaves the caption as the pane's name; a show unsets it")
    func clearSetsTheClearedFlag() throws {
        try withNames(Self.outie) {
            try withRig { rig in
                let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1, agent: "claude")?.surfaceID)
                #expect(!rig.workspace.agentPaneIsCleared(agentPane.id))
                _ = try #require(rig.clear(from: rig.terminalA))
                #expect(rig.workspace.agentPaneIsCleared(agentPane.id))
                #expect(rig.caption(agentPane.id) == "wg-still Outie")
                _ = try #require(rig.show(from: rig.terminalA, Self.page2, agent: "claude"))
                #expect(!rig.workspace.agentPaneIsCleared(agentPane.id))
            }
        }
    }

    @Test("a restored Agent Pane is not cleared, and one whose page is in the cleared folder comes back cleared")
    func restoredAgentPaneDerivesItsClearedFlag() throws {
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            let snapshot = rig.workspace.sessionSnapshot(includeScrollback: false)

            // Restore into a fresh workspace with deferred browser panels
            let restored = Workspace()
            defer { restored.teardownAllPanels() }
            let remap = restored.restoreSessionSnapshot(snapshot, deferBrowserPanels: true)
            let restoredTerminalID = try #require(remap[rig.terminalA.id])
            let restoredAgentPaneID = try #require(remap[agentPane.id])
            let restoredTerminal = try #require(restored.panels[restoredTerminalID] as? TerminalPanel)

            #expect(!restored.agentPaneIsCleared(restoredAgentPaneID))

            // Also verify cleared URL restore sets .cleared and flag false
            let clearedFolder = try #require(Workspace.agentPaneClearedFolderURL())
            let clearedURL = clearedFolder.appendingPathComponent("\(agentPane.id.uuidString).html")
            var clearedSnapshot = snapshot
            for panelIdx in clearedSnapshot.panels.indices {
                if clearedSnapshot.panels[panelIdx].id == agentPane.id {
                    clearedSnapshot.panels[panelIdx].browser?.urlString = clearedURL.absoluteString
                }
            }
            let restoredCleared = Workspace()
            defer { restoredCleared.teardownAllPanels() }
            let clearedRemap = restoredCleared.restoreSessionSnapshot(clearedSnapshot, deferBrowserPanels: true)
            let clearedTerminalID = try #require(clearedRemap[rig.terminalA.id])
            let clearedPaneID = try #require(clearedRemap[agentPane.id])
            let clearedTerminal = try #require(restoredCleared.panels[clearedTerminalID] as? TerminalPanel)

            #expect(restoredCleared.agentPaneIsCleared(clearedPaneID))
        }
    }

    // MARK: - cmux-rbf #cm-126.14: Step 2 cold-review fixes (red-first)

    @Test("a live (non-deferred) restore leaves the Agent Pane uncleared and with its caption")
    func liveNonDeferredRestoreKeepsTheClearedFlagAndCaption() throws {
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            let snapshot = rig.workspace.sessionSnapshot(includeScrollback: false)

            let restored = Workspace()
            defer { restored.teardownAllPanels() }
            let remap = restored.restoreSessionSnapshot(snapshot, deferBrowserPanels: false)
            let restoredTerminalID = try #require(remap[rig.terminalA.id])
            let restoredAgentPaneID = try #require(remap[agentPane.id])
            let restoredTerminal = try #require(restored.panels[restoredTerminalID] as? TerminalPanel)
            let tabID = try #require(restored.surfaceIdFromPanelId(restoredAgentPaneID))

            #expect(!restored.agentPaneIsCleared(restoredAgentPaneID))
            #expect(restored.bonsplitController.tab(tabID)?.title == "Agent Pane")
        }
    }

    @Test("closing the Agent Pane drops its cleared flag")
    func closingAgentPaneDropsItsClearedFlag() throws {
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            #expect(rig.workspace.agentPaneClearedFlags[agentPane.id] == false)
            #expect(rig.workspace.closePanel(agentPane.id, force: true))
            #expect(rig.workspace.agentPaneClearedFlags[agentPane.id] == nil)
        }
    }

    // MARK: - clear (cm-126.14, step 3)

    private func fileURLsMatch(_ a: URL?, _ b: URL) -> Bool {
        a?.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
    }

    @Test("clear writes the pane's own page with a link to the last post, steers the pane to it, and marks it cleared")
    func clearShowsTheClearedPage() throws {
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            let paneCount = rig.paneCount
            let applied = try #require(rig.clear(from: rig.terminalA))
            #expect(applied.action == .cleared)
            #expect(applied.surfaceID == agentPane.id)
            #expect(rig.paneCount == paneCount, "a clear opens no pane")
            #expect(rig.agentPaneCount == 1)
            #expect(fileURLsMatch(agentPane.currentURL, rig.clearedPage(of: agentPane.id)))
            #expect(rig.workspace.agentPaneIsCleared(agentPane.id))
            let text = try #require(rig.clearedPageText(of: agentPane.id))
            #expect(text == AgentPaneMark.clearedPageHTML(
                title: "Nothing to answer right now", linkText: "The last post", previousURL: Self.page1
            ))
            #expect(text.contains("href=\"\(Self.page1.absoluteString)\""))
        }
    }

    @Test("a clear on a pane already cleared succeeds and changes nothing, so the link still points at the post")
    func repeatClearChangesNothing() throws {
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            _ = try #require(rig.clear(from: rig.terminalA))
            let before = try #require(rig.clearedPageText(of: agentPane.id))
            let shown = agentPane.currentURL
            let again = try #require(rig.clear(from: rig.terminalA))
            #expect(again.action == .alreadyCleared)
            #expect(again.surfaceID == agentPane.id)
            #expect(rig.clearedPageText(of: agentPane.id) == before)
            #expect(agentPane.currentURL == shown)
            #expect(rig.workspace.agentPaneIsCleared(agentPane.id))
        }
    }

    @Test("a show after a clear is a post again; the next clear rewrites the same file with the new link")
    func showThenClearOverwritesThePage() throws {
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            _ = try #require(rig.clear(from: rig.terminalA))
            _ = try #require(rig.show(from: rig.terminalA, Self.page2))
            #expect(!rig.workspace.agentPaneIsCleared(agentPane.id))
            #expect(agentPane.currentURL == Self.page2)
            let applied = try #require(rig.clear(from: rig.terminalA))
            #expect(applied.action == .cleared)
            let text = try #require(rig.clearedPageText(of: agentPane.id))
            #expect(text.contains("href=\"\(Self.page2.absoluteString)\""))
            #expect(!text.contains(Self.page1.absoluteString))
            #expect(try FileManager.default.contentsOfDirectory(atPath: rig.clearedFolder.path).count == 1)
        }
    }

    @Test("clear is refused for a terminal with no Agent Pane, a plain browser pane, a non-terminal and an unknown surface, and opens nothing")
    func clearRefusals() throws {
        try withRig { rig in
            let plain = try rig.addPlainBrowser()
            let paneCount = rig.paneCount
            #expect(rig.clearCheck(from: rig.terminalA.id) == .refused(.noAgentPane))
            #expect(rig.clearCheck(from: plain.id) == .refused(.notTerminal(surfaceID: plain.id, type: "browser")))
            let ghost = UUID()
            #expect(rig.clearCheck(from: ghost) == .refused(.notFound(surfaceID: ghost)))
            #expect(rig.paneCount == paneCount)
            #expect(rig.agentPaneCount == 0)
            #expect(!FileManager.default.fileExists(atPath: rig.clearedFolder.path), "a refused clear wrote a page")
        }
    }

    @Test("clear is refused when local files are off, and when the browser is off, writing nothing")
    func clearRefusedBySettings() throws {
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            let suite = "cm-126.14-nofiles-\(UUID().uuidString)"
            let noFiles = try #require(AgentPaneForcedNoLocalFilesDefaults(suiteName: suite))
            defer { noFiles.removePersistentDomain(forName: suite) }
            noFiles.set(false, forKey: ManagedDevicePolicyKey.browserAllowLocalFiles.rawValue)
            try #require(!BrowserURLAllowlistPolicy(defaults: noFiles).allowsLocalFiles)
            if case .refused(.urlBlocked) = rig.clearCheck(from: rig.terminalA.id, defaults: noFiles) {} else {
                Issue.record("local files off answered \(rig.clearCheck(from: rig.terminalA.id, defaults: noFiles))")
            }
            let browserOff = try rig.isolatedDefaults("browseroff")
            browserOff.set(true, forKey: BrowserAvailabilitySettings.disabledKey)
            #expect(rig.clearCheck(from: rig.terminalA.id, defaults: browserOff) == .refused(.browserOff))
            #expect(rig.clearedPageText(of: agentPane.id) == nil)
            #expect(!rig.workspace.agentPaneIsCleared(agentPane.id))
        }
    }

    @Test("two Agent Panes get two page files, each with its own link")
    func eachPaneHasItsOwnPage() throws {
        try withRig { rig in
            let terminalB = try rig.addTerminal()
            let paneA = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            let paneB = try rig.browser(rig.show(from: terminalB, Self.page2)?.surfaceID)
            _ = try #require(rig.clear(from: rig.terminalA))
            let aText = try #require(rig.clearedPageText(of: paneA.id))
            _ = try #require(rig.clear(from: terminalB))
            #expect(rig.clearedPageText(of: paneA.id) == aText, "clearing B changed A's page")
            #expect(try #require(rig.clearedPageText(of: paneB.id)).contains(Self.page2.absoluteString))
            #expect(rig.clearedPage(of: paneA.id) != rig.clearedPage(of: paneB.id))
        }
    }

    @Test("with Design Focus on, a clear is held: nothing changes until it ends, then it applies with the link computed then")
    func designFocusHoldsAClear() throws {
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            try enterDesignFocus(rig)
            let held = try #require(rig.clear(from: rig.terminalA))
            #expect(held.action == .heldDesignFocus)
            #expect(held.surfaceID == agentPane.id)
            #expect(!rig.workspace.agentPaneIsCleared(agentPane.id))
            #expect(agentPane.currentURL == Self.page1)
            #expect(rig.clearedPageText(of: agentPane.id) == nil)
            agentPane.navigate(to: Self.page2)
            // cmux-rbf: changed on purpose (#cm-142.1): upstream's #18318 publishes the web view's address on a later
            // main-actor turn, and not while the load is provisional. Publish what the observer published here before,
            // the address the web view took, through its seam: a refused load leaves page 1 and fails below. The subject
            // is the link the held clear computes when it applies.
            agentPane.publishObservedDocumentURL(agentPane.webView.url)
            rig.workspace.exitDesignFocus(reason: "test")
            #expect(rig.workspace.agentPaneIsCleared(agentPane.id))
            #expect(fileURLsMatch(agentPane.currentURL, rig.clearedPage(of: agentPane.id)))
            let text = try #require(rig.clearedPageText(of: agentPane.id))
            #expect(text.contains(Self.page2.absoluteString), "the link is not the page the pane showed when the clear applied")
            #expect(rig.agentPaneCount == 1)
        }
    }

    @Test("a held clear whose pane closed meanwhile opens no Agent Pane and writes no page")
    func heldClearForAClosedPaneIsDropped() throws {
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            try enterDesignFocus(rig)
            _ = try #require(rig.clear(from: rig.terminalA))
            let paneCount = rig.paneCount
            #expect(rig.workspace.closePanel(agentPane.id, force: true))
            rig.workspace.exitDesignFocus(reason: "test")
            #expect(rig.agentPaneCount == 0, "a held clear opened an Agent Pane")
            #expect(rig.paneCount <= paneCount)
            #expect(rig.clearedPageText(of: agentPane.id) == nil)
        }
    }

    @Test("a held clear on a pane that is already cleared leaves its page and link as they were")
    func heldClearOnAClearedPaneChangesNothing() throws {
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            _ = try #require(rig.clear(from: rig.terminalA))
            let before = try #require(rig.clearedPageText(of: agentPane.id))
            try enterDesignFocus(rig)
            _ = try #require(rig.clear(from: rig.terminalA))
            rig.workspace.exitDesignFocus(reason: "test")
            #expect(rig.clearedPageText(of: agentPane.id) == before, "the link now points at the cleared page itself")
            #expect(rig.workspace.agentPaneIsCleared(agentPane.id))
        }
    }

    @Test("a restored pane whose page is in its workspace's cleared folder comes back cleared")
    func restoreDerivesClearedFromTheWorkspacesFolder() throws {
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            _ = try #require(rig.clear(from: rig.terminalA))
            let snapshot = rig.workspace.sessionSnapshot(includeScrollback: false)
            let restored = Workspace()
            defer { restored.teardownAllPanels() }
            restored.agentPaneClearedFolderOverride = rig.clearedFolder
            let remap = restored.restoreSessionSnapshot(snapshot, deferBrowserPanels: true)
            let restoredPane = try #require(remap[agentPane.id])
            #expect(restored.agentPaneIsCleared(restoredPane))
        }
    }

    @Test("held clear and held show: the later one wins, either way round")
    func latestHeldUpdateWinsBetweenShowAndClear() throws {
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            try enterDesignFocus(rig)
            _ = try #require(rig.show(from: rig.terminalA, Self.page2))
            _ = try #require(rig.clear(from: rig.terminalA))
            rig.workspace.exitDesignFocus(reason: "test")
            #expect(rig.workspace.agentPaneIsCleared(agentPane.id))
        }
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            try enterDesignFocus(rig)
            _ = try #require(rig.clear(from: rig.terminalA))
            _ = try #require(rig.show(from: rig.terminalA, Self.page2))
            rig.workspace.exitDesignFocus(reason: "test")
            #expect(!rig.workspace.agentPaneIsCleared(agentPane.id))
            #expect(agentPane.currentURL == Self.page2)
        }
    }

    @Test("Tom closing the Agent Pane deletes its page; a workspace teardown, a quit and a move keep it")
    func closingThePaneDeletesItsPageOnlyWhenTomCloses() throws {
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            _ = try #require(rig.clear(from: rig.terminalA))
            let page = rig.clearedPage(of: agentPane.id)
            #expect(FileManager.default.fileExists(atPath: page.path))
            #expect(rig.workspace.closePanel(agentPane.id, force: true))
            #expect(!FileManager.default.fileExists(atPath: page.path), "Tom closed the pane and its page stayed")
        }
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            _ = try #require(rig.clear(from: rig.terminalA))
            let page = rig.clearedPage(of: agentPane.id)
            rig.workspace.removeClearedPageIfClosedByTom(
                panelId: agentPane.id, origin: "tab_close", closePanel: true, appIsTerminating: true
            )
            rig.workspace.removeClearedPageIfClosedByTom(
                panelId: agentPane.id, origin: "tab_close", closePanel: false, appIsTerminating: false
            )
            #expect(FileManager.default.fileExists(atPath: page.path), "a quit or a move deleted the page")
            rig.workspace.teardownAllPanels()
            #expect(FileManager.default.fileExists(atPath: page.path), "a workspace teardown deleted the page")
        }
    }

    @Test("agent_pane.clear over the socket clears the caller's pane and answers with the action and the page")
    func clearOverTheSocket() throws {
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            let reply = try rig.call("agent_pane.clear", ["surface_id": rig.terminalA.id.uuidString])
            #expect(reply["ok"] as? Bool == true, "\(reply)")
            let result = try #require(reply["result"] as? [String: Any])
            #expect(result["action"] as? String == "cleared")
            #expect(result["surface_id"] as? String == agentPane.id.uuidString)
            #expect(rig.workspace.agentPaneIsCleared(agentPane.id))
            let again = try rig.call("agent_pane.clear", ["surface_id": rig.terminalA.id.uuidString])
            let againResult = try #require(again["result"] as? [String: Any])
            #expect(againResult["action"] as? String == "already-cleared")
        }
    }

    // MARK: - step 3d (cold review)

    @Test("a clear after the pane went back to its cleared page links the last post, never the cleared page itself")
    func clearAfterBackToTheClearedPageKeepsTheLastPost() throws {
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            _ = try #require(rig.clear(from: rig.terminalA))
            let cleared = rig.clearedPage(of: agentPane.id)
            _ = try #require(rig.show(from: rig.terminalA, Self.page2))
            // Tom swipes back: the pane shows the cleared page again, the state is still a post, and he writes.
            agentPane.navigate(to: cleared)
            // cmux-rbf: changed on purpose (#cm-142.1): upstream's #18318 publishes the web view's address on a later
            // main-actor turn, and not while the load is provisional. Publish what the observer published here before,
            // the address the web view took, through its seam: a refused load leaves page 2 and fails below. The subject
            // is the link the next clear writes.
            agentPane.publishObservedDocumentURL(agentPane.webView.url)
            #expect(fileURLsMatch(agentPane.currentURL, cleared))
            let applied = try #require(rig.clear(from: rig.terminalA))
            #expect(applied.action == .cleared)
            let text = try #require(rig.clearedPageText(of: agentPane.id))
            #expect(text.contains("href=\"\(Self.page2.absoluteString)\""), "the link is not the last post: \(text)")
            #expect(!text.contains("href=\"file:"), "the cleared page links to a cleared page")
        }
    }

    @Test("a cleared pane moved to another workspace is still cleared there; an uncleared one stays uncleared")
    func movedPaneKeepsItsClearedFlagAcrossWorkspaces() throws {
        for clearFirst in [true, false] {
            try withRig { rig in
                let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
                if clearFirst { _ = try #require(rig.clear(from: rig.terminalA)) }
                let other = Workspace()
                defer { other.teardownAllPanels() }
                other.agentPaneClearedFolderOverride = rig.clearedFolder
                let detached = try #require(rig.workspace.detachSurface(panelId: agentPane.id))
                let otherPane = try #require(other.bonsplitController.allPaneIds.first)
                #expect(other.attachDetachedSurface(detached, inPane: otherPane, focus: false) == agentPane.id)
                #expect(other.agentPaneIsCleared(agentPane.id) == clearFirst, "cleared first: \(clearFirst)")
            }
        }
    }

    @Test("an agent that shows the cleared page itself and then clears gets the cleared page's own link, never the page")
    func clearAfterShowingTheClearedPageItselfKeepsItsOwnLink() throws {
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            _ = try #require(rig.clear(from: rig.terminalA))
            let cleared = rig.clearedPage(of: agentPane.id)
            // The record of the last post now names a cleared page, so the clear falls back to the link the page has.
            _ = try #require(rig.show(from: rig.terminalA, cleared))
            #expect(!rig.workspace.agentPaneIsCleared(agentPane.id))
            let applied = try #require(rig.clear(from: rig.terminalA))
            #expect(applied.action == .cleared)
            let text = try #require(rig.clearedPageText(of: agentPane.id))
            #expect(text.contains("href=\"\(Self.page1.absoluteString)\""), "the link is not the page's own link: \(text)")
        }
    }

    @Test("a plain browser pane moved to another workspace gains no cleared flag")
    func movedPlainBrowserPaneGainsNoClearedFlag() throws {
        try withRig { rig in
            let plain = try rig.addPlainBrowser()
            let other = Workspace()
            defer { other.teardownAllPanels() }
            let detached = try #require(rig.workspace.detachSurface(panelId: plain.id))
            let otherPane = try #require(other.bonsplitController.allPaneIds.first)
            #expect(other.attachDetachedSurface(detached, inPane: otherPane, focus: false) == plain.id)
            #expect(other.agentPaneClearedFlags[plain.id] == nil, "a plain browser pane got a cleared flag")
            #expect(other.agentPaneClearedFlags.isEmpty)
        }
    }

    @Test("a held clear with no pane answers a null url over the socket, not the cleared folder")
    func heldClearWithNoPaneAnswersNullURL() throws {
        try withRig { rig in
            try enterDesignFocus(rig)
            _ = try #require(rig.show(from: rig.terminalA, Self.page1))
            let reply = try rig.call("agent_pane.clear", ["surface_id": rig.terminalA.id.uuidString])
            #expect(reply["ok"] as? Bool == true, "\(reply)")
            let result = try #require(reply["result"] as? [String: Any])
            #expect(result["action"] as? String == "held-design-focus")
            #expect(result["url"] is NSNull, "url was \(String(describing: result["url"]))")
            #expect(result["surface_id"] is NSNull)
        }
    }

    @Test("a post moved to another pane is still a post")
    func movedPostPaneStaysAPost() throws {
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            let tomsPane = try #require(rig.workspace.newTerminalSplit(
                from: rig.terminalA.id, orientation: .horizontal, insertFirst: true, focus: false
            ))
            tomsPane.adoptStableSurfaceId(UUID())
            #expect(rig.workspace.moveSurface(panelId: agentPane.id, toPane: try rig.pane(of: tomsPane.id), focus: false))
            #expect(!rig.workspace.agentPaneIsCleared(agentPane.id))
        }
    }

    @Test("under Design Focus a clear on an already-cleared pane answers already-cleared and holds nothing")
    func clearedPaneUnderDesignFocusHoldsNothing() throws {
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            _ = try #require(rig.clear(from: rig.terminalA))
            try enterDesignFocus(rig)
            let applied = try #require(rig.clear(from: rig.terminalA))
            #expect(applied.action == .alreadyCleared, "answered \(applied.action)")
            #expect(applied.surfaceID == agentPane.id)
            #expect(rig.workspace.heldAgentPaneUpdates.isEmpty)
        }
    }

    @Test("a held show for a cleared pane makes the clear a real change, so it is held and replaces the show")
    func clearReplacesAHeldShowOnAClearedPane() throws {
        try withRig { rig in
            let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
            _ = try #require(rig.clear(from: rig.terminalA))
            try enterDesignFocus(rig)
            _ = try #require(rig.show(from: rig.terminalA, Self.page2))
            let applied = try #require(rig.clear(from: rig.terminalA))
            #expect(applied.action == .heldDesignFocus, "answered \(applied.action)")
            rig.workspace.exitDesignFocus(reason: "test")
            #expect(rig.workspace.agentPaneIsCleared(agentPane.id))
            #expect(fileURLsMatch(agentPane.currentURL, rig.clearedPage(of: agentPane.id)), "the held show still opened its post")
        }
    }

    @Test("a clear while a show is held for a pane not yet open replaces the show, and nothing opens when Design Focus ends")
    func clearRetiresAHeldShowBeforeAnyPaneOpened() throws {
        try withRig { rig in
            try enterDesignFocus(rig)
            #expect(try #require(rig.show(from: rig.terminalA, Self.page1)).action == .heldDesignFocus)
            #expect(rig.agentPaneCount == 0)
            let applied = try #require(rig.clear(from: rig.terminalA), "a clear with a held show was refused")
            #expect(applied.action == .heldDesignFocus)
            #expect(applied.surfaceID == nil)
            #expect(applied.url == nil, "a clear held with no pane has no page: \(String(describing: applied.url))")
            rig.workspace.exitDesignFocus(reason: "test")
            #expect(rig.agentPaneCount == 0, "the retired post opened an Agent Pane")
            #expect(!FileManager.default.fileExists(atPath: rig.clearedFolder.path), "a held clear with no pane wrote a page")
        }
    }

    @Test("with no pane and no held show, a clear is still refused, Design Focus or not")
    func clearWithNothingToClearIsRefusedUnderDesignFocus() throws {
        try withRig { rig in
            try enterDesignFocus(rig)
            #expect(rig.clearCheck(from: rig.terminalA.id) == .refused(.noAgentPane))
        }
    }

    // (the refusal over the socket)

    @Test("clear on a terminal with no Agent Pane is refused over the socket and opens nothing")
    func clearWithoutAnAgentPaneRefusesAndOpensNothing() throws {
        try withRig { rig in
            let paneCountBefore = rig.paneCount
            let reply = try rig.call("agent_pane.clear", ["surface_id": rig.terminalA.id.uuidString])
            #expect(reply["ok"] as? Bool == false, "\(reply)")
            let error = try #require(reply["error"] as? [String: Any])
            #expect(error["code"] as? String == "invalid_params")
            let data = try #require(error["data"] as? [String: Any])
            #expect(data["reason"] as? String == "no_agent_pane")
            #expect(rig.paneCount == paneCountBefore)
            #expect(rig.agentPaneCount == 0)
        }
    }
    // MARK: - cm-126.15: the pane named for its agent

    private static let outie = ["claude": "wg-still Outie", "*": "Agent Outie"]
    /// The names a test installs while it awaits. `AgentPaneNameSetting.current` is global and other suites (`FigmaTabTitle`) read
    /// it from Agent Panes that have no agent, which `*` would name; a holder with no `*` leaves those readers at "Agent Pane" even if
    /// two suites interleave at an `await`. Every test that installs `*` has no suspension point. This suite is the only writer.
    private static let outieNoStar = ["claude": "wg-still Outie"]

    /// Runs `body` with a holder that names the panes, and puts the app's back.
    private func withNames(_ names: [String: String], _ body: () throws -> Void) rethrows {
        let saved = AgentPaneNameSetting.current
        defer { AgentPaneNameSetting.current = saved }
        AgentPaneNameSetting.current = AgentPaneNameSetting(names: names)
        try body()
    }

    @Test("15.1 a new Agent Pane's first caption is already its agent's name, and * names an agent with no entry")
    func firstCaptionIsTheName() throws {
        try withNames(Self.outie) {
            try withRig { rig in
                let claude = try rig.browser(rig.show(from: rig.terminalA, Self.page1, agent: "claude")?.surfaceID)
                #expect(claude.ownerAgent == "claude")
                #expect(rig.caption(claude.id) == "wg-still Outie")
                let terminalB = try rig.addTerminal()
                let codex = try rig.browser(rig.show(from: terminalB, Self.page2, agent: "codex")?.surfaceID)
                #expect(rig.caption(codex.id) == "Agent Outie")
                // An agent cmux's wrappers don't mark, and no live state: * or Agent Pane.
                let terminalC = try rig.addTerminal()
                let unmarked = try rig.browser(rig.show(from: terminalC, Self.page2)?.surfaceID)
                #expect(unmarked.ownerAgent == nil)
                #expect(rig.caption(unmarked.id) == "Agent Outie")
            }
        }
    }

    @Test("15.2 with no entry for its agent and none for *, the caption reads Agent Pane as before")
    func noEntryReadsAgentPane() throws {
        try withNames([:]) {
            try withRig { rig in
                let pane = try rig.browser(rig.show(from: rig.terminalA, Self.page1, agent: "claude")?.surfaceID)
                #expect(rig.caption(pane.id) == "Agent Pane")
            }
        }
        try withNames(["claude": "wg-still Outie"]) {
            try withRig { rig in
                let pane = try rig.browser(rig.show(from: rig.terminalA, Self.page1, agent: "codex")?.surfaceID)
                #expect(rig.caption(pane.id) == "Agent Pane")
            }
        }
    }

    @Test("15.3 changing the names renames every open pane of that agent; removing * puts Agent Pane back")
    func changingTheNamesRenamesOpenPanes() throws {
        let saved = AgentPaneNameSetting.current
        defer { AgentPaneNameSetting.current = saved }
        AgentPaneNameSetting.current = AgentPaneNameSetting(names: Self.outie)
        try withRig { rig in
            let claude = try rig.browser(rig.show(from: rig.terminalA, Self.page1, agent: "claude")?.surfaceID)
            let terminalB = try rig.addTerminal()
            let codex = try rig.browser(rig.show(from: terminalB, Self.page2, agent: "codex")?.surfaceID)
            AgentPaneNameSetting.current = AgentPaneNameSetting(names: ["claude": "Renamed Outie"])
            rig.workspace.refreshAgentPaneCaptions()
            #expect(rig.caption(claude.id) == "Renamed Outie")
            #expect(rig.caption(codex.id) == "Agent Pane", "removing * left the codex pane named")
            AgentPaneNameSetting.current = AgentPaneNameSetting(names: [:])
            rig.workspace.refreshAgentPaneCaptions()
            #expect(rig.caption(claude.id) == "Agent Pane")
        }
    }

    @Test("15.4 a page load and a page-title change after a show keep the name")
    func pageTitleChangeKeepsTheName() async throws {
        let saved = AgentPaneNameSetting.current
        defer { AgentPaneNameSetting.current = saved }
        AgentPaneNameSetting.current = AgentPaneNameSetting(names: Self.outieNoStar)
        let rig = try Rig()
        defer { rig.cleanup() }
        let pane = try rig.browser(rig.show(from: rig.terminalA, Self.page1, agent: "claude")?.surfaceID)
        pane.publishObservedDocumentTitle("First title")
        await oneMainQueueTurn()
        #expect(rig.caption(pane.id) == "wg-still Outie", "a page title replaced the name")
        TerminalController.shared.setActiveTabManager(rig.manager)
        _ = try #require(rig.show(from: rig.terminalA, Self.page2, agent: "claude"))
        pane.publishObservedDocumentTitle("Second title")
        await oneMainQueueTurn()
        #expect(rig.caption(pane.id) == "wg-still Outie", "a navigating show replaced the name")
    }

    @Test("15.5 a terminal that switches agents renames its pane on the new agent's first post")
    func switchingAgentsRenames() throws {
        try withNames(["claude": "Claude Outie", "codex": "Codex Outie"]) {
            try withRig { rig in
                let pane = try rig.browser(rig.show(from: rig.terminalA, Self.page1, agent: "claude")?.surfaceID)
                #expect(rig.caption(pane.id) == "Claude Outie")
                _ = try #require(rig.show(from: rig.terminalA, Self.page2, agent: "codexTeams"))
                #expect(pane.ownerAgent == "codex", "newest wins")
                #expect(rig.caption(pane.id) == "Codex Outie")
            }
        }
    }

    @Test("15.6 the name holds through the agent's exit, a clear, and a show with none")
    func nameHoldsThroughExitClearAndShowWithNone() throws {
        try withNames(Self.outie) {
            try withRig { rig in
                let pane = try rig.browser(rig.show(from: rig.terminalA, Self.page1, agent: "claude")?.surfaceID)
                rig.workspace.setAgentLifecycle(key: "claude_code", panelId: rig.terminalA.id, lifecycle: .running)
                // the agent exits: its live state goes
                rig.workspace.agentLifecycleStatesByPanelId[rig.terminalA.id] = nil
                #expect(rig.caption(pane.id) == "wg-still Outie")
                // a clear
                _ = try #require(rig.clear(from: rig.terminalA))
                #expect(rig.workspace.agentPaneIsCleared(pane.id))
                #expect(pane.ownerAgent == "claude", "a clear touched the saved agent")
                #expect(rig.caption(pane.id) == "wg-still Outie")
                // a show with no variable keeps the saved name
                _ = try #require(rig.show(from: rig.terminalA, Self.page2, agent: nil))
                #expect(pane.ownerAgent == "claude")
                #expect(rig.caption(pane.id) == "wg-still Outie")
            }
        }
    }

    @Test("15.6b the name holds through Clear Agent State, which empties the terminal's live state")
    func nameHoldsThroughClearAgentState() async throws {
        let saved = AgentPaneNameSetting.current
        defer { AgentPaneNameSetting.current = saved }
        AgentPaneNameSetting.current = AgentPaneNameSetting(names: Self.outieNoStar)
        try await ClearAgentStateHarness.run { harness in
            let workspace = harness.workspace
            let terminal = try #require(workspace.panels[harness.panel] as? TerminalPanel)
            terminal.adoptStableSurfaceId(UUID())
            let pane = try #require(workspace.openAgentPane(
                beside: terminal.id, url: Self.page1, owner: terminal.stableSurfaceId, agent: "claude"))
            workspace.setAgentLifecycle(key: "claude_code", panelId: terminal.id, lifecycle: .running)
            #expect(workspace.clearAgentState(journal: harness.center), "there was no agent state to clear")
            #expect(workspace.agentLifecycleStatesByPanelId[terminal.id]?["claude_code"] == .unknown, "Clear Agent State did not run on the terminal's state")
            #expect(pane.ownerAgent == "claude", "Clear Agent State touched the saved agent")
            workspace.refreshAgentPaneCaption(panelId: pane.id)
            #expect(workspace.panelTitles[pane.id] == "wg-still Outie")
            #expect(workspace.surfaceIdFromPanelId(pane.id).flatMap { workspace.bonsplitController.tab($0)?.title } == "wg-still Outie")
        }
    }

    @Test("15.7 with no variable the pane takes its agent from the terminal's live agent state, and the one live agent beats a stale saved one")
    func liveStateNamesAPaneWithNoVariable() throws {
        try withNames(["claude": "Claude Outie", "codex": "Codex Outie"]) {
            try withRig { rig in
                rig.workspace.setAgentLifecycle(key: "claude_code", panelId: rig.terminalA.id, lifecycle: .running)
                let pane = try rig.browser(rig.show(from: rig.terminalA, Self.page1)?.surfaceID)
                #expect(pane.ownerAgent == "claude", "claude_code was not read as claude")
                #expect(rig.caption(pane.id) == "Claude Outie")
                // Claude exits and a different agent runs: a show that sends no variable names the pane for it, not for the saved one
                rig.workspace.agentLifecycleStatesByPanelId[rig.terminalA.id] = nil
                rig.workspace.setAgentLifecycle(key: "codex", panelId: rig.terminalA.id, lifecycle: .running)
                _ = try #require(rig.show(from: rig.terminalA, Self.page2))
                #expect(pane.ownerAgent == "codex", "a stale saved agent beat the one live agent")
                #expect(rig.caption(pane.id) == "Codex Outie")
            }
        }
    }

    @Test("15.8 an inherited variable gives way to the one agent running in the terminal; two live agents leave the variable")
    func liveStateBeatsAnInheritedVariable() throws {
        try withNames(["claude": "Claude Outie", "gemini": "Gemini Outie"]) {
            try withRig { rig in
                rig.workspace.setAgentLifecycle(key: "gemini", panelId: rig.terminalA.id, lifecycle: .running)
                let pane = try rig.browser(rig.show(from: rig.terminalA, Self.page1, agent: "claude")?.surfaceID)
                #expect(pane.ownerAgent == "gemini")
                #expect(rig.caption(pane.id) == "Gemini Outie", "the inherited variable named the pane")
                // two live agents: the variable stands, none is picked from the state
                rig.workspace.setAgentLifecycle(key: "codex", panelId: rig.terminalA.id, lifecycle: .running)
                _ = try #require(rig.show(from: rig.terminalA, Self.page2, agent: "claude"))
                #expect(pane.ownerAgent == "claude")
                #expect(rig.caption(pane.id) == "Claude Outie")
            }
        }
    }

    @Test("15.8b a key Clear Agent State left at unknown is no live agent: the one agent still running wins over the variable")
    func anUnknownKeyIsNotALiveAgent() throws {
        try withNames(["claude": "Claude Outie", "gemini": "Gemini Outie"]) {
            try withRig { rig in
                // Two agents ran in this terminal; Claude's was cleared to unknown, Gemini runs. The variable says claude.
                rig.workspace.setAgentLifecycle(key: "claude_code", panelId: rig.terminalA.id, lifecycle: .unknown)
                rig.workspace.setAgentLifecycle(key: "gemini", panelId: rig.terminalA.id, lifecycle: .running)
                let pane = try rig.browser(rig.show(from: rig.terminalA, Self.page1, agent: "claude")?.surfaceID)
                #expect(pane.ownerAgent == "gemini", "a cleared agent's key counted as live: \(String(describing: pane.ownerAgent))")
                #expect(rig.caption(pane.id) == "Gemini Outie")
                // Only unknown keys left: no live agent at all, so the variable stands, and with no variable the saved agent does
                rig.workspace.setAgentLifecycle(key: "gemini", panelId: rig.terminalA.id, lifecycle: .unknown)
                _ = try #require(rig.show(from: rig.terminalA, Self.page2, agent: "claude"))
                #expect(pane.ownerAgent == "claude")
                _ = try #require(rig.show(from: rig.terminalA, Self.page1))
                #expect(pane.ownerAgent == "claude", "unknown keys counted as a live agent when nothing was sent")
            }
        }
    }

    @Test("15.9 a show held by Design Focus keeps its agent with its page")
    func heldShowKeepsItsAgent() throws {
        try withNames(Self.outie) {
            try withRig { rig in
                let pane = try rig.browser(rig.show(from: rig.terminalA, Self.page1, agent: "claude")?.surfaceID)
                try enterDesignFocus(rig)
                let held = try #require(rig.show(from: rig.terminalA, Self.page2, agent: "codex"))
                #expect(held.action == .heldDesignFocus)
                #expect(pane.ownerAgent == "claude", "the hold applied its agent early")
                rig.workspace.exitDesignFocus(reason: "test")
                #expect(pane.currentURL == Self.page2)
                #expect(pane.ownerAgent == "codex", "the held page lost its agent")
                #expect(rig.caption(pane.id) == "Agent Outie")
            }
        }
    }

    @Test("15.10 a saved session carries the agent, and a session saved before .15 decodes with none")
    func snapshotCarriesTheAgent() throws {
        try withNames(Self.outie) {
            try withRig { rig in
                let pane = try rig.browser(rig.show(from: rig.terminalA, Self.page1, agent: "claude")?.surfaceID)
                let saved = try #require(rig.workspace.sessionSnapshot(includeScrollback: false)
                    .panels.first { $0.id == pane.id }?.browser)
                #expect(saved.ownerAgent == "claude", "the workspace's record lost the agent")
                let encoded = try JSONEncoder().encode(saved)
                var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
                #expect(object["ownerAgent"] as? String == "claude")
                let restoredPane = BrowserPanel(workspaceId: UUID())
                restoredPane.restoreSessionSnapshot(try JSONDecoder().decode(SessionBrowserPanelSnapshot.self, from: encoded))
                #expect(restoredPane.ownerAgent == "claude")
                // a session saved by a build without .15
                object["ownerAgent"] = nil
                let older = try JSONDecoder().decode(SessionBrowserPanelSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
                #expect(older.ownerAgent == nil)
                // a value that is not text is no agent, never a failed session
                object["ownerAgent"] = 5
                let odd = try JSONDecoder().decode(SessionBrowserPanelSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
                #expect(odd.ownerAgent == nil)
            }
        }
        // the Dock's record
        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil }, browserAvailabilityProvider: { true })
        dock.hasLoadedConfiguration = true
        defer { dock.closeAllPanels() }
        let paneId = try #require(dock.bonsplitController.allPaneIds.first)
        let panelId = try #require(dock.newSurface(kind: .browser, inPane: paneId, url: Self.page1, focus: false))
        let browser = try #require(dock.panels[panelId] as? BrowserPanel)
        browser.ownerAgent = "codex"
        let record = try #require(dock.sessionSnapshot(includeScrollback: false).panels.first { $0.id == panelId }?.browser)
        #expect(record.ownerAgent == "codex", "the Dock's record lost the agent")
    }

    @Test("15.11 after a restart the placeholder and the pane both read the name; a pane saved before .15 reads Agent Pane until its next show")
    func restoreKeepsTheNameAndAnOlderPaneTakesItOnItsNextShow() throws {
        try withNames(Self.outie) {
            try withRig { rig in
                let pane = try rig.browser(rig.show(from: rig.terminalA, Self.page1, agent: "claude")?.surfaceID)
                var saved = rig.workspace.sessionSnapshot(includeScrollback: false)
                let restored = Workspace()
                defer { restored.teardownAllPanels() }
                let remap = restored.restoreSessionSnapshot(saved, deferBrowserPanels: true)
                let restoredID = try #require(remap[pane.id])
                #expect(restored.panels[restoredID] is DeferredBrowserPanel)
                let tabID = try #require(restored.surfaceIdFromPanelId(restoredID))
                #expect(restored.bonsplitController.tab(tabID)?.title == "wg-still Outie", "the placeholder lost the name")
                #expect(restored.panelTitles[restoredID] == "wg-still Outie")
                let placeholder = try #require(restored.panels[restoredID] as? DeferredBrowserPanel)
                let materialized = try #require(restored.materializeDeferredBrowserPanel(placeholder))
                #expect(materialized.ownerAgent == "claude", "materializing lost the agent")
                #expect(restored.bonsplitController.tab(tabID)?.title == "wg-still Outie")

                // a session saved before .15: no ownerAgent in the record
                let index = try #require(saved.panels.firstIndex { $0.id == pane.id })
                saved.panels[index].browser?.ownerAgent = nil
                let older = Workspace()
                defer { older.teardownAllPanels() }
                let olderRemap = older.restoreSessionSnapshot(saved, deferBrowserPanels: true)
                let olderID = try #require(olderRemap[pane.id])
                let olderTab = try #require(older.surfaceIdFromPanelId(olderID))
                #expect(older.bonsplitController.tab(olderTab)?.title == "Agent Outie", "no agent saved: * names it")
                withNames(["claude": "wg-still Outie"]) {
                    older.refreshAgentPaneCaptions()
                    #expect(older.bonsplitController.tab(olderTab)?.title == "Agent Pane", "a pane saved before .15 took a name with no agent")
                }
                // its terminal's next post names it
                _ = try #require(older.navigateAgentPane(olderID, to: Self.page2, agent: "claude"))
                #expect(older.bonsplitController.tab(olderTab)?.title == "wg-still Outie", "the next post did not name the pane")
            }
        }
    }

    @Test("15.12b the caption is always the pane's name, through a show, a clear and a refresh, and never reads 'You wrote' (Tom, 2026-11-19)")
    func theCaptionIsAlwaysTheName() throws {
        try withNames(Self.outie) {
            try withRig { rig in
                let pane = try rig.browser(rig.show(from: rig.terminalA, Self.page1, agent: "claude")?.surfaceID)
                #expect(rig.caption(pane.id) == "wg-still Outie")
                rig.workspace.refreshAgentPaneCaption(panelId: pane.id)
                #expect(rig.caption(pane.id) == "wg-still Outie")
                _ = try #require(rig.clear(from: rig.terminalA))
                #expect(rig.caption(pane.id) == "wg-still Outie")
                _ = try #require(rig.show(from: rig.terminalA, Self.page2, agent: "claude"))
                #expect(rig.caption(pane.id) == "wg-still Outie")
                // with no name set it reads Agent Pane
                try withNames([:]) {
                    rig.workspace.refreshAgentPaneCaptions()
                    #expect(rig.caption(pane.id) == "Agent Pane")
                }
            }
        }
    }

    @Test("15.13 Rename Tab replaces the whole caption and stays through a show and a rename of the names")
    func renameTabWinsOverTheName() throws {
        try withNames(Self.outie) {
            try withRig { rig in
                let pane = try rig.browser(rig.show(from: rig.terminalA, Self.page1, agent: "claude")?.surfaceID)
                #expect(rig.workspace.setPanelCustomTitle(panelId: pane.id, title: "my review"))
                #expect(rig.caption(pane.id) == "my review")
                _ = try #require(rig.show(from: rig.terminalA, Self.page2, agent: "claude"))
                #expect(rig.caption(pane.id) == "my review")
                AgentPaneNameSetting.current = AgentPaneNameSetting(names: ["claude": "Other Outie"])
                rig.workspace.refreshAgentPaneCaptions()
                #expect(rig.caption(pane.id) == "my review")
            }
        }
    }

    @Test("15.14 a plain browser pane never takes a name")
    func aPlainPaneIsNotNamed() throws {
        try withNames(Self.outie) {
            try withRig { rig in
                _ = try #require(rig.show(from: rig.terminalA, Self.page1, agent: "claude"))
                let plain = try rig.addPlainBrowser()
                rig.workspace.refreshAgentPaneCaptions()
                #expect(rig.caption(plain.id) != "Agent Outie")
                #expect(rig.caption(plain.id) != "wg-still Outie")
                #expect(plain.ownerAgent == nil)
            }
        }
    }

    @Test("15.15 the check hands the agent to the apply in its plan")
    func theCheckCarriesTheAgentInItsPlan() throws {
        try withRig { rig in
            guard case .ready(let plan) = TerminalController.shared.controlAgentPaneCheck(
                surfaceID: rig.terminalA.id, url: Self.page1, agent: "codex", defaults: rig.defaults
            ) else { Issue.record("not ready"); return }
            #expect(plan.agent == "codex")
        }
    }

    @Test("15.19 a workspace-context reset keeps the name, as it keeps the Agent Pane's identity")
    func contextResetKeepsTheName() throws {
        try withNames(Self.outie) {
            try withRig { rig in
                let pane = try rig.browser(rig.show(from: rig.terminalA, Self.page1, agent: "claude")?.surfaceID)
                rig.workspace.resetBrowserPanelsForContextChange(reason: "test")
                #expect(rig.caption(pane.id) == "wg-still Outie", "a context reset replaced the name")
                #expect(rig.workspace.panelTitles[pane.id] == "wg-still Outie")
            }
        }
    }

    @Test("15.20 a split made with its agent has the name from its first caption, before any show or state change")
    func newSplitsFirstCaptionIsTheName() throws {
        try withNames(Self.outie) {
            try withRig { rig in
                let pane = try #require(rig.workspace.newBrowserSplit(
                    from: rig.terminalA.id, orientation: .horizontal, url: Self.page1, focus: false,
                    allowsExternalBrowserFallback: false,
                    owner: BrowserPaneOwner(terminalStableID: rig.terminalA.stableSurfaceId, kind: .agentPane, agent: "claude")
                ))
                #expect(pane.ownerAgent == "claude")
                let tab = try #require(rig.workspace.surfaceIdFromPanelId(pane.id).flatMap { rig.workspace.bonsplitController.tab($0) })
                #expect(tab.title == "wg-still Outie", "the split's first caption was \(tab.title)")
                #expect(rig.workspace.panelTitles[pane.id] == "wg-still Outie")
            }
        }
    }

    @Test("15.21 a session restored with its panes live reads the name where the saved title is applied")
    func liveRestoreKeepsTheName() throws {
        try withNames(Self.outie) {
            try withRig { rig in
                let pane = try rig.browser(rig.show(from: rig.terminalA, Self.page1, agent: "claude")?.surfaceID)
                var saved = rig.workspace.sessionSnapshot(includeScrollback: false)
                let index = try #require(saved.panels.firstIndex { $0.id == pane.id })
                saved.panels[index].title = "Saved page title"
                let restored = Workspace()
                defer { restored.teardownAllPanels() }
                let remap = restored.restoreSessionSnapshot(saved, deferBrowserPanels: false)
                let restoredID = try #require(remap[pane.id])
                #expect(restored.panels[restoredID] is BrowserPanel)
                #expect(restored.panelTitles[restoredID] == "wg-still Outie", "the saved page title replaced the name")
                let tabID = try #require(restored.surfaceIdFromPanelId(restoredID))
                #expect(restored.bonsplitController.tab(tabID)?.title == "wg-still Outie")
            }
        }
    }

    @Test("15.21b the saved-title writer (applySessionPanelMetadata) writes the name, never the saved page title")
    func sessionMetadataWritesTheName() throws {
        try withNames(Self.outie) {
            try withRig { rig in
                let pane = try rig.browser(rig.show(from: rig.terminalA, Self.page1, agent: "claude")?.surfaceID)
                var record = try #require(rig.workspace.sessionSnapshot(includeScrollback: false).panels.first { $0.id == pane.id })
                record.title = "Saved page title"
                rig.workspace.panelTitles[pane.id] = "something else"
                rig.workspace.applySessionPanelMetadata(record, toPanelId: pane.id)
                #expect(rig.workspace.panelTitles[pane.id] == "wg-still Outie", "applySessionPanelMetadata wrote \(String(describing: rig.workspace.panelTitles[pane.id]))")
            }
        }
    }

    @Test("15.24 a pane moved into another workspace is captioned for its agent by the names in force when it arrives")
    func movedPaneIsCaptionedOnArrival() throws {
        try withNames(["claude": "Before Outie"]) {
            try withRig { rig in
                let agentPane = try rig.browser(rig.show(from: rig.terminalA, Self.page1, agent: "claude")?.surfaceID)
                #expect(rig.caption(agentPane.id) == "Before Outie")
                let other = Workspace()
                defer { other.teardownAllPanels() }
                other.agentPaneClearedFolderOverride = rig.clearedFolder
                let detached = try #require(rig.workspace.detachSurface(panelId: agentPane.id))
                // the names change while the pane is between workspaces, which no workspace's refresh visits
                AgentPaneNameSetting.current = AgentPaneNameSetting(names: ["claude": "After Outie"])
                let otherPane = try #require(other.bonsplitController.allPaneIds.first)
                #expect(other.attachDetachedSurface(detached, inPane: otherPane, focus: false) == agentPane.id)
                let tab = other.surfaceIdFromPanelId(agentPane.id).flatMap { other.bonsplitController.tab($0)?.title }
                #expect(tab == "After Outie", "the moved pane kept the caption it left with: \(String(describing: tab))")
            }
        }
    }

    // MARK: the Figma setting's re-title, one of the seven caption writers (here, not in FigmaTabTitleTests, so this suite is the
    // only writer of `AgentPaneNameSetting.current`)

    private static let figmaLink = "https://www.figma.com/design/MVdKSLWiPvKNyWab361uJ2/cm-73-figma-native-pane"

    private func figmaTabTitle(_ w: Workspace, _ id: UUID) -> String? {
        w.surfaceIdFromPanelId(id).flatMap { w.bonsplitController.tab($0)?.title }
    }

    @Test("15.22 a Figma setting flip keeps a live Agent Pane's name")
    func figmaSettingFlipKeepsTheName() async throws {
        let savedNames = AgentPaneNameSetting.current
        defer { AgentPaneNameSetting.current = savedNames }
        AgentPaneNameSetting.current = AgentPaneNameSetting(names: Self.outieNoStar)
        let savedFigma = FigmaTabTitleSetting.current
        defer { FigmaTabTitleSetting.current = savedFigma }

        let w = Workspace(); defer { w.teardownAllPanels() }
        let pane = try #require(w.bonsplitController.allPaneIds.first)
        let a = try #require(w.newFigmaSurface(inPane: pane))
        await oneMainQueueTurn()
        a.ownerTerminalSurfaceId = UUID()
        a.ownedKind = .agentPane
        a.ownerAgent = "claude"
        a.publishObservedDocumentURL(try #require(URL(string: Self.figmaLink)))
        a.publishObservedDocumentTitle("cm-73 - figma native pane – Figma")
        await oneMainQueueTurn()
        w.refreshAgentPaneCaption(panelId: a.id)
        #expect(figmaTabTitle(w, a.id) == "wg-still Outie")

        for shows in [false, true] {
            FigmaTabTitleSetting.current = FigmaTabTitleSetting(showsFileName: shows)
            w.refreshFigmaTabTitles()
            #expect(figmaTabTitle(w, a.id) == "wg-still Outie", "a Figma setting flip (names: \(shows)) dropped the name")
            #expect(w.panelTitles[a.id] == "wg-still Outie")
        }
    }

    @Test("15.23 a restored Figma-address Agent Pane keeps its name through the Figma flip")
    func restoredFigmaAgentPaneKeepsItsNameThroughTheFlip() throws {
        try withNames(["claude": "wg-still Outie"]) {
            let savedFigma = FigmaTabTitleSetting.current
            defer { FigmaTabTitleSetting.current = savedFigma }
            let source = Workspace()
            defer { source.retireFromOwningTabManager() }
            let terminal = try #require(source.focusedPanelId)
            let made = try #require(source.newBrowserSplit(
                from: terminal, orientation: .horizontal, url: URL(string: Self.figmaLink), focus: false,
                allowsExternalBrowserFallback: false, chromeVisibility: BrowserChromeVisibility(omnibarVisible: false)
            ))
            var snapshot = source.sessionSnapshot(includeScrollback: false)
            let index = try #require(snapshot.panels.firstIndex { $0.id == made.id })
            snapshot.panels[index].title = "cm-73 - figma native pane – Figma"
            var record = try #require(snapshot.panels[index].browser)
            record.ownerTerminalSurfaceId = UUID()
            record.ownedKind = BrowserOwnedKind.agentPane.rawValue
            record.ownerAgent = "claude"
            snapshot.panels[index].browser = record
            let restored = Workspace()
            defer { restored.teardownAllPanels() }
            let remap = restored.restoreSessionSnapshot(snapshot, deferBrowserPanels: true)
            let id = try #require(remap[made.id])
            #expect(restored.panels[id] is DeferredBrowserPanel, "the restored tab was shown, so this test would prove nothing")
            #expect(restored.panelTitle(panelId: id) == "wg-still Outie")
            FigmaTabTitleSetting.current = FigmaTabTitleSetting(showsFileName: false)
            restored.refreshFigmaTabTitles()
            #expect(restored.panelTitle(panelId: id) == "wg-still Outie", "a Figma flip dropped a restored pane's name")
            #expect(figmaTabTitle(restored, id) == "wg-still Outie")
        }
    }

    // MARK: the holder and its route

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func scratchConfigFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cm-126.15-scratch-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cmux.json")
    }

    @Test("15.16 the holder follows cmux.json: a save changes the names, a bad entry is skipped, a names that is not an object gives none")
    func holderFollowsTheFile() async throws {
        let file = try scratchConfigFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data(#"{"agentPane":{"names":{"claude":"wg-still Outie","codex":5,"gemini":""}}}"#.utf8).write(to: file, options: .atomic)
        var changes = 0
        let holder = AgentPaneNameSetting(store: JSONConfigStore(fileURL: file), onChange: { changes += 1 })
        #expect(holder.names == ["claude": "wg-still Outie"], "bad entries were not skipped: \(holder.names)")

        try Data(#"{"agentPane":{"names":{"claude":"Renamed","*":"Agent Outie"}}}"#.utf8).write(to: file, options: .atomic)
        #expect(await waitUntil { holder.names == ["claude": "Renamed", "*": "Agent Outie"] }, "the holder missed a save: \(holder.names)")
        #expect(await waitUntil { changes >= 1 }, "onChange did not run")

        try Data(#"{"agentPane":{"names":"claude"}}"#.utf8).write(to: file, options: .atomic)
        #expect(await waitUntil { holder.names.isEmpty }, "a names that is not an object left names behind: \(holder.names)")
    }

    @Test("15.17 saving cmux.json renames every open Agent Pane in every window, with no restart")
    func aSaveRenamesEveryWindow() async throws {
        let file = try scratchConfigFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data("{}".utf8).write(to: file, options: .atomic)

        let previousApp = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = previousApp  // AppDelegate.init assigns shared; this test calls `app` directly
        let saved = AgentPaneNameSetting.current
        defer { AgentPaneNameSetting.current = saved }
        let rig = try Rig()
        defer { rig.cleanup() }
        let secondManager = TabManager()
        let firstWindowId = app.registerMainWindowContextForTesting(tabManager: rig.manager)
        let secondWindowId = app.registerMainWindowContextForTesting(tabManager: secondManager)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: firstWindowId)
            app.unregisterMainWindowContextForTesting(windowId: secondWindowId)
        }
        let first = try rig.browser(rig.show(from: rig.terminalA, Self.page1, agent: "claude")?.surfaceID)
        let w2 = try #require(secondManager.selectedWorkspace)
        let w2Terminal = try #require(w2.focusedPanelId.flatMap { w2.panels[$0] as? TerminalPanel })
        w2Terminal.adoptStableSurfaceId(UUID())
        let second = try #require(w2.openAgentPane(beside: w2Terminal.id, url: Self.page2, owner: w2Terminal.stableSurfaceId, agent: "claude"))
        #expect(rig.caption(first.id) == "Agent Pane")

        // The holder the app builds, over a scratch file, calling the app's own route.
        AgentPaneNameSetting.current = AgentPaneNameSetting.makeAppSetting(
            environment: [:], configFile: file, onChange: { app.refreshAgentPaneCaptions() }
        )
        try Data(#"{"agentPane":{"names":{"claude":"wg-still Outie"}}}"#.utf8).write(to: file, options: .atomic)
        func title(_ w: Workspace, _ p: BrowserPanel) -> String? {
            w.surfaceIdFromPanelId(p.id).flatMap { w.bonsplitController.tab($0)?.title }
        }
        // The holder sets its names and runs `onChange` in one main-actor step, so the moment the names show here the route has run.
        // Read the titles right then, with no further wait: a page load's own title event also re-titles a pane through the same
        // writer, and would hide a route that did nothing.
        let sawNames = await waitUntil { AgentPaneNameSetting.current.names == ["claude": "wg-still Outie"] }
        #expect(sawNames, "the holder missed the save within 3 s")
        #expect(title(rig.workspace, first) == "wg-still Outie", "the route did not rename the first window: \(String(describing: title(rig.workspace, first)))")
        #expect(title(w2, second) == "wg-still Outie", "the route did not rename the second window: \(String(describing: title(w2, second)))")

        try Data("{}".utf8).write(to: file, options: .atomic)
        let sawNone = await waitUntil { AgentPaneNameSetting.current.names.isEmpty }
        #expect(sawNone, "the holder missed the removal within 3 s")
        #expect(title(rig.workspace, first) == "Agent Pane", "removing the entry did not put Agent Pane back in the first window")
        #expect(title(w2, second) == "Agent Pane", "removing the entry did not put Agent Pane back in the second window")
        w2.teardownAllPanels()
    }

    @Test("15.18 the route asks for the published copy that `cmux tree` reads")
    func theRoutePublishesWhatTreeReads() async throws {
        let previousApp = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = previousApp
        let saved = AgentPaneNameSetting.current
        defer { AgentPaneNameSetting.current = saved }
        let rig = try Rig()
        defer { rig.cleanup() }
        let windowId = app.registerMainWindowContextForTesting(tabManager: rig.manager)
        defer { app.unregisterMainWindowContextForTesting(windowId: windowId) }
        _ = try rig.browser(rig.show(from: rig.terminalA, Self.page1, agent: "claude")?.surfaceID)

        let controller = TerminalController.shared
        let store = controller.socketReadSnapshotStore
        #expect(await waitUntil { controller.socketReadSnapshotRefreshTask == nil })
        var generation = store.read().generation
        var quiet = 0
        let settleBy = ContinuousClock.now + .seconds(3)
        while quiet < 5, ContinuousClock.now < settleBy {
            try? await Task.sleep(for: .milliseconds(40))
            let now = store.read().generation
            if now == generation { quiet += 1 } else { generation = now; quiet = 0 }
        }
        try #require(quiet >= 5, "the copy never held still for 200 ms, so a change can't be pinned on the route")
        for name in ["One Outie", "Two Outie"] {
            let before = store.read().generation
            AgentPaneNameSetting.current = AgentPaneNameSetting(names: ["claude": name])
            app.refreshAgentPaneCaptions()
            #expect(await waitUntil { store.read().generation != before }, "names \(name)")
        }
    }
}

/// cmux-rbf #cm-126.14: Settings' "local files off", which only counts when the profile forces it (as in FigmaPageSwitchTests).
private final class AgentPaneForcedNoLocalFilesDefaults: UserDefaults, @unchecked Sendable {
    override func objectIsForced(forKey defaultName: String) -> Bool {
        defaultName == ManagedDevicePolicyKey.browserAllowLocalFiles.rawValue
    }
}
