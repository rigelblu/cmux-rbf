import Bonsplit
import CmuxPanes
import CmuxSettings
import CoreGraphics
import Foundation

/// One adaptive arrange pattern `Arrange Splits` offers — built in (#cm-67) or
/// user-defined in `cmux.json` (#cm-67.1).
///
/// A pattern is a weight rule over the same-orientation spans along the root
/// split's orientation, in spatial order, so it fits any workspace with at
/// least two spans — no count-locked ratio vectors. Even/equal stays with
/// Equalize Splits.
///
/// Both origins carry a `SplitRatioSpec`, so there is one span-adaptation rule
/// rather than one per origin: `mainFirst` is literally `"2:1"`, and a user's
/// `"1:1:0.5"` runs the same code down to the same `ratioDividerPlan`.
struct SplitArrangementPattern: Identifiable, Equatable {
    let id: String
    let displayLabel: String
    let spec: SplitRatioSpec

    /// The weight vector for `spanCount` spans, or `nil` below two spans.
    func ratios(forSpanCount spanCount: Int) -> [CGFloat]? {
        spec.ratios(forSpanCount: spanCount)
    }

    var commandId: String { "palette.arrangeSplits.\(id)" }
}

extension SplitArrangementPattern {
    /// The four patterns cmux ships. Main gives its span a double share; Minor
    /// gives it a half share — expressed as specs so they adapt by the same
    /// rule a user's pattern does.
    ///
    /// Two tests hold this, and neither alone is enough. `SplitRatioSpecTests`
    /// proves the *rule* reproduces the pre-`#cm-67.1` switch across 2…12 spans,
    /// but it builds its own specs from strings — it is in another module and
    /// cannot see these values. `testArrangementPresetWeightRulesAdaptToSpanCount`
    /// pins *these* vectors, and must assert each at a span count above its
    /// written length: below it the rule drops `weights[1]`, so a wrong middle
    /// weight would not show. Cold review 2026-09-01 found exactly that hole.
    ///
    /// The force-unwraps are deliberate: these are compile-time constants that
    /// must satisfy `SplitRatioSpec`'s guard, so an edit that breaks one is a
    /// programming error, not a runtime condition. Failing loudly beats a
    /// fallback that would render a menu item doing the wrong thing silently.
    /// Three tests touch `builtIns`, so a bad edit dies in the suite first.
    static let builtIns: [SplitArrangementPattern] = [
        SplitArrangementPattern(
            id: "mainFirst",
            displayLabel: String(
                localized: "command.arrangeSplits.preset.mainFirst",
                defaultValue: "Main First (2:1:…)"
            ),
            spec: SplitRatioSpec(weights: [2, 1])!
        ),
        SplitArrangementPattern(
            id: "mainLast",
            displayLabel: String(
                localized: "command.arrangeSplits.preset.mainLast",
                defaultValue: "Main Last (…:2)"
            ),
            spec: SplitRatioSpec(weights: [1, 1, 2])!
        ),
        SplitArrangementPattern(
            id: "minorFirst",
            displayLabel: String(
                localized: "command.arrangeSplits.preset.minorFirst",
                defaultValue: "Minor First (0.5:1:…)"
            ),
            spec: SplitRatioSpec(weights: [0.5, 1])!
        ),
        SplitArrangementPattern(
            id: "minorLast",
            displayLabel: String(
                localized: "command.arrangeSplits.preset.minorLast",
                defaultValue: "Minor Last (1:…:0.5)"
            ),
            spec: SplitRatioSpec(weights: [1, 1, 0.5])!
        ),
    ]

    /// The user's own patterns from `panes.arrangePatterns` in `cmux.json`,
    /// keyed by the display name they chose.
    ///
    /// An entry whose ratio text will not parse is dropped **alone**, matching
    /// `WorkspaceColorsCatalogSection`'s stated policy that an unusable stored
    /// value selects nothing rather than failing the file. Names are sorted the
    /// way `WorkspaceTabColorSettings.palette()` sorts custom colours, since a
    /// JSON object carries no order of its own.
    static var customPatternsDefaultsKey: String {
        PanesCatalogSection().arrangePatterns.userDefaultsKey
    }

    static func custom(defaults: UserDefaults = .standard) -> [SplitArrangementPattern] {
        guard let stored = defaults.dictionary(forKey: customPatternsDefaultsKey) as? [String: String]
        else { return [] }
        return stored
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .compactMap { name, text in
                let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedName.isEmpty, let spec = SplitRatioSpec(text) else {
#if DEBUG
                    cmuxDebugLog("arrangeSplits.customPattern.dropped name=\(name) ratios=\(text)")
#endif
                    return nil
                }
                let ratios = text.trimmingCharacters(in: .whitespaces)
                return SplitArrangementPattern(
                    id: "custom.\(trimmedName)",
                    // The hint is the user's own written ratio, so the label
                    // reads back the notation they typed; their name is not
                    // localizable, because it is theirs.
                    //
                    // The `(Custom)` marker is the origin signal (`#cm-67.2`).
                    // The menu groups these under a divider, but a command
                    // palette contribution carries no rank, order, or group
                    // field — the fuzzy matcher owns the ordering outright, so
                    // custom and built-in rows interleave and position tells
                    // the reader nothing. The label is the only channel there.
                    //
                    // Named for what it is, not where it lives: `cmux.json`
                    // was tried in v0.25.2 and read as too technical in
                    // dogfood, which is also the answer to "why not say where
                    // to edit it" — that is documentation's job, not a label's.
                    displayLabel: String(
                        localized: "command.arrangeSplits.customPattern.label",
                        defaultValue: "\(trimmedName) (\(ratios)) (Custom)"
                    ),
                    spec: spec
                )
            }
    }

    /// Every pattern the menu and palette offer: the built-ins in their shipped
    /// order, then the user's, exactly as `WorkspaceTabColorSettings.palette()`
    /// orders built-in colours before custom ones.
    static func all(defaults: UserDefaults = .standard) -> [SplitArrangementPattern] {
        builtIns + custom(defaults: defaults)
    }
}

extension TabManager {
    /// Arranges the workspace's splits into `pattern`'s proportions along the
    /// root split's orientation. Returns false when there is no split to
    /// arrange or a divider rejected its new position — callers log and no-op.
    func arrangeSplits(tabId: UUID, pattern: SplitArrangementPattern) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }
        let tree = tab.bonsplitController.treeSnapshot()
        guard case .split(let rootSplit) = tree else { return false }
        let orientation = rootSplit.orientation
        guard let ratios = pattern.ratios(forSpanCount: tree.spanCount(along: orientation)),
              let result = paneLayout.arrangeSplits(
                  ratios: ratios,
                  in: tree,
                  controller: tab.bonsplitController,
                  orientation: orientation
              ) else {
            return false
        }
        if result.foundSplit {
            tab.didProgrammaticallyChangeSplitGeometry()
        }
        return result.didFullyEqualize
    }
    /// Equalize splits - not directly supported by bonsplit.
    /// `orientationFilter` narrows the pass to "horizontal" (side-by-side, i.e.
    /// widths) or "vertical" (stacked, i.e. heights); `nil` equalizes all splits.
    func equalizeSplits(tabId: UUID, orientationFilter: String? = nil) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }

        let result = equalizeSplitsOnce(in: tab, orientationFilter: orientationFilter)
        if result.foundSplit {
            tab.didProgrammaticallyChangeSplitGeometry()
        }
        return result.didFullyEqualize
    }

    @discardableResult
    private func equalizeSplitsOnce(
        in tab: Workspace,
        orientationFilter: String? = nil
    ) -> SplitEqualizeResult {
        paneLayout.equalizeSplits(
            in: tab.bonsplitController.treeSnapshot(),
            controller: tab.bonsplitController,
            orientationFilter: orientationFilter
        )
    }
}
