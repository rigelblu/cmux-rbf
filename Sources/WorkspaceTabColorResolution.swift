import CmuxSettings
import Foundation

extension WorkspaceTabColorSettings {
    /// Labels exactly as stored, before validation.
    ///
    /// Handed to the resolver un-validated on purpose: `resolve` applies the same
    /// validation every other consumer sees, so there is one place where a label can be
    /// judged valid and no way for two callers to disagree.
    static func rawColorLabels(defaults: UserDefaults = .standard) -> [String: String] {
        defaults.dictionary(forKey: SettingCatalog().workspaceColors.labels.userDefaultsKey)
            as? [String: String] ?? [:]
    }

    /// Labels that survive validation against the current palette, for display.
    static func effectiveColorLabels(defaults: UserDefaults = .standard) -> [String: String] {
        WorkspaceColorSemanticLabelResolver.validLabels(
            rawLabels: rawColorLabels(defaults: defaults),
            palette: resolvedPaletteMap(defaults: defaults)
        )
    }

    /// The effective palette as display entries, in `palette()` order, labels attached.
    static func labeledPaletteEntries(defaults: UserDefaults = .standard) -> [WorkspaceColorPaletteEntry] {
        WorkspaceColorSemanticLabelResolver.effectiveEntries(
            orderedNames: palette(defaults: defaults).map(\.name),
            palette: resolvedPaletteMap(defaults: defaults),
            labels: rawColorLabels(defaults: defaults)
        )
    }

    /// Turns any user-supplied color value into a normalized hex.
    ///
    /// The single resolver behind the config workspace definition, the socket/CLI
    /// `set_color` handler, and `TabManager.applyWorkspacePaletteColor`. Ordered
    /// explicit `#RRGGBB` → exact-case raw name → folded raw name → exact unique label →
    /// bare six-digit hex; ambiguity fails closed. Bare hex is deliberately last, so a
    /// palette entry or label spelled from hex letters (`Decade`, `Facade`) keeps its own
    /// colour. `workspace.group.set_color` and the Choose Custom Color… alert stay
    /// hex-only by decision and do not call this.
    static func resolvedColorHex(_ raw: String, defaults: UserDefaults = .standard) -> String? {
        WorkspaceColorSemanticLabelResolver.resolve(
            raw,
            palette: resolvedPaletteMap(defaults: defaults),
            labels: rawColorLabels(defaults: defaults)
        )
    }

    /// The rows the workspace color chooser should draw, with on/off/mixed state.
    ///
    /// One bounded pass over the palette and the selected workspaces. Safe to call while
    /// building a menu: it reads settings, allocates no observers, and writes nothing.
    static func colorMenuCandidates(
        targetHexes: [String?],
        defaults: UserDefaults = .standard
    ) -> [WorkspaceColorMenuCandidate] {
        WorkspaceColorMenuModel.candidates(
            orderedNames: palette(defaults: defaults).map(\.name),
            palette: resolvedPaletteMap(defaults: defaults),
            labels: rawColorLabels(defaults: defaults),
            targetHexes: targetHexes
        )
    }

    /// Changes whenever anything a palette consumer renders changes.
    ///
    /// Labels participate: renaming a label with the same colors must still refresh
    /// command-palette entries, whose titles are built from the display name.
    static func paletteCacheFingerprint(defaults: UserDefaults = .standard) -> String {
        let palette = resolvedPaletteMap(defaults: defaults)
            .sorted { lhs, rhs in lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending }
            .map { "\($0.key)=\($0.value)" }
        let labels = effectiveColorLabels(defaults: defaults)
            .sorted { lhs, rhs in lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending }
            .map { "\($0.key)→\($0.value)" }
        return (palette + labels).joined(separator: "\n")
    }
}
