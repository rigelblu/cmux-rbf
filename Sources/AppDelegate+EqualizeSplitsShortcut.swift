extension AppDelegate {
    func performEqualizeSplitsShortcut(orientationFilter: String? = nil) {
        let actionName = Self.equalizeShortcutActionName(orientationFilter: orientationFilter)
        guard let tabManager, let workspace = tabManager.selectedWorkspace else {
#if DEBUG
            cmuxDebugLog("shortcut.action name=\(actionName) result=noWorkspace")
#endif
            return
        }
#if DEBUG
        cmuxDebugLog("shortcut.action name=\(actionName) workspaceId=\(workspace.id)")
#endif
        if workspace.layoutMode == .canvas {
            let executor = CanvasActionExecutor(workspace: workspace)
            // Widths map to side-by-side ("horizontal") splits, heights to
            // stacked ("vertical") ones; the unfiltered action does both.
            let didEqualizeWidths = orientationFilter == "vertical"
                ? false
                : executor.perform(.alignment(.equalizeWidths))
            let didEqualizeHeights = orientationFilter == "horizontal"
                ? false
                : executor.perform(.alignment(.equalizeHeights))
#if DEBUG
            if !didEqualizeWidths && !didEqualizeHeights {
                cmuxDebugLog("shortcut.action name=\(actionName) result=noCanvasChange workspaceId=\(workspace.id)")
            }
#endif
            return
        }
        if shouldSuppressSplitShortcutForTransientTerminalFocusState(tabManager: tabManager) {
            return
        }
        let didEqualize = tabManager.equalizeSplits(
            tabId: workspace.id,
            orientationFilter: orientationFilter
        )
#if DEBUG
        if !didEqualize {
            cmuxDebugLog("shortcut.action name=\(actionName) result=noSplitOrFailed workspaceId=\(workspace.id)")
        }
#endif
    }

    static func equalizeShortcutActionName(orientationFilter: String?) -> String {
        switch orientationFilter {
        case "horizontal": return "equalizeSplitWidths"
        case "vertical": return "equalizeSplitHeights"
        default: return "equalizeSplits"
        }
    }
}
