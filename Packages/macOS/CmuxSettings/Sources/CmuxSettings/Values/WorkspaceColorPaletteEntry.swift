import Foundation

/// An effective workspace palette entry with stable identity and optional user-authored names.
///
/// Display puts meaning first and raw identity second — `GOAL: Primary (Teal)` — so a
/// person picks by purpose while config and automation keep speaking the stable name.
public struct WorkspaceColorPaletteEntry: Equatable, Hashable, Sendable {
    /// Stable identity. The config dictionary key, the label key, and the FNV-1a input
    /// to `WorkspaceColorCommandIdentity`. Never localized.
    public let name: String
    /// Normalized `#RRGGBB`.
    public let hex: String
    /// User-authored meaning, or `nil` when unset. Rendered verbatim; never localized.
    public let label: String?
    /// User-authored display name for a custom entry, or `nil` when the raw name is shown.
    public let customDisplayName: String?

    /// Creates an effective palette entry.
    ///
    /// - Parameters:
    ///   - name: Stable raw identity used by configuration and commands.
    ///   - hex: Normalized `#RRGGBB` value.
    ///   - label: Optional semantic meaning.
    ///   - customDisplayName: Optional editable name for a custom entry.
    public init(
        name: String,
        hex: String,
        label: String? = nil,
        customDisplayName: String? = nil
    ) {
        self.name = name
        self.hex = hex
        self.label = label
        self.customDisplayName = customDisplayName
    }

    /// Meaning first, then the editable custom name or stable raw fallback.
    ///
    /// Un-localized on purpose: the raw name is a config and command lookup key, so it
    /// must read identically in every locale. Only the surrounding frame is translated.
    public var displayName: String {
        let visibleName = customDisplayName ?? name
        guard let label else { return visibleName }
        return "\(label) (\(visibleName))"
    }
}
