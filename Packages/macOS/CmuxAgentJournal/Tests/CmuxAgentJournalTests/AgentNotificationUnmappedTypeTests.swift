import Foundation
import Testing
@testable import CmuxAgentJournal

/// cm-124.5: an unmapped notification type is delivered once ever and raises nothing; an id-less typed answer
/// retires only a wait a typed question raised. Promoted from the spike's test, on the `notification-type:` marker.
private let typedMarker = "notification-type:"

struct AgentNotificationUnmappedTypeTests {
    private let workspace = UUID().uuidString
    private let surface = UUID().uuidString

    private func event(_ sequence: Int64, _ kind: AgentJournalEventKind = .stateChanged, source: String = "claude",
                       nativeEvent: String? = "Notification", detail: String?, request: String? = nil,
                       notify: Bool = true) -> AgentJournalEvent {
        AgentJournalEvent(sequence: sequence, committedAtMs: 1000 + sequence,
            draft: AgentJournalEventDraft(eventId: "event-\(sequence)", kind: kind, occurredAtMs: sequence,
                source: source, agentKey: source, sessionId: "session", workspaceId: workspace, surfaceId: surface,
                nativeEvent: nativeEvent, detail: detail,
                attention: AgentAttentionContext(eventIdentity: nil, turnIdentity: "turn-1", requestIdentity: request,
                    notification: notify ? AgentJournalNotification(title: "Claude Code", subtitle: "",
                        body: "A worker wants to run Bash", category: "other") : nil)))
    }

    private func started(_ source: String = "claude") -> AgentNotificationReconciler {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, nativeEvent: "UserPromptSubmit", detail: nil,
                                   notify: false))
        return reconciler
    }

    // MARK: the first-ever ping

    @Test func anUnmappedTypeIsAcceptedOnceEverAndRaisesNoHand() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let dbURL = url.appendingPathComponent("journal.sqlite")
        var reconciler = started()
        let type = "worker_permission_prompt"
        let first = reconciler.apply(event(2, detail: typedMarker + type))
        #expect(first.disposition == .accepted)
        #expect(first.projectsLifecycle == false)
        let identity = try #require(first.identity)
        #expect(reconciler.openRequests(source: "claude", sessionId: "session").count == 0, "no hand")

        let store = try AgentJournalStore(databaseURL: dbURL)
        #expect(try store.claimNotification(identity: identity) == true, "first ever: delivered")
        let again = reconciler.apply(event(3, detail: typedMarker + type))
        #expect(again.identity == identity)
        #expect(try store.claimNotification(identity: identity) == false, "second time: deduplicated")
        store.close()

        var restarted = started()
        let reopened = try AgentJournalStore(databaseURL: dbURL)
        defer { reopened.close() }
        let afterRestart = restarted.apply(event(4, detail: typedMarker + type))
        #expect(afterRestart.identity == identity)
        #expect(try reopened.claimNotification(identity: identity) == false, "restart: still deduplicated")
    }

    @Test(arguments: ["Notification", "notification", nil] as [String?])
    func theMarkerAloneDecidesWhateverTheNativeEventSays(nativeEvent: String?) {
        var reconciler = started()
        let decision = reconciler.apply(event(2, nativeEvent: nativeEvent, detail: typedMarker + "cm124_grok_type"))
        #expect(decision.disposition == .accepted, "native event \(nativeEvent ?? "nil")")
        #expect(decision.identity != nil)
    }

    @Test func anotherTypeAndAnotherAgentEachGetTheirOwnFirstTime() throws {
        var claude = started()
        let first = try #require(claude.apply(event(2, detail: typedMarker + "worker_permission_prompt")).identity)
        let otherType = try #require(claude.apply(event(3, detail: typedMarker + "agent_needs_input")).identity)
        #expect(otherType != first)
        var kimi = started("kimi")
        let otherAgent = try #require(kimi.apply(event(2, source: "kimi",
            detail: typedMarker + "worker_permission_prompt")).identity)
        #expect(otherAgent != first)
    }

    @Test(arguments: [
        nil, "", typedMarker, "grok-internal-notification", "cursor-shell-completed", "stale-turn-corrected",
        "worker_permission_prompt",
    ] as [String?])
    func noMarkerOrAnEmptyTypeStaysAnObservation(detail: String?) {
        var reconciler = started()
        #expect(reconciler.apply(event(2, detail: detail)).disposition == .observation, "detail \(detail ?? "nil")")
    }

    @Test func aMarkedRowWithNoNotificationStaysAnObservation() {
        var reconciler = started()
        #expect(reconciler.apply(event(2, detail: typedMarker + "worker_permission_prompt", notify: false))
            .disposition == .observation)
    }

    // MARK: the form guard follows any typed question

    @Test func anIdLessTypedAnswerRetiresALoneWaitATypedQuestionRaised() {
        var reconciler = started()
        let raised = reconciler.apply(event(2, .questionRequested, detail: typedMarker + "x_asked"))
        #expect(raised.disposition == .accepted)
        #expect(reconciler.openRequests(source: "claude", sessionId: "session").count == 1)
        let resolved = reconciler.apply(event(3, .attentionResolved, detail: typedMarker + "x_answered", notify: false))
        #expect(!resolved.invalidatedCorrelationKeys.isEmpty, "the typed answer retired nothing")
        #expect(reconciler.openRequests(source: "claude", sessionId: "session").count == 0)
    }

    @Test func anIdLessTypedAnswerLeavesALoneApprovalWaitOpen() {
        var reconciler = started()
        let raised = reconciler.apply(event(2, .approvalRequested, detail: nil))
        #expect(raised.disposition == .accepted)
        let resolved = reconciler.apply(event(3, .attentionResolved, detail: typedMarker + "x_answered", notify: false))
        #expect(resolved.invalidatedCorrelationKeys.isEmpty, "a typed answer retired an approval")
        #expect(reconciler.openRequests(source: "claude", sessionId: "session").count == 1)
    }

    @Test func hermesIdLessApprovalResponseStillRetiresItsLoneApprovalWait() {
        var reconciler = started("hermes")
        let raised = reconciler.apply(event(2, .approvalRequested, source: "hermes", nativeEvent: "pre_approval_request",
                                            detail: nil))
        #expect(raised.disposition == .accepted)
        let resolved = reconciler.apply(event(3, .attentionResolved, source: "hermes",
            nativeEvent: "post_approval_response", detail: "approval-response", notify: false))
        #expect(!resolved.invalidatedCorrelationKeys.isEmpty, "Hermes's answer retired nothing")
        #expect(reconciler.openRequests(source: "hermes", sessionId: "session").count == 0)
    }

    @Test func aReplayedPreCm1245ElicitationPairWithNoPrefixStillCountsAsTyped() {
        var reconciler = started()
        _ = reconciler.apply(event(2, .questionRequested, detail: "elicitation_dialog"))
        let resolved = reconciler.apply(event(3, .attentionResolved, detail: "elicitation_response", notify: false))
        #expect(!resolved.invalidatedCorrelationKeys.isEmpty)
        #expect(reconciler.openRequests(source: "claude", sessionId: "session").count == 0)
    }

    @Test func aReplayedBareAnswerLeavesAnApprovalWaitOpen() {
        var reconciler = started()
        _ = reconciler.apply(event(2, .approvalRequested, detail: nil))
        let resolved = reconciler.apply(event(3, .attentionResolved, detail: "elicitation_response", notify: false))
        #expect(resolved.invalidatedCorrelationKeys.isEmpty)
        #expect(reconciler.openRequests(source: "claude", sessionId: "session").count == 1)
    }
}
