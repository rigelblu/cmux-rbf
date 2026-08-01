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
        switch self {
        case .zoomIn:
            GlobalFontMagnification.step(by: 1)
        case .zoomOut:
            GlobalFontMagnification.step(by: -1)
        case .reset:
            // Guarded for the same reason ``GlobalFontMagnification/step(by:)``
            // is: an unconditional reset would post a change notification and
            // reload every terminal's config on each repeat while already at
            // 100%.
            guard !GlobalFontMagnification.isDefault else { return true }
            GlobalFontMagnification.resetToDefault()
        }
        return true
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
        let focusContext = shortcutEventFocusContext(event)
        if focusContext.filePreviewTextEditorFocused {
            let targetTabs = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
            switch action {
            case .browserZoomIn:
                return targetTabs?.zoomInFocusedTextFilePreview() ?? false
            case .browserZoomOut:
                return targetTabs?.zoomOutFocusedTextFilePreview() ?? false
            case .browserZoomReset:
                return targetTabs?.resetZoomFocusedTextFilePreview() ?? false
            default:
                return false
            }
        }

        switch action {
        case .browserZoomIn:
            return focusContext.browserPanel?.zoomIn() ?? false
        case .browserZoomOut:
            return focusContext.browserPanel?.zoomOut() ?? false
        case .browserZoomReset:
            return focusContext.browserPanel?.resetZoom() ?? false
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
