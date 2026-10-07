public import Foundation

/// The outcome of `workspace.group.move` (#cm-106): the old yes or no, and a third answer for a target
/// that sits in a different parent, so the handler can say why it refused.
public enum ControlWorkspaceGroupMoveResolution: Sendable, Equatable {
    /// No TabManager resolved (`unavailable` / "TabManager not available").
    case tabManagerUnavailable
    /// The group existed and a target resolved; the move ran.
    case moved
    /// The group was not found, or no target position resolved. Nothing changed.
    case unresolved
    /// The group is already where the request puts it, so nothing moved (#cm-106). Only a window with a nested
    /// group answers this; a flat window answers `moved` as it always did. The socket's answer to the caller is the same
    /// plain success as for `moved`.
    case unchanged
    /// The target is a group in a different parent from the moved group. Nothing changed.
    case targetNotBeside
}
