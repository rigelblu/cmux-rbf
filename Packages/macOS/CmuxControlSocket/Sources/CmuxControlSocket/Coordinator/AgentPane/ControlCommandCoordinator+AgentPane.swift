internal import Foundation

// cmux-rbf #cm-126.3: Agent Pane RPC dispatch, on main because the app changes layout.

extension ControlCommandCoordinator {
    /// Parses this local-only domain before calling its read-only check and single apply.
    func handleAgentPane(_ request: ControlRequest) -> ControlCallResult? {
        guard request.method == "agent_pane.show" || request.method == "agent_pane.list" else { return nil }
        guard request.params["_cmux_remote_workspace_id"] == nil else {
            return .err(code: "remote_relay_authentication_failed", message: "Agent Panes are local-only", data: nil)
        }
        guard let context else {
            return .err(code: "unavailable", message: "App context unavailable", data: nil)
        }
        if request.method == "agent_pane.list" {
            let workspaceID: UUID?
            if let raw = request.params["workspace_id"], raw != .null {
                guard let parsed = uuid(request.params, "workspace_id") else {
                    return .err(code: "invalid_params", message: "Invalid workspace_id", data: nil)
                }
                workspaceID = parsed
            } else {
                workspaceID = nil
            }
            guard let panes = context.controlAgentPaneList(workspaceID: workspaceID) else {
                return .err(code: "not_found", message: "Workspace not found", data: nil)
            }
            return .ok(.object(["agent_panes": .array(panes.map { pane in
                .object(agentPanePayload(
                    surfaceID: pane.surfaceID, paneID: pane.paneID, workspaceID: pane.workspaceID,
                    ownerSurfaceID: pane.ownerSurfaceID, ownerStableID: pane.ownerStableID,
                    url: pane.url, others: pane.others
                ))
            })]))
        }
        guard let surfaceID = uuid(request.params, "surface_id"),
              let rawURL = string(request.params, "url"), let url = URL(string: rawURL) else {
            return .err(
                code: "invalid_params", message: "Missing or invalid surface_id or url",
                data: .object(["reason": .string("invalid_show_params")])
            )
        }
        switch context.controlAgentPaneCheck(surfaceID: surfaceID, url: url) {
        case .refused(let refusal):
            return agentPaneRefusalResult(refusal, url: url)
        case .ready(let plan):
            guard let applied = context.controlAgentPaneApply(plan) else {
                return .err(code: "internal_error", message: "Agent Pane could not be opened or navigated", data: nil)
            }
            var payload = agentPanePayload(
                surfaceID: applied.surfaceID, paneID: applied.paneID, workspaceID: applied.workspaceID,
                ownerSurfaceID: applied.ownerSurfaceID, ownerStableID: applied.ownerStableID,
                url: applied.url.absoluteString, others: applied.others
            )
            payload["action"] = .string(applied.action.rawValue)
            return .ok(.object(payload))
        }
    }

    /// Mints refs only from live identifiers; the stable owner never becomes a live handle.
    private func agentPanePayload(
        surfaceID: UUID?, paneID: UUID?, workspaceID: UUID, ownerSurfaceID: UUID?,
        ownerStableID: UUID, url: String?, others: Int
    ) -> [String: JSONValue] {
        [
            "surface_id": orNull(surfaceID?.uuidString), "surface_ref": ref(.surface, surfaceID),
            "pane_id": orNull(paneID?.uuidString), "pane_ref": ref(.pane, paneID),
            "workspace_id": .string(workspaceID.uuidString), "workspace_ref": ref(.workspace, workspaceID),
            "owner_surface_id": orNull(ownerSurfaceID?.uuidString), "owner_surface_ref": ref(.surface, ownerSurfaceID),
            "owner_stable_id": .string(ownerStableID.uuidString), "url": orNull(url), "others": .int(Int64(others))
        ]
    }

    /// Keeps the code, diagnostic, and reason together for the CLI's English message mapping.
    private func agentPaneRefusalResult(_ refusal: ControlAgentPaneRefusal, url: URL) -> ControlCallResult {
        let code: String
        let reason: String
        let message: String
        var data: [String: JSONValue] = ["url": .string(url.absoluteString)]
        switch refusal {
        case .notFound(let surfaceID):
            code = "not_found"; reason = "not_found"; message = "Surface not found"
            data["surface"] = .string(surfaceID.uuidString)
        case .notTerminal(let surfaceID, let type):
            code = "invalid_params"; reason = "not_terminal"; message = "Caller is not a terminal"
            data["surface"] = .string(surfaceID.uuidString)
            data["type"] = .string(type)
        case .inDock:
            code = "unsupported"; reason = "in_dock"; message = "Caller is in the Dock"
        case .badScheme:
            code = "invalid_params"; reason = "bad_scheme"; message = "Unsupported page scheme"
        case .figmaAddress:
            code = "invalid_params"; reason = "figma_address"; message = "Figma addresses require a wrapper page"
        case .urlBlocked(let diagnostic):
            code = "browser_url_blocked"; reason = "url_blocked"; message = diagnostic
        case .insecureHTTP(let host):
            code = "invalid_params"; reason = "insecure_http"; message = "Insecure HTTP host is not allowed"
            data["host"] = .string(host)
        case .browserOff:
            code = "unavailable"; reason = "browser_off"; message = "Embedded browser is disabled"
        }
        data["reason"] = .string(reason)
        return .err(code: code, message: message, data: .object(data))
    }
}
