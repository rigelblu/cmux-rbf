import Testing
@testable import CmuxAgentJournal

/// cm-128.5 (Scenario 75's data half): the reducer keeps whether an error was a typed usage limit, keyed by source, native
/// event and `detail` together, so the triangle's tooltip can say "hit its usage limit" and nothing else does.
@Suite("Usage limit flag")
struct AgentUsageLimitFlagTests {
    private let surface = "5E7A11AA-0000-4000-8000-000000000001"
    private let workspace = "5E7A11AA-0000-4000-8000-0000000000AA"

    private func event(_ sequence: Int64, _ kind: AgentJournalEventKind, source: String = "claude", native: String? = nil,
                       detail: String? = nil) -> AgentJournalEvent {
        AgentJournalEvent(sequence: sequence, committedAtMs: 1_000 + sequence,
            draft: AgentJournalEventDraft(eventId: "e\(sequence)", kind: kind, occurredAtMs: 1_000 + sequence, source: source,
                agentKey: source == "claude" ? "claude_code" : source, sessionId: "s1", workspaceId: workspace,
                surfaceId: surface, nativeEvent: native, detail: detail))
    }

    private func snapshot(_ events: [AgentJournalEvent]) -> AgentLifecycleSnapshot {
        var state = AgentLifecycleReducerState()
        for event in events { AgentLifecycleReducer().apply(event, to: &state) }
        return state.snapshot()
    }

    private func flagged(_ events: [AgentJournalEvent], key: String) -> Bool {
        snapshot(events).usageLimitAgentKeys[surface]?.contains(key) == true
    }

    @Test(arguments: [
        ("claude", "claude_code", "StopFailure", "rate_limit", true),
        ("claude", "claude_code", "StopFailure", "server_error", false),
        ("claude", "claude_code", "StopFailure", "max_output_tokens", false),
        ("codex", "codex", "Stop", "usage_limit_exceeded", true),
        ("codex", "codex", "task_complete", "usage_limit_exceeded", true),
        ("codex", "codex", "notification", "usage_limit_exceeded", false),
        ("claude", "claude_code", "Stop", "rate_limit", false),
        ("claude", "claude_code", "StopFailure", "usage_limit_exceeded", false),
        ("pi", "pi", "Stop", "rate_limit", false),
        ("pi", "pi", "Stop", "usage_limit_exceeded", false),
        ("cursor", "cursor", "shell-failed", "usage_limit_exceeded", false),
    ] as [(String, String, String, String, Bool)])
    func onlyTheTwoTypedProducersFlagAUsageLimit(_ row: (String, String, String, String, Bool)) {
        let (source, key, native, detail, expected) = row
        let events = [event(1, .turnStarted, source: source), event(2, .errorReported, source: source, native: native, detail: detail)]
        #expect(snapshot(events).phases[surface]?[key] == .error)
        #expect(flagged(events, key: key) == expected, "\(source) \(native) \(detail)")
    }

    @Test func anyOtherTransitionClearsIt() {
        let limit = [event(1, .turnStarted), event(2, .errorReported, native: "StopFailure", detail: "rate_limit")]
        #expect(flagged(limit, key: "claude_code"))
        #expect(!flagged(limit + [event(3, .turnStarted)], key: "claude_code"))
        #expect(!flagged(limit + [event(3, .turnCompleted)], key: "claude_code"))
        #expect(!flagged(limit + [event(3, .errorReported, native: "StopFailure", detail: "server_error")], key: "claude_code"))
    }

    @Test func theAssignmentCarriesItAndAFlagOnlyChangeIsAnAssignment() {
        let before = snapshot([event(1, .errorReported, native: "StopFailure", detail: "server_error")])
        let after = snapshot([event(1, .errorReported, native: "StopFailure", detail: "server_error"),
                              event(2, .errorReported, native: "StopFailure", detail: "rate_limit")])
        #expect(before.phases == after.phases)
        let moved = after.assignments(since: before)
        #expect(moved.count == 1 && moved.first?.usageLimit == true && moved.first?.phase == .error, "\(moved)")
    }

    @Test func startupReplayKeepsItOrTheLineReadsStoppedAfterEveryRelaunch() {
        let full = snapshot([event(1, .errorReported, native: "StopFailure", detail: "rate_limit")])
        let replayed = AgentJournalReplayPolicy().startupSnapshot(from: full)
        #expect(replayed.phases[surface]?["claude_code"] == .error)
        #expect(replayed.usageLimitAgentKeys[surface]?.contains("claude_code") == true)
    }
}
