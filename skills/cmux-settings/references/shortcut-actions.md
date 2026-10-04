# Keyboard shortcut action ids

Auto-generated from `web/data/cmux.schema.json` (`shortcuts.bindings.propertyNames.enum`).

Values for `shortcuts.bindings.<action>`:

- A string like `"cmd+b"` for a single shortcut.
- A two-element array like `["ctrl+b","c"]` for a chord.
- `null` or an empty string (`""`, `"none"`, `"clear"`, `"unbound"`, `"disabled"`) to unbind.

## App

- `shortcuts.bindings.openSettings`
- `shortcuts.bindings.reloadConfiguration`
- `shortcuts.bindings.showHideAllWindows`
- `shortcuts.bindings.globalSearch`
- `shortcuts.bindings.newWindow`
- `shortcuts.bindings.closeWindow`
- `shortcuts.bindings.toggleFullScreen`
- `shortcuts.bindings.quit`
- `shortcuts.bindings.openFolder`
- `shortcuts.bindings.sendFeedback`

## Tabs

- `shortcuts.bindings.newTab`
- `shortcuts.bindings.newBrowserWorkspace`
- `shortcuts.bindings.reopenPreviousSession`
- `shortcuts.bindings.renameTab`
- `shortcuts.bindings.closeTab`
- `shortcuts.bindings.closeOtherTabsInPane`

## Workspace

- `shortcuts.bindings.goToWorkspace`
- `shortcuts.bindings.selectWorkspaceByNumber`
- `shortcuts.bindings.renameWorkspace`
- `shortcuts.bindings.editWorkspaceDescription`
- `shortcuts.bindings.closeWorkspace`
- `shortcuts.bindings.newWorkspaceGroup`
- `shortcuts.bindings.groupSelectedWorkspaces`
- `shortcuts.bindings.toggleFocusedWorkspaceGroupCollapsed`
- `shortcuts.bindings.reopenClosedWorkspace`
- `shortcuts.bindings.reopenClosedBrowserPanel` (legacy ID for **Reopen Last Closed**)
- `shortcuts.bindings.moveWorkspaceUp`
- `shortcuts.bindings.moveWorkspaceDown`

## Panes and surfaces

- `shortcuts.bindings.nextSurface`
- `shortcuts.bindings.prevSurface`
- `shortcuts.bindings.moveSurfaceLeft`
- `shortcuts.bindings.moveSurfaceRight`
- `shortcuts.bindings.moveSurfaceToPreviousPane`
- `shortcuts.bindings.moveSurfaceToNextPane`
- `shortcuts.bindings.moveSurfaceToPaneLeft`
- `shortcuts.bindings.moveSurfaceToPaneRight`
- `shortcuts.bindings.moveSurfaceToPaneUp`
- `shortcuts.bindings.moveSurfaceToPaneDown`
- `shortcuts.bindings.selectSurfaceByNumber`
- `shortcuts.bindings.newSurface`
- `shortcuts.bindings.toggleTerminalCopyMode`
- `shortcuts.bindings.clearScreenKeepScrollback`
- `shortcuts.bindings.simulatorHome`
- `shortcuts.bindings.simulatorRotateLeft`
- `shortcuts.bindings.simulatorRotateRight`
- `shortcuts.bindings.simulatorToggleAppearance`
- `shortcuts.bindings.simulatorToggleSoftwareKeyboard`
- `shortcuts.bindings.focusLeft`
- `shortcuts.bindings.focusRight`
- `shortcuts.bindings.focusUp`
- `shortcuts.bindings.focusDown`
- `shortcuts.bindings.focusPreviousPane`
- `shortcuts.bindings.focusNextPane`
- `shortcuts.bindings.splitLeft`
- `shortcuts.bindings.splitRight`
- `shortcuts.bindings.splitUp`
- `shortcuts.bindings.splitDown`
- `shortcuts.bindings.toggleSplitZoom`
- `shortcuts.bindings.increaseWorkspaceTerminalFontSize`
- `shortcuts.bindings.decreaseWorkspaceTerminalFontSize`
- `shortcuts.bindings.resetWorkspaceTerminalFontSize`
- `shortcuts.bindings.equalizeSplits`
- `shortcuts.bindings.equalizeSplitWidths`
- `shortcuts.bindings.equalizeSplitHeights`

## Canvas

- `shortcuts.bindings.toggleCanvasLayout`
- `shortcuts.bindings.canvasRevealFocusedPane`
- `shortcuts.bindings.canvasOverview`
- `shortcuts.bindings.canvasZoomIn`
- `shortcuts.bindings.canvasZoomOut`
- `shortcuts.bindings.canvasZoomReset`
- `shortcuts.bindings.canvasTidy`
- `shortcuts.bindings.canvasAlignLeft`
- `shortcuts.bindings.canvasAlignRight`
- `shortcuts.bindings.canvasAlignTop`
- `shortcuts.bindings.canvasAlignBottom`
- `shortcuts.bindings.canvasEqualizeWidths`
- `shortcuts.bindings.canvasEqualizeHeights`
- `shortcuts.bindings.canvasDistributeHorizontally`
- `shortcuts.bindings.canvasDistributeVertically`

## Command palette

- `shortcuts.bindings.commandPalette`
- `shortcuts.bindings.commandPaletteNext`
- `shortcuts.bindings.commandPalettePrevious`

## Notifications

- `shortcuts.bindings.showNotifications`
- `shortcuts.bindings.jumpToUnread`
- `shortcuts.bindings.toggleUnread`
- `shortcuts.bindings.markOldestUnreadAndJumpNext`
- `shortcuts.bindings.markAllNotificationsRead`
- `shortcuts.bindings.clearAllNotifications`
- `shortcuts.bindings.triggerFlash`

## Right sidebar

- `shortcuts.bindings.toggleSidebar`
- `shortcuts.bindings.focusRightSidebar`
- `shortcuts.bindings.focusRightSidebarInReply`
- `shortcuts.bindings.switchRightSidebarToFiles`
- `shortcuts.bindings.switchRightSidebarToFind`
- `shortcuts.bindings.switchRightSidebarToSessions`
- `shortcuts.bindings.switchRightSidebarToFeed`
- `shortcuts.bindings.switchRightSidebarToDock`
- `shortcuts.bindings.switchRightSidebarToMachines`
- `shortcuts.bindings.nextSidebarTab`
- `shortcuts.bindings.prevSidebarTab`
- `shortcuts.bindings.nextSidebarTabInGroup`
- `shortcuts.bindings.prevSidebarTabInGroup`

## Browser

- `shortcuts.bindings.splitBrowserRight`
- `shortcuts.bindings.splitBrowserDown`
- `shortcuts.bindings.openBrowser`
- `shortcuts.bindings.focusBrowserAddressBar`
- `shortcuts.bindings.browserBack`
- `shortcuts.bindings.browserForward`
- `shortcuts.bindings.browserReload`
- `shortcuts.bindings.browserZoomIn`
- `shortcuts.bindings.browserZoomOut`
- `shortcuts.bindings.browserZoomReset`
- `shortcuts.bindings.toggleBrowserDeveloperTools`
- `shortcuts.bindings.showBrowserJavaScriptConsole`

## Find

**`find` does nothing while the Reply panel holds the keyboard**, whatever it is bound to. The Reply panel became a place the keyboard lives in `#cm-69.1b`, and find was never wired for it — `findShortcutTarget(forRightSidebarMode:)` answers `.rightSidebarFileSearch` for Files and `.none` for every other sidebar mode, and `.none` returns early. Measured 2026-09-09: 30 of 30 presses in the reply body did nothing, against 2 of 2 working in the terminal in the same session. Rebinding cannot fix it; finding within a reply is `#cm-69.10`.

- `shortcuts.bindings.find`
- `shortcuts.bindings.findInDirectory`
- `shortcuts.bindings.findNext`
- `shortcuts.bindings.findPrevious`
- `shortcuts.bindings.hideFind`
- `shortcuts.bindings.useSelectionForFind`

## Files and React Grab

- `shortcuts.bindings.toggleFileExplorer`
- `shortcuts.bindings.saveFilePreview`
- `shortcuts.bindings.toggleReactGrab`
