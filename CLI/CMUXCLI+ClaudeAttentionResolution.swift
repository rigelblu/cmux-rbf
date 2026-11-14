import CmuxAgentJournal
import Foundation

extension CMUXCLI {
    /// The tool input's fingerprint, taken where the hook ran and carried in the queued payload. Queue admission compacts a
    /// payload over its size limit, which drops most of `tool_input`, so the handler cannot fingerprint what is left.
    static let claudeToolInputFingerprintPayloadKey = "_cmux_tool_input_fingerprint"

    func captureClaudeToolInputFingerprint(_ rawPayload: String, agent: String, subcommand: String) -> String {
        guard agent == "claude", subcommand == "post-tool-use" else { return rawPayload }
        return injecting(Self.claudeToolInputFingerprintPayloadKey, { object in
            guard let toolName = (object["tool_name"] ?? object["toolName"]) as? String,
                  let input = object["tool_input"] ?? object["toolInput"] else { return nil }
            return ClaudePendingPermission.fingerprint(toolName: toolName, input: input)
        }, into: rawPayload)
    }

    func runClaudePostToolUseHook(client: SocketClient, telemetry: CLISocketSentryTelemetry,
                                 parsedInput: ClaudeHookParsedInput, sessionStore: ClaudeHookSessionStore,
                                 routing: ClaudeHookRoutingContext) throws {
        defer { printClaudeHookAck() }
        guard let sessionId = parsedInput.sessionId,
              let raw = parsedInput.rawObject,
              let toolName = firstString(in: raw, keys: ["tool_name", "toolName"]),
              let fingerprint = (raw[Self.claudeToolInputFingerprintPayloadKey] as? String)
                  ?? (raw["tool_input"] ?? raw["toolInput"]).flatMap({ ClaudePendingPermission.fingerprint(toolName: toolName, input: $0) }),
              let pending = try sessionStore.consumeClaudePermission(sessionId: sessionId, toolName: toolName,
                  inputFingerprint: fingerprint, agentId: firstString(in: raw, keys: ["agent_id", "agentId"])) else { return }
        let mapped = try sessionStore.lookup(sessionId: sessionId)
        guard let target = try resolveClaudeHookDeliveryTarget(mappedSession: mapped, routing: routing, client: client),
              target.isAuthoritative else { return }
        emitAgentJournalEvent(client: client, kind: .attentionResolved, source: "claude",
            agentKey: Self.claudeCodeStatusKey, sessionId: sessionId,
            workspaceId: target.workspaceId, surfaceId: target.surfaceId,
            pendingWork: false, nativeEvent: "PostToolUse",
            attention: AgentAttentionContext(turnIdentity: parsedInput.turnId, requestIdentity: pending.requestId),
            occurredAtMs: Self.semanticOccurredAtMs(raw), store: sessionStore, telemetry: telemetry)
    }
}
