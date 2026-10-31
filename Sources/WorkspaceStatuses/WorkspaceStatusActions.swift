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
    /// Runs a write and opens the folds above each workspace it moved (#cm-110.14). The default runs the write alone, so a test
    /// that builds its own actions needs no window.
    var revealing: ([Workspace], MoveRevealCause, () -> Void) -> Void = { _, _, write in write() }

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
            },
            revealing: { workspaces, cause, write in // (#cm-110.14)
                guard let first = workspaces.first,
                      let manager = AppDelegate.shared?.tabManagerFor(tabId: first.id) else { return write() }
                manager.revealingMoves(of: workspaces, cause: cause, write)
            }
        )
    }

    /// Sets an action on every target. The steps, in order, for a status: set it; stop if the origin is the
    /// phone; take the list's entry, and stop when there is none or it has no `color`; resolve the color, and stop
    /// when this app has no such color; write it. Auto and None clear color except from the phone. (#cm-110.13)
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
        requireControls: Bool,
        cause: MoveRevealCause = .status // (#cm-110.14)
    ) -> ApplyResult {
        if requireControls && !controlsEnabled { return .controlsOff }
        var result = ApplyResult.set // (#cm-110.14)
        revealing(workspaces, cause) { result = applyUnrevealed(action, to: workspaces) } // (#cm-110.14) one reveal around the one write path
        return result
    }

    private func applyUnrevealed(_ action: WorkspaceStatusPickAction, to workspaces: [Workspace]) -> ApplyResult { // (#cm-110.14)
        switch action {
        case .auto:
            WorkspaceStatusOrigin.$current.withValue(origin) { // (#cm-110.13)
                for workspace in workspaces { workspace.clearTaskStatusOverride() } // (#cm-110.13)
            } // (#cm-110.13)
            return .set
        case .hide:
            WorkspaceStatusOrigin.$current.withValue(origin) { // (#cm-110.13)
                for workspace in workspaces { workspace.hideTaskStatus() } // (#cm-110.13)
            } // (#cm-110.13)
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
