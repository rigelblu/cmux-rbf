import AppKit
import CmuxCanvas
import CmuxFoundation
import CmuxPanes
import CmuxSettings

/// The single path every global-zoom entrypoint runs through.
///
/// The keyboard shortcut, the View menu, and the command palette all call
/// ``perform()``, so the three can never drift apart. Lives here beside the
/// surface-scoped zoom router rather than in its own file because this project
/// has no file-system-synchronized groups — an unwired new file compiles to
/// nothing, silently.
@MainActor
enum GlobalZoomAction {
    case zoomIn
    case zoomOut
    case reset

    /// Applies the step and always reports the event consumed.
    ///
    /// Reporting handled even at a bound is deliberate: if a no-op step fell
    /// through, the chord would reach the focused surface and zoom a single
    /// pane instead — the exact confusion this feature exists to remove.
    @discardableResult
    func perform() -> Bool {
        perform(in: nil)
    }

    @discardableResult
    func perform(in tabManager: TabManager?) -> Bool {
        switch self {
        case .zoomIn:
            GlobalFontMagnification.step(by: 1)
        case .zoomOut:
            GlobalFontMagnification.step(by: -1)
        case .reset:
            if !GlobalFontMagnification.isDefault {
                GlobalFontMagnification.resetToDefault()
            }
            if let tabManager {
                _ = tabManager.resetAllPaneZooms()
            } else if let appDelegate = AppDelegate.shared {
                for manager in appDelegate.allActiveTabManagers() {
                    _ = manager.resetAllPaneZooms()
                }
            }
        }
        return true
    }

    static var canZoomIn: Bool {
        GlobalFontMagnification.storedPercent < GlobalFontMagnification.maximumPercent
    }

    static var canZoomOut: Bool {
        GlobalFontMagnification.storedPercent > GlobalFontMagnification.minimumPercent
    }

    static func canReset(in tabManager: TabManager? = nil) -> Bool {
        if !GlobalFontMagnification.isDefault { return true }
        if let tabManager {
            return tabManager.hasAnyZoomedPane
        }
        if let appDelegate = AppDelegate.shared {
            return appDelegate.allActiveTabManagers().contains(where: { $0.hasAnyZoomedPane })
        }
        return false
    }
}

extension AppDelegate {
    @discardableResult
    func performBrowserSplitShortcut(direction: SplitDirection) -> Bool {
        guard BrowserAvailabilitySettings.isEnabled() else {
#if DEBUG
            cmuxDebugLog("split.browser.shortcut blocked reason=browser_disabled")
#endif
            return false
        }

        _ = synchronizeActiveMainWindowContext(preferredWindow: shortcutRoutingActiveWindow)

        if let workspace = tabManager?.selectedWorkspace, workspace.layoutMode == .canvas {
            guard let panelId = workspace.openNewCanvasPane(
                type: .browser,
                focus: true,
                direction: direction.canvasDirection
            ) else {
                return false
            }
            _ = focusBrowserAddressBar(panelId: panelId)
            return true
        }

#if DEBUG
        let directionLabel: String
        switch direction {
        case .left: directionLabel = "left"
        case .right: directionLabel = "right"
        case .up: directionLabel = "up"
        case .down: directionLabel = "down"
        }
        let selectedTabBefore = tabManager?.selectedTabId?.uuidString.prefix(5) ?? "nil"
        let focusedPanelBefore = tabManager?.selectedWorkspace?.focusedPanelId?.uuidString.prefix(5) ?? "nil"
        cmuxDebugLog(
            "split.browser.shortcut pre dir=\(directionLabel) " +
            "tab=\(selectedTabBefore) focusedPanel=\(focusedPanelBefore)"
        )
#endif

        guard let panelId = tabManager?.createBrowserSplit(direction: direction) else {
#if DEBUG
            cmuxDebugLog("split.browser.shortcut failed dir=\(directionLabel)")
#endif
            return false
        }

#if DEBUG
        let selectedTabAfter = tabManager?.selectedTabId?.uuidString.prefix(5) ?? "nil"
        let focusedPanelAfter = tabManager?.selectedWorkspace?.focusedPanelId?.uuidString.prefix(5) ?? "nil"
        cmuxDebugLog(
            "split.browser.shortcut post dir=\(directionLabel) " +
            "created=\(panelId.uuidString.prefix(5)) tab=\(selectedTabAfter) focusedPanel=\(focusedPanelAfter)"
        )
#endif

        _ = focusBrowserAddressBar(panelId: panelId)
        return true
    }

    func performToggleSplitZoomShortcut(tabManager routedManager: TabManager?) {
        if let workspace = routedManager?.selectedWorkspace, workspace.layoutMode == .canvas {
            _ = CanvasActionExecutor(workspace: workspace).perform(.toggleOverview)
        } else {
            _ = routedManager?.toggleFocusedSplitZoom()
        }
    }

    func performBrowserOrTextPreviewZoomShortcut(event: NSEvent, action: KeyboardShortcutSettings.Action) -> Bool {
        let targetTabs = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
        guard let targetTabs else { return false }
        switch action {
        case .browserZoomIn:
            return targetTabs.zoomInFocusedPane()
        case .browserZoomOut:
            return targetTabs.zoomOutFocusedPane()
        case .browserZoomReset:
            return targetTabs.resetZoomFocusedPane()
        default:
            return false
        }
    }
}

extension SplitDirection {
    var canvasDirection: CanvasDirection {
        switch self {
        case .left: return .left
        case .right: return .right
        case .up: return .up
        case .down: return .down
        }
    }
}
