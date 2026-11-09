/// Reduced lifecycle state of one agent session on one surface.
public struct AgentSessionLifecycleState: Sendable, Equatable {
    /// The session's current phase.
    public var phase: AgentLifecyclePhase
    /// Whether the session has ended (ended sessions no longer contribute to
    /// the surface's combined phase).
    public var ended: Bool
    /// Sequence of the newest event applied to this session; older or
    /// duplicate events are dropped, which makes the fold deterministic under
    /// re-delivery and permutation.
    public var lastSequence: Int64
    /// Producer timestamp of the newest applied event (ms since Unix epoch).
    public var lastOccurredAtMs: Int64
    /// Whether the error this session is at was a typed usage limit (cm-128.5). Set by an `errorReported` whose source,
    /// native event and `detail` all match one (`AgentLifecycleReducer.isUsageLimit`); cleared by any other transition.
    public var usageLimit: Bool

    /// Creates a session state.
    ///
    /// - Parameters:
    ///   - phase: The session's current phase.
    ///   - ended: Whether the session has ended.
    ///   - lastSequence: Sequence of the newest applied event.
    ///   - lastOccurredAtMs: Producer timestamp of the newest applied event.
    public init(
        phase: AgentLifecyclePhase,
        ended: Bool,
        lastSequence: Int64,
        lastOccurredAtMs: Int64,
        usageLimit: Bool = false
    ) {
        self.phase = phase
        self.ended = ended
        self.lastSequence = lastSequence
        self.lastOccurredAtMs = lastOccurredAtMs
        self.usageLimit = usageLimit
    }
}
