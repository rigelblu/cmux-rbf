import CMUXAgentLaunch // cmux-rbf #cm-73.17
import CmuxAgentChat
import Foundation

/// One chat-capable agent session the Mac knows about: hook-derived
/// identity, terminal binding, transcript location, and live state.
struct AgentChatSessionRecord: Sendable {
    /// The agent's own session identifier (hook `session_id`, unprefixed).
    let sessionID: String

    /// Which agent runtime owns the session.
    let agentKind: ChatAgentKind

    /// Owning cmux workspace UUID string, when known.
    var workspaceID: String?

    /// Hosting cmux terminal surface UUID string, when known. Required for
    /// the send/interrupt path.
    var surfaceID: String?

    /// The session's working directory, when known.
    var workingDirectory: String?

    /// Absolute transcript JSONL path, when resolved.
    var transcriptPath: String?

    /// Live activity state derived from hook events.
    // cmux-rbf #cm-73.17: clear a pending-input reason on every exit, including process death.
    var state: ChatAgentState {
        didSet {
            if case .needsInput = state {} else {
                needsInputEvent = nil
                notificationType = nil
            }
            if state != .idle { idleObserver = nil }
        }
    }

    /// Whether `state` has been established by the agent's hook lifecycle.
    /// Process-table discovery proves presence and identity, but not idleness.
    var hasHookLifecycleState: Bool = false

    // cmux-rbf #cm-73.17: distinguish prompt/reminder and transcript/process idle.
    var needsInputEvent: WorkstreamEvent.HookEventName? = nil
    var notificationType: String? = nil
    var sawHookEvent = false
    enum IdleObserver { case process, transcript }
    var idleObserver: IdleObserver? = nil

    /// When the record entered `.ended`. Best-effort process observations sampled
    /// before this point must not revive it after a hook or exit watcher ended it.
    var endedAt: Date?

    /// Timestamp of the most recent hook or transcript activity.
    var lastActivityAt: Date

    /// Child agent runs (Claude `Task` tool spawns, Codex subagent runs)
    /// observed under this session, newest last. Bounded; settled children
    /// are pruned after ``AgentChatChildRun/settledRetention``.
    var children: [AgentChatChildRun] = []

    /// Conversation title (first user prompt), filled by the tailer.
    var title: String?

    /// The agent process id, for liveness sweeps.
    var pid: Int?

    /// Real hook-store key, when this record is surfaced under a pending alias.
    var hookStoreSessionID: String?

    /// Monotonic revision stamped by the registry on every change, so clients
    /// can reconcile best-effort pushes against authoritative pulls. Owned by
    /// the registry; mutators do not set it directly.
    var version: Int = 0

    var hookStoreLookupSessionID: String { hookStoreSessionID ?? sessionID }

    mutating func rememberHookStoreSessionID(_ id: String) {
        if id != sessionID { hookStoreSessionID = id }
    }

    // cmux-rbf #cm-73.17: prompts latch until a turn hook clears them; reminders never dismiss dialogs.
    mutating func setHookLifecycleState(_ nextState: ChatAgentState, event: WorkstreamEvent.HookEventName? = nil, notificationType: String? = nil) {
        sawHookEvent = true
        // cmux-rbf #cm-73.17: telemetry keeps the parent's state and its provenance.
        switch event {
        case .subagentStart, .subagentStop, .preCompact, .postCompact:
            return
        default:
            break
        }
        state = nextState
        hasHookLifecycleState = true
        idleObserver = nil
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

    mutating func setProcessObservedIdle() {
        sawHookEvent = sawHookEvent || hasHookLifecycleState // cmux-rbf #cm-73.17
        state = .idle
        hasHookLifecycleState = false
        idleObserver = .process // cmux-rbf #cm-73.17
    }

    mutating func setTranscriptObservedIdle() {
        sawHookEvent = sawHookEvent || hasHookLifecycleState // cmux-rbf #cm-73.17
        state = .idle
        hasHookLifecycleState = false
        idleObserver = .transcript // cmux-rbf #cm-73.17
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
    mutating func adoptBindings(
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
    mutating func adoptMissingBindings(
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
    var descriptor: ChatSessionDescriptor {
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
struct AgentChatChildRun: Sendable, Equatable {
    /// Correlation id: the hook `requestId` when present, else synthesized.
    let id: String
    /// Human label: the Task description / subagent type, when the payload
    /// carried one.
    var label: String?
    let startedAt: Date
    var endedAt: Date?

    var isRunning: Bool { endedAt == nil }

    /// How long a settled child stays in the record before pruning.
    static let settledRetention: TimeInterval = 15 * 60
    /// Bound on children kept per session (oldest settled dropped first).
    static let capacity = 16
}
