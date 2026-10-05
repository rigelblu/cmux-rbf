import CmuxCommandPalette
import Foundation

extension ContentView {
    /// "Name Window…" and "Clear Window Name" (#cm-104).
    ///
    /// Kept out of `commandPaletteCommandContributions()` so a unit test can
    /// call it and an upstream sync meets one appended line there, not two
    /// blocks. A palette row draws a title and an optional shortcut only, so
    /// the subtitle is search text and never shows.
    static func commandPaletteWindowNameCommandContributions() -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        let windowSubtitle = constant(String(localized: "command.newWindow.subtitle", defaultValue: "Window"))
        return [
            // No `when`: every window can be named, with or without a workspace.
            CommandPaletteCommandContribution(
                commandId: "palette.nameWindow",
                title: constant(String(localized: "command.nameWindow.title", defaultValue: "Name Window…")),
                subtitle: windowSubtitle,
                keywords: ["name", "rename", "window", "label"],
                dismissOnRun: false
            ),
            // Reads the context snapshot and nothing else: the command list is
            // rebuilt only when the snapshot's fingerprint changes, so a gate
            // that asked `tabManager` directly would go stale.
            CommandPaletteCommandContribution(
                commandId: "palette.clearWindowName",
                title: constant(String(localized: "command.clearWindowName.title", defaultValue: "Clear Window Name")),
                subtitle: windowSubtitle,
                keywords: ["clear", "remove", "window", "name"],
                when: { $0.bool(CommandPaletteContextKeys.windowHasName) }
            ),
        ]
    }
}

/// What a workspace row in the workspace search shows for its window (#cm-104.2).
struct CommandPaletteSwitcherWorkspaceWindowPresentation: Equatable {
    /// Drawn at the row's right edge.
    let trailingLabel: String
    /// Added to the row's search keywords.
    let extraKeywords: [String]
}

extension ContentView {
    /// The longest window name a workspace row draws at its right edge.
    static let commandPaletteSwitcherWindowNameLabelLimit = 24

    /// The one rule for what a workspace row shows about its window (#cm-104.2).
    /// A named window shows its name and is found by it; an unnamed one is
    /// exactly as before. The row's subtitle is not this function's business:
    /// it is searched, so the name stays out of it.
    static func commandPaletteSwitcherWorkspaceWindowPresentation(
        windowName: String?,
        kindWord: String
    ) -> CommandPaletteSwitcherWorkspaceWindowPresentation {
        guard let windowName else {
            return CommandPaletteSwitcherWorkspaceWindowPresentation(
                trailingLabel: kindWord,
                extraKeywords: []
            )
        }
        let limit = commandPaletteSwitcherWindowNameLabelLimit
        let trailingLabel: String
        if windowName.count > limit {
            let head = String(windowName.prefix(limit - 1)).trimmingCharacters(in: .whitespaces)
            trailingLabel = head + "\u{2026}"
        } else {
            trailingLabel = windowName
        }
        return CommandPaletteSwitcherWorkspaceWindowPresentation(
            trailingLabel: trailingLabel,
            extraKeywords: [windowName.lowercased()]
        )
    }

    /// Folds every window's name into the workspace search's list fingerprint,
    /// so naming or clearing a window rebuilds the list (#cm-104.2).
    static func commandPaletteSwitcherFingerprint(base: Int, windowNames: [String?]) -> Int {
        var hasher = Hasher()
        hasher.combine(base)
        hasher.combine(windowNames)
        return hasher.finalize()
    }
}
