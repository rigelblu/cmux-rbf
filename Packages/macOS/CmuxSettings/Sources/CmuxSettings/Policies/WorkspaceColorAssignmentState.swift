import Foundation

/// Whether a menu candidate is the current color of every, some, or none of the
/// workspaces an action will apply to.
///
/// Derived from target hex snapshots only — never from a remembered menu slot, because
/// cmux persists a color, not the palette entry that produced it.
public enum WorkspaceColorAssignmentState: Equatable, Sendable {
    /// No target carries this color.
    case off
    /// Every target carries this color.
    case on
    /// Some but not all targets carry this color.
    case mixed
}

public extension WorkspaceColorAssignmentState {
    /// Computes state for one candidate against the workspaces the action will apply to.
    ///
    /// - Parameters:
    ///   - candidate: the candidate's hex, or `nil` for the **No Color** row.
    ///   - targets: each selected workspace's assigned hex, `nil` when uncolored.
    static func state(candidate: String?, targets: [String?]) -> WorkspaceColorAssignmentState {
        // "every element matches" is vacuously true for an empty set, which would draw a
        // checkmark for a menu acting on nothing.
        guard !targets.isEmpty else { return .off }

        let matchCount = targets.count { target in
            guard let candidate else {
                // The No Color row. Only a genuinely unassigned workspace matches — an
                // unparseable stored value is a color we failed to read, not no color.
                return target == nil
            }
            guard let target,
                  let normalizedCandidate = WorkspaceColorHex.normalized(candidate),
                  let normalizedTarget = WorkspaceColorHex.normalized(target) else { return false }
            return normalizedCandidate == normalizedTarget
        }

        if matchCount == targets.count { return .on }
        return matchCount == 0 ? .off : .mixed
    }
}
