import Foundation

/// A validated custom palette edit and its current explicit-assignment impact.
public struct WorkspacePaletteColorEditPreview: Equatable, Sendable {
    /// Stable raw palette identity being edited.
    public let paletteName: String
    /// Expected current normalized value.
    public let oldHex: String
    /// Proposed normalized value.
    public let newHex: String
    /// Explicit workspace overrides currently matching ``oldHex``.
    public let workspaceCount: Int
    /// Explicit workspace-group overrides currently matching ``oldHex``.
    public let groupCount: Int
    /// Whether the old value identifies one palette entry and may be propagated.
    public let propagationAllowed: Bool
    /// Opaque host-state fingerprint checked again before apply.
    public let revisionToken: String

    /// Creates an impact preview returned by the host app.
    public init(
        paletteName: String,
        oldHex: String,
        newHex: String,
        workspaceCount: Int,
        groupCount: Int,
        propagationAllowed: Bool,
        revisionToken: String
    ) {
        self.paletteName = paletteName
        self.oldHex = oldHex
        self.newHex = newHex
        self.workspaceCount = workspaceCount
        self.groupCount = groupCount
        self.propagationAllowed = propagationAllowed
        self.revisionToken = revisionToken
    }

    /// The mutation Settings applies without asking the user to choose.
    ///
    /// A unique old value identifies this palette entry, so its explicit assignments
    /// follow the edit. Imported duplicate old values are ambiguous and remain untouched.
    public var automaticDecision: WorkspacePaletteColorEditDecision {
        propagationAllowed ? .paletteAndAssignments : .paletteOnly
    }
}

/// Why the host rejected a proposed custom palette value.
public enum WorkspacePaletteColorEditRejection: Error, Equatable, Sendable {
    /// The candidate is not a six-digit hex color.
    case invalidHex
    /// Another palette entry already owns the normalized candidate value.
    case duplicatePaletteValue(paletteName: String)
    /// The stable raw palette identity no longer exists or is built in.
    case unavailablePaletteEntry
    /// The stored old value changed before preview or apply.
    case staleValue
}

/// The explicit assignment choice made after an impact preview.
public enum WorkspacePaletteColorEditDecision: Equatable, Sendable {
    /// Change the custom palette entry and matching explicit workspace/group overrides.
    case paletteAndAssignments
    /// Change only the custom palette entry.
    case paletteOnly
}

/// Authoritative result of a host-owned custom palette edit.
public enum WorkspacePaletteColorEditResult: Equatable, Sendable {
    /// The edit committed; carries the authoritative palette map.
    case applied(palette: [String: String])
    /// State changed after preview; the UI should present or apply this replacement.
    case stale(replacement: WorkspacePaletteColorEditPreview)
    /// Validation rejected the request without mutation.
    case rejected(WorkspacePaletteColorEditRejection)
    /// A write failed and the previous palette and assignments were restored.
    case failedRestored(palette: [String: String])
    /// A write and its restoration both failed; carries the authoritative palette reload.
    case failedUnrecovered(palette: [String: String])
}

public extension SettingsHostActions {
    /// Validates a custom palette value and counts matching explicit overrides.
    ///
    /// - Parameters:
    ///   - paletteName: Stable raw palette identity.
    ///   - expectedOldHex: Value shown by Settings when the edit began.
    ///   - proposedHex: Candidate from direct text or the final picker value.
    /// - Returns: A preview or a claimant-specific rejection.
    func previewWorkspacePaletteColorEdit(
        paletteName: String,
        expectedOldHex: String,
        proposedHex: String
    ) -> Result<WorkspacePaletteColorEditPreview, WorkspacePaletteColorEditRejection> {
        .failure(.unavailablePaletteEntry)
    }

    /// Applies one still-current preview through the host's palette and assignment owners.
    ///
    /// - Parameters:
    ///   - preview: Previously returned revisioned impact preview.
    ///   - decision: Palette-only or palette-and-explicit-assignments.
    /// - Returns: The authoritative post-mutation state.
    func applyWorkspacePaletteColorEdit(
        _ preview: WorkspacePaletteColorEditPreview,
        decision: WorkspacePaletteColorEditDecision
    ) -> WorkspacePaletteColorEditResult {
        .rejected(.unavailablePaletteEntry)
    }
}
