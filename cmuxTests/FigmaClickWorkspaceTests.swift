import AppKit
import CmuxBrowser
import CmuxSettings
import Foundation
import Testing
import struct CmuxSettings.AppCatalogSection

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The `Workspace` method that acts on ``FigmaClickRoute``. Every test passes a
/// temporary page folder and its own `UserDefaults` suite, so none touches
/// `~/Library/Application Support/cmux` or the shared browser setting. The panes
/// the fixture builds never fall back to the system browser. The pane a click
/// makes still reads the shared browser setting inside `newBrowserSurface`: if
/// the browser is turned off in `.standard` while these run, that pane's address
/// goes to the system browser.
@MainActor
@Suite("FigmaClickWorkspace", .serialized)
struct FigmaClickWorkspaceTests {

    /// One workspace holding a terminal, with a page folder and defaults of its own.
    @MainActor
    private final class Fixture {
        let workspace = Workspace()
        let folder: URL
        let page: URL
        let defaults: UserDefaults
        private let suiteName = "figma-click-workspace-tests-\(UUID().uuidString)"
        let terminalId: UUID

        init() throws {
            _ = NSApplication.shared
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-figma-click-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            page = folder.appendingPathComponent("figma-embed.html")
            defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)
            terminalId = try #require(workspace.focusedPanelId)
            workspace.figmaClickEnvironment = FigmaClickEnvironment(page: page, defaults: defaults)
        }

        func cleanup() {
            workspace.teardownAllPanels()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: folder)
        }

        var panelCount: Int { workspace.panels.count }
        var tabCount: Int { workspace.bonsplitController.allTabIds.count }
        var browserPanelIds: Set<UUID> {
            Set(workspace.panels.values.compactMap { ($0 as? BrowserPanel)?.id })
        }

        /// A browser pane in a new split to the right of the terminal (or of `source`).
        @discardableResult
        func addBrowser(
            _ address: String,
            addressBar: Bool = false,
            from source: UUID? = nil,
            insertFirst: Bool = false
        ) throws -> BrowserPanel {
            try #require(workspace.newBrowserSplit(
                from: source ?? terminalId,
                orientation: .horizontal,
                insertFirst: insertFirst,
                url: URL(string: address),
                focus: false,
                // Never hand the address to the system browser, whatever `.standard` holds.
                allowsExternalBrowserFallback: false,
                chromeVisibility: BrowserChromeVisibility(omnibarVisible: addressBar)
            ))
        }

        /// What the pane loads for a link: the editor as given, or the read view on a frame.
        func address(_ link: String, node: String? = nil) throws -> String {
            try FigmaPaneURL.destination(for: URL(string: link)!, node: node, wrapper: page).url.absoluteString
        }

        func click(_ link: String) -> Bool {
            workspace.openClickedFigmaLink(URL(string: link)!, sourcePanelId: terminalId, page: page, defaults: defaults)
        }

        /// The address the pane was last told to load. `navigate` records it at
        /// once; `currentURL` follows the commit.
        func loading(_ panel: BrowserPanel) -> String? {
            panel.navigationDelegate?.lastAttemptedURL?.absoluteString ?? panel.currentURL?.absoluteString
        }
    }

    private func withFixture(_ body: (Fixture) throws -> Void) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try body(fixture)
    }

    private let key = "https://www.figma.com/design/KEY"

    @Test("W1 a Figma pane on the file, a link with a frame: it moves to the frame on its own path, and nothing is added")
    func w1MovesThePane() throws {
        try withFixture { f in
            let pane = try f.addBrowser(f.address("\(key)/old-name?node-id=1-1"))
            let panels = f.panelCount, tabs = f.tabCount

            #expect(f.click("\(key)/new-name?node-id=12-2"))

            #expect(f.loading(pane) == (try f.address("\(key)/old-name", node: "12-2")))
            #expect(f.workspace.focusedPanelId == pane.id)
            #expect(f.panelCount == panels)
            #expect(f.tabCount == tabs)
        }
    }

    @Test("W2 a Figma pane that is the editor, a link with a frame: it becomes the read view, and no pane is added")
    func w2EditorBecomesReadView() throws {
        try withFixture { f in
            let pane = try f.addBrowser("\(key)/old-name")
            let panels = f.panelCount, tabs = f.tabCount

            #expect(f.click("\(key)/new-name?node-id=12-2"))

            let moved = try #require(f.loading(pane))
            #expect(moved == (try f.address("\(key)/old-name", node: "12-2")))
            #expect(moved.hasPrefix("file://"))
            #expect(f.workspace.focusedPanelId == pane.id)
            #expect(f.panelCount == panels)
            #expect(f.tabCount == tabs)
        }
    }

    @Test("W3 a Figma pane on the file, a link with no frame: it is the front tab of its pane, and its address is unchanged")
    func w3BringsThePaneForward() throws {
        try withFixture { f in
            let pane = try f.addBrowser("\(key)/old-name")
            let paneId = try #require(f.workspace.paneId(forPanelId: pane.id))
            // Another tab in front of the Figma tab, and the terminal holding focus.
            let other = try #require(f.workspace.newBrowserSurface(
                inPane: paneId, url: URL(string: "https://example.com/"), focus: false,
                allowsExternalBrowserFallback: false
            ))
            let otherTab = try #require(f.workspace.surfaceIdFromPanelId(other.id))
            f.workspace.bonsplitController.selectTab(otherTab)
            f.workspace.focusPanel(f.terminalId)
            let figmaTab = try #require(f.workspace.surfaceIdFromPanelId(pane.id))
            try #require(f.workspace.bonsplitController.selectedTab(inPane: paneId)?.id == otherTab)
            let before = f.loading(pane)
            let panels = f.panelCount, tabs = f.tabCount

            #expect(f.click("\(key)/new-name"))

            #expect(f.workspace.bonsplitController.selectedTab(inPane: paneId)?.id == figmaTab)
            #expect(f.workspace.focusedPanelId == pane.id)
            #expect(f.loading(pane) == before)
            #expect(f.panelCount == panels)
            #expect(f.tabCount == tabs)
        }
    }

    @Test("W4 no Figma pane: one tab is added with its address bar hidden, the read view for a frame and the editor for none")
    func w4OpensANewTab() throws {
        try withFixture { f in
            let before = f.browserPanelIds
            let panels = f.panelCount

            #expect(f.click("\(key)/name?node-id=12-2"))
            let framed = try #require(f.workspace.panels.values.compactMap { $0 as? BrowserPanel }
                .first { !before.contains($0.id) })
            #expect(!framed.isOmnibarVisible)
            #expect(f.workspace.focusedPanelId == framed.id)
            #expect(framed.currentURL?.absoluteString == (try f.address("\(key)/name", node: "12-2")))
            #expect(f.panelCount == panels + 1)

            let beforeSecond = f.browserPanelIds
            #expect(f.click("https://www.figma.com/design/OTHER/name"))
            let bare = try #require(f.workspace.panels.values.compactMap { $0 as? BrowserPanel }
                .first { !beforeSecond.contains($0.id) })
            #expect(!bare.isOmnibarVisible)
            #expect(bare.currentURL?.absoluteString == "https://www.figma.com/design/OTHER/name")
            #expect(f.panelCount == panels + 2)
        }
    }

    @Test("W5 a Figma pane on a different file is not touched, and one tab is added")
    func w5DifferentFile() throws {
        try withFixture { f in
            let pane = try f.addBrowser("https://www.figma.com/design/OTHER/name")
            let before = f.loading(pane)
            let panels = f.panelCount

            #expect(f.click("\(key)/name?node-id=12-2"))

            #expect(f.loading(pane) == before)
            #expect(f.panelCount == panels + 1)
        }
    }

    @Test("W6 an ordinary browser pane on the file is not moved, and one tab is added")
    func w6OrdinaryPaneUntouched() throws {
        try withFixture { f in
            let pane = try f.addBrowser("\(key)/name", addressBar: true)
            let before = f.loading(pane)
            let panels = f.panelCount

            #expect(f.click("\(key)/name?node-id=12-2"))

            #expect(f.loading(pane) == before)
            #expect(f.panelCount == panels + 1)
        }
    }

    @Test("W7 a link that is not a Figma file link: the method returns false and adds nothing")
    func w7NotOurs() throws {
        try withFixture { f in
            let panels = f.panelCount, tabs = f.tabCount
            for link in ["https://example.com/", "https://www.figma.com/proto/KEY/name"] {
                #expect(!f.click(link), "\(link)")
            }
            #expect(f.panelCount == panels)
            #expect(f.tabCount == tabs)
        }
    }

    @Test("W8 cmux's browser turned off: false, no page written, nothing added")
    func w8BrowserOff() throws {
        try withFixture { f in
            f.defaults.set(true, forKey: BrowserAvailabilitySettings.disabledKey)
            let panels = f.panelCount, tabs = f.tabCount

            #expect(!f.click("\(key)/name?node-id=12-2"))

            #expect(!FileManager.default.fileExists(atPath: f.page.path))
            #expect(f.panelCount == panels)
            #expect(f.tabCount == tabs)
        }
    }

    /// A page whose folder cannot be made: a file sits where the folder would go.
    private func unwritable(_ f: Fixture) throws -> URL {
        let blocker = f.folder.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let page = blocker.appendingPathComponent("figma-embed.html")
        #expect(throws: (any Error).self) { try FigmaWrapperPage.install(at: page) }
        return page
    }

    @Test("W9 the page cannot be written and the link names a frame: false, and nothing is added")
    func w9UnwritablePageFrame() throws {
        try withFixture { f in
            let page = try unwritable(f)
            let panels = f.panelCount, tabs = f.tabCount

            let took = f.workspace.openClickedFigmaLink(
                URL(string: "\(key)/name?node-id=12-2")!, sourcePanelId: f.terminalId, page: page, defaults: f.defaults
            )

            #expect(!took)
            #expect(f.panelCount == panels)
            #expect(f.tabCount == tabs)
        }
    }

    @Test("W10 the page cannot be written and the link names no frame: the editor tab still opens")
    func w10UnwritablePageNoFrame() throws {
        try withFixture { f in
            let page = try unwritable(f)
            let before = f.browserPanelIds
            let panels = f.panelCount

            let took = f.workspace.openClickedFigmaLink(
                URL(string: "\(key)/name")!, sourcePanelId: f.terminalId, page: page, defaults: f.defaults
            )

            #expect(took)
            #expect(f.panelCount == panels + 1)
            let added = try #require(f.workspace.panels.values.compactMap { $0 as? BrowserPanel }
                .first { !before.contains($0.id) })
            #expect(added.currentURL?.absoluteString == "\(key)/name")
        }
    }

    @Test("W11 openTerminalBrowserLink itself takes a framed Figma link into a pane with no address bar to the right of the terminal")
    func w11TerminalCallerCallsTheRule() throws {
        try withFixture { f in
            let terminalPane = try #require(f.workspace.paneId(forPanelId: f.terminalId))
            let before = f.browserPanelIds

            let took = f.workspace.openTerminalBrowserLink(
                url: URL(string: "\(key)/name?node-id=12-2")!, sourcePanelId: f.terminalId
            )

            #expect(took)
            let added = try #require(f.workspace.panels.values.compactMap { $0 as? BrowserPanel }
                .first { !before.contains($0.id) })
            #expect(!added.isOmnibarVisible)
            let addedPane = try #require(f.workspace.paneId(forPanelId: added.id))
            #expect(addedPane != terminalPane)
            #expect(f.workspace.bonsplitController.allPaneIds.count == 2)
            #expect(FileManager.default.fileExists(atPath: f.page.path))
        }
    }

    @Test("W12 a person's link settings win: an external-open pattern that matches figma.com sends the link out once, and no pane is made or moved")
    func w12LinkSettingsWin() throws {
        try withFixture { f in
            f.defaults.set(true, forKey: BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey)
            f.defaults.set([".*figma\\.com.*"], forKey: BrowserLinkOpenSettings.browserExternalOpenPatternsKey)
            let pane = try f.addBrowser("\(key)/name")
            let before = f.loading(pane)
            let panels = f.panelCount, tabs = f.tabCount
            let link = try #require(URL(string: "\(key)/name?node-id=12-2"))
            var externallyOpened: [URL] = []
            let terminalId = f.terminalId
            let workspace = f.workspace
            let coordinator = TerminalLinkOpenCoordinator(
                defaults: f.defaults,
                containerResolver: { _, panelId in panelId == terminalId ? workspace : nil },
                externalOpen: { url in
                    externallyOpened.append(url)
                    return true
                },
                deferOperation: { operation in operation() }
            )

            #expect(coordinator.open(TerminalLinkOpenRequest(
                rawValue: link.absoluteString,
                sourceWorkspaceId: nil,
                sourcePanelId: terminalId,
                workingDirectory: nil
            )))

            #expect(externallyOpened == [link])
            #expect(f.loading(pane) == before)
            #expect(f.panelCount == panels)
            #expect(f.tabCount == tabs)
            #expect(!FileManager.default.fileExists(atPath: f.page.path))
        }
    }

    @Test("W13 this workspace only: a Figma pane on the file in another workspace is not moved, and this one gets a tab")
    func w13ThisWorkspaceOnly() throws {
        let first = try Fixture()
        defer { first.cleanup() }
        let second = try Fixture()
        defer { second.cleanup() }
        let elsewhere = try second.addBrowser("\(key)/name")
        let before = second.loading(elsewhere)
        let panels = first.panelCount

        #expect(first.click("\(key)/name?node-id=12-2"))

        #expect(second.loading(elsewhere) == before)
        #expect(first.panelCount == panels + 1)
    }

    @Test("W14 the order handed over is the split tree's: of five panes on one file, built last-in-tree first, the first in the tree moves")
    func w14TreeOrder() throws {
        for round in 1...5 {
            try withFixture { f in
                // Each split of the terminal's pane puts the new pane between the
                // terminal and the earlier ones, so the tree reads p5 ... p1.
                var panes: [BrowserPanel] = []
                for index in 1...5 {
                    panes.append(try f.addBrowser("\(key)/p\(index)"))
                }
                let before = panes.map { f.loading($0) }

                #expect(f.click("\(key)/anything?node-id=12-2"), "round \(round)")

                let moved = panes.indices.filter { f.loading(panes[$0]) != before[$0] }
                #expect(moved == [4], "round \(round): moved \(moved.map { $0 + 1 })")
                #expect(f.loading(panes[4]) == (try f.address("\(key)/p5", node: "12-2")), "round \(round)")
            }
        }
    }

    /// A workspace restored from a snapshot with its browser panes left as
    /// placeholders, as after a restart and before the tabs are shown.
    private func restoredWithDeferredFigmaPane(
        _ f: Fixture,
        address: String,
        addressBar: Bool = false
    ) throws -> (workspace: Workspace, pane: UUID, terminal: UUID) {
        let source = Workspace()
        defer { source.retireFromOwningTabManager() }
        let sourceTerminal = try #require(source.focusedPanelId)
        let sourceBrowser = try #require(source.newBrowserSplit(
            from: sourceTerminal,
            orientation: .horizontal,
            url: URL(string: address),
            focus: false,
            // Never hand the address to the system browser, whatever `.standard` holds.
            allowsExternalBrowserFallback: false,
            chromeVisibility: BrowserChromeVisibility(omnibarVisible: addressBar)
        ))
        let snapshot = source.sessionSnapshot(includeScrollback: false)
        let restored = Workspace()
        let remap = restored.restoreSessionSnapshot(snapshot, deferBrowserPanels: true)
        let pane = try #require(remap[sourceBrowser.id])
        let terminal = try #require(remap[sourceTerminal])
        try #require(restored.panels[pane] is DeferredBrowserPanel)
        return (restored, pane, terminal)
    }

    @Test("W15 a restored Figma tab not yet shown, on the file, a link with a frame: it is shown and moves, and no pane is added")
    func w15DeferredPaneMoves() throws {
        try withFixture { f in
            let (restored, paneId, terminal) = try restoredWithDeferredFigmaPane(f, address: "\(key)/old-name")
            defer { restored.teardownAllPanels() }
            let panels = restored.panels.count

            #expect(restored.openClickedFigmaLink(
                URL(string: "\(key)/new-name?node-id=12-2")!, sourcePanelId: terminal, page: f.page, defaults: f.defaults
            ))

            let pane = try #require(restored.panels[paneId] as? BrowserPanel)
            #expect(f.loading(pane) == (try f.address("\(key)/old-name", node: "12-2")))
            #expect(restored.focusedPanelId == paneId)
            #expect(restored.panels.count == panels)
        }
    }

    @Test("W16 a restored Figma tab not yet shown, on the file, a link with no frame: it comes forward, and no pane is added")
    func w16DeferredPaneComesForward() throws {
        try withFixture { f in
            let (restored, paneId, terminal) = try restoredWithDeferredFigmaPane(f, address: "\(key)/old-name")
            defer { restored.teardownAllPanels() }
            let panels = restored.panels.count

            #expect(restored.openClickedFigmaLink(
                URL(string: "\(key)/new-name")!, sourcePanelId: terminal, page: f.page, defaults: f.defaults
            ))

            #expect(restored.focusedPanelId == paneId)
            #expect(restored.panels.count == panels)
        }
    }

    @Test("W17 a restored Figma tab with its address bar showing is not counted: a tab is added and it stays as it was")
    func w17DeferredPaneWithAddressBarNotCounted() throws {
        try withFixture { f in
            let (restored, paneId, terminal) = try restoredWithDeferredFigmaPane(f, address: "\(key)/old-name", addressBar: true)
            defer { restored.teardownAllPanels() }
            let panels = restored.panels.count

            #expect(restored.openClickedFigmaLink(
                URL(string: "\(key)/new-name?node-id=12-2")!, sourcePanelId: terminal, page: f.page, defaults: f.defaults
            ))

            #expect(restored.panels[paneId] is DeferredBrowserPanel)
            #expect(restored.panels.count == panels + 1)
        }
    }

    @Test("W18 two Figma tabs on the file in one pane: the first in tab order moves")
    func w18TabOrderInsideOnePane() throws {
        try withFixture { f in
            let first = try f.addBrowser("\(key)/first")
            let paneId = try #require(f.workspace.paneId(forPanelId: first.id))
            let second = try #require(f.workspace.newBrowserSurface(
                inPane: paneId,
                url: URL(string: "\(key)/second"),
                focus: false,
                insertAtEnd: true,
                allowsExternalBrowserFallback: false,
                chromeVisibility: BrowserChromeVisibility(omnibarVisible: false)
            ))
            let order = f.workspace.surfaceIdsInTabOrder(inPaneId: paneId.id)
                .compactMap { f.workspace.panelId(forSurfaceId: $0) }
            try #require(order == [first.id, second.id])
            let secondBefore = f.loading(second)

            #expect(f.click("\(key)/anything?node-id=12-2"))

            #expect(f.loading(first) == (try f.address("\(key)/first", node: "12-2")))
            #expect(f.loading(second) == secondBefore)
        }
    }

    @Test("W19 a link the embedded browser's URL policy refuses is not taken: false, and nothing is added")
    func w19UrlPolicyRefuses() throws {
        try withFixture { f in
            f.defaults.set("example.com", forKey: BrowserURLAllowlistPolicy.userDefaultsKey)
            let panels = f.panelCount, tabs = f.tabCount

            #expect(!f.click("\(key)/name"))

            #expect(f.panelCount == panels)
            #expect(f.tabCount == tabs)
        }
    }

    @Test("W20 a click that makes a pane publishes the socket's read snapshot before it returns, with no wait")
    func w20ClickThatMakesAPanePublishesTheSocketSnapshot() throws {
        try withFixture { f in
            let store = TerminalController.shared.socketReadSnapshotStore

            // Nothing here yields, so a generation bump is the click's own publish
            // and not the refresh the app schedules for the next actor turn.
            // Not checked: that the publish comes after the pane exists. A bare
            // `Workspace()` is not registered with the app, so the published
            // `surface.list` never holds its panes.
            let before = store.read().generation
            #expect(f.click("\(key)/name?node-id=12-2"))
            #expect(store.read().generation != before)
        }
    }
}
