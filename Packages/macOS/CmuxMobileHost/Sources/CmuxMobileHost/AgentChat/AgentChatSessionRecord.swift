public import CMUXAgentLaunch // cmux-rbf #cm-73.17
public import CmuxAgentChat
public import Foundation

/// One chat-capable agent session the Mac knows about: hook-derived
/// identity, terminal binding, transcript location, and live state.
public struct AgentChatSessionRecord: Sendable {
    /// The agent's own session identifier (hook `session_id`, unprefixed).
    public let sessionID: String

    /// Which agent runtime owns the session.
    public let agentKind: ChatAgentKind

    /// Owning cmux workspace UUID string, when known.
    public var workspaceID: String?

    /// Hosting cmux terminal surface UUID string, when known. Required for
    /// the send/interrupt path.
    public var surfaceID: String?

    /// The session's working directory, when known.
    public var workingDirectory: String?

    /// Absolute transcript JSONL path, when resolved.
    public var transcriptPath: String?

    /// Live activity state derived from hook events.
    // cmux-rbf #cm-73.17: clear a pending-input reason on every exit, including process death.
    public var state: ChatAgentState {
        didSet {
            if case .needsInput = state {} else {
                needsInputEvent = nil
                notificationType = nil
            }
            if state != .idle { idleObserver = nil; idleEntryEvent = nil } // cmux-rbf #cm-73.24
        }
    }

    /// Whether `state` has been established by the agent's hook lifecycle.
    /// Process-table discovery proves presence and identity, but not idleness.
    public var hasHookLifecycleState: Bool = false

    // cmux-rbf #cm-73.17: distinguish prompt/reminder and transcript/process idle.
    public var needsInputEvent: WorkstreamEvent.HookEventName? = nil
    public var notificationType: String? = nil
    // cmux-rbf #cm-73.24: the hook event that set `.idle` (`.stop` or `.sessionStart`); nil when idle came from watching the process or transcript.
    public var idleEntryEvent: WorkstreamEvent.HookEventName? = nil
    public var sawHookEvent = false
    public enum IdleObserver: Sendable { case process, transcript }
    public var idleObserver: IdleObserver? = nil

    /// When the record entered `.ended`. Best-effort process observations sampled
    /// before this point must not revive it after a hook or exit watcher ended it.
    public var endedAt: Date?

    /// Timestamp of the most recent hook or transcript activity.
    public var lastActivityAt: Date

    /// Child agent runs (Claude `Task` tool spawns, Codex subagent runs)
    /// observed under this session, newest last. Bounded; settled children
    /// are pruned after ``AgentChatChildRun/settledRetention``.
    public var children: [AgentChatChildRun] = []

    /// Conversation title (first user prompt), filled by the tailer.
    public var title: String?

    /// The agent process id, for liveness sweeps.
    public var pid: Int?

    /// Real hook-store key, when this record is surfaced under a pending alias.
    public var hookStoreSessionID: String?

    /// Monotonic revision stamped by the registry on every change, so clients
    /// can reconcile best-effort pushes against authoritative pulls. Owned by
    /// the registry; mutators do not set it directly.
    public var version: Int = 0

    public init(
        sessionID: String,
        agentKind: ChatAgentKind,
        workspaceID: String? = nil,
        surfaceID: String? = nil,
        workingDirectory: String? = nil,
        transcriptPath: String? = nil,
        state: ChatAgentState,
        hasHookLifecycleState: Bool = false,
        endedAt: Date? = nil,
        lastActivityAt: Date,
        children: [AgentChatChildRun] = [],
        title: String? = nil,
        pid: Int? = nil,
        hookStoreSessionID: String? = nil,
        version: Int = 0
    ) {
        self.sessionID = sessionID
        self.agentKind = agentKind
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.workingDirectory = workingDirectory
        self.transcriptPath = transcriptPath
        self.state = state
        self.hasHookLifecycleState = hasHookLifecycleState
        self.endedAt = endedAt
        self.lastActivityAt = lastActivityAt
        self.children = children
        self.title = title
        self.pid = pid
        self.hookStoreSessionID = hookStoreSessionID
        self.version = version
    }

    public var hookStoreLookupSessionID: String { hookStoreSessionID ?? sessionID }

    public mutating func rememberHookStoreSessionID(_ id: String) {
        if id != sessionID { hookStoreSessionID = id }
    }

    // cmux-rbf #cm-73.17: prompts latch until a turn hook clears them; reminders never dismiss dialogs.
    public mutating func setHookLifecycleState(_ nextState: ChatAgentState, event: WorkstreamEvent.HookEventName? = nil, notificationType: String? = nil, hasAgentID: Bool = false) {
        sawHookEvent = true
        // cmux-rbf #cm-73.17: telemetry keeps the parent's state and its provenance.
        switch event {
        case .subagentStart, .subagentStop, .preCompact, .postCompact:
            return
        default:
            break
        }
        // cmux-rbf #cm-73.24: a helper's tool event (`agent_id`) after the turn's `Stop` or its idle reminder is not the main thread working again.
        if agentKind == .claude, hasAgentID,
           event == .preToolUse || event == .postToolUse || event == .postToolUseFailure || event == .todoWrite {
            let waitingAfterStop = state == .idle && idleEntryEvent == .stop
            let waitingOnReminder: Bool
            if case .needsInput = state {
                waitingOnReminder = needsInputEvent == .notification && self.notificationType == "idle_prompt"
            } else {
                waitingOnReminder = false
            }
            if waitingAfterStop || waitingOnReminder { return }
        }
        state = nextState
        hasHookLifecycleState = true
        idleObserver = nil
        idleEntryEvent = nextState == .idle && (event == .stop || event == .sessionStart) ? event : nil // cmux-rbf #cm-73.24
        if case .needsInput = nextState {
            switch event {
            case .permissionRequest, .askUserQuestion, .exitPlanMode:
                needsInputEvent = event
                self.notificationType = nil
            case .notification:
                let notificationIsPrompt = self.notificationType == "permission_prompt" || self.notificationType == "elicitation_dialog"
                if needsInputEvent == nil || (needsInputEvent == .notification && !notificationIsPrompt) {
                    needsInputEvent = event
                    self.notificationType = notificationType
                }
            default:
                break
            }
        }
    }

    public mutating func setProcessObservedIdle() {
        sawHookEvent = sawHookEvent || hasHookLifecycleState // cmux-rbf #cm-73.17
        state = .idle
        hasHookLifecycleState = false
        idleObserver = .process // cmux-rbf #cm-73.17
        idleEntryEvent = nil // cmux-rbf #cm-73.24
    }

    public mutating func setTranscriptObservedIdle() {
        sawHookEvent = sawHookEvent || hasHookLifecycleState // cmux-rbf #cm-73.17
        state = .idle
        hasHookLifecycleState = false
        idleObserver = .transcript // cmux-rbf #cm-73.17
        idleEntryEvent = nil // cmux-rbf #cm-73.24
    }

    /// Adopts terminal/transcript bindings from a hook-store entry. The
    /// store is rewritten by every hook event, so its non-nil fields are
    /// fresher than the record's (panel UUIDs change across app
    /// relaunches; never keep a stale binding over a present one).
    ///
    /// - Parameter entry: The store entry to adopt from.
    /// - Parameters:
    ///   - entry: The store entry to adopt from.
    ///   - includingPID: Whether to adopt the process id. Failure-driven
    ///     refreshes pass `false`: the store can lag a SessionStart by one
    ///     write, and adopting a dead pid there would let the liveness
    ///     sweep end a live resumed session.
    public mutating func adoptBindings(
        from entry: AgentChatHookSessionStore.Entry,
        includingPID: Bool = true
    ) {
        rememberHookStoreSessionID(entry.sessionID)
        surfaceID = entry.surfaceID ?? surfaceID
        workspaceID = entry.workspaceID ?? workspaceID
        transcriptPath = entry.transcriptPath ?? transcriptPath
        workingDirectory = entry.workingDirectory ?? workingDirectory
        if includingPID {
            pid = entry.pid ?? pid
        }
    }

    /// Fills gaps from the hook store without replacing live cmux bindings.
    public mutating func adoptMissingBindings(
        from entry: AgentChatHookSessionStore.Entry,
        includingPID: Bool = true
    ) {
        rememberHookStoreSessionID(entry.sessionID)
        if surfaceID == nil { surfaceID = entry.surfaceID }
        if workspaceID == nil { workspaceID = entry.workspaceID }
        if transcriptPath == nil { transcriptPath = entry.transcriptPath }
        if workingDirectory == nil { workingDirectory = entry.workingDirectory }
        if includingPID, pid == nil { pid = entry.pid }
    }

    /// The wire descriptor for this record.
    public var descriptor: ChatSessionDescriptor {
        ChatSessionDescriptor(
            id: sessionID,
            agentKind: agentKind,
            title: title,
            workspaceID: workspaceID,
            terminalID: surfaceID,
            workingDirectory: workingDirectory,
            state: state,
            lastActivityAt: lastActivityAt,
            version: version
        )
    }
}

/// One child agent run under a parent session: a Claude `Task` tool spawn or
/// a Codex subagent run, tracked purely from the parent's hook events (the
/// child has no hooks of its own).
public struct AgentChatChildRun: Sendable, Equatable {
    /// Correlation id: the hook `requestId` when present, else synthesized.
    public let id: String
    /// Human label: the Task description / subagent type, when the payload
    /// carried one.
    public var label: String?
    public let startedAt: Date
    public var endedAt: Date?

    public init(id: String, label: String? = nil, startedAt: Date, endedAt: Date? = nil) {
        self.id = id
        self.label = label
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    public var isRunning: Bool { endedAt == nil }

    /// How long a settled child stays in the record before pruning.
    public static let settledRetention: TimeInterval = 15 * 60
    /// Bound on children kept per session (oldest settled dropped first).
    public static let capacity = 16
}
