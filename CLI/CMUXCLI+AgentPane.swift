import Foundation

// cmux-rbf #cm-126.3: `cmux agent-pane`, the pane beside one agent that shows its updates.

extension CMUXCLI {

    var agentPaneUsage: String {
        """
        Usage: cmux [--json] [--id-format refs|uuids|both] agent-pane show <page> [--surface <id|ref>]
               cmux [--json] [--id-format refs|uuids|both] agent-pane list [--workspace <id|ref>]

        Show a page beside the agent, in its own pane: the Agent Pane.

        show <page>
          The first time, opens the Agent Pane as a new split of the terminal's own
          pane; after that, changes its page. cmux finds the Agent Pane by the terminal the
          command runs in, so there are no ids to keep. It never takes focus.
          <page> is a path to an existing file (made absolute against the current
          directory), or a file://, https:// or http:// URL. A relative file: URL
          is also made absolute against the current directory. http:// opens only for
          localhost or a host on cmux's insecure-HTTP list (Settings). A Figma address is
          refused: put the board in a page of your own (Figma's embed in an iframe).
          --surface  the agent's terminal. Without it: herdr-agent's note for this herdr
                     pane when its attach is live, then $CMUX_SURFACE_ID; when cmux doesn't
                     know the first, the next is tried.
          Prints: OK surface=<ref> pane=<ref> workspace=<ref> action=opened|navigated|held-design-focus
          While Design Focus is on, the update is held (action=held-design-focus, exit 0)
          and the Agent Pane shows it when the mode ends: send one `cmux notify` with the
          update's "But:" line.

        list
          Every Agent Pane: <surface> pane=<pane> workspace=<ws> owner=<terminal|none> url=<url>
          owner is the owning terminal's live surface, none when that terminal is gone;
          --json adds owner_stable_id, the stored value.

        Not available over `cmux ssh`.

        Errors (exit 1):
          \(AgentPaneCLIRules.noCallerMessage)
          --surface value is empty
          no such surface: <surface>
          not a file, file://, https:// or http:// page: <page>
          not a file, file://, https:// or http:// page: <name>:<port>; did you mean http://<name>:<port>?
          no such file: <path>
          not a file: <path>
          \(AgentPaneCLIRules.figmaAddressMessage)
          that terminal is gone: <surface>
          the Agent Pane belongs to a terminal, and <surface> is a <type>
          the Agent Pane opens beside a terminal in a workspace, not in the Dock
          cmux's browser is off in Settings, so the Agent Pane can't open
          http:// opens only for localhost or a host on cmux's insecure-HTTP list (Settings): <host>. Use https:// or a local file
          the embedded browser's URL policy blocks <url>: <reason>
          the Agent Pane couldn't open, and nothing was changed: <diagnostic>
        """
    }

    func runAgentPaneCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        var args = commandArgs
        guard !args.isEmpty else {
            throw CLIError(message: "cmux agent-pane requires a subcommand: show, list")
        }
        let subcommand = args.removeFirst().lowercased()
        if ["help", "--help", "-h"].contains(subcommand) {
            print(agentPaneUsage)
            return
        }
        switch subcommand {
        case "show":
            let (surface, rest) = parseOption(args, name: "--surface")
            guard rest.count == 1, let page = rest.first, !page.hasPrefix("--") else {
                throw CLIError(message: "usage: cmux agent-pane show <page> [--surface <id|ref>]")
            }
            try runAgentPaneShow(
                page: page,
                surfaceOverride: surface,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat
            )
        case "list":
            let (workspace, rest) = parseOption(args, name: "--workspace")
            guard rest.isEmpty else {
                throw CLIError(message: "usage: cmux agent-pane list [--workspace <id|ref>]")
            }
            try runAgentPaneList(workspace: workspace, client: client, jsonOutput: jsonOutput, idFormat: idFormat)
        default:
            throw CLIError(message: "unknown cmux agent-pane subcommand '\(subcommand)' (expected show, list)")
        }
    }

    // MARK: - show

    private func runAgentPaneShow(
        page raw: String,
        surfaceOverride: String?,
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let url: URL
        switch AgentPaneCLIRules.page(raw, cwd: FileManager.default.currentDirectoryPath) {
        case .success(let page):
            url = page
        case .failure(let refusal):
            let reason: String
            switch refusal {
            case .badPage, .hostPortWithoutScheme: reason = "bad_page"
            case .noSuchFile: reason = "no_such_file"
            case .notFile: reason = "not_file"
            case .figmaAddress: reason = "figma_address"
            }
            throw agentPaneFailure(
                code: "invalid_params", reason: reason, message: AgentPaneCLIRules.message(for: refusal),
                jsonOutput: jsonOutput
            )
        }

        // `--surface` names the one caller. Without it, cm-73.45's shared lookup:
        // the live herdr-agent note, then `CMUX_SURFACE_ID`; never `identify`, which
        // answers from focus. `strict`, as for `figma open`: an Agent Pane opens beside a
        // terminal, so a `CMUX_SURFACE_ID` that is no surface at all fails here.
        let callers: [String]
        if let surfaceOverride {
            let surface = surfaceOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !surface.isEmpty else {
                throw agentPaneFailure(
                    code: "invalid_params", reason: nil, message: "--surface value is empty", jsonOutput: jsonOutput
                )
            }
            guard isUUID(surface) || isHandleRef(surface) || Int(surface) != nil else {
                throw agentPaneFailure(
                    code: "not_found", reason: nil, message: "no such surface: \(surface)", jsonOutput: jsonOutput
                )
            }
            guard let caller = try normalizeSurfaceHandle(surfaceOverride, client: client) else {
                throw agentPaneFailure(
                    code: "not_found", reason: nil, message: "no such surface: \(surfaceOverride)", jsonOutput: jsonOutput
                )
            }
            callers = [caller]
        } else {
            callers = try figmaCallerSurfaces(client: client, strict: true)
        }
        guard !callers.isEmpty else {
            throw agentPaneFailure(
                code: "invalid_params", reason: "no_caller", message: AgentPaneCLIRules.noCallerMessage,
                jsonOutput: jsonOutput
            )
        }

        // Unknown implicit refs fail parsing before lookup; retry them like `not_found`.
        var lastNotFound: AgentPaneCLIRules.SocketFailure?
        for caller in callers {
            switch try agentPaneCall(
                "agent_pane.show",
                ["url": url.absoluteString, "surface_id": caller],
                client: client
            ) {
            case .success(let payload):
                if jsonOutput {
                    print(jsonString(formatIDs(payload, mode: idFormat)))
                } else {
                    let surface = formatHandle(payload, kind: "surface", idFormat: idFormat) ?? "none"
                    let pane = formatHandle(payload, kind: "pane", idFormat: idFormat) ?? "none"
                    let workspace = formatHandle(payload, kind: "workspace", idFormat: idFormat) ?? "none"
                    let action = payload["action"] as? String ?? "unknown"
                    print("OK surface=\(surface) pane=\(pane) workspace=\(workspace) action=\(action)")
                }
                return
            case .failure(let failure) where surfaceOverride != nil && (
                failure.code == "not_found" || (
                    failure.code == "invalid_params" && failure.reason == "invalid_show_params"
                )
            ):
                let surface = surfaceOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? caller
                throw agentPaneFailure(
                    code: "not_found", reason: nil, message: "no such surface: \(surface)", jsonOutput: jsonOutput
                )
            case .failure(var failure) where failure.code == "not_found" || (
                failure.code == "invalid_params" && failure.reason == "invalid_show_params"
            ):
                failure.code = "not_found"
                if failure.reason == "invalid_show_params" { failure.reason = "not_found" }
                failure.surface = failure.surface ?? caller
                lastNotFound = failure
            case .failure(let failure):
                throw agentPaneFailure(failure, jsonOutput: jsonOutput)
            }
        }
        if let lastNotFound {
            throw agentPaneFailure(lastNotFound, jsonOutput: jsonOutput)
        }
    }

    // MARK: - list

    private func runAgentPaneList(
        workspace: String?,
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        var params: [String: Any] = [:]
        if let workspace {
            params["workspace_id"] = try normalizeWorkspaceHandle(workspace, client: client) ?? workspace
        }
        let payload: [String: Any]
        switch try agentPaneCall("agent_pane.list", params, client: client) {
        case .success(let answer): payload = answer
        case .failure(let failure): throw agentPaneFailure(failure, jsonOutput: jsonOutput)
        }
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        let panes = payload["agent_panes"] as? [[String: Any]] ?? []
        guard !panes.isEmpty else {
            print("(none)")
            return
        }
        for agentPane in panes {
            print(agentPaneListLine(agentPane, idFormat: idFormat))
        }
    }

    /// One `list` line. `owner` is the owning terminal's live surface, or `none`
    /// when no live terminal carries the stored one; never the stored stable id.
    func agentPaneListLine(_ agentPane: [String: Any], idFormat: CLIIDFormat) -> String {
        let surface = formatHandle(agentPane, kind: "surface", idFormat: idFormat) ?? "none"
        let pane = formatHandle(agentPane, kind: "pane", idFormat: idFormat) ?? "none"
        let workspace = formatHandle(agentPane, kind: "workspace", idFormat: idFormat) ?? "none"
        let owner = formatHandle(agentPane, kind: "owner_surface", idFormat: idFormat) ?? "none"
        let url = agentPane["url"] as? String ?? ""
        return "\(surface) pane=\(pane) workspace=\(workspace) owner=\(owner) url=\(url)"
    }

    // MARK: - Socket and errors

    /// One v2 request whose error keeps its `data`, which `sendV2`'s `CLIError`
    /// drops: the messages key on `data.reason` and name values from it.
    private func agentPaneCall(
        _ method: String,
        _ params: [String: Any],
        client: SocketClient
    ) throws -> Result<[String: Any], AgentPaneCLIRules.SocketFailure> {
        let request: [String: Any] = ["id": UUID().uuidString, "method": method, "params": params]
        guard JSONSerialization.isValidJSONObject(request),
              let line = String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8) else {
            throw CLIError(message: "Failed to encode v2 request")
        }
        let raw = try client.send(command: line)
        if raw.hasPrefix("ERROR:") { throw CLIError(message: raw) }
        guard let data = raw.data(using: .utf8),
              let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError(message: "Invalid v2 response: \(raw)")
        }
        if response["ok"] as? Bool == true {
            return .success(response["result"] as? [String: Any] ?? [:])
        }
        let error = response["error"] as? [String: Any] ?? [:]
        let details = error["data"] as? [String: Any] ?? [:]
        return .failure(AgentPaneCLIRules.SocketFailure(
            code: error["code"] as? String ?? "error",
            message: error["message"] as? String ?? "Unknown v2 error",
            reason: details["reason"] as? String,
            surface: details["surface"] as? String,
            type: details["type"] as? String,
            host: details["host"] as? String,
            url: details["url"] as? String,
            page: details["page"] as? String
        ))
    }

    private func agentPaneFailure(_ failure: AgentPaneCLIRules.SocketFailure, jsonOutput: Bool) -> CLIError {
        agentPaneFailure(
            code: failure.code,
            reason: failure.reason,
            message: AgentPaneCLIRules.message(for: failure),
            jsonOutput: jsonOutput
        )
    }

    /// The error to throw; under `--json` the code and reason also go to stdout
    /// as one object, so an agent can branch on them without reading the message.
    private func agentPaneFailure(code: String, reason: String?, message: String, jsonOutput: Bool) -> CLIError {
        if jsonOutput {
            var error: [String: Any] = ["code": code, "message": message]
            if let reason { error["reason"] = reason }
            print(jsonString(["ok": false, "error": error]))
        }
        return CLIError(message: message, v2Code: code)
    }

}
