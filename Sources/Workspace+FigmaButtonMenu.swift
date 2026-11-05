import AppKit
import Bonsplit
import CmuxBrowser
import CmuxSettings
import Foundation

// cmux-rbf #cm-73.16: the menu built at press time for the clicked pane.
extension Workspace {
    var canEnterDesignFocusFromFigmaMenu: Bool {
        layoutMode != .canvas && pickDesignFocusPair() != nil
    }

    func splitTabBar(_ controller: BonsplitController, menuForCustomAction identifier: String, inPane pane: PaneID) -> NSMenu? {
        guard surfaceTabBarCommandButtons[identifier]?.builtInAction == .newFigma else { return nil }
        return figmaButtonMenu(inPane: pane)
    }

    func figmaButtonMenu(
        inPane pane: PaneID,
        choice: FigmaFolderChoice? = nil,
        configFile: URL = CmuxConfigLocation().userConfigFile,
        folderWriter: FigmaFolderWriter? = nil,
        runFolderDialog: (@MainActor (FigmaFolderDialogState, NSWindow?) -> FigmaFolderDialogResult?)? = nil,
        page: URL = FigmaPaneURL.previewPageURL,
        defaults: UserDefaults = .standard,
        // cmux-rbf #cm-73.17: test seams never send to a process or install in real home.
        agentRegistry: AgentChatSessionRegistry? = nil,
        skillHome: URL = FileManager.default.homeDirectoryForCurrentUser,
        deliverHandOff: ((UUID, [TextBoxSubmit.DispatchEvent]) -> Void)? = nil,
        logHandOffRefusal: ((String) -> Void)? = nil,
        openExternally: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) },
        showSettings: @escaping @MainActor (SettingsNavigationTarget, String, Bool) -> Void = { target, anchor, highlight in
            SettingsWindowPresenter.show(navigationTarget: target, anchorID: anchor, highlight: highlight)
        }
    ) -> NSMenu {
        // cmux-rbf #cm-73.42: the folder for this workspace's directory, by the one rule
        // `cmux figma folder` runs too. A remote workspace has no local directory, so the default answers.
        let store = JSONConfigStore(fileURL: configFile)
        let localDirectory: String? = usesRemoteDirectoryProvenance || currentDirectory.isEmpty ? nil : currentDirectory
        let folderEntries = store.snapshotValue(for: SettingCatalog().figma.folders)
        let currentChoice = choice ?? FigmaFolderChoice.answer(
            forms: localDirectory.map { FigmaFolderPath.forms(of: $0) },
            entries: folderEntries,
            defaultFolder: store.snapshotValue(for: SettingCatalog().figma.defaultFolder)
        )
        let currentFolder: String? = { if case .folder(let link, _) = currentChoice { link.url } else { nil } }()
        let writer = folderWriter ?? FigmaFolderWriter(store: store)
        let dialogState = localDirectory.map {
            FigmaFolderDialogState(directory: $0, entries: folderEntries, choice: currentChoice)
        }
        let files = figmaFiles
        // cmux-rbf #cm-73.17: read now for presentation, and again inside send on selection.
        let registry = agentRegistry ?? TerminalController.shared.agentChatTranscriptService?.registry
        let canHandOff = registry.flatMap { FigmaDesignHandOff.target(in: self, registry: $0) } != nil
        let model = FigmaButtonMenuModel(
            files: files,
            choice: currentChoice,
            canEnterDesignFocus: canEnterDesignFocusFromFigmaMenu,
            shortcut: KeyboardShortcutSettings.menuShortcut(for: .toggleDesignFocus),
            canHandOff: canHandOff,
            canSetFolder: !(dialogState?.items.isEmpty ?? true)
        )
        let menu = NSMenu()
        menu.autoenablesItems = false
        func addItems(_ rows: [FigmaButtonMenuModel.Row], to menu: NSMenu) {
            for row in rows {
                guard let action = row.action else {
                    menu.addItem(.separator())
                    continue
                }
                let item = FigmaButtonMenuItem(title: row.title) { [weak self] in
                    guard let self else { return }
                    switch action {
                    case .file(let key):
                        guard let entry = files.entries.first(where: { $0.key == key }) else { return }
                        self.openFigmaMenuFile(entry, inPane: pane, page: page, defaults: defaults, openExternally: openExternally)
                    case .newFile(let kind):
                        guard let address = FigmaNewFileLink.address(kind: kind, folder: currentFolder) else { return }
                        self.newFigmaSurface(inPane: pane, address: address, focus: true, defaults: defaults, openExternally: openExternally)
                    case .recents:
                        self.newFigmaSurface(inPane: pane, defaults: defaults, openExternally: openExternally)
                    case .chooseFolder:
                        showSettings(.automation, "setting:automation:figma-default-folder", true)
                    // cmux-rbf #cm-73.17: one shared delivery path, with a fresh gate.
                    case .putDesignIntoFigma, .newDesignInFigma:
                        FigmaDesignHandOff.send(
                            action == .putDesignIntoFigma ? .put : .new,
                            in: self,
                            registry: registry,
                            home: skillHome,
                            deliver: deliverHandOff,
                            logRefusal: logHandOffRefusal
                        )
                    case .enterDesignFocus:
                        guard !self.isDesignFocusActive, self.canEnterDesignFocusFromFigmaMenu else { return }
                        _ = self.toggleDesignFocus()
                    case .folderRow, .folderNote:
                        break
                    case .openFolder:
                        guard case .folder(let link, _) = currentChoice, let address = URL(string: link.url) else { return }
                        self.newFigmaSurface(inPane: pane, address: address, focus: true, defaults: defaults, openExternally: openExternally)
                    case .setFolder:
                        guard let state = dialogState, !state.items.isEmpty else { return }
                        let window = AppDelegate.shared?.mainWindowContainingWorkspace(self.id)
                        let result = runFolderDialog.map { $0(state, window) } ?? FigmaFolderDialog.run(state: state, presentingWindow: window)
                        guard let result else { return }
                        FigmaFolderWriteTracker.last = Task { @MainActor in
                            await writer.write(.set(result.link), directory: result.directory)
                        }
                    case .removeFolder(let key):
                        let resolved = FigmaFolderPath.keyForms(key)?.resolved ?? key
                        FigmaFolderWriteTracker.last = Task { @MainActor in
                            await writer.write(.clear, directory: resolved)
                        }
                    }
                }
                switch action {
                case .newFile(let kind): item.image = FigmaKindIcon.image(for: kind)
                case .file(let key):
                    if let entry = files.entries.first(where: { $0.key == key }),
                       let kind = FigmaKindIcon.kind(for: entry.link) {
                        item.image = FigmaKindIcon.image(for: kind)
                    }
                default: break
                }
                item.isEnabled = row.enabled
                item.toolTip = row.toolTip // cmux-rbf #cm-73.17
                if let shortcut = row.shortcut, let key = shortcut.menuItemKeyEquivalent {
                    item.keyEquivalent = key
                    item.keyEquivalentModifierMask = shortcut.modifierFlags
                }
                if !row.submenu.isEmpty {
                    let submenu = NSMenu()
                    submenu.autoenablesItems = false
                    addItems(row.submenu, to: submenu)
                    item.submenu = submenu
                }
                menu.addItem(item)
            }
        }
        addItems(model.rows, to: menu)
        return menu
    }

    private func openFigmaMenuFile(
        _ entry: FigmaFileList.Entry,
        inPane pane: PaneID,
        page: URL,
        defaults: UserDefaults,
        openExternally: (URL) -> Void
    ) {
        guard BrowserAvailabilitySettings.isEnabled(defaults: defaults) else { return }
        switch FigmaClickRoute.answer(for: entry.link, panes: figmaClickPanes(), wrapper: page) {
        case .bringForward(let panelID), .move(let panelID, _):
            // The saved frame never navigates an already-open file away from where it was left.
            focusPanel(panelID)
        case .openNew:
            let address: URL
            if entry.view == .read {
                guard let destination = figmaClickDestination(
                    for: entry.link,
                    node: FigmaPaneURL.node(fromPaneURL: entry.link),
                    page: page,
                    defaults: defaults
                ) else {
                    openExternally(entry.link)
                    return
                }
                address = destination.url
            } else {
                address = entry.link
            }
            newFigmaSurface(
                inPane: pane,
                address: address,
                focus: true,
                defaults: defaults,
                // Even a refusal hands Figma's own link to the browser, never cmux's read-view address. cmux-rbf #cm-73.39: the read view itself is no longer refused (trusted internal scheme).
                openExternally: { _ in openExternally(entry.link) }
            )
        case .notOurs:
            break
        }
    }
}
