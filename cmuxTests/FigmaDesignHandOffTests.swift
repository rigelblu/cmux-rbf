import CMUXAgentLaunch
import CmuxAgentChat
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct FigmaDesignHandOffTests {
    // Scenario 149: each row of the availability table.
    @Test func gateTable() {
        let now = Date(timeIntervalSince1970: 0)
        func available(_ state: ChatAgentState?, hook: Bool = true, event: WorkstreamEvent.HookEventName? = nil, observer: FigmaDesignHandOff.IdleObserver? = nil, kind: ChatAgentKind? = .claude) -> Bool {
            FigmaDesignHandOff.isAvailable(kind: kind, state: state, hasHookLifecycleState: hook, needsInputEvent: event, idleObserver: observer, sawHookEvent: false)
        }
        #expect(!available(nil, kind: nil))
        #expect(!available(.idle, kind: .other("pi")))
        #expect(!available(.working(since: now)))
        #expect(!available(.ended))
        for event: WorkstreamEvent.HookEventName in [.permissionRequest, .askUserQuestion, .exitPlanMode] {
            #expect(!available(.needsInput(since: now), event: event))
        }
        #expect(!available(.needsInput(since: now)))
        #expect(!available(.needsInput(since: now), event: .notification))
        #expect(available(.idle))
        #expect(available(.idle, kind: .codex))
        #expect(available(.idle, hook: false, observer: .transcript))
        #expect(!available(.idle, hook: false, observer: .process))
        #expect(!available(.idle, hook: false))
        #expect(!FigmaDesignHandOff.isAvailable(kind: .claude, state: .idle, hasHookLifecycleState: false, needsInputEvent: nil, idleObserver: .transcript))
    }

    // Scenario 151: exact, clipboard-free sequence through TextBoxSubmit.
    @MainActor @Test(arguments: FigmaDesignHandOff.Job.allCases)
    func deliverySequence(job: FigmaDesignHandOff.Job) {
        for kind: ChatAgentKind in [.claude, .codex] {
            let prefix = kind == .claude ? "/" : "$"
            let command = prefix + "design-in-figma-pane " + job.rawValue
            var expected: [TextBoxSubmit.DispatchEvent] = [.namedKey("escape"), .keyText("i")]
            for _ in 0..<20 {
                expected += [ .namedKey("ctrl+a"), .namedKey("ctrl+k"), .namedKey("ctrl+u"), .namedKey("backspace") ]
            }
            let submit = TextBoxSubmit.dispatchEvents(for: [.text(command)], terminalAgentContext: kind.sourceName, submit: true)
            #expect(submit == [.pasteText(command), .namedKey("return")])
            expected += submit
            #expect(FigmaDesignHandOff.dispatchEvents(for: job, kind: kind) == expected)
        }
        #expect(FigmaDesignHandOff.dispatchEvents(for: job, kind: .other("pi")).isEmpty)
    }
    @MainActor @Test func registryProvenance() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".agents"), withIntermediateDirectories: true)
        let registry = AgentChatSessionRegistry(hookStore: AgentChatHookSessionStore(homeDirectory: home))
        defer { try? FileManager.default.removeItem(at: home) }
        let surface = UUID().uuidString, session = UUID().uuidString
        func fire(_ event: WorkstreamEvent.HookEventName, type: String? = "idle_prompt") -> AgentChatSessionRecord {
            let extra = type.map { "{\"notification_type\":\"\($0)\"}" }
            return registry.noteHookEvent(WorkstreamEvent(sessionId: session, hookEventName: event, source: "claude", surfaceId: surface, extraFieldsJSON: extra))
        }
        #expect(!FigmaDesignHandOff.isAvailable(registry.liveSession(surfaceID: surface)))
        #expect(FigmaDesignHandOff.isAvailable(fire(.sessionStart)))
        #expect(!FigmaDesignHandOff.isAvailable(fire(.userPromptSubmit)))
        #expect(!FigmaDesignHandOff.isAvailable(fire(.preToolUse)))
        #expect(FigmaDesignHandOff.isAvailable(fire(.stop)))
        #expect(FigmaDesignHandOff.isAvailable(fire(.notification)))
        for prompt: WorkstreamEvent.HookEventName in [.permissionRequest, .askUserQuestion, .exitPlanMode] {
            _ = fire(.stop)
            #expect(!FigmaDesignHandOff.isAvailable(fire(prompt)))
            #expect(!FigmaDesignHandOff.isAvailable(fire(.notification)))
            #expect(registry.record(sessionID: session)?.needsInputEvent == prompt)
            _ = fire(.stop); _ = fire(.notification)
            #expect(!FigmaDesignHandOff.isAvailable(fire(prompt)))
            #expect(registry.record(sessionID: session)?.needsInputEvent == prompt)
        }
        _ = fire(.stop)
        #expect(registry.record(sessionID: session)?.needsInputEvent == nil)
        registry.update(sessionID: session) { $0.setProcessObservedIdle() }
        #expect(!FigmaDesignHandOff.isAvailable(registry.record(sessionID: session)))
        _ = fire(.userPromptSubmit)
        registry.noteAssistantTurnCompleted(sessionID: session, at: Date())
        #expect(!FigmaDesignHandOff.isAvailable(registry.record(sessionID: session)))
        #expect(registry.record(sessionID: session)?.idleObserver == .transcript)
        for type: String? in [nil, "permission_prompt", "elicitation_dialog", "auth_success"] {
            _ = fire(.stop)
            #expect(!FigmaDesignHandOff.isAvailable(fire(.notification, type: type)))
        }
        _ = fire(.stop)
        #expect(FigmaDesignHandOff.isAvailable(fire(.notification)))
        _ = fire(.sessionEnd)
        #expect(registry.liveSession(surfaceID: surface) == nil)
        #expect(!FigmaDesignHandOff.isAvailable(registry.currentOrMostRecentSession(surfaceID: surface)))
    }

    @MainActor @Test func liveTargetsAndStalePick() throws {
        let w = Workspace(); defer { w.teardownAllPanels() }
        let a = try #require(w.focusedPanelId)
        let b = try #require(w.newTerminalSplit(from: a, orientation: .horizontal)).id
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".agents"), withIntermediateDirectories: true)
        let registry = AgentChatSessionRegistry(hookStore: AgentChatHookSessionStore(homeDirectory: home))
        func fire(_ panel: UUID, _ event: WorkstreamEvent.HookEventName, source: String = "claude") {
            _ = registry.noteHookEvent(WorkstreamEvent(sessionId: panel.uuidString + "-" + source, hookEventName: event, source: source, surfaceId: panel.uuidString))
        }
        #expect(FigmaDesignHandOff.target(in: w, registry: registry) == nil)
        fire(a, .sessionStart); fire(b, .sessionStart, source: "codex")
        w.focusPanel(a)
        #expect(FigmaDesignHandOff.target(in: w, registry: registry) == .init(panelID: a, kind: .claude))
        fire(a, .sessionEnd)
        #expect(FigmaDesignHandOff.target(in: w, registry: registry) == .init(panelID: b, kind: .codex))
        var sent: [(UUID, [TextBoxSubmit.DispatchEvent])] = [], refusals: [String] = []
        #expect(FigmaDesignHandOff.send(.put, in: w, registry: registry, home: home, deliver: { sent.append(($0, $1)) }, logRefusal: { refusals.append($0) }))
        #expect(sent.count == 1)
        #expect(sent.first?.0 == b)
        #expect(sent.first?.1 == FigmaDesignHandOff.dispatchEvents(for: .put, kind: .codex))
        #expect(w.focusedPanelId == a)
        fire(b, .userPromptSubmit, source: "codex")
        #expect(!FigmaDesignHandOff.send(.new, in: w, registry: registry, home: home, deliver: { sent.append(($0, $1)) }, logRefusal: { refusals.append($0) }))
        #expect(sent.count == 1)
        #expect(refusals.count == 1)
        fire(b, .sessionEnd, source: "codex"); fire(a, .sessionStart, source: "pi")
        #expect(FigmaDesignHandOff.target(in: w, registry: registry) == nil)
    }

    @MainActor @Test func proseOnlyBatchCannotEnableHookDrivenTurn() throws {
        let registry = AgentChatSessionRegistry(hookStore: AgentChatHookSessionStore(homeDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let service = AgentChatTranscriptService(registry: registry, hasEventSubscribers: { false }, emitEventPayload: { _ in })
        let session = UUID().uuidString
        _ = registry.noteHookEvent(WorkstreamEvent(sessionId: session, hookEventName: .sessionStart, source: "claude"))
        _ = registry.noteHookEvent(WorkstreamEvent(sessionId: session, hookEventName: .userPromptSubmit, source: "claude"))
        let prose = ChatMessage(id: "p", seq: 1, role: .agent, timestamp: Date(), kind: .prose(ChatProse(text: "I will write the new view now.")))
        service.publishBatch(.init(appended: [prose], updated: [], discoveredTitle: nil), sessionID: session)
        #expect(!FigmaDesignHandOff.isAvailable(registry.record(sessionID: session)))
        // A truly hookless transcript may still establish idle.
        let hookless = AgentChatSessionRecord(sessionID: "hookless", agentKind: .codex, state: .working(since: Date()), lastActivityAt: Date())
        let r = AgentChatSessionRegistry(restoredRecords: [hookless])
        let s = AgentChatTranscriptService(registry: r, hasEventSubscribers: { false }, emitEventPayload: { _ in })
        s.publishBatch(.init(appended: [prose], updated: [], discoveredTitle: nil), sessionID: "hookless")
        #expect(FigmaDesignHandOff.isAvailable(r.record(sessionID: "hookless")))
    }

    @MainActor @Test func replyAndMenuUseTheSameStickyPane() throws {
        let w = Workspace(); defer { w.teardownAllPanels() }
        let a = try #require(w.focusedPanelId)
        let b = try #require(w.newTerminalSplit(from: a, orientation: .horizontal)).id
        let neutral = try #require(w.newTerminalSplit(from: b, orientation: .horizontal)).id
        let registry = AgentChatSessionRegistry()
        for id in [a, b] { _ = registry.noteHookEvent(WorkstreamEvent(sessionId: id.uuidString, hookEventName: .sessionStart, source: "claude", surfaceId: id.uuidString)) }
        let higher = [a, b].max { $0.uuidString < $1.uuidString }!
        let store = ReplyPanelStore()
        w.focusPanel(higher)
        #expect(store.resolveAgentPanelID(in: w, registry: registry) == higher)
        w.focusPanel(neutral)
        #expect(store.resolveAgentPanelID(in: w, registry: registry) == higher)
        #expect(FigmaDesignHandOff.target(in: w, registry: registry)?.panelID == higher)
    }

    @MainActor @Test func missingSkillRefusesSendButOwnSkillStillRuns() throws {
        let w = Workspace(); defer { w.teardownAllPanels() }
        let panel = try #require(w.focusedPanelId), home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".claude/skills")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        let registry = AgentChatSessionRegistry()
        _ = registry.noteHookEvent(WorkstreamEvent(sessionId: panel.uuidString, hookEventName: .sessionStart, source: "claude", surfaceId: panel.uuidString))
        var sent = 0, logs = 0
        let result = FigmaDesignHandOff.send(.put, in: w, registry: registry, home: home, deliver: { _, _ in sent += 1 }, logRefusal: { _ in logs += 1 })
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        #expect(!result); #expect(sent == 0); #expect(logs == 1)
        let dir = root.appendingPathComponent("design-in-figma-pane")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "My own skill".write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        #expect(FigmaDesignHandOff.send(.put, in: w, registry: registry, home: home, deliver: { _, _ in sent += 1 }, logRefusal: { _ in logs += 1 }))
        #expect(sent == 1)
        #expect(try String(contentsOf: dir.appendingPathComponent("SKILL.md"), encoding: .utf8) == "My own skill")
    }

    @MainActor @Test func typedNotificationDialogsLatchUntilTurnHook() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let registry = AgentChatSessionRegistry(hookStore: AgentChatHookSessionStore(homeDirectory: home))
        let session = UUID().uuidString
        func fire(_ event: WorkstreamEvent.HookEventName, type: String? = nil) -> AgentChatSessionRecord {
            let extra = type.map { "{\"notification_type\":\"\($0)\"}" }
            return registry.noteHookEvent(WorkstreamEvent(sessionId: session, hookEventName: event, source: "claude", extraFieldsJSON: extra))
        }
        _ = fire(.sessionStart)
        for dialog in ["permission_prompt", "elicitation_dialog"] {
            _ = fire(.stop)
            #expect(!FigmaDesignHandOff.isAvailable(fire(.notification, type: dialog)))
            for laterType: String? in ["idle_prompt", "auth_success", nil] {
                let record = fire(.notification, type: laterType)
                #expect(!FigmaDesignHandOff.isAvailable(record))
                #expect(record.notificationType == dialog)
            }
            _ = fire(.userPromptSubmit)
            #expect(registry.record(sessionID: session)?.needsInputEvent == nil)
            #expect(FigmaDesignHandOff.isAvailable(fire(.stop)))
            #expect(FigmaDesignHandOff.isAvailable(fire(.notification, type: "idle_prompt")))
        }
    }

    @MainActor @Test(arguments: [WorkstreamEvent.HookEventName.subagentStart, .subagentStop, .preCompact, .postCompact])
    func statePreservingHooksKeepTranscriptIdleProvenance(event: WorkstreamEvent.HookEventName) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let registry = AgentChatSessionRegistry(hookStore: AgentChatHookSessionStore(homeDirectory: home))
        let service = AgentChatTranscriptService(registry: registry, hasEventSubscribers: { false }, emitEventPayload: { _ in })
        let session = UUID().uuidString
        _ = registry.noteHookEvent(WorkstreamEvent(sessionId: session, hookEventName: .sessionStart, source: "claude"))
        _ = registry.noteHookEvent(WorkstreamEvent(sessionId: session, hookEventName: .userPromptSubmit, source: "claude"))
        let prose = ChatMessage(id: "p", seq: 1, role: .agent, timestamp: Date(), kind: .prose(ChatProse(text: "The parent is still working.")))
        service.publishBatch(.init(appended: [prose], updated: [], discoveredTitle: nil), sessionID: session)
        #expect(!FigmaDesignHandOff.isAvailable(registry.record(sessionID: session)))
        let record = registry.noteHookEvent(WorkstreamEvent(sessionId: session, hookEventName: event, source: "claude"))
        #expect(record.state == .idle)
        #expect(record.sawHookEvent)
        #expect(!record.hasHookLifecycleState)
        #expect(record.idleObserver == .transcript)
        #expect(!FigmaDesignHandOff.isAvailable(record))
    }

}
