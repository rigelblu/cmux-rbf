import Foundation

extension TerminalController {
    /// `workspace.clear_agent_state` `{workspace_id}`: Clear Agent State on one workspace (cm-128.2), the socket entrance of
    /// the shared `Workspace.clearAgentState()` action, behind `cmux clear-agent-state`.
    ///
    /// Not focus-intent: it never selects a workspace, activates the app or moves focus. It runs its mutation on the main
    /// actor because it writes the sidebar models and the notification store, which are main-bound; it is a user-driven
    /// action, not telemetry. With nothing to clear it succeeds and changes nothing (`cleared: false`).
    ///
    /// Stays off the `cmux ssh` relay allowlist: it marks notifications read and ends agent state on local objects.
    func v2WorkspaceClearAgentState(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2UUIDAny(params["workspace_id"]) else {
            return .err(code: "invalid_params", message: "workspace_id is required", data: nil)
        }
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        var cleared: Bool?
        v2MainSync {
            cleared = tabManager.workspacesById[workspaceId]?.clearAgentState()
        }
        guard let cleared else {
            return .err(code: "not_found", message: "Workspace not found", data: [
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId)
            ])
        }
        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "cleared": cleared
        ])
    }
}
