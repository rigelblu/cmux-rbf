import AppKit
import Bonsplit
import CmuxBrowser
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Where `Workspace` hands a tab its picture: when the tab is made and when a
/// restored tab stands in before it is shown. The rule is held in
/// ``FigmaTabMarkTests``; a rule that is right and never called shows a globe.
/// Held here: a tab made in a split and in a pane, the first value of the
/// subscription that follows a live pane, a restored placeholder before and after
/// it is shown, and a tab moved to another workspace (live and placeholder).
/// A workspace context change leaves a pane with no address, so it has no mark to
/// carry and nothing to test. A pane's own fetched icon needs a network fetch and
/// is held in the rule's tests.
@MainActor
@Suite("FigmaTabMarkWorkspace", .serialized)
struct FigmaTabMarkWorkspaceTests {

    private static let readView = URL(string: FigmaPaneURL.wrapperFileURL().absoluteString
        + "?embed=https%3A%2F%2Fembed.figma.com%2Fdesign%2FKEY%2Fa")!
    private static let figmaFile = URL(string: "https://www.figma.com/design/KEY/a")!

    private func addBrowser(
        to workspace: Workspace,
        url: URL,
        addressBar: Bool
    ) throws -> BrowserPanel {
        _ = NSApplication.shared
        let terminal = try #require(workspace.focusedPanelId)
        return try #require(workspace.newBrowserSplit(
            from: terminal,
            orientation: .horizontal,
            url: url,
            focus: false,
            // Never hand the address to the system browser, whatever `.standard` holds.
            allowsExternalBrowserFallback: false,
            chromeVisibility: BrowserChromeVisibility(omnibarVisible: addressBar)
        ))
    }

    private func tab(_ workspace: Workspace, panel: UUID) throws -> Bonsplit.Tab {
        let tabId = try #require(workspace.surfaceIdFromPanelId(panel))
        return try #require(workspace.bonsplitController.tab(tabId))
    }

    /// A workspace restored from a record of a Figma pane, left as a placeholder.
    /// `editRecord` rewrites the saved browser record first, to the shape an older
    /// build wrote.
    private func restoredPlaceholder(
        editRecord: ((inout SessionBrowserPanelSnapshot) -> Void)? = nil
    ) throws -> (workspace: Workspace, panel: DeferredBrowserPanel) {
        let source = Workspace()
        defer { source.retireFromOwningTabManager() }
        let sourcePane = try addBrowser(to: source, url: Self.figmaFile, addressBar: false)
        var snapshot = source.sessionSnapshot(includeScrollback: false)
        if let editRecord {
            for index in snapshot.panels.indices {
                guard var browser = snapshot.panels[index].browser else { continue }
                editRecord(&browser)
                snapshot.panels[index].browser = browser
            }
        }
        let restored = Workspace()
        let remap = restored.restoreSessionSnapshot(snapshot, deferBrowserPanels: true)
        let paneId = try #require(remap[sourcePane.id])
        let deferred = try #require(restored.panels[paneId] as? DeferredBrowserPanel)
        return (restored, deferred)
    }

    /// One turn of the main queue. The subscription's first value was queued on the
    /// main queue when it was installed, so a block queued now runs after it.
    private func oneMainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test("figmaPaneHasTheMarkWhenMade: no address bar on the read view, the tab holds the shipped picture at once")
    func figmaPaneHasTheMarkWhenMade() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let pane = try addBrowser(to: workspace, url: Self.readView, addressBar: false)
        let made = try tab(workspace, panel: pane.id)
        #expect(made.iconImageData == FigmaTabMark.shippedPicture)
        #expect(made.iconAsset == nil)
    }

    @Test("ordinaryBrowserTabHasNone: a Figma file with the address bar showing")
    func ordinaryBrowserTabHasNone() async throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let pane = try addBrowser(to: workspace, url: Self.figmaFile, addressBar: true)
        #expect(try tab(workspace, panel: pane.id).iconImageData == nil)
        // And after the subscription's first value, which asks the rule again.
        await oneMainQueueTurn()
        #expect(try tab(workspace, panel: pane.id).iconImageData == nil)
    }

    @Test("restoredTabHasTheMarkBeforeItIsShown: a placeholder panel whose record is a Figma file with no address bar")
    func restoredTabHasTheMarkBeforeItIsShown() throws {
        let (restored, deferred) = try restoredPlaceholder()
        defer { restored.teardownAllPanels() }
        let restoredTab = try tab(restored, panel: deferred.id)
        #expect(restoredTab.iconImageData == FigmaTabMark.shippedPicture)
        #expect(restoredTab.iconAsset == nil)
    }

    @Test("olderRecordKeepsTheMarkBeforeItIsShown: a record with only the older omnibarVisible field, no address bar")
    func olderRecordKeepsTheMarkBeforeItIsShown() throws {
        let (restored, deferred) = try restoredPlaceholder { record in
            record.chromeVisibility = nil
            record.omnibarVisible = false
        }
        defer { restored.teardownAllPanels() }
        let record = deferred.sessionPanelSnapshot.browser
        #expect(record?.chromeVisibility == nil && record?.omnibarVisible == false, "the record is the older shape")
        #expect(try tab(restored, panel: deferred.id).iconImageData == FigmaTabMark.shippedPicture)
    }

    @Test("recordWithNeitherFieldHasNoMark: no chromeVisibility and no omnibarVisible means the address bar shows")
    func recordWithNeitherFieldHasNoMark() throws {
        // The real restore reads the same default: `?? true` (BrowserPanel.swift:4567-4570).
        let (restored, deferred) = try restoredPlaceholder { record in
            record.chromeVisibility = nil
            record.omnibarVisible = nil
        }
        defer { restored.teardownAllPanels() }
        let record = deferred.sessionPanelSnapshot.browser
        #expect(record?.chromeVisibility == nil && record?.omnibarVisible == nil, "the record is the oldest shape")
        #expect(try tab(restored, panel: deferred.id).iconImageData == nil)
    }

    @Test("figmaTabHasTheMarkWhenMadeInAPane: the other way a tab is made, in a pane that exists")
    func figmaTabHasTheMarkWhenMadeInAPane() throws {
        _ = NSApplication.shared
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let pane = try #require(workspace.newBrowserSurface(
            inPane: paneId,
            url: Self.readView,
            focus: false,
            allowsExternalBrowserFallback: false,
            chromeVisibility: BrowserChromeVisibility(omnibarVisible: false)
        ))
        #expect(try tab(workspace, panel: pane.id).iconImageData == FigmaTabMark.shippedPicture)
    }

    @Test("markSurvivesTheSubscriptionsFirstValue: one turn later the read view's tab still holds the mark")
    func markSurvivesTheSubscriptionsFirstValue() async throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let pane = try addBrowser(to: workspace, url: Self.readView, addressBar: false)
        await oneMainQueueTurn()
        #expect(try tab(workspace, panel: pane.id).iconImageData == FigmaTabMark.shippedPicture)
    }

    @Test("restoredTabKeepsTheMarkWhenShown: a placeholder whose tab holds no picture gets the mark as it becomes a real pane")
    func restoredTabKeepsTheMarkWhenShown() async throws {
        let (restored, deferred) = try restoredPlaceholder()
        defer { restored.teardownAllPanels() }
        // A placeholder that arrives with a bare tab, as one moved in from the Dock
        // does (its writers pass no mark). The call is the one the app uses.
        let tabId = try #require(restored.surfaceIdFromPanelId(deferred.id))
        restored.bonsplitController.updateTab(tabId, iconImageData: .some(nil))
        #expect(try tab(restored, panel: deferred.id).iconImageData == nil)

        let pane = try #require(restored.materializeDeferredBrowserPanel(deferred))
        // Before any main-queue turn: the subscription's first value is not what is held.
        #expect(try tab(restored, panel: pane.id).iconImageData == FigmaTabMark.shippedPicture)
        await oneMainQueueTurn()
        #expect(try tab(restored, panel: pane.id).iconImageData == FigmaTabMark.shippedPicture)
    }

    @Test("reopenedTabHasTheMarkOneTurnLater: a closed Figma tab brought back by Reopen Closed Tab")
    func reopenedTabHasTheMarkOneTurnLater() async throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let pane = try addBrowser(to: workspace, url: Self.readView, addressBar: false)
        let record = try #require(
            workspace.sessionSnapshot(includeScrollback: false).panels.first { $0.id == pane.id }
        )
        let paneId = try #require(workspace.paneId(forPanelId: pane.id))
        let entry = ClosedPanelHistoryEntry(workspaceId: workspace.id, paneId: paneId.id, tabIndex: 0, snapshot: record)
        #expect(workspace.closePanel(pane.id, force: true))

        // The non-deferred path: the tab is made with no address, so the mark comes
        // from the subscription's first value, one main-queue turn later.
        let reopened = try #require(workspace.restoreClosedPanel(entry))
        let before = try tab(workspace, panel: reopened).iconImageData
        print("reopenedTabHasTheMarkOneTurnLater: before the turn the tab holds \(before == nil ? "nil (a globe)" : before == FigmaTabMark.shippedPicture ? "the mark" : "some other picture")")
        await oneMainQueueTurn()
        #expect(try tab(workspace, panel: reopened).iconImageData == FigmaTabMark.shippedPicture)
    }

    @Test("movedTabKeepsTheMark: a live Figma pane moved to another workspace")
    func movedTabKeepsTheMark() throws {
        let source = Workspace()
        defer { source.teardownAllPanels() }
        let pane = try addBrowser(to: source, url: Self.readView, addressBar: false)
        let detached = try #require(source.detachSurface(panelId: pane.id))

        let destination = Workspace()
        defer { destination.teardownAllPanels() }
        let destinationPane = try #require(destination.bonsplitController.focusedPaneId)
        let moved = try #require(destination.attachDetachedSurface(detached, inPane: destinationPane, focus: false))
        #expect(try tab(destination, panel: moved).iconImageData == FigmaTabMark.shippedPicture)
    }

    @Test("movedPlaceholderKeepsTheMark: a restored Figma tab not yet shown, moved to another workspace")
    func movedPlaceholderKeepsTheMark() throws {
        let (restored, deferred) = try restoredPlaceholder()
        defer { restored.teardownAllPanels() }
        let detached = try #require(restored.detachSurface(panelId: deferred.id))

        let destination = Workspace()
        defer { destination.teardownAllPanels() }
        let destinationPane = try #require(destination.bonsplitController.focusedPaneId)
        let moved = try #require(destination.attachDetachedSurface(detached, inPane: destinationPane, focus: false))
        #expect(destination.panels[moved] is DeferredBrowserPanel)
        #expect(try tab(destination, panel: moved).iconImageData == FigmaTabMark.shippedPicture)
    }
}
