import AppKit
import CmuxCommandPalette
import CmuxSidebar
import CmuxSwiftRender

extension ContentView {
    // cmux-rbf #cm-73.3: the palette's real command registration, independent of view rendering.
    static func registerFigmaPageSwitchPaletteHandler(
        _ registry: inout CommandPaletteHandlerRegistry,
        tabManager: TabManager
    ) {
        registry.register(commandId: "palette.switchFigmaPreviewAndEditor") {
            _ = tabManager.switchFigmaPreviewAndEditor()
        }
    }

    // cmux-rbf (#cm-73.37): the same producer feeds the live palette and focused tests.
    static func populateFigmaMotionContext(_ snapshot: inout CommandPaletteContextSnapshot, target: BrowserPanel?) {
        snapshot.setBool(CommandPaletteContextKeys.workspaceHasFigmaMotion, target != nil)
        snapshot.setBool(CommandPaletteContextKeys.workspaceFigmaMotionHasPlayer, target.map { $0.figmaMotionState != .still } ?? false)
        snapshot.setBool(CommandPaletteContextKeys.workspaceCanToggleFigmaMotion, target?.figmaMotionState.canToggle == true)
        snapshot.setBool(CommandPaletteContextKeys.workspaceFigmaMotionIsPlaying, target?.figmaMotionState == .playing)
    }

    // cmux-rbf (#cm-73.32): the palette's motion toggle command registration.
    static func registerFigmaMotionPaletteHandler(
        _ registry: inout CommandPaletteHandlerRegistry,
        tabManager: TabManager
    ) {
        // cmux-rbf (#cm-73.37)
        registry.register(commandId: "palette.showFigmaStill") { _ = tabManager.showFigmaStill() }
        registry.register(commandId: "palette.toggleFigmaMotion") {
            _ = tabManager.toggleFigmaMotion()
        }
    }

    // cmux-rbf (#cm-73.32): command palette contribution for Figma motion toggle. Reject a revert of this hunk on upstream sync.
    static func figmaMotionCommandContribution() -> CommandPaletteCommandContribution {
        CommandPaletteCommandContribution(
            commandId: "palette.toggleFigmaMotion",
            title: { context in
                if context.bool(CommandPaletteContextKeys.workspaceFigmaMotionIsPlaying) {
                    return String(localized: "command.figmaPauseMotion.title", defaultValue: "Figma: Pause Motion")
                } else {
                    return String(localized: "command.figmaPlayMotion.title", defaultValue: "Figma: Play Motion")
                }
            },
            subtitle: { _ in String(localized: "figma.menu.tooltip", defaultValue: "Figma") },
            keywords: ["play", "still", "motion", "figma", "prototype"],
            when: { $0.bool(CommandPaletteContextKeys.workspaceHasFigmaMotion) },
            enablement: { $0.bool(CommandPaletteContextKeys.workspaceCanToggleFigmaMotion) }
        )
    }

    // cmux-rbf (#cm-73.37)
    static func figmaShowStillCommandContribution() -> CommandPaletteCommandContribution {
        CommandPaletteCommandContribution(
            commandId: "palette.showFigmaStill",
            title: { _ in String(localized: "command.figmaShowStill.title", defaultValue: "Figma: Show Still") },
            subtitle: { _ in String(localized: "figma.menu.tooltip", defaultValue: "Figma") },
            keywords: ["still", "zoom", "figma"],
            when: { $0.bool(CommandPaletteContextKeys.workspaceFigmaMotionHasPlayer) },
            enablement: { $0.bool(CommandPaletteContextKeys.workspaceCanToggleFigmaMotion) }
        )
    }

    static func commandPaletteShortcutAction(forCommandID commandId: String) -> KeyboardShortcutSettings.Action? {
        if let movement = SurfacePaneMovement(commandID: commandId) {
            return movement.shortcutAction
        }
        if let rightSidebarModeAction = commandPaletteRightSidebarModeShortcutAction(forCommandID: commandId) {
            return rightSidebarModeAction
        }

        switch commandId {
        case "palette.newWorkspace":
            return .newTab
        case "palette.newBrowserWorkspace":
            return .newBrowserWorkspace
        case ContentView.commandPaletteCloudNewMachineCommandId:
            return .newCloudMachine
        case "palette.newWindow":
            return .newWindow
        case "palette.openFolder":
            return .openFolder
        case "palette.reopenPreviousSession":
            return .reopenPreviousSession
        case "palette.reopenClosedWorkspace":
            return .reopenClosedWorkspace
        case "palette.reopenClosedBrowserTab":
            return .reopenClosedBrowserPanel
        case "palette.newTerminalTab":
            return .newSurface
        case "palette.newBrowserTab":
            return .openBrowser
        case "palette.closeWindow":
            return .closeWindow
        case "palette.toggleSidebar":
            return .toggleSidebar
        case "palette.showNotifications":
            return .showNotifications
        case "palette.jumpUnread":
            return .jumpToUnread
        case "palette.toggleUnread":
            return .toggleUnread
        case "palette.markOldestUnreadAndJumpNext":
            return .markOldestUnreadAndJumpNext
        case "palette.renameTab":
            return .renameTab
        case "palette.renameWorkspace":
            return .renameWorkspace
        case "palette.editWorkspaceDescription":
            return .editWorkspaceDescription
        case "palette.markWorkspaceDone":
            return .markWorkspaceDone
        case "palette.nextWorkspace":
            return .nextSidebarTab
        case "palette.previousWorkspace":
            return .prevSidebarTab
        case "palette.moveWorkspaceUp":
            return .moveWorkspaceUp
        case "palette.moveWorkspaceDown":
            return .moveWorkspaceDown
        case "palette.nextTabInPane":
            return .nextSurface
        case "palette.previousTabInPane":
            return .prevSurface
        case "palette.browserToggleDevTools":
            return .toggleBrowserDeveloperTools
        case "palette.browserConsole":
            return .showBrowserJavaScriptConsole
        case "palette.browserReactGrab":
            return .toggleReactGrab
        case "palette.browserSplitRight", "palette.terminalSplitBrowserRight":
            return .splitBrowserRight
        case "palette.browserSplitDown", "palette.terminalSplitBrowserDown":
            return .splitBrowserDown
        case "palette.terminalSplitRight":
            return .splitRight
        case "palette.terminalSplitDown":
            return .splitDown
        case "palette.terminalSplitLeft":
            return .splitLeft
        case "palette.terminalSplitUp":
            return .splitUp
        case "palette.findInDirectory":
            return .findInDirectory
        case "palette.terminalFind":
            return .find
        case "palette.terminalFindNext":
            return .findNext
        case "palette.terminalFindPrevious":
            return .findPrevious
        case "palette.terminalHideFind":
            return .hideFind
        case "palette.terminalUseSelectionForFind":
            return .useSelectionForFind
        case "palette.terminalFocusTextBoxInput":
            return .focusTextBoxInput
        case "palette.terminalAttachTextBoxFile":
            return .attachTextBoxFile
        case "palette.terminalSendCtrlF":
            return .sendCtrlFToTerminal
        case "palette.terminalClearScreenKeepScrollback":
            return .clearScreenKeepScrollback
        case "palette.toggleSplitZoom":
            return .toggleSplitZoom
        // cmux-rbf #cm-73.3: show the configured switch key in the palette.
        case "palette.switchFigmaPreviewAndEditor":
            return .switchFigmaPreviewAndEditor
        // cmux-rbf (#cm-73.32): show the configured motion key in the palette if any.
        case "palette.showFigmaStill": return .showFigmaStill // cmux-rbf (#cm-73.37)
        case "palette.toggleFigmaMotion":
            return .toggleFigmaMotion
        // cmux-rbf #cm-73.2a
        case "palette.toggleDesignFocus":
            return .toggleDesignFocus
        // cmux-rbf #cm-73.2a
        case "palette.flipDesignFocusLayout":
            return .flipDesignFocusLayout
        case "palette.equalizeSplits":
            return .equalizeSplits
        case "palette.equalizeSplitWidths":
            return .equalizeSplitWidths
        case "palette.equalizeSplitHeights":
            return .equalizeSplitHeights
        case "palette.resizePaneLeft":
            return .resizePaneLeft
        case "palette.resizePaneRight":
            return .resizePaneRight
        case "palette.resizePaneUp":
            return .resizePaneUp
        case "palette.resizePaneDown":
            return .resizePaneDown
        case "palette.triggerFlash":
            return .triggerFlash
        default:
            return nil
        }
    }

    static func commandPaletteRightSidebarModeCommandContributions() -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        // Palette execution resolves through the mode's shortcut action;
        // customSidebar has none yet (a new cmux-owned shortcut carries the
        // full settings/config/docs policy), so it stays out of the palette
        // until that lands. The mode bar, CLI, and socket verb cover it.
        // cmux-rbf `#cm-69`: `.reply` has no shortcut action either, but
        // `handleCommandPaletteRightSidebarMode` needs none, so keep it in the
        // palette. Reject this hunk on upstream sync.
        return RightSidebarMode.availableModes().filter { $0.shortcutAction != nil || $0 == .reply }.map { mode in
            let title = mode.shortcutAction?.label ?? mode.label
            return CommandPaletteCommandContribution(
                commandId: Self.commandPaletteRightSidebarModeCommandID(mode),
                title: constant(title),
                subtitle: constant(String(localized: "command.rightSidebarMode.subtitle", defaultValue: "Right Sidebar")),
                keywords: ["right", "sidebar", "show", "switch", "focus", mode.rawValue]
            )
        }
    }

    static func commandPaletteRightSidebarToolPaneCommandContributions() -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        return commandPaletteRightSidebarToolPaneCommandDescriptors().map { descriptor in
            CommandPaletteCommandContribution(
                commandId: descriptor.commandId,
                title: constant(descriptor.title),
                subtitle: constant(String(localized: "command.openRightSidebarToolAsPane.subtitle", defaultValue: "Pane")),
                keywords: ["open", "pane", "tool", "right", "sidebar", descriptor.mode.rawValue, descriptor.mode.label.lowercased()]
            )
        }
    }

    static func commandPaletteRightSidebarModeCommandID(_ mode: RightSidebarMode) -> String {
        switch mode {
        case .files:
            return "palette.showRightSidebarFiles"
        case .find:
            return "palette.showRightSidebarFind"
        case .sessions:
            return "palette.showRightSidebarSessions"
        case .feed:
            return "palette.showRightSidebarFeed"
        case .dock:
            return "palette.showRightSidebarDock"
        case .reply:
            return "palette.showRightSidebarReply"
        case .machines:
            return "palette.showRightSidebarMachines"
        case .customSidebar:
            return "palette.showRightSidebarCustomSidebar"
        }
    }

    static func commandPaletteRightSidebarToolPaneCommandDescriptors() -> [(mode: RightSidebarMode, commandId: String, title: String)] {
        RightSidebarMode.paneModes.compactMap { mode in
            guard mode.isAvailable(),
                  let commandId = commandPaletteRightSidebarToolPaneCommandID(mode),
                  let title = commandPaletteRightSidebarToolPaneTitle(mode) else {
                return nil
            }
            return (mode: mode, commandId: commandId, title: title)
        }
    }

    private static func commandPaletteRightSidebarToolPaneCommandID(_ mode: RightSidebarMode) -> String? {
        switch mode {
        case .files:
            return "palette.openFilesPane"
        case .find:
            return "palette.openFindPane"
        case .sessions:
            return "palette.openVaultPane"
        case .reply:
            return "palette.openReplyPane"
        case .machines:
            return "palette.openCloudPane"
        case .feed, .dock, .customSidebar:
            return nil
        }
    }

    private static func commandPaletteRightSidebarToolPaneTitle(_ mode: RightSidebarMode) -> String? {
        switch mode {
        case .files:
            return String(localized: "command.openFilesPane.title", defaultValue: "Open Files as Pane")
        case .find:
            return String(localized: "command.openFindPane.title", defaultValue: "Open Find as Pane")
        case .sessions:
            return String(localized: "command.openVaultPane.title", defaultValue: "Open Vault as Pane")
        case .reply:
            return String(localized: "command.openReplyPane.title", defaultValue: "Open Reply as Pane")
        case .machines:
            return String(localized: "command.openCloudPane.title", defaultValue: "Open Cloud as Pane")
        case .feed, .dock, .customSidebar:
            return nil
        }
    }

    func handleCommandPaletteRightSidebarMode(_ mode: RightSidebarMode, observedWindow: NSWindow?) {
        guard mode.isAvailable() else {
            NSSound.beep()
            return
        }
        if AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
            mode: mode,
            focusFirstItem: true,
            preferredWindow: observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        ) != true {
            fileExplorerState.setVisible(true)
            if fileExplorerState.mode != mode {
                fileExplorerState.mode = mode
            }
        }
    }

    func handleCommandPaletteRightSidebarToolPane(_ mode: RightSidebarMode) {
        openRightSidebarToolPane(mode)
    }

    func openCustomSidebarPane(_ name: String) {
        guard let workspace = tabManager.selectedWorkspace else {
            NSSound.beep()
            return
        }

        sidebarSelectionState.selection = .tabs
        workspace.clearSplitZoom()
        if let focusedPanelId = workspace.focusedPanelId,
           workspace.openOrFocusCustomSidebarSplit(from: focusedPanelId, name: name) != nil {
            return
        }
        guard let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first,
              workspace.openOrFocusCustomSidebarSurface(inPane: paneId, name: name, focus: true) != nil else {
            NSSound.beep()
            return
        }
    }

    private static func commandPaletteRightSidebarModeShortcutAction(
        forCommandID commandID: String
    ) -> KeyboardShortcutSettings.Action? {
        guard let mode = RightSidebarMode.availableModes().first(where: { mode in
            Self.commandPaletteRightSidebarModeCommandID(mode) == commandID
        }) else {
            return nil
        }
        return mode.shortcutAction
    }

    func rightSidebarCustomSidebarDataContext(now: Date) -> [String: SwiftValue] {
        let selectedId = tabManager.selectedTabId
        let workspaces = tabManager.tabs.enumerated().map { index, workspace in
            workspace.customSidebarWorkspaceSnapshot(
                index: index,
                selectedId: selectedId,
                unreadCount: sidebarUnread.unreadCount(forWorkspaceId: workspace.id)
            )
        }
        let selectedWorkspace = tabManager.tabs.first { $0.id == selectedId }
        let snapshot = CustomSidebarContextSnapshot(
            workspaces: workspaces,
            selectedWorkspaceId: selectedId,
            selectedWorkspaceTitle: selectedWorkspace?.customTitle ?? selectedWorkspace?.title ?? "",
            totalUnreadCount: sidebarUnread.totalUnreadCount,
            now: now
        )
        return CustomSidebarDataContextBuilder().dataContext(for: snapshot)
    }

}
