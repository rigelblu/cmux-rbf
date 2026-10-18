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
        folder: String? = nil,
        page: URL = FigmaPaneURL.wrapperFileURL(),
        defaults: UserDefaults = .standard,
        openExternally: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) },
        showSettings: @escaping @MainActor (SettingsNavigationTarget, String, Bool) -> Void = { target, anchor, highlight in
            SettingsWindowPresenter.show(navigationTarget: target, anchorID: anchor, highlight: highlight)
        }
    ) -> NSMenu {
        let currentFolder = folder ?? JSONConfigStore(fileURL: CmuxConfigLocation().userConfigFile)
            .snapshotValue(for: SettingCatalog().figma.defaultFolder)
        let files = figmaFiles
        let model = FigmaButtonMenuModel(
            files: files,
            folder: currentFolder,
            canEnterDesignFocus: canEnterDesignFocusFromFigmaMenu,
            shortcut: KeyboardShortcutSettings.menuShortcut(for: .toggleDesignFocus)
        )
        let menu = NSMenu()
        menu.autoenablesItems = false
        for row in model.rows {
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
                case .enterDesignFocus:
                    guard !self.isDesignFocusActive, self.canEnterDesignFocusFromFigmaMenu else { return }
                    _ = self.toggleDesignFocus()
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
            if let shortcut = row.shortcut, let key = shortcut.menuItemKeyEquivalent {
                item.keyEquivalent = key
                item.keyEquivalentModifierMask = shortcut.modifierFlags
            }
            menu.addItem(item)
        }
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
                // Even a read-view refusal hands Figma's link to the browser, never the local wrapper.
                openExternally: { _ in openExternally(entry.link) }
            )
        case .notOurs:
            break
        }
    }
}
