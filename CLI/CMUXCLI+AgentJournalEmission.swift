import CMUXAgentLaunch
import CmuxAgentJournal
import Foundation

extension CMUXCLI {
    /// Emits one semantic agent event into the app's append-only agent
    /// journal and blocks until the app acknowledges the durable commit.
    ///
    /// This is the structured replacement for the fire-and-forget
    /// `set_agent_lifecycle` verb: sidebar lifecycle is now a reduction over
    /// these events. Attribution is decided by the caller — an event that
    /// could not be attributed carries `unattributedReason` (and no target)
    /// so the app surfaces it as a diagnostic instead of guessing a pane.
    ///
    /// Delivery failures are never silent: they land in the dead-letter file
    /// and, when a session store and telemetry are provided, in the throttled
    /// hook-failure report channel.
    func emitAgentJournalEvent(
        client: SocketClient,
        kind: AgentJournalEventKind,
        source: String,
        agentKey: String,
        sessionId: String?,
        workspaceId: String?,
        surfaceId: String?,
        unattributedReason: String? = nil,
        isSubagent: Bool = false,
        pendingWork: Bool = false,
        nativeEvent: String?,
        declaredPhase: AgentLifecyclePhase? = nil,
        detail: String? = nil,
        attention: AgentAttentionContext? = nil,
        occurredAtMs: Int64? = nil,
        responseTimeout: TimeInterval? = nil,
        deadline: Date? = nil,
        store: ClaudeHookSessionStore? = nil,
        telemetry: CLISocketSentryTelemetry? = nil
    ) {
        // A malformed or partial target (empty string, non-UUID, missing
        // half) is never trusted: the event is journaled as an explicit
        // diagnostic instead of being rejected at admission or guessed.
        let validWorkspaceId = workspaceId.flatMap { UUID(uuidString: $0) != nil ? $0 : nil }
        let validSurfaceId = surfaceId.flatMap { UUID(uuidString: $0) != nil ? $0 : nil }
        let hasCompleteTarget = validWorkspaceId != nil && validSurfaceId != nil
        let resolvedReason: String?
        if let unattributedReason {
            resolvedReason = unattributedReason
        } else if !hasCompleteTarget {
            resolvedReason = "malformed-target"
        } else {
            resolvedReason = nil
        }
        let draft = AgentJournalEventDraft(
            kind: kind,
            occurredAtMs: occurredAtMs ?? Int64(Date().timeIntervalSince1970 * 1000),
            source: source,
            agentKey: agentKey,
            sessionId: sessionId,
            workspaceId: resolvedReason == nil ? validWorkspaceId : nil,
            surfaceId: resolvedReason == nil ? validSurfaceId : nil,
            unattributedReason: resolvedReason,
            isSubagent: isSubagent,
            pendingWork: pendingWork,
            nativeEvent: nativeEvent,
            declaredPhase: declaredPhase,
            detail: detail,
            attention: attention
        )
        if let problem = draft.validationProblem() {
            recordAgentJournalDeliveryFailure(
                draft: draft,
                message: "invalid draft: \(problem)",
                store: store,
                telemetry: telemetry,
                deadline: deadline
            )
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(draft),
              let json = String(data: data, encoding: .utf8) else {
            recordAgentJournalDeliveryFailure(
                draft: draft,
                message: "encode failed",
                store: store,
                telemetry: telemetry,
                deadline: deadline
            )
            return
        }
        do {
            let response: String
            if responseTimeout != nil || deadline != nil {
                response = try client.send(
                    command: "agent_journal_append \(json)",
                    responseTimeout: responseTimeout,
                    deadline: deadline
                )
            } else {
                response = try sendV1Command("agent_journal_append \(json)", client: client)
            }
            guard response.hasPrefix("OK") else {
                recordAgentJournalDeliveryFailure(
                    draft: draft,
                    message: response,
                    store: store,
                    telemetry: telemetry,
                    deadline: deadline
                )
                return
            }
        } catch {
            recordAgentJournalDeliveryFailure(
                draft: draft,
                message: String(describing: error),
                store: store,
                telemetry: telemetry,
                deadline: deadline
            )
        }
    }

    /// Resolves the semantic kind for a generic agent hook's `notification`
    /// action. Only a fact picks it (cm-128.5, Tom, grill Q32 and Q39): cmux's
    /// own decision (Cursor's approval), the mapper's verdict from the native
    /// event name (`StopFailure`, `pre_approval_request`, …), or a typed
    /// field (Amp's `agent_state`, Campfire's `campfire_event_type`, a
    /// `notification_type`). A message's words never choose a kind: what none
    /// of those names is `stateChanged`, an observation that raises and pings
    /// nothing.
    func agentJournalNotificationKind(
        def: AgentHookDef,
        nativeEvent: String?,
        toolName: String?,
        rawObject: [String: Any]?,
        cursorShellNeedsApproval: Bool,
        lifecycleRoute: AgentHookLifecycleReconciler.Route?
    ) -> AgentJournalEventKind {
        if cursorShellNeedsApproval { return .approvalRequested }
        if let nativeEvent, !nativeEvent.isEmpty {
            let mapped = AgentSemanticEventMapper().kind(source: def.name, nativeEvent: nativeEvent, toolName: toolName)
            if mapped != .stateChanged {
                return mapped
            }
        }
        if let kind = ampLifecycleJournalKind(route: lifecycleRoute, rawObject: rawObject) { return kind }
        if def.name == "campfire", let kind = campfireJournalKind(rawObject: rawObject) { return kind }
        return typedNotificationJournalKind(forNotificationType: typedNotificationType(in: rawObject))
    }

    /// An agent's typed `notification_type`; grok's permission prompt spells it `notificationType`. (cm-128.5)
    func typedNotificationType(in rawObject: [String: Any]?) -> String? {
        rawObject.flatMap { firstString(in: $0, keys: ["notification_type", "notificationType"]) }
    }

    /// The one typed table every agent's `Notification` goes through, Claude's own handler included. (cm-128.5)
    /// `agent_needs_input` stays unmapped until a live record shows which session it names (Tom, grill Q35), and a
    /// needs-you type Claude adds later stays silent until it is mapped here (Tom, grill Q32: "Drop it").
    func typedNotificationJournalKind(forNotificationType type: String?) -> AgentJournalEventKind {
        switch type {
        case "permission_prompt":
            return .approvalRequested
        case "idle_prompt":
            return .idleObserved
        case "elicitation_dialog", "elicitation_url_dialog":
            return .questionRequested
        case "elicitation_response", "elicitation_complete":
            return .attentionResolved
        default:
            return .stateChanged
        }
    }

    /// The types whose `detail` the reconciler needs: a form's raising event and the answer that may retire it. (cm-128.5)
    func notificationTypeDetail(_ type: String?, kind: AgentJournalEventKind) -> String? {
        guard let type, kind == .questionRequested || kind == .attentionResolved else { return nil }
        switch type {
        case "elicitation_dialog", "elicitation_url_dialog", "elicitation_response", "elicitation_complete":
            return type
        default:
            return nil
        }
    }

    /// Amp's lifecycle protocol, from its typed `agent_state` and `turn_outcome` (cm-128.5). The route already holds
    /// the decision: the notification action takes `awaiting-approval` and `needs-input`, the terminal one an error.
    func ampLifecycleJournalKind(
        route: AgentHookLifecycleReconciler.Route?,
        rawObject: [String: Any]?
    ) -> AgentJournalEventKind? {
        switch route {
        case .notification?:
            let state = (rawObject?["agent_state"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
            switch state {
            case "awaiting-approval": return .approvalRequested
            case "needs-input": return .questionRequested
            default: return nil
            }
        case .terminalNotification?:
            return .errorReported
        default:
            return nil
        }
    }

    /// Campfire's observer events, from the typed `campfire_event_type` (cm-128.5). `relay.error` is a connection
    /// failure and ends no turn, so it keeps its ping as a plain message and never enters the error row (Tom, grill Q39).
    func campfireJournalKind(rawObject: [String: Any]?) -> AgentJournalEventKind? {
        guard let rawObject else { return nil }
        switch campfireEventType(in: rawObject) {
        case "permission.asked", "join.requested": return .approvalRequested
        case "relay.error": return .messagePublished
        default: return nil
        }
    }

    /// Records a failed journal emission: appended to the bounded dead-letter
    /// file, warned on stderr, and (when possible) reported through the
    /// throttled hook-failure channel. Never silent.
    func recordAgentJournalDeliveryFailure(
        draft: AgentJournalEventDraft,
        message: String,
        store: ClaudeHookSessionStore?,
        telemetry: CLISocketSentryTelemetry?,
        deadline: Date? = nil
    ) {
        appendAgentJournalDeadLetter(draft: draft, message: message)
        cliWriteStderr("Warning: agent journal append failed (\(draft.kind.rawValue)): \(message)\n")
        if let store, let telemetry {
            reportAgentHookFailure(
                stage: .journalAppend,
                agentName: draft.source,
                sessionId: draft.sessionId ?? "",
                event: draft.nativeEvent ?? draft.kind.rawValue,
                error: nil,
                store: store,
                telemetry: telemetry,
                deadline: deadline
            )
        }
    }

    /// Dead-letter location: one JSON line per failed emission, bounded by
    /// truncation so an unreachable app cannot grow it without limit.
    static func agentJournalDeadLetterURL(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = env["CMUX_AGENT_JOURNAL_DEAD_LETTER_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("agent-journal-dead-letter.jsonl", isDirectory: false)
    }

    private func appendAgentJournalDeadLetter(draft: AgentJournalEventDraft, message: String) {
        let url = Self.agentJournalDeadLetterURL()
        let maximumBytes: UInt64 = 1_048_576
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size]) as? UInt64,
               size > maximumBytes {
                try? fileManager.removeItem(at: url)
            }
            var record: [String: Any] = [
                "at_ms": Int64(Date().timeIntervalSince1970 * 1000),
                "error": message,
            ]
            if let draftData = try? JSONEncoder().encode(draft),
               let draftObject = try? JSONSerialization.jsonObject(with: draftData) {
                record["event"] = draftObject
            }
            let lineData = try JSONSerialization.data(withJSONObject: record)
            guard var line = String(data: lineData, encoding: .utf8) else { return }
            line += "\n"
            // O_APPEND with one write(2) call keeps concurrent hook
            // processes' records intact (no read-modify-write interleaving).
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            _ = Array(line.utf8).withUnsafeBufferPointer { buffer in
                write(descriptor, buffer.baseAddress, buffer.count)
            }
        } catch {
            // stderr warning above already made the failure visible.
        }
    }
}
