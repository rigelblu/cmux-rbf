public import Foundation

/// One effective workspace palette entry, as `workspace.color.list` reports it.
///
/// Read-only by design. Labels are edited in Settings and `cmux.json` only, so cmux keeps
/// one durable configuration owner and automation cannot create a second source of truth
/// for what a color means.
///
/// The ephemeral `Custom (#RRGGBB)` rows the chooser synthesises never appear here: those
/// are truthful *assignment candidates* for the current selection, not palette members.
public struct ControlWorkspaceColorEntry: Sendable, Equatable {
    /// Stable identity — the `cmux.json` dictionary key, the label key, and the FNV-1a
    /// input behind the command-palette command ID. Never localized, never recycled.
    public let name: String
    /// The user's semantic label, or `nil` when unset. Rendered verbatim.
    public let label: String?
    /// What every menu shows: `Label (Name)`, or the bare name when unlabelled.
    public let displayName: String
    /// Normalized `#RRGGBB`.
    public let hex: String

    /// Creates one effective palette row.
    public init(name: String, label: String?, displayName: String, hex: String) {
        self.name = name
        self.label = label
        self.displayName = displayName
        self.hex = hex
    }
}
