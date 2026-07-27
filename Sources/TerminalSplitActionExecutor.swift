import AppKit
import CmuxPanes

extension TerminalPanelCreationOutcome {
    /// Lift a creation outcome into an action result. `unsupported` is not
    /// reachable here: the capability gate runs before any creation attempt.
    var splitActionResult: TerminalSplitActionResult {
        switch self {
        case .created(let panel): return .created(panelID: panel.id)
        case .routedToRemote: return .routedToRemote
        case .failed: return .failed
        }
    }
}

extension AppDelegate {
    /// The single direction-preserving path every app entry point terminates in.
    ///
    /// Direction is reduced to `orientation` only *after* the capability gate
    /// rejects `direction.insertFirst` for a remote mirror, so a remote Left/Up
    /// can never be silently mutated into a Right/Down.
    ///
    /// - Note: Lifts the contract already proven in the v1 socket handler
    ///   (`TerminalController.newSplit`) so GUI surfaces stop deriving their own
    ///   success/failure semantics from `Bool` / `UUID?`.
    @discardableResult
    func executeTerminalSplit(
        direction: SplitDirection,
        source: TerminalSplitActionSource
    ) -> TerminalSplitActionResult {
        let result: TerminalSplitActionResult
        switch source {
        case .focusedWindow(let window):
#if DEBUG
            cmuxDebugLog("split.shortcut dir=\(direction) pre")
#endif
            result = splitFromFocus(direction: direction, preferredWindow: window)
        case .explicitWorkspacePane(let workspaceId, let panelId):
            result = tabManagerFor(tabId: workspaceId).map {
                splitWorkspace(
                    tabManager: $0,
                    workspaceId: workspaceId,
                    panelId: panelId,
                    direction: direction
                )
            } ?? .failed
        case .explicitRemoteMirrorPane(let surfaceId):
            if direction.insertFirst {
                result = .unsupported(.remoteMirrorCannotInsertBefore)
            } else {
                let routed = remoteTmuxController.handleMirrorSplitRequested(
                    surfaceId: surfaceId,
                    vertical: direction.orientation == .vertical,
                    focusIntent: .focusCreatedPane
                )
                result = routed ? .routedToRemote : .failed
            }
        }
#if DEBUG
        if case .focusedWindow = source {
            cmuxDebugLog("split.shortcut dir=\(direction) result=\(result)")
            if result.didSucceed {
                recordGotoSplitSplitIfNeeded(direction: direction)
            }
        }
        if case .unsupported(let reason) = result {
            cmuxDebugLog("split.unsupported dir=\(direction) reason=\(reason.logToken)")
        }
#endif
        return result
    }

    // MARK: - Focus-resolved source

    private func splitFromFocus(
        direction: SplitDirection,
        preferredWindow: NSWindow?
    ) -> TerminalSplitActionResult {
        let targetWindow = preferredWindow ?? shortcutRoutingActiveWindow

        // Dock first: when the Dock owns keyboard focus a split belongs to the
        // Dock's own store, not the main area. Matches the precedence the
        // shortcut dispatcher already applies via `routeSplitToFocusedDock`.
        if let store = focusedDockStoreForShortcut(preferredWindow: targetWindow) {
            return splitDockStore(store, direction: direction, sourcePanelId: store.focusedPanelId)
        }

        _ = synchronizeActiveMainWindowContext(preferredWindow: targetWindow)

        if let context = focusedTerminalShortcutContext(preferredWindow: targetWindow) {
            return splitWorkspace(
                tabManager: context.tabManager,
                workspaceId: context.workspaceId,
                panelId: context.panelId,
                direction: direction
            )
        }

        // No focused terminal: fall back to the selected workspace's focused
        // pane, the same target the pre-executor `performSplitShortcut` used.
        guard let tabManager,
              let workspace = tabManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            return .failed
        }
        return splitWorkspace(
            tabManager: tabManager,
            workspaceId: workspace.id,
            panelId: panelId,
            direction: direction
        )
    }

    // MARK: - Targets

    private func splitWorkspace(
        tabManager: TabManager,
        workspaceId: UUID,
        panelId: UUID,
        direction: SplitDirection
    ) -> TerminalSplitActionResult {
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
            return .failed
        }

        // Capability gate — BEFORE direction becomes orientation. Mirrors the
        // v1 socket handler's pre-mutation check.
        if workspace.isRemoteTmuxMirror, direction.insertFirst {
            return .unsupported(.remoteMirrorCannotInsertBefore)
        }

        if workspace.layoutMode == .canvas {
            guard let panelID = workspace.openNewCanvasPane(
                type: .terminal,
                focus: true,
                direction: direction.canvasDirection
            ) else { return .failed }
            return .created(panelID: panelID)
        }

        return tabManager.createSplitOutcome(
            tabId: workspaceId,
            surfaceId: panelId,
            direction: direction
        ).splitActionResult
    }

    private func splitDockStore(
        _ store: DockSplitStore,
        direction: SplitDirection,
        sourcePanelId: UUID?
    ) -> TerminalSplitActionResult {
        guard let panelID = store.newSplit(
            kind: .terminal,
            orientation: direction.orientation,
            insertFirst: direction.insertFirst,
            sourcePanelId: sourcePanelId,
            focus: true
        ) else { return .failed }
        return .created(panelID: panelID)
    }
}
