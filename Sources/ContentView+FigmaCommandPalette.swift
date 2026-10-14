import AppKit
import CmuxCommandPalette

// cmux-rbf `#cm-73.9`: the palette's "New Tab (Figma)" (Tom, 2026-10-12, Q16). The row and the
// handler are functions here, so a test reaches them; `ContentView`'s own lists are private.

extension CommandPaletteCommandContribution {
    static var newFigmaTab: Self {
        Self(
            commandId: "palette.newFigmaTab",
            title: { _ in String(localized: "command.newFigmaTab.title", defaultValue: "New Tab (Figma)") },
            // The browser row's small word, so one new string is translated.
            subtitle: { _ in String(localized: "command.newBrowserTab.subtitle", defaultValue: "Tab") },
            keywords: ["new", "figma", "tab", "design"],
            // A Figma tab is a browser tab: not offered while cmux's browser is off.
            when: { !$0.bool(CommandPaletteContextKeys.browserDisabled) }
        )
    }
}

extension CommandPaletteHandlerRegistry {
    @MainActor
    mutating func registerNewFigmaTab(tabManager: TabManager, windowId: UUID) {
        register(commandId: "palette.newFigmaTab") {
            // The same path a `cmux.json` action naming the id reaches, so the
            // tab is last in the focused pane and has focus.
            guard let appDelegate = AppDelegate.shared,
                  appDelegate.executeConfiguredCmuxAction(
                    id: CmuxSurfaceTabBarBuiltInAction.newFigma.configID,
                    tabManager: tabManager,
                    preferredWindow: appDelegate.mainWindow(for: windowId)
                  ) else {
                NSSound.beep()
                return
            }
        }
    }
}
