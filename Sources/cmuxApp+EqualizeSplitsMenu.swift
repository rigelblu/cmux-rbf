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
            ForEach(SplitArrangementPreset.allCases) { preset in
                Button(preset.displayLabel) {
                    let manager = activeTabManager
                    if let workspace = manager.selectedWorkspace {
                        let didArrange = manager.arrangeSplits(tabId: workspace.id, preset: preset)
#if DEBUG
                        if !didArrange {
                            cmuxDebugLog("menu.arrangeSplits preset=\(preset.rawValue) result=noSplitOrFailed workspaceId=\(workspace.id)")
                        }
#endif
                    }
                }
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
