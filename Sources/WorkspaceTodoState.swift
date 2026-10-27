import Combine
import CmuxWorkspaces
import Foundation

/// The workspace-owned todo state: the manual task-status override and the
/// persisted checklist. A separate `ObservableObject` (held as a `let` on
/// `Workspace`, like `sidebarAgentRuntimeObservation`) so todo churn publishes
/// through its own object and sidebar rows can observe it without
/// invalidating on unrelated `Workspace` `@Published` traffic.
///
/// All mutation goes through the `Workspace` entry points in
/// `Workspace+Todos.swift` (shared by socket verbs, CLI, and UI) so caps,
/// text normalization, and override anti-rot apply identically everywhere.
@MainActor
final class WorkspaceTodoState: ObservableObject {
    /// The manual status override, or `nil` when the status is automatic.
    /// Carries the inference recorded at override time so a stale override
    /// auto-expires (see `WorkspaceTaskStatusOverride.effectiveStatus`).
    @Published var statusOverride: WorkspaceTaskStatusOverride?
    /// One of his own statuses, from the `workspaceStatuses` list, or `nil`. Never set together with
    /// `statusOverride`, which stays the only home of a cmux status set by hand. (#cm-109)
    @Published var ownStatus: WorkspaceOwnStatus?
    /// When true, this workspace is on None. With status controls on, its row (#cm-110.13)
    /// draws a dot in the glyph's slot; Auto keeps that slot empty but still infers status. (#cm-110.13)
    /// Selecting Auto or any lane clears this flag. (#cm-110.13)
    @Published var statusHidden: Bool = true
    /// The persisted checklist, in display order.
    @Published var checklist: [WorkspaceChecklistItem] = []
}
