import AppKit

extension TabManager {
    /// Returns the focused panel if it is a main-area or Dock browser.
    var focusedBrowserPanel: BrowserPanel? {
        guard let tab = selectedWorkspace else { return nil }
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        if let window, let responder = window.firstResponder {
            if let addressBarPanelId = AppDelegate.shared?.focusedBrowserAddressBarPanelId(),
               browserOmnibarPanelId(for: responder) == addressBarPanelId,
               let browser = tab.browserPanelIncludingDock(for: addressBarPanelId) {
                return browser
            }
            if let context = BrowserWindowPortalRegistry.paneDropContext(owning: responder, in: window),
               context.workspaceId == tab.id,
               let browser = tab.browserPanelIncludingDock(for: context.panelId) {
                return browser
            }
        }
        if let panelId = tab.focusedPanelId,
           let browser = tab.panels[panelId] as? BrowserPanel {
            return browser
        }
        return nil
    }

    var focusedTextFilePreviewPanel: FilePreviewPanel? {
        guard let tab = selectedWorkspace,
              let panelId = tab.focusedPanelId,
              let panel = tab.panels[panelId] as? FilePreviewPanel,
              panel.previewMode == .text else { return nil }
        return panel
    }

    /// Returns the focused panel if it's a MarkdownPanel showing the rendered
    /// preview, nil otherwise. Zoom applies to the preview WKWebView, so the raw
    /// text-edit mode is deliberately excluded.
    var focusedMarkdownPanel: MarkdownPanel? {
        guard let tab = selectedWorkspace,
              let panelId = tab.focusedPanelId,
              let panel = tab.panels[panelId] as? MarkdownPanel,
              panel.displayMode == .preview else { return nil }
        return panel
    }

    @discardableResult
    func zoomInFocusedTextFilePreview() -> Bool {
        performFocusedTextFilePreviewZoom { $0.zoomTextPreviewIn() } ?? false
    }

    @discardableResult
    func zoomOutFocusedTextFilePreview() -> Bool {
        performFocusedTextFilePreviewZoom { $0.zoomTextPreviewOut() } ?? false
    }

    @discardableResult
    func resetZoomFocusedTextFilePreview() -> Bool {
        performFocusedTextFilePreviewZoom { $0.resetTextPreviewZoom() } ?? false
    }

    @discardableResult
    func zoomInFocusedBrowserOrTextFilePreview() -> Bool {
        if let result = performFocusedTextFilePreviewZoom({ $0.zoomTextPreviewIn() }) { return result }
        return zoomInFocusedBrowser()
    }

    @discardableResult
    func zoomOutFocusedBrowserOrTextFilePreview() -> Bool {
        if let result = performFocusedTextFilePreviewZoom({ $0.zoomTextPreviewOut() }) { return result }
        return zoomOutFocusedBrowser()
    }

    @discardableResult
    func resetZoomFocusedBrowserOrTextFilePreview() -> Bool {
        if let result = performFocusedTextFilePreviewZoom({ $0.resetTextPreviewZoom() }) { return result }
        return resetZoomFocusedBrowser()
    }

    var focusedTerminalPanel: TerminalPanel? {
        if let workspace = selectedWorkspace {
            if let dock = workspace._dockSplit,
               AppDelegate.shared?.rightSidebarOwnsInputFocus(for: workspace) == true,
               let focusedId = dock.focusedPanelId,
               let dockTerminal = dock.panels[focusedId] as? TerminalPanel {
                return dockTerminal
            }
        }
        return selectedTerminalPanel
    }

    var canZoomFocusedPane: Bool {
        if focusedBrowserPanel != nil { return true }
        if focusedTextFilePreviewPanel != nil { return true }
        if focusedMarkdownPanel != nil { return true }
        if focusedTerminalPanel != nil { return true }
        return false
    }

    /// Whether the focused pane is zoomable and off its default size. Uses the
    /// same pane precedence as the zoom dispatch, so `Actual Size` gates on the
    /// pane it resets; an unzoomable pane matches no branch and reads `false`.
    var canResetFocusedPane: Bool {
        if let browser = focusedBrowserPanel { return browser.isPageZoomAdjusted }
        if let preview = focusedTextFilePreviewPanel { return preview.isTextPreviewZoomed }
        if let markdown = focusedMarkdownPanel { return markdown.isFontSizeAdjusted }
        if let terminal = focusedTerminalPanel { return terminal.isFontSizeAdjusted }
        return false
    }

    @discardableResult
    func zoomInFocusedPane() -> Bool {
        let changed: Bool
        if let browser = focusedBrowserPanel {
            changed = browser.zoomIn()
        } else if let result = performFocusedTextFilePreviewZoom({ $0.zoomTextPreviewIn() }) {
            changed = result
        } else if let markdown = focusedMarkdownPanel {
            changed = markdown.zoomIn()
        } else if let terminal = focusedTerminalPanel {
            changed = terminal.zoomIn()
        } else {
            changed = false
        }
        return changed
    }

    @discardableResult
    func zoomOutFocusedPane() -> Bool {
        let changed: Bool
        if let browser = focusedBrowserPanel {
            changed = browser.zoomOut()
        } else if let result = performFocusedTextFilePreviewZoom({ $0.zoomTextPreviewOut() }) {
            changed = result
        } else if let markdown = focusedMarkdownPanel {
            changed = markdown.zoomOut()
        } else if let terminal = focusedTerminalPanel {
            changed = terminal.zoomOut()
        } else {
            changed = false
        }
        return changed
    }

    @discardableResult
    func resetZoomFocusedPane() -> Bool {
        let changed: Bool
        if let browser = focusedBrowserPanel {
            changed = browser.resetZoom()
        } else if let result = performFocusedTextFilePreviewZoom({ $0.resetTextPreviewZoom() }) {
            changed = result
        } else if let markdown = focusedMarkdownPanel {
            changed = markdown.resetZoom()
        } else if let terminal = focusedTerminalPanel {
            changed = terminal.resetZoom()
        } else {
            changed = false
        }
        return changed
    }

    var hasAnyZoomedPane: Bool {
        for workspace in tabs {
            for panel in workspace.panels.values {
                if let terminal = panel as? TerminalPanel, terminal.isFontSizeAdjusted {
                    return true
                }
                if let browser = panel as? BrowserPanel, browser.isPageZoomAdjusted {
                    return true
                }
                if let markdown = panel as? MarkdownPanel, markdown.isFontSizeAdjusted {
                    return true
                }
                if let preview = panel as? FilePreviewPanel, preview.isTextPreviewZoomed {
                    return true
                }
            }
            if let dock = workspace._dockSplit {
                for panel in dock.panels.values {
                    if let terminal = panel as? TerminalPanel, terminal.isFontSizeAdjusted {
                        return true
                    }
                    if let browser = panel as? BrowserPanel, browser.isPageZoomAdjusted {
                        return true
                    }
                }
            }
            for mirror in workspace.remoteTmuxWindowMirrors.values {
                for panel in mirror.panelsByPaneId.values {
                    if panel.isFontSizeAdjusted {
                        return true
                    }
                }
            }
        }
        return false
    }

    @discardableResult
    func resetAllPaneZooms() -> Bool {
        var didReset = false
        for workspace in tabs {
            if workspace.resetTerminalFontSizes() > 0 {
                didReset = true
            }
            for panel in workspace.panels.values {
                if let browser = panel as? BrowserPanel, browser.isPageZoomAdjusted {
                    if browser.resetZoom() {
                        didReset = true
                    }
                } else if let markdown = panel as? MarkdownPanel, markdown.isFontSizeAdjusted {
                    if markdown.resetZoom() {
                        didReset = true
                    }
                } else if let preview = panel as? FilePreviewPanel, preview.isTextPreviewZoomed {
                    if preview.resetTextPreviewZoom() {
                        didReset = true
                    }
                }
            }
            if let dock = workspace._dockSplit {
                for panel in dock.panels.values {
                    if let browser = panel as? BrowserPanel, browser.isPageZoomAdjusted {
                        if browser.resetZoom() {
                            didReset = true
                        }
                    }
                }
            }
        }
        return didReset
    }
}

extension Notification.Name {
    /// Posted whenever a single pane's own zoom changes, so the View menu can
    /// re-evaluate `Actual Size` and `Everything: Actual Size`.
    static let paneZoomDidChange = Notification.Name("cmux.paneZoomDidChange")
}

