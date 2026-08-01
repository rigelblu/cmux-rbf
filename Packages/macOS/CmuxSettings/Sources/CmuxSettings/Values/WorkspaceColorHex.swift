import Foundation

/// Canonical normalization for workspace color hex values.
///
/// Moved verbatim from the app target's `WorkspaceTabColorSettings.normalizedHex`
/// so the palette resolver, assignment-state comparison, and the app agree on one
/// spelling of a color. Comparing assignment state against un-normalized input is
/// the defect this exists to prevent.
public enum WorkspaceColorHex {
    /// Returns `#RRGGBB` upper-cased, or `nil` when `raw` is not a six-digit hex.
    public static func normalized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let body = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard body.count == 6 else { return nil }
        guard UInt64(body, radix: 16) != nil else { return nil }
        return "#" + body.uppercased()
    }
}
