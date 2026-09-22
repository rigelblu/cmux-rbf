import XCTest
import Combine
import CmuxFoundation
import CmuxTerminal
import CmuxSettings

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class ViewMenuZoomActionTests: XCTestCase {
    private var originalPercent: Int = GlobalFontMagnification.defaultPercent

    override func setUp() {
        super.setUp()
        originalPercent = GlobalFontMagnification.storedPercent
        GlobalFontMagnification.setPercent(GlobalFontMagnification.defaultPercent)
    }

    override func tearDown() {
        GlobalFontMagnification.setPercent(originalPercent)
        super.tearDown()
    }

    // MARK: - Slice 1: Universal Pane Zoom Enablement & Dispatch

    func testCanZoomFocusedPaneReturnsTrueForZoomablePanes() throws {
        let tabManager = TabManager()
        let workspace = tabManager.addWorkspace(select: true)
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)

        // 1. Terminal Panel focused (initial workspace has a terminal in focusedPaneId)
        XCTAssertTrue(tabManager.canZoomFocusedPane, "Terminal panel should be zoomable")

        // 2. Browser Panel focused
        let browserPanel = try XCTUnwrap(workspace.newBrowserSurface(inPane: paneId, focus: true))
        XCTAssertEqual(workspace.focusedPanelId, browserPanel.id)
        XCTAssertTrue(tabManager.canZoomFocusedPane, "Browser panel should be zoomable")

        // 3. Markdown Panel in preview mode focused
        let mdPath = NSTemporaryDirectory() + "test-\(UUID().uuidString).md"
        let markdownPanel = try XCTUnwrap(workspace.newMarkdownSurface(inPane: paneId, filePath: mdPath, focus: true))
        markdownPanel.setDisplayMode(.preview)
        XCTAssertEqual(workspace.focusedPanelId, markdownPanel.id)
        XCTAssertTrue(tabManager.canZoomFocusedPane, "Markdown panel in preview mode should be zoomable")

        // 4. FilePreviewPanel in text mode focused
        let txtPath = NSTemporaryDirectory() + "test-\(UUID().uuidString).txt"
        let filePreview = try XCTUnwrap(workspace.newFilePreviewSurface(inPane: paneId, filePath: txtPath, focus: true))
        filePreview.attachTextView(SavingTextView())
        XCTAssertEqual(workspace.focusedPanelId, filePreview.id)
        XCTAssertTrue(tabManager.canZoomFocusedPane, "File preview panel in text mode should be zoomable")
    }

    func testCanZoomFocusedPaneReturnsFalseForUnzoomablePanes() throws {
        let tabManager = TabManager()
        let workspace = tabManager.addWorkspace(select: true)
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)

        // 1. Markdown Panel in text (edit) mode
        let mdPath = NSTemporaryDirectory() + "test-\(UUID().uuidString).md"
        let markdownPanel = try XCTUnwrap(workspace.newMarkdownSurface(inPane: paneId, filePath: mdPath, focus: true))
        markdownPanel.setDisplayMode(.text)
        XCTAssertFalse(tabManager.canZoomFocusedPane, "Markdown panel in text mode should not be zoomable")

        // 2. FilePreviewPanel in image mode
        let imgPath = NSTemporaryDirectory() + "test-\(UUID().uuidString).png"
        _ = try XCTUnwrap(workspace.newFilePreviewSurface(inPane: paneId, filePath: imgPath, focus: true))
        XCTAssertFalse(tabManager.canZoomFocusedPane, "File preview panel in image mode should not be zoomable via pane zoom")
    }

    func testZoomDispatchesToMarkdownPreview() throws {
        let tabManager = TabManager()
        let workspace = tabManager.addWorkspace(select: true)
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)

        let mdPath = NSTemporaryDirectory() + "test-\(UUID().uuidString).md"
        let markdownPanel = try XCTUnwrap(workspace.newMarkdownSurface(inPane: paneId, filePath: mdPath, focus: true))
        markdownPanel.setDisplayMode(.preview)

        let initialFontSize = markdownPanel.fontSize
        XCTAssertTrue(tabManager.zoomInFocusedPane())
        XCTAssertGreaterThan(markdownPanel.fontSize, initialFontSize)

        XCTAssertTrue(tabManager.zoomOutFocusedPane())
        XCTAssertEqual(markdownPanel.fontSize, initialFontSize, accuracy: 0.0001)

        _ = markdownPanel.setFontSize(24)
        XCTAssertTrue(tabManager.resetZoomFocusedPane())
        XCTAssertEqual(markdownPanel.fontSize, MarkdownFontSizeSettings.resolvedDefault(), accuracy: 0.0001)
    }

    func testZoomDispatchesToBrowser() throws {
        let tabManager = TabManager()
        let workspace = tabManager.addWorkspace(select: true)
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)

        let browserPanel = try XCTUnwrap(workspace.newBrowserSurface(inPane: paneId, focus: true))

        let initialZoom = browserPanel.currentPageZoomFactor()
        XCTAssertTrue(tabManager.zoomInFocusedPane())
        XCTAssertGreaterThan(browserPanel.currentPageZoomFactor(), initialZoom)

        XCTAssertTrue(tabManager.zoomOutFocusedPane())
        XCTAssertEqual(browserPanel.currentPageZoomFactor(), initialZoom, accuracy: 0.001)
    }

    // MARK: - Slice 2: Everything: Actual Size

    func testGlobalZoomResetDisabledAtDefaultWithNoZoomedPanes() {
        let tabManager = TabManager()
        let workspace = tabManager.addWorkspace(select: true)
        let browserPanel = BrowserPanel(workspaceId: workspace.id)
        workspace.panels[browserPanel.id] = browserPanel

        XCTAssertTrue(GlobalFontMagnification.isDefault)
        XCTAssertFalse(tabManager.hasAnyZoomedPane)
        XCTAssertFalse(GlobalZoomAction.canReset(in: tabManager))
    }

    func testGlobalZoomResetEnabledWhenGlobalScaleChanged() {
        let tabManager = TabManager()
        GlobalFontMagnification.setPercent(150)

        XCTAssertTrue(GlobalZoomAction.canReset(in: tabManager))
    }

    func testGlobalZoomResetEnabledWhenAnyPaneIsZoomedAtDefaultGlobalScale() {
        let tabManager = TabManager()
        let workspace = tabManager.addWorkspace(select: true)
        let browserPanel = BrowserPanel(workspaceId: workspace.id)
        workspace.panels[browserPanel.id] = browserPanel

        XCTAssertFalse(GlobalZoomAction.canReset(in: tabManager))

        _ = browserPanel.zoomIn()
        XCTAssertTrue(browserPanel.isPageZoomAdjusted)
        XCTAssertTrue(tabManager.hasAnyZoomedPane)
        XCTAssertTrue(GlobalZoomAction.canReset(in: tabManager))
    }

    func testGlobalZoomResetRestoresBothGlobalScaleAndAllPerPaneZooms() {
        let tabManager = TabManager()
        let workspace = tabManager.addWorkspace(select: true)

        let browserPanel = BrowserPanel(workspaceId: workspace.id)
        workspace.panels[browserPanel.id] = browserPanel
        _ = browserPanel.zoomIn()

        let markdownPanel = MarkdownPanel(
            workspaceId: workspace.id,
            filePath: NSTemporaryDirectory() + "test-\(UUID().uuidString).md"
        )
        markdownPanel.setDisplayMode(.preview)
        workspace.panels[markdownPanel.id] = markdownPanel
        _ = markdownPanel.setFontSize(22)

        GlobalFontMagnification.setPercent(150)

        XCTAssertTrue(GlobalZoomAction.canReset(in: tabManager))

        _ = GlobalZoomAction.reset.perform(in: tabManager)

        XCTAssertTrue(GlobalFontMagnification.isDefault, "Global font magnification must be reset to 100%")
        XCTAssertFalse(browserPanel.isPageZoomAdjusted, "Browser zoom must be reset to 1.0")
        XCTAssertFalse(markdownPanel.isFontSizeAdjusted, "Markdown font size must be reset to default")
        XCTAssertFalse(tabManager.hasAnyZoomedPane, "No panes should remain zoomed")
        XCTAssertFalse(GlobalZoomAction.canReset(in: tabManager), "Reset should now be disabled")
    }

    // MARK: - Actual Size is disabled at 100%

    func testCanResetFocusedPaneFollowsMarkdownPreviewZoom() throws {
        let tabManager = TabManager()
        let workspace = tabManager.addWorkspace(select: true)
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let mdPath = NSTemporaryDirectory() + "test-\(UUID().uuidString).md"
        let markdownPanel = try XCTUnwrap(workspace.newMarkdownSurface(inPane: paneId, filePath: mdPath, focus: true))
        markdownPanel.setDisplayMode(.preview)

        XCTAssertTrue(tabManager.canZoomFocusedPane)
        XCTAssertFalse(tabManager.canResetFocusedPane, "Actual Size must be disabled at the default size")

        XCTAssertTrue(tabManager.zoomInFocusedPane())
        XCTAssertTrue(tabManager.canResetFocusedPane, "Actual Size must enable once the pane is zoomed in")

        XCTAssertTrue(tabManager.resetZoomFocusedPane())
        XCTAssertFalse(tabManager.canResetFocusedPane, "Actual Size must disable again after reset")

        XCTAssertTrue(tabManager.zoomOutFocusedPane())
        XCTAssertTrue(tabManager.canResetFocusedPane, "Actual Size must enable once the pane is zoomed out")
    }

    func testCanResetFocusedPaneFollowsBrowserZoom() throws {
        let tabManager = TabManager()
        let workspace = tabManager.addWorkspace(select: true)
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        _ = try XCTUnwrap(workspace.newBrowserSurface(inPane: paneId, focus: true))

        XCTAssertFalse(tabManager.canResetFocusedPane)
        XCTAssertTrue(tabManager.zoomInFocusedPane())
        XCTAssertTrue(tabManager.canResetFocusedPane)
        XCTAssertTrue(tabManager.resetZoomFocusedPane())
        XCTAssertFalse(tabManager.canResetFocusedPane)
    }

    func testCanResetFocusedPaneIsFalseOnUnzoomablePane() throws {
        let tabManager = TabManager()
        let workspace = tabManager.addWorkspace(select: true)
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let mdPath = NSTemporaryDirectory() + "test-\(UUID().uuidString).md"
        let markdownPanel = try XCTUnwrap(workspace.newMarkdownSurface(inPane: paneId, filePath: mdPath, focus: true))
        markdownPanel.setDisplayMode(.preview)
        _ = markdownPanel.setFontSize(24)
        markdownPanel.setDisplayMode(.text)

        XCTAssertTrue(markdownPanel.isFontSizeAdjusted)
        XCTAssertFalse(tabManager.canResetFocusedPane, "A zoomed pane in an unzoomable mode must not offer Actual Size")
    }

    // MARK: - A pane's own zoom change refreshes the View menu

    func testMarkdownFontSizeChangeOutsideTheMenuPostsPaneZoomDidChange() {
        let markdownPanel = MarkdownPanel(
            workspaceId: UUID(),
            filePath: NSTemporaryDirectory() + "test-\(UUID().uuidString).md"
        )
        // The header font-size popover calls setFontSize directly, never the TabManager.
        let posted = expectation(forNotification: .paneZoomDidChange, object: nil)
        XCTAssertTrue(markdownPanel.setFontSize(24))
        wait(for: [posted], timeout: 1)
    }

    func testBrowserZoomPostsPaneZoomDidChange() {
        let browserPanel = BrowserPanel(workspaceId: UUID())
        let posted = expectation(forNotification: .paneZoomDidChange, object: nil)
        XCTAssertTrue(browserPanel.zoomIn())
        wait(for: [posted], timeout: 1)
    }

    func testTextPreviewZoomPostsPaneZoomDidChange() {
        // Cmd-scroll and smart-magnify reach the text view directly, not through the TabManager.
        let textView = SavingTextView()
        let posted = expectation(forNotification: .paneZoomDidChange, object: nil)
        XCTAssertTrue(textView.zoomPreviewFontIn())
        wait(for: [posted], timeout: 1)
    }

    func testMenuInvalidatorRevisesOnPaneZoomDidChange() {
        let center = NotificationCenter()
        let invalidator = FocusHistoryMenuInvalidator(center: center)
        let revised = expectation(description: "menu revision bumped")
        let subscription = invalidator.$revision.dropFirst().sink { _ in revised.fulfill() }
        center.post(name: .paneZoomDidChange, object: nil)
        wait(for: [revised], timeout: 1)
        subscription.cancel()
    }

    func testMenuInvalidatorRevisesOnTerminalCellSizeChange() {
        // A terminal's font changes through Ghostty's own bindings (Cmd-= in a
        // focused terminal never reaches cmux's zoom routing); Ghostty reports
        // every font change as a cell-size action, reposted as this notification.
        let center = NotificationCenter()
        let invalidator = FocusHistoryMenuInvalidator(center: center)
        let revised = expectation(description: "menu revision bumped")
        let subscription = invalidator.$revision.dropFirst().sink { _ in revised.fulfill() }
        center.post(name: .ghosttyDidUpdateCellSize, object: nil)
        wait(for: [revised], timeout: 1)
        subscription.cancel()
    }

    func testTerminalZoomedBackToConfiguredSizeIsNotOffDefault() {
        // Cmd-= then Cmd-- lands on the configured size, but Ghostty's flag
        // stays set; `Actual Size` would have nothing to reset.
        XCTAssertFalse(TerminalPanel.isFontSizeOffConfigured(
            ghosttyAdjusted: true,
            livePoints: 13,
            configuredRuntimePoints: 13
        ))
    }

    func testTerminalZoomedOffConfiguredSizeIsOffDefault() {
        XCTAssertTrue(TerminalPanel.isFontSizeOffConfigured(
            ghosttyAdjusted: true,
            livePoints: 14,
            configuredRuntimePoints: 13
        ))
    }

    func testTerminalFollowingConfigIsNotOffDefault() {
        XCTAssertFalse(TerminalPanel.isFontSizeOffConfigured(
            ghosttyAdjusted: false,
            livePoints: 14,
            configuredRuntimePoints: 13
        ))
    }
}
