import Bonsplit
import CMUXAgentLaunch
import CmuxAgentChat
import Foundation

// cmux-rbf #cm-73.17: one gate and delivery path for both menu jobs.
struct FigmaDesignHandOff {
    enum Job: String, CaseIterable { case put, new }
    typealias IdleObserver = AgentChatSessionRecord.IdleObserver

    static func isAvailable(kind: ChatAgentKind?, state: ChatAgentState?, hasHookLifecycleState: Bool, needsInputEvent: WorkstreamEvent.HookEventName?, idleObserver: IdleObserver?, sawHookEvent: Bool = true, notificationType: String? = nil) -> Bool {
        guard kind == .claude || kind == .codex, let state else { return false }
        switch state {
        case .idle:
            return hasHookLifecycleState || (idleObserver == .transcript && !sawHookEvent)
        case .needsInput:
            return needsInputEvent == .notification && notificationType == "idle_prompt"
        case .working, .ended:
            return false
        }
    }

    static func isAvailable(_ record: AgentChatSessionRecord?) -> Bool {
        isAvailable(kind: record?.agentKind, state: record?.state, hasHookLifecycleState: record?.hasHookLifecycleState ?? false, needsInputEvent: record?.needsInputEvent, idleObserver: record?.idleObserver, sawHookEvent: record?.sawHookEvent ?? true, notificationType: record?.notificationType)
    }

    @MainActor static func dispatchEvents(for job: Job, kind: ChatAgentKind) -> [TextBoxSubmit.DispatchEvent] {
        guard kind == .claude || kind == .codex else { return [] }
        var events: [TextBoxSubmit.DispatchEvent] = [.namedKey("escape"), .keyText("i")]
        for _ in 0..<20 {
            events += [.namedKey("ctrl+a"), .namedKey("ctrl+k"), .namedKey("ctrl+u"), .namedKey("backspace")]
        }
        let prefix = kind == .claude ? "/" : "$"
        let command = prefix + "design-in-figma-pane " + job.rawValue
        events += TextBoxSubmit.dispatchEvents(for: [.text(command)], terminalAgentContext: kind.sourceName, submit: true)
        return events
    }
    struct Target: Equatable {
        let panelID: UUID
        let kind: ChatAgentKind
    }

    @MainActor static func target(in workspace: Workspace, registry: AgentChatSessionRegistry) -> Target? {
        let sessions = workspace.panels.keys.compactMap { panelID -> (UUID, AgentChatSessionRecord)? in
            guard workspace.panels[panelID] is TerminalPanel,
                  let record = registry.liveSession(surfaceID: panelID.uuidString),
                  record.agentKind == .claude || record.agentKind == .codex else { return nil }
            return (panelID, record)
        }
        let candidates = sessions.map { $0.0 }
        guard let panelID = AgentPaneChoice.resolve(agentPanelIDs: candidates, focused: workspace.focusedPanelId, sticky: workspace.replyPanelAgentChoiceStore?.stickyPanelID, live: Set(candidates)),
              let record = sessions.first(where: { $0.0 == panelID })?.1,
              isAvailable(record) else { return nil }
        return Target(panelID: panelID, kind: record.agentKind)
    }

    @MainActor @discardableResult static func send(
        _ job: Job,
        in workspace: Workspace,
        registry: AgentChatSessionRegistry?,
        home: URL,
        deliver: ((UUID, [TextBoxSubmit.DispatchEvent]) -> Void)? = nil,
        logRefusal: ((String) -> Void)? = nil
    ) -> Bool {
        let logRefusal = logRefusal ?? Self.log
        // Read the live gate again at the pick, before writing or sending anything.
        guard let registry, let target = target(in: workspace, registry: registry),
              let panel = workspace.panels[target.panelID] as? TerminalPanel else {
            logRefusal("figma.designHandOff.refused reason=no-available-live-agent")
            return false
        }
        _ = FigmaDesignSkill.install(home: home)
        let root = target.kind == .claude ? ".claude/skills" : ".agents/skills"
        let skillFile = home.appendingPathComponent(root + "/design-in-figma-pane/SKILL.md")
        guard (try? Data(contentsOf: skillFile)) != nil else {
            logRefusal("figma.designHandOff.refused reason=no-readable-skill")
            return false
        }
        let events = dispatchEvents(for: job, kind: target.kind)
        if let deliver {
            deliver(target.panelID, events)
        } else {
            TextBoxSubmit.sendEvents(events, via: panel.surface)
        }
        return true
    }

    static func log(_ message: String) {
        #if DEBUG
        dlog(message)
        #endif
    }

}
