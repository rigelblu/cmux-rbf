import CmuxWorkspaces
import Foundation

/// The one write path for a workspace's status (#cm-109.2): sets a status and writes its color. A picker, a key, the
/// palette, the socket and the phone differ only in the action they pass and the origin they run under.
///
/// Built with the list in use, so a test passes its own list and needs no app delegate. The app builds one with
/// ``app(list:)``.
@MainActor
struct WorkspaceStatusActions {
    /// What `apply` answers.
    enum ApplyResult: Equatable {
        /// Every target was set.
        case set
        /// The status controls are off and the caller asked to respect that. Nothing was written.
        case controlsOff
        /// The id is neither in the list nor one of cmux's five. Nothing was written. `accepted` is what a set
        /// accepts, in the order a refusal names them.
        case unknown(String, accepted: [String])
    }

    let list: WorkspaceStatusList
    let origin: WorkspaceStatusOrigin
    let controlsEnabled: Bool
    /// The hex this app has for a typed color, or `nil`.
    let resolveColor: (String) -> String?
    /// Puts a hex on a workspace the way the Workspace Color menu does.
    let writeColor: (String, Workspace) -> Void

    /// The write path as the app runs it: the list in use (`list` when given, else the app's), the origin of the
    /// call in progress, the status controls' gate, the palette's resolver and the Workspace Color menu's writer.
    /// The list is read in the body and not in a default argument, which would be nonisolated.
    static func app(list: WorkspaceStatusList? = nil) -> WorkspaceStatusActions {
        WorkspaceStatusActions(
            list: list ?? AppDelegate.statusListInUse,
            origin: WorkspaceStatusOrigin.current,
            controlsEnabled: WorkspaceTodoFeature.isEnabled,
            resolveColor: { WorkspaceTabColorSettings.resolvedColorHex($0) },
            writeColor: { hex, workspace in
                AppDelegate.shared?.tabManagerFor(tabId: workspace.id)?.applyWorkspaceColor(hex, to: [workspace])
            }
        )
    }

    /// Sets an action on every target. The steps, in order, for a status: set it; stop if the origin is the
    /// phone; take the list's entry, and stop when there is none or it has no `color`; resolve the color, and stop
    /// when this app has no such color; write it. Auto and None write no color.
    ///
    /// - Parameters:
    ///   - action: What was asked for.
    ///   - workspaces: The targets.
    ///   - requireControls: Whether to refuse when the status controls are off. The socket and the cycle key pass
    ///     `false`.
    @discardableResult
    func apply(
        _ action: WorkspaceStatusPickAction,
        to workspaces: [Workspace],
        requireControls: Bool
    ) -> ApplyResult {
        if requireControls && !controlsEnabled { return .controlsOff }
        switch action {
        case .auto:
            for workspace in workspaces { workspace.clearTaskStatusOverride() }
            return .set
        case .hide:
            for workspace in workspaces { workspace.hideTaskStatus() }
            return .set
        case .status(let id):
            let entry = list.entry(id: id)
            let cmux = WorkspaceTaskStatus(rawValue: id)
            guard entry != nil || cmux != nil else { return .unknown(id, accepted: list.acceptedIDs) }
            for workspace in workspaces {
                // A cmux id is never stored as one of his own (Decisions, 2026-10-12, point 19).
                if let cmux {
                    workspace.setTaskStatusOverride(cmux, list: list) // (#cm-109.4)
                } else if let entry {
                    workspace.setOwnStatus(entry, list: list)
                }
                writeColorIfAny(of: entry, to: workspace)
            }
            return .set
        }
    }

    private func writeColorIfAny(of entry: WorkspaceStatusEntry?, to workspace: Workspace) {
        guard origin != .phone else { return }
        guard let color = entry?.color else { return }
        guard let hex = resolveColor(color) else { return }
        writeColor(hex, workspace)
    }
}
