import SwiftUI

extension cmuxApp {
    func equalizeSplitsCommandButton() -> some View {
        equalizeCommandButton(
            title: String(localized: "command.equalizeSplits.title", defaultValue: "Equalize Splits"),
            action: .equalizeSplits,
            logName: "equalizeSplits",
            orientationFilter: nil
        )
    }

    func equalizeSplitWidthsCommandButton() -> some View {
        equalizeCommandButton(
            title: String(localized: "command.equalizeSplitWidths.title", defaultValue: "Equalize Split Widths"),
            action: .equalizeSplitWidths,
            logName: "equalizeSplitWidths",
            orientationFilter: "horizontal"
        )
    }

    func equalizeSplitHeightsCommandButton() -> some View {
        equalizeCommandButton(
            title: String(localized: "command.equalizeSplitHeights.title", defaultValue: "Equalize Split Heights"),
            action: .equalizeSplitHeights,
            logName: "equalizeSplitHeights",
            orientationFilter: "vertical"
        )
    }

    func arrangeSplitsMenu() -> some View {
        Menu(String(localized: "command.arrangeSplits.title", defaultValue: "Arrange Splits")) {
            ForEach(SplitArrangementPattern.builtIns) { pattern in
                arrangeSplitsButton(pattern)
            }
            // Only when the user has some: with no `panes.arrangePatterns` the
            // menu is identical to what shipped in v0.25.0.
            let custom = SplitArrangementPattern.custom()
            if !custom.isEmpty {
                Divider()
                ForEach(custom) { pattern in
                    arrangeSplitsButton(pattern)
                }
            }
        }
    }

    private func arrangeSplitsButton(_ pattern: SplitArrangementPattern) -> some View {
        Button(pattern.displayLabel) {
            let manager = activeTabManager
            if let workspace = manager.selectedWorkspace {
                let didArrange = manager.arrangeSplits(tabId: workspace.id, pattern: pattern)
#if DEBUG
                if !didArrange {
                    cmuxDebugLog("menu.arrangeSplits pattern=\(pattern.id) result=noSplitOrFailed workspaceId=\(workspace.id)")
                }
#endif
            }
        }
    }

    private func equalizeCommandButton(
        title: String,
        action: KeyboardShortcutSettings.Action,
        logName: String,
        orientationFilter: String?
    ) -> some View {
        splitCommandButton(title: title, shortcut: menuShortcut(for: action)) {
            let manager = activeTabManager
            if let workspace = manager.selectedWorkspace {
                let didEqualize = manager.equalizeSplits(
                    tabId: workspace.id,
                    orientationFilter: orientationFilter
                )
#if DEBUG
                if !didEqualize {
                    cmuxDebugLog("menu.\(logName) result=noSplitOrFailed workspaceId=\(workspace.id)")
                }
#endif
            }
        }
    }
}
