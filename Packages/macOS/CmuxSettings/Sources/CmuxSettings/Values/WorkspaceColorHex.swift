import Foundation

/// Canonical normalization for workspace color hex values.
///
/// Moved verbatim from the app target's `WorkspaceTabColorSettings.normalizedHex`
/// so the palette resolver, assignment-state comparison, and the app agree on one
/// spelling of a color. Comparing assignment state against un-normalized input is
/// the defect this exists to prevent.
public enum WorkspaceColorHex {
    /// Returns `#RRGGBB` upper-cased, or `nil` when `raw` is not a six-digit hex.
    ///
    /// The leading `#` is optional, so this also accepts `C0392B`. That is deliberate
    /// for storage and comparison — but it means any six-letter word built from hex
    /// digits (`Decade`, `Facade`, `Deface`, `Efface`, `Accede`, `Beaded`) parses as a
    /// colour. Callers resolving *user input* that could also be a palette name or a
    /// label must therefore not run this first; see `isExplicitHex`.
    public static func normalized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let body = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard body.count == 6 else { return nil }
        guard UInt64(body, radix: 16) != nil else { return nil }
        return "#" + body.uppercased()
    }

    /// Whether `raw` is written as a hex value rather than merely readable as one.
    ///
    /// The `#` is what makes the intent unambiguous: `#DECADE` can only be a colour,
    /// while `Decade` is a name someone may well have given a palette entry. Resolution
    /// uses this to let an explicit hex win outright while a bare one yields to a real
    /// name or label.
    public static func isExplicitHex(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#")
    }
}
