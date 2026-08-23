import AppKit
import Foundation

/// One immutable, web-only terminal link action captured when a context menu opens.
@MainActor
struct TerminalContextMenuLinkAction {
    let url: URL

    init?(rawValue: String?, isTerminalViewport: Bool) {
        guard isTerminalViewport,
              let rawValue,
              case let .embeddedBrowser(url) = resolveTerminalOpenURLTarget(rawValue) else {
            return nil
        }
        self.url = url
    }

    func prepend(to menu: NSMenu, target: AnyObject?, action: Selector) {
        let item = NSMenuItem(
            title: String(
                localized: "browser.openInDefaultBrowser",
                defaultValue: "Open in Default Browser"
            ),
            action: action,
            keyEquivalent: ""
        )
        item.target = target
        item.representedObject = url
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
    }
}
