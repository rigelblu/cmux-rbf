import Bonsplit
import CmuxPanes
import CoreGraphics
import Foundation

/// The adaptive arrange patterns `Arrange Splits` offers (#cm-67). Each is a
/// weight rule over the same-orientation spans along the root split's
/// orientation, in spatial order, so every preset fits any workspace with at
/// least two spans — no count-locked ratio vectors. Even/equal stays with
/// Equalize Splits.
enum SplitArrangementPreset: String, CaseIterable, Identifiable {
    case mainFirst
    case mainLast
    case minorFirst
    case minorLast

    var id: String { rawValue }

    /// The weight vector for `spanCount` spans, or `nil` below two spans.
    /// Main gives its span a double share; Minor gives it a half share.
    func ratios(forSpanCount spanCount: Int) -> [CGFloat]? {
        guard spanCount >= 2 else { return nil }
        var ratios = [CGFloat](repeating: 1, count: spanCount)
        switch self {
        case .mainFirst: ratios[0] = 2
        case .mainLast: ratios[spanCount - 1] = 2
        case .minorFirst: ratios[0] = 0.5
        case .minorLast: ratios[spanCount - 1] = 0.5
        }
        return ratios
    }

    var displayLabel: String {
        switch self {
        case .mainFirst:
            return String(localized: "command.arrangeSplits.preset.mainFirst", defaultValue: "Main First (2:1:…)")
        case .mainLast:
            return String(localized: "command.arrangeSplits.preset.mainLast", defaultValue: "Main Last (…:2)")
        case .minorFirst:
            return String(localized: "command.arrangeSplits.preset.minorFirst", defaultValue: "Minor First (0.5:1:…)")
        case .minorLast:
            return String(localized: "command.arrangeSplits.preset.minorLast", defaultValue: "Minor Last (1:…:0.5)")
        }
    }

    var commandId: String { "palette.arrangeSplits.\(rawValue)" }
}

extension TabManager {
    /// Arranges the workspace's splits into `preset`'s proportions along the
    /// root split's orientation. Returns false when there is no split to
    /// arrange or a divider rejected its new position — callers log and no-op.
    func arrangeSplits(tabId: UUID, preset: SplitArrangementPreset) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }
        let tree = tab.bonsplitController.treeSnapshot()
        guard case .split(let rootSplit) = tree else { return false }
        let orientation = rootSplit.orientation
        guard let ratios = preset.ratios(forSpanCount: tree.spanCount(along: orientation)),
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
