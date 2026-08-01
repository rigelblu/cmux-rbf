import Foundation

/// An effective workspace palette entry: stable raw name, normalized hex, and the
/// optional semantic label the user layered over it.
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

    public init(name: String, hex: String, label: String? = nil) {
        self.name = name
        self.hex = hex
        self.label = label
    }

    /// `Label (Raw Name)` when labelled, otherwise the bare raw name.
    ///
    /// Un-localized on purpose: the raw name is a config and command lookup key, so it
    /// must read identically in every locale. Only the surrounding frame is translated.
    public var displayName: String {
        guard let label else { return name }
        return "\(label) (\(name))"
    }
}
