import AppKit
import Bonsplit
import CmuxBrowser
import CmuxCommandPalette
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The `Workspace` methods behind `cm-73.9`'s Figma button, its palette command
/// and its `cmux.json` id, on a bare `Workspace`. Every test passes its own
/// `UserDefaults` suite and its own recorder for the hand-off to the system
/// browser, so none flips Tom's shared browser setting or opens a browser.
/// The pane a click makes still reads the shared browser setting inside
/// `newBrowserSurface`: if the browser is turned off in `.standard` while these
/// run, that pane's tab is not made.
@MainActor
@Suite("FigmaHeaderButtonWorkspace", .serialized)
struct FigmaHeaderButtonWorkspaceTests {

    private static let recents = "https://www.figma.com/files/recent"

    @MainActor
    private final class Fixture {
        let workspace = Workspace()
        let defaults: UserDefaults
        private let suiteName = "figma-header-button-tests-\(UUID().uuidString)"
        /// Every address the method handed to the system browser.
        var handedOff: [URL] = []

        init() {
            _ = NSApplication.shared
            defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)
        }

        func cleanup() {
            workspace.teardownAllPanels()
            defaults.removePersistentDomain(forName: suiteName)
        }

        var firstPane: PaneID { workspace.bonsplitController.allPaneIds[0] }
        func tabs(in pane: PaneID) -> [Bonsplit.Tab] { workspace.bonsplitController.tabs(inPane: pane) }
        var tabCount: Int { workspace.bonsplitController.allTabIds.count }

        /// A second pane to the right of the first, left focused as a split is.
        func addSecondPane() throws -> PaneID {
            let terminal = try #require(workspace.focusedPanelId)
            _ = try #require(workspace.newTerminalSplit(from: terminal, orientation: .horizontal))
            let panes = workspace.bonsplitController.allPaneIds
            try #require(panes.count == 2)
            return panes[1]
        }

        @discardableResult
        func click(inPane pane: PaneID, focus: Bool? = nil, insertAtEnd: Bool = false) -> BrowserPanel? {
            workspace.newFigmaSurface(
                inPane: pane,
                focus: focus,
                insertAtEnd: insertAtEnd,
                defaults: defaults,
                openExternally: { [self] in handedOff.append($0) }
            )
        }

        /// The address the pane was last told to load, as the click tests read it.
        func loading(_ panel: BrowserPanel) -> String? {
            panel.navigationDelegate?.lastAttemptedURL?.absoluteString ?? panel.currentURL?.absoluteString
        }
    }

    private func withFixture(_ body: (Fixture) throws -> Void) throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        try body(fixture)
    }

    @Test("clickAddsOneTabInThatPane: one more tab, a browser pane on Figma's recent files, no address bar, a see-through background")
    func clickAddsOneTabInThatPane() throws {
        try withFixture { f in
            let pane = f.firstPane
            let before = f.tabs(in: pane).count

            let panel = try #require(f.click(inPane: pane))

            #expect(f.tabs(in: pane).count == before + 1)
            #expect(f.workspace.panels[panel.id] === panel)
            #expect(f.loading(panel) == Self.recents)
            #expect(!panel.isOmnibarVisible)
            #expect(panel.sessionSnapshotTransparentBackground)
            #expect(f.handedOff.isEmpty)
        }
    }

    @Test("focusMovesOnlyWhenThatPaneWasFocused: the focused pane's tab takes focus, another pane's does not")
    func focusMovesOnlyWhenThatPaneWasFocused() throws {
        try withFixture { f in
            let other = f.firstPane
            let focusedPane = try f.addSecondPane()
            try #require(f.workspace.bonsplitController.focusedPaneId == focusedPane)

            // Another pane: the focused panel stays where it was.
            let focusedBefore = try #require(f.workspace.focusedPanelId)
            let quiet = try #require(f.click(inPane: other))
            #expect(f.workspace.focusedPanelId == focusedBefore)
            #expect(f.workspace.focusedPanelId != quiet.id)

            // The focused pane: the new tab is the focused panel.
            let loud = try #require(f.click(inPane: focusedPane))
            #expect(f.workspace.focusedPanelId == loud.id)
        }
    }

    @Test("secondClickAddsAnotherTab: a second call adds a second tab and leaves the first where it was")
    func secondClickAddsAnotherTab() throws {
        try withFixture { f in
            let pane = f.firstPane
            let first = try #require(f.click(inPane: pane))
            let afterFirst = f.tabs(in: pane).map(\.id)

            let second = try #require(f.click(inPane: pane))

            #expect(first.id != second.id)
            let afterSecond = f.tabs(in: pane).map(\.id)
            #expect(afterSecond.count == afterFirst.count + 1)
            #expect(Array(afterSecond.prefix(afterFirst.count)) == afterFirst)
        }
    }

    @Test("aMadePanePublishesThePaneList: the saved pane list's generation rises before the call returns")
    func aMadePanePublishesThePaneList() throws {
        try withFixture { f in
            let store = TerminalController.shared.socketReadSnapshotStore
            // Nothing here yields, so a generation bump is the method's own publish
            // and not the refresh the app schedules for the next actor turn. Not
            // checked: that the publish comes after the pane exists. A bare
            // `Workspace()` is not registered with the app.
            let before = store.read().generation
            try #require(f.click(inPane: f.firstPane) != nil)
            #expect(store.read().generation != before)
        }
    }

    @Test("browserOffMakesNoTabAndOpensNothing: with the browser off, no tab and nothing handed to the system browser")
    func browserOffMakesNoTabAndOpensNothing() throws {
        try withFixture { f in
            f.defaults.set(true, forKey: BrowserAvailabilitySettings.disabledKey)
            let tabs = f.tabCount

            #expect(f.click(inPane: f.firstPane) == nil)

            #expect(f.tabCount == tabs)
            #expect(f.handedOff.isEmpty)
        }
    }

    @Test("browserOffWinsOverAnAllowlistWithoutFigma: the browser is asked first, so nothing opens at all")
    func browserOffWinsOverAnAllowlistWithoutFigma() throws {
        try withFixture { f in
            f.defaults.set(true, forKey: BrowserAvailabilitySettings.disabledKey)
            f.defaults.set("localhost", forKey: BrowserURLAllowlistPolicy.userDefaultsKey)
            let tabs = f.tabCount

            #expect(f.click(inPane: f.firstPane) == nil)

            #expect(f.tabCount == tabs)
            #expect(f.handedOff.isEmpty)
        }
    }

    @Test("allowlistWithoutFigmaMakesNoTab: a URL allowlist that leaves Figma out hands the address to the system browser, once")
    func allowlistWithoutFigmaMakesNoTab() throws {
        try withFixture { f in
            f.defaults.set("localhost", forKey: BrowserURLAllowlistPolicy.userDefaultsKey)
            let tabs = f.tabCount

            #expect(f.click(inPane: f.firstPane) == nil)

            #expect(f.tabCount == tabs)
            #expect(f.handedOff.map(\.absoluteString) == [Self.recents])
        }
    }

    @Test("allowlistWithFigmaMakesTheTab: the same allowlist with Figma's host added makes the tab and hands nothing off")
    func allowlistWithFigmaMakesTheTab() throws {
        try withFixture { f in
            f.defaults.set(["localhost", "www.figma.com"], forKey: BrowserURLAllowlistPolicy.userDefaultsKey)
            let tabs = f.tabCount

            #expect(f.click(inPane: f.firstPane) != nil)

            #expect(f.tabCount == tabs + 1)
            #expect(f.handedOff.isEmpty)
        }
    }

    @Test("fromTheFocusedPaneTheTabIsLastAndFocused: the call a configured action makes adds a fourth tab at the end of the focused pane and focuses it")
    func fromTheFocusedPaneTheTabIsLastAndFocused() throws {
        try withFixture { f in
            let other = f.firstPane
            let focusedPane = try f.addSecondPane()
            // The focused pane holds three tabs.
            _ = try #require(f.workspace.newTerminalSurface(inPane: focusedPane))
            _ = try #require(f.workspace.newTerminalSurface(inPane: focusedPane))
            try #require(f.workspace.bonsplitController.focusedPaneId == focusedPane)
            let focusedBefore = f.tabs(in: focusedPane).map(\.id)
            try #require(focusedBefore.count == 3)
            // The first tab is the selected one. A new tab goes after the selected tab unless it
            // is asked to go last, so only a tab placed on purpose ends up at the end.
            f.workspace.bonsplitController.selectTab(focusedBefore[0])
            let otherBefore = f.tabs(in: other).map(\.id)

            let made = f.workspace.openFigmaTabInFocusedPane(
                defaults: f.defaults,
                openExternally: { [f] in f.handedOff.append($0) }
            )
            let panel = try #require(made)

            let after = f.tabs(in: focusedPane).map(\.id)
            #expect(after.count == 4)
            #expect(Array(after.prefix(3)) == focusedBefore)
            let newTab = try #require(f.workspace.surfaceIdFromPanelId(panel.id))
            #expect(after.last == newTab, "the tab is last in the pane")
            #expect(f.workspace.focusedPanelId == panel.id, "and it has focus")
            #expect(f.loading(panel) == Self.recents)
            #expect(!panel.isOmnibarVisible)
            #expect(f.tabs(in: other).map(\.id) == otherBefore, "the other pane is unchanged")
        }
    }

    @Test("configuredActionAndPaletteHandlerOpenTheTabLastAndFocused: the id and the palette row's handler, through the app's own action path")
    func configuredActionAndPaletteHandlerOpenTheTabLastAndFocused() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-figma-header-action-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configPath = root.appendingPathComponent("cmux.json")
        try "{}".write(to: configPath, atomically: true, encoding: .utf8)
        let store = CmuxConfigStore(globalConfigPath: configPath.path, localConfigPath: nil, startFileWatchers: false)
        store.loadAll()

        let appDelegate = AppDelegate()
        let tabManager = TabManager()
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: tabManager, cmuxConfigStore: store)
        let previousShared = AppDelegate.shared
        AppDelegate.shared = appDelegate
        let workspace = try #require(tabManager.selectedWorkspace)
        defer {
            AppDelegate.shared = previousShared
            workspace.teardownAllPanels()
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            try? FileManager.default.removeItem(at: root)
        }
        // Two panes, the focused one second: the new tab goes where the focus is, not in the first pane.
        let firstPane = try #require(workspace.bonsplitController.focusedPaneId)
        let firstPaneTabs = workspace.bonsplitController.tabs(inPane: firstPane).map(\.id)
        let terminal = try #require(workspace.focusedPanelId)
        _ = try #require(workspace.newTerminalSplit(from: terminal, orientation: .horizontal))
        let pane = try #require(workspace.bonsplitController.focusedPaneId)
        try #require(pane != firstPane)
        _ = try #require(workspace.newTerminalSurface(inPane: pane))
        let before = workspace.bonsplitController.tabs(inPane: pane).map(\.id)
        // The first tab is the selected one, so a tab not placed on purpose would land second.
        workspace.bonsplitController.selectTab(before[0])

        // The id, as a cmux.json action or shortcut reaches it.
        #expect(appDelegate.executeConfiguredCmuxAction(id: "cmux.newFigma", tabManager: tabManager))
        let afterAction = workspace.bonsplitController.tabs(inPane: pane).map(\.id)
        #expect(afterAction.count == before.count + 1)
        #expect(Array(afterAction.prefix(before.count)) == before)
        let firstFigma = try #require(workspace.focusedPanelId)
        #expect(workspace.panels[firstFigma] is BrowserPanel)
        #expect(afterAction.last == workspace.surfaceIdFromPanelId(firstFigma), "last in the pane, and focused")
        #expect(workspace.bonsplitController.tabs(inPane: firstPane).map(\.id) == firstPaneTabs, "the other pane is unchanged")
        let recents = URL(string: Self.recents)
        func attempted(_ panelId: UUID) -> URL? {
            (workspace.panels[panelId] as? BrowserPanel)?.navigationDelegate?.lastAttemptedURL
        }
        #expect(attempted(firstFigma) == recents, "the tab shows Figma's recent files")

        // The palette row's handler.
        var registry = CommandPaletteHandlerRegistry()
        registry.registerNewFigmaTab(tabManager: tabManager, windowId: windowId)
        let handler = try #require(registry.handler(for: "palette.newFigmaTab"))
        handler()
        let afterPalette = workspace.bonsplitController.tabs(inPane: pane).map(\.id)
        #expect(afterPalette.count == afterAction.count + 1)
        #expect(Array(afterPalette.prefix(afterAction.count)) == afterAction)
        #expect(workspace.focusedPanelId != firstFigma)
        #expect(workspace.focusedPanelId.flatMap(attempted) == recents, "and so does the palette's")
        #expect(afterPalette.last == workspace.focusedPanelId.flatMap { workspace.surfaceIdFromPanelId($0) })
    }

    /// The workspace's header list as the app builds it: the default buttons, resolved.
    private func applyDefaultHeaderButtons(to workspace: Workspace, config: String = "{}") throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-figma-header-list-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configPath = root.appendingPathComponent("cmux.json")
        try config.write(to: configPath, atomically: true, encoding: .utf8)
        let store = CmuxConfigStore(globalConfigPath: configPath.path, localConfigPath: nil, startFileWatchers: false)
        store.loadAll()
        workspace.applySurfaceTabBarButtons(
            store.surfaceTabBarButtons,
            sourcePath: nil,
            globalConfigPath: store.globalConfigPath,
            terminalCommandSourcePaths: store.surfaceTabBarCommandSourcePaths,
            workspaceCommands: [:]
        )
        return root
    }

    private func headerButtonIDs(_ workspace: Workspace) -> [String] {
        workspace.bonsplitController.configuration.appearance.splitButtons.map(\.id)
    }

    @Test("headerClickOpensMenuAndRecentsAddsOneTab: the header's own route, from the button's id to a tab in the clicked pane")
    func headerClickOpensMenuAndRecentsAddsOneTab() throws {
        try withFixture { f in
            let root = try applyDefaultHeaderButtons(to: f.workspace)
            defer { try? FileManager.default.removeItem(at: root) }
            #expect(headerButtonIDs(f.workspace) == [
                "cmux.newTerminal", "cmux.newBrowser", "cmux.newFigma", "cmux.splitRight", "cmux.splitDown"
            ])

            let other = f.firstPane
            let clickedPane = try f.addSecondPane()
            let beforeClicked = f.tabs(in: clickedPane).count
            let beforeOther = f.tabs(in: other).count

            // cmux-rbf #cm-73.16: Bonsplit requests the menu, and Recents adds the tab.
            let menu = try #require(f.workspace.splitTabBar(f.workspace.bonsplitController, menuForCustomAction: "cmux.newFigma", inPane: clickedPane))
            let recents = try #require(menu.items.firstIndex { $0.title == "Recents…" })
            menu.performActionForItem(at: recents)
            #expect(f.tabs(in: clickedPane).count == beforeClicked + 1)
            #expect(f.tabs(in: other).count == beforeOther)
            let made = try #require(f.workspace.panels.values.compactMap { $0 as? BrowserPanel }.first)
            #expect(f.loading(made) == Self.recents)
            #expect(!made.isOmnibarVisible)
        }
    }

    // cmux-rbf #cm-73.16: R2, the built-in action identifies this menu even with a user-defined id.
    @Test func customIDFigmaButtonGetsTheMenu() throws {
        try withFixture { f in
            let root = try applyDefaultHeaderButtons(to: f.workspace, config: #"{"ui":{"surfaceTabBar":{"buttons":[{"id":"figma","builtin":"cmux.newFigma"}]}}}"#)
            defer { try? FileManager.default.removeItem(at: root) }
            let button = try #require(f.workspace.bonsplitController.configuration.appearance.splitButtons.first { $0.id == "figma" })
            #expect(button.activatesOnMouseDown)
            #expect(button.tooltip == "Figma")
            let menu = try #require(f.workspace.splitTabBar(f.workspace.bonsplitController, menuForCustomAction: "figma", inPane: f.firstPane))
            #expect(menu.items.contains { $0.title == "Recents…" })
        }
    }

    // cmux-rbf #cm-73.16: programmatic custom-action dispatch retains the one-step fallback.
    @Test func customIDFigmaActionFallsBackToRecents() throws {
        try withFixture { f in
            let root = try applyDefaultHeaderButtons(to: f.workspace, config: #"{"ui":{"surfaceTabBar":{"buttons":[{"id":"figma","builtin":"cmux.newFigma"}]}}}"#)
            defer { try? FileManager.default.removeItem(at: root) }
            let before = f.tabCount
            f.workspace.splitTabBar(f.workspace.bonsplitController, didRequestCustomAction: "figma", inPane: f.firstPane)
            #expect(f.tabCount == before + 1)
        }
    }

    /// A switch a test flips to say the browser is off, with no write to any defaults.
    @MainActor
    private final class BrowserSwitch { var on = true }

    @Test("browserSettingToggleRemovesAndRestoresTheButton: the button follows the browser setting by each of the three signals, one at a time")
    func browserSettingToggleRemovesAndRestoresTheButton() async throws {
        _ = NSApplication.shared
        let tabManager = TabManager()
        let workspace = try #require(tabManager.tabs.first)
        defer { workspace.teardownAllPanels() }
        // The manager reads the setting through a closure of the test's own: a suite for the direct write, and a switch
        // for the signals that carry no write. So this never flips the shared setting that other suites' panes read.
        let suiteName = "figma-header-toggle-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)
        let browserSwitch = BrowserSwitch()
        tabManager.browserDefaults = defaults
        tabManager.browserEnabledProvider = { browserSwitch.on && BrowserAvailabilitySettings.isEnabled(defaults: defaults) }
        let root = try applyDefaultHeaderButtons(to: workspace)
        defer { try? FileManager.default.removeItem(at: root) }
        try #require(headerButtonIDs(workspace).contains("cmux.newFigma"))

        func waitFor(_ present: Bool) async -> Bool {
            for _ in 0..<200 {
                if headerButtonIDs(workspace).contains("cmux.newFigma") == present { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }

        // 1. The Settings toggle writes defaults and posts nothing else: only `UserDefaults.didChangeNotification` fires.
        defaults.set(true, forKey: BrowserAvailabilitySettings.disabledKey)
        #expect(await waitFor(false), "a direct write: the button stayed in the header with the browser off")
        #expect(headerButtonIDs(workspace).contains("cmux.newBrowser"), "the globe stays, as it does today")
        defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)
        #expect(await waitFor(true), "a direct write: the button did not come back")

        // The two signals below carry no write. Other writes to defaults in the process also make the manager read the
        // setting, so these two do not wait long: they look after two turns of the main queue, which is what
        // the posted notification needs, and a build that ignores the notification does not get a second chance.
        func afterTwoMainQueueTurns() async {
            for _ in 0..<2 {
                await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            }
        }
        func present() -> Bool { headerButtonIDs(workspace).contains("cmux.newFigma") }

        // 2. The palette and policy post `didChangeNotification` and write no defaults of the suite.
        browserSwitch.on = false
        NotificationCenter.default.post(name: BrowserAvailabilitySettings.didChangeNotification, object: nil)
        await afterTwoMainQueueTurns()
        #expect(!present(), "the posted notification: the button stayed")
        browserSwitch.on = true
        NotificationCenter.default.post(name: BrowserAvailabilitySettings.didChangeNotification, object: nil)
        await afterTwoMainQueueTurns()
        #expect(present(), "the posted notification: the button did not come back")

        // 3. The CLI writes from another process and nothing is posted here: the app becoming active is the signal.
        browserSwitch.on = false
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await afterTwoMainQueueTurns()
        #expect(!present(), "becoming active: the button stayed")
        browserSwitch.on = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await afterTwoMainQueueTurns()
        #expect(present(), "becoming active: the button did not come back")
    }
}
