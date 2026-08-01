import Foundation

/// Monotonic minting for auto-generated `Custom N` palette names.
///
/// A raw palette name is an identity, not a display string: it keys `workspaceColors.labels`,
/// it is the config dictionary key, and it is the FNV-1a input to
/// `WorkspaceColorCommandIdentity`. Reusing a freed index therefore silently retargets any
/// `cmux.json` `actions` override keyed by that command ID onto a different color.
///
/// Lives here rather than in the app target because Settings' **Remove** button writes the
/// palette straight to `UserDefaults` from `CmuxSettingsUI`, which cannot import the app
/// target. Both writers must be able to advance the mark, so the mark must live below both.
public enum WorkspaceColorCustomNameMint {
    /// Its own defaults key, deliberately *not* inside the palette dictionary, so that
    /// `reset()` and Settings' **Reset Palette** restore default colors without also
    /// restoring the ability to recycle a name that already carried meaning.
    public static let highWaterMarkDefaultsKey = "workspaceTabColor.customNameHighWaterMark"

    private static let namePrefix = "Custom "

    /// The `N` in `Custom N`, or `nil` for any other name.
    ///
    /// Matches case-insensitively because palette keys are trimmed but never case-folded,
    /// so a hand-written `cmux.json` may spell it `custom 3`.
    public static func customIndex(forName name: String) -> Int? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > namePrefix.count else { return nil }
        guard trimmed.prefix(namePrefix.count).caseInsensitiveCompare(namePrefix) == .orderedSame else {
            return nil
        }
        let suffix = trimmed.dropFirst(namePrefix.count)
        // Reject "Custom 007" and "Custom 1x" — only a plain positive integer is an index.
        guard suffix.allSatisfy(\.isASCII), suffix.allSatisfy(\.isNumber) else { return nil }
        guard let index = Int(suffix), index > 0 else { return nil }
        return index
    }

    /// Highest `Custom N` index among the given names, or `0` when there are none.
    public static func highestIndex(in names: some Sequence<String>) -> Int {
        names.compactMap { customIndex(forName: $0) }.max() ?? 0
    }

    /// The persisted mark. `0` when nothing has been minted yet.
    public static func highWaterMark(defaults: UserDefaults) -> Int {
        max(0, defaults.integer(forKey: highWaterMarkDefaultsKey))
    }

    /// Raises the mark to cover every `Custom N` in `paletteNames`. Never lowers it.
    ///
    /// Call this from **every** path that persists a palette, not from the path that mints
    /// a name. Names also enter through a hand-written `cmux.json`, the legacy migration,
    /// and Settings' **Remove** — none of which mint. Advancing only at the mint site
    /// leaves all of those able to recycle.
    public static func advanceHighWaterMark(
        forPaletteNames paletteNames: some Sequence<String>,
        defaults: UserDefaults
    ) {
        let candidate = highestIndex(in: paletteNames)
        guard candidate > highWaterMark(defaults: defaults) else { return }
        defaults.set(candidate, forKey: highWaterMarkDefaultsKey)
    }

    /// The next name to mint: one past the highest index ever seen, never a freed one.
    ///
    /// A pure read — it does not persist. Callers reachable from a SwiftUI view body rely
    /// on that, since writing state from a view body is a re-render feedback loop.
    public static func nextCustomName(
        existingNames: some Sequence<String>,
        defaults: UserDefaults
    ) -> String {
        let names = Array(existingNames)
        var index = max(highWaterMark(defaults: defaults), highestIndex(in: names)) + 1
        // Defensive: an explicitly typed "Custom 9" can sit above the mark in a way the
        // index scan already covers, but a non-numeric collision could still exist.
        let taken = Set(names.map { $0.lowercased() })
        while taken.contains("\(namePrefix)\(index)".lowercased()) {
            index += 1
        }
        return "\(namePrefix)\(index)"
    }
}
