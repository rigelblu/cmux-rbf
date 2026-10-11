import CmuxControlSocket
import CmuxWorkspaces
import Foundation

extension AppDelegate {
    /// The list in use, for the hand-over lines in files upstream owns. cmux's five until the app's store has
    /// loaded a list, and in any process that has no app delegate.
    static var statusListInUse: WorkspaceStatusList {
        shared?.workspaceStatusListStore.list ?? .cmuxFive
    }
}

extension TerminalController {
    /// The app's side of `workspace.status.list` (#cm-109): the list in use, each status's resolved color, whether
    /// the status controls are on, and the problems the pill lists. It satisfies `ControlWorkspaceTodoContext`; the
    /// conformance is declared in `TerminalController+ControlWorkspaceTodoContext.swift`.
    ///
    /// It runs on the main actor, like the three status methods next to it, because it reads main-actor state: the
    /// store (an `@MainActor @Observable` class) and `WorkspaceTodoFeature.isEnabled`. It is a read of a few
    /// values for a script that asks, not a hot path, and it takes no routing: the list belongs to the app, not to
    /// a window.
    @MainActor
    func controlWorkspaceStatusList() -> ControlWorkspaceStatusListSnapshot {
        let store = AppDelegate.shared?.workspaceStatusListStore
        let list = store?.list ?? .cmuxFive
        let hexes = store?.colorHexes ?? [:]
        let statuses = list.entries.map { entry -> ControlWorkspaceStatusListSnapshot.Status in
            let name: String?
            switch entry.label {
            case .named(let word): name = word
            case .cmux: name = nil
            }
            return ControlWorkspaceStatusListSnapshot.Status(
                id: entry.id,
                name: name,
                extends: entry.isCmuxOwn ? nil : entry.behavesAs.rawValue,
                color: entry.color,
                colorHex: hexes[entry.id]
            )
        }
        let problems = (store?.problems ?? []).map { problem -> ControlWorkspaceStatusListSnapshot.Problem in
            if case .fileNotRead(let missing, let detail) = problem {
                return ControlWorkspaceStatusListSnapshot.Problem(
                    code: problem.code, entry: nil, id: nil,
                    value: detail.isEmpty ? nil : detail, fileMissing: missing
                )
            }
            return ControlWorkspaceStatusListSnapshot.Problem(
                code: problem.code, entry: problem.entry, id: problem.id, value: problem.value
            )
        }
        return ControlWorkspaceStatusListSnapshot(
            controlsEnabled: WorkspaceTodoFeature.isEnabled,
            source: ControlWorkspaceStatusListSnapshot.Source(rawValue: list.source.rawValue) ?? .cmux,
            statuses: statuses,
            problems: problems
        )
    }
}
