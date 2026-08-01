import Foundation

/// One row in the workspace color chooser.
public struct WorkspaceColorMenuCandidate: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The unconditional **No Color** row. Always present, always carrying state.
        case noColor
        /// A real palette entry, with its label if it has a valid one.
        case paletteEntry(WorkspaceColorPaletteEntry)
        /// A color a selected workspace currently has that the palette no longer contains.
        ///
        /// Rendered with its hex rather than a bare index, because "Custom" is already
        /// overloaded here by **Choose Custom Color…** and by auto-minted `Custom N`
        /// names. Ephemeral: it is a truthful assignment candidate, never a palette write,
        /// and never appears in `workspace.color.list`.
        case unlisted(hex: String)
        /// The trailing **Edit Color Labels…** row, which opens Settings rather than
        /// assigning anything.
        ///
        /// It lives in this model, not in each menu builder, so the two choosers cannot
        /// disagree about whether the row exists or where it sits. Each builder still
        /// supplies the action, exactly as it does for `noColor`.
        case editLabels
    }

    public let kind: Kind
    /// Normalized hex, or `nil` for **No Color**.
    public let hex: String?
    public let state: WorkspaceColorAssignmentState

    public init(kind: Kind, hex: String?, state: WorkspaceColorAssignmentState) {
        self.kind = kind
        self.hex = hex
        self.state = state
    }
}

/// Builds the workspace color chooser's rows from immutable snapshots.
///
/// Pure and allocation-bounded: one pass over the selected workspaces and the small
/// palette. Menus call this while opening, so it performs no I/O, schedules no work, and
/// touches no observable store.
public enum WorkspaceColorMenuModel {
    /// Rows in display order: **No Color**, the effective palette, then any current colors
    /// the palette no longer lists.
    ///
    /// - Parameters:
    ///   - orderedNames: palette names in display order (built-ins, then custom).
    ///   - targetHexes: one entry per workspace the action will apply to; `nil` if uncolored.
    public static func candidates(
        orderedNames: [String],
        palette: [String: String],
        labels: [String: String],
        targetHexes: [String?]
    ) -> [WorkspaceColorMenuCandidate] {
        // Targets are used un-normalized on purpose: WorkspaceColorAssignmentState
        // normalizes both sides of every comparison, and the unlisted-row loop below
        // normalizes what it dedupes. Pre-normalizing here as well was redundant —
        // mutation testing showed deleting it broke no test, which is how it surfaced.

        var rows: [WorkspaceColorMenuCandidate] = [
            WorkspaceColorMenuCandidate(
                kind: .noColor,
                hex: nil,
                state: .state(candidate: nil, targets: targetHexes)
            )
        ]

        let entries = WorkspaceColorSemanticLabelResolver.effectiveEntries(
            orderedNames: orderedNames,
            palette: palette,
            labels: labels
        )
        for entry in entries {
            // Every entry matching the assigned hex is checked. cmux stores a color, not
            // the slot that produced it, so nominating one winner would invent state.
            rows.append(
                WorkspaceColorMenuCandidate(
                    kind: .paletteEntry(entry),
                    hex: entry.hex,
                    state: .state(candidate: entry.hex, targets: targetHexes)
                )
            )
        }

        // A workspace keeps its color when its palette entry is removed or the palette is
        // reset. Surfacing those as rows keeps current state visible instead of vanishing.
        let paletteHexes = Set(entries.compactMap { WorkspaceColorHex.normalized($0.hex) })
        var seenUnlisted: Set<String> = []
        for target in targetHexes {
            guard let hex = target.flatMap(WorkspaceColorHex.normalized) else { continue }
            guard !paletteHexes.contains(hex), seenUnlisted.insert(hex).inserted else { continue }
            rows.append(
                WorkspaceColorMenuCandidate(
                    kind: .unlisted(hex: hex),
                    hex: hex,
                    state: .state(candidate: hex, targets: targetHexes)
                )
            )
        }

        // Last, after every assignment candidate: label management is a different kind of
        // act from choosing a color, and it navigates away rather than mutating anything.
        // `.off` is not a placeholder here — this row is never checked, which is exactly
        // what `.off` means to both builders' state rendering.
        rows.append(
            WorkspaceColorMenuCandidate(kind: .editLabels, hex: nil, state: .off)
        )

        return rows
    }
}
