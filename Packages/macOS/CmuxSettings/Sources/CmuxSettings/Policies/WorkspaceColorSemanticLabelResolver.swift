import Foundation

/// Validation, display, and lookup for semantic workspace color labels.
///
/// Sole owner of the resolution order. Every entrypoint that turns a user-supplied color
/// value into a hex — the config workspace definition, the socket/CLI `set_color`
/// handler, and the command-palette action — goes through `resolve`, so meaning cannot
/// work in one surface and fail in another.
public enum WorkspaceColorSemanticLabelResolver {
    /// Longest a label may be before it stops scanning in a native menu.
    public static let maximumLabelLength = 64

    /// Why a proposed label cannot enter the effective palette.
    public enum LabelRejection: Equatable, Sendable {
        /// Empty after trimming.
        case empty
        /// Longer than `maximumLabelLength`.
        case tooLong
        /// Case-insensitively equal to another label.
        case duplicateLabel(otherName: String)
        /// Case-insensitively equal to a raw palette name — resolution would be ambiguous.
        case collidesWithPaletteName(String)
        /// Keyed to a palette entry that does not exist.
        case unknownPaletteName
    }

    /// Keeps only labels that can resolve unambiguously.
    ///
    /// Collision is symmetric: a label may not impersonate any raw palette name, and a
    /// palette entry added later whose name collides with an existing label invalidates
    /// that label rather than shadowing it. The raw name always keeps resolving.
    ///
    /// - Returns: the surviving labels keyed by raw palette name.
    public static func validLabels(
        rawLabels: [String: String],
        palette: [String: String]
    ) -> [String: String] {
        let rejected = rejections(rawLabels: rawLabels, palette: palette)
        var valid: [String: String] = [:]
        for (name, raw) in rawLabels where rejected[name] == nil {
            valid[name] = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return valid
    }

    /// Explains why each rejected label was dropped, for inline Settings validation.
    public static func rejections(
        rawLabels: [String: String],
        palette: [String: String]
    ) -> [String: LabelRejection] {
        var rejected: [String: LabelRejection] = [:]

        // Case-folded palette names, mapped back to their canonical spelling so the
        // rejection can name the entry the user actually collided with.
        var canonicalPaletteName: [String: String] = [:]
        for name in palette.keys {
            canonicalPaletteName[name.lowercased()] = name
        }

        var survivors: [String: String] = [:]
        for (name, raw) in rawLabels {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard palette[name] != nil else {
                rejected[name] = .unknownPaletteName
                continue
            }
            guard !trimmed.isEmpty else {
                rejected[name] = .empty
                continue
            }
            guard trimmed.count <= maximumLabelLength else {
                rejected[name] = .tooLong
                continue
            }
            // Symmetric collision: whether the label came first or the palette entry did,
            // the raw name keeps resolving and the label is what yields.
            if let collided = canonicalPaletteName[trimmed.lowercased()] {
                rejected[name] = .collidesWithPaletteName(collided)
                continue
            }
            survivors[name] = trimmed
        }

        var namesByFoldedLabel: [String: [String]] = [:]
        for (name, trimmed) in survivors {
            namesByFoldedLabel[trimmed.lowercased(), default: []].append(name)
        }
        for (_, names) in namesByFoldedLabel where names.count > 1 {
            // Ambiguity fails closed for every claimant, not just the losers of a
            // tie-break — picking a winner would make lookup depend on dictionary order.
            for name in names {
                let other = names.filter { $0 != name }.min() ?? name
                rejected[name] = .duplicateLabel(otherName: other)
            }
        }

        return rejected
    }

    /// Turns a user-supplied color value into a normalized hex.
    ///
    /// Ordered: explicit `#RRGGBB` hex → exact case-sensitive raw name → case-folded raw
    /// name → exact unique valid label → bare six-digit hex. The exact-case name pass can
    /// never be ambiguous, because palette keys are trimmed but never case-folded —
    /// `cmux.json` may legitimately define both `Teal` and `teal`. Ambiguity below that
    /// pass fails closed rather than picking a winner.
    ///
    /// **Bare hex runs last, and that ordering is load-bearing.**
    /// `WorkspaceColorHex.normalized` treats the `#` as optional, so six-letter words
    /// built from hex digits — `Decade`, `Facade`, `Deface`, `Efface`, `Accede`,
    /// `Beaded` — parse as colours. Accepting those before the palette lookup meant a
    /// user-defined entry named `Decade` resolved to `#DECADE`, a colour in no palette,
    /// with no error. That was reachable without the CLI: the command palette hands an
    /// entry's own key back to `applyWorkspacePaletteColor`, so cmux fed itself the bad
    /// input. An explicit `#` still wins outright, because it can only mean a colour.
    public static func resolve(
        _ input: String,
        palette: [String: String],
        labels: [String: String]
    ) -> String? {
        if WorkspaceColorHex.isExplicitHex(input), let hex = WorkspaceColorHex.normalized(input) {
            return hex
        }

        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Exact case-sensitive raw name. Never ambiguous, because palette keys are
        // trimmed but not case-folded, so `Teal` and `teal` are distinct entries.
        if let hex = palette[trimmed] { return hex }

        let folded = trimmed.lowercased()
        let foldedNameMatches = palette.filter { $0.key.lowercased() == folded }
        if foldedNameMatches.count == 1 { return foldedNameMatches.first?.value }
        // Two entries fold together and neither was an exact match — fail closed.
        if foldedNameMatches.count > 1 { return nil }

        // A raw name always outranks a label, so this pass runs before hex-without-#.
        let valid = validLabels(rawLabels: labels, palette: palette)
        let labelMatches = valid.filter { $0.value.lowercased() == folded }
        if labelMatches.count == 1, let name = labelMatches.first?.key { return palette[name] }
        if labelMatches.count > 1 { return nil }

        // Nothing in the user's own vocabulary claimed it, so a bare six-digit hex is
        // safe to read as a colour.
        return WorkspaceColorHex.normalized(trimmed)
    }

    /// The effective entries a menu, the command palette, and `workspace.color.list`
    /// all render, in `palette` order with validated labels attached.
    public static func effectiveEntries(
        orderedNames: [String],
        palette: [String: String],
        labels: [String: String]
    ) -> [WorkspaceColorPaletteEntry] {
        let valid = validLabels(rawLabels: labels, palette: palette)
        return orderedNames.compactMap { name in
            guard let hex = palette[name] else { return nil }
            return WorkspaceColorPaletteEntry(name: name, hex: hex, label: valid[name])
        }
    }
}
