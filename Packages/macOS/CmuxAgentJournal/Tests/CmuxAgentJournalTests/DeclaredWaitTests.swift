import Foundation
import Testing
@testable import CmuxAgentJournal

/// Verifies declared wait lifecycle semantics mapped through AgentSemanticEventMapper (#cm-124.2).
@Suite("Declared waits")
struct DeclaredWaitTests {
    private let workspace = UUID().uuidString
    private let surfaceA = UUID().uuidString
    private let surfaceB = UUID().uuidString
    private let mapper = AgentSemanticEventMapper()

    private func makeEvent(
        _ sequence: Int64,
        source: String = "pi",
        nativeEvent: String,
        request: String?,
        notify: Bool,
        surfaceID: String? = nil,
        turn: String? = "turn-1",
        body: String = "Agent is asking a question",
        category: String = "idle-reminder"
    ) -> AgentJournalEvent {
        let kind = mapper.kind(source: source, nativeEvent: nativeEvent, toolName: nil)
        return AgentJournalEvent(
            sequence: sequence,
            committedAtMs: 1000 + sequence,
            draft: AgentJournalEventDraft(
                eventId: "event-\(sequence)",
                kind: kind,
                occurredAtMs: sequence,
                source: source,
                agentKey: source,
                sessionId: "s1",
                workspaceId: workspace,
                surfaceId: surfaceID ?? surfaceA,
                pendingWork: false,
                nativeEvent: nativeEvent,
                attention: AgentAttentionContext(
                    eventIdentity: nil,
                    turnIdentity: turn,
                    requestIdentity: request,
                    notification: notify
                        ? AgentJournalNotification(
                            title: source,
                            subtitle: "",
                            body: body,
                            category: category
                        )
                        : nil
                )
            )
        )
    }

    @Test func declaredAsksRaiseHandAndRetireOnMatchingAnswer() {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(makeEvent(1, nativeEvent: "UserPromptSubmit", request: nil, notify: false))
        _ = reconciler.apply(makeEvent(2, nativeEvent: "QuestionAsked", request: "q-1", notify: true))
        _ = reconciler.apply(makeEvent(3, nativeEvent: "QuestionAsked", request: "q-2", notify: true))

        // Unrelated answer leaves both open.
        let eUnrelated = makeEvent(4, nativeEvent: "QuestionAnswered", request: "q-9", notify: false)
        _ = reconciler.apply(eUnrelated)
        #expect(reconciler.lifecycleEvent(eUnrelated).draft.declaredPhase == .needsInput)
        #expect(reconciler.openRequests(source: "pi", sessionId: "s1").identified == ["q-1", "q-2"])

        // Answer q-1 keeps q-2 open and hand up.
        let eFirst = makeEvent(5, nativeEvent: "QuestionAnswered", request: "q-1", notify: false)
        _ = reconciler.apply(eFirst)
        #expect(reconciler.lifecycleEvent(eFirst).draft.declaredPhase == .needsInput)
        #expect(reconciler.openRequests(source: "pi", sessionId: "s1").identified == ["q-2"])

        // Answer q-2 retires the last wait and clears the hand.
        let eSecond = makeEvent(6, nativeEvent: "QuestionAnswered", request: "q-2", notify: false)
        _ = reconciler.apply(eSecond)
        #expect(reconciler.lifecycleEvent(eSecond).draft.declaredPhase == .running)
        #expect(reconciler.openRequests(source: "pi", sessionId: "s1").identified.isEmpty)
    }

    @Test func declaredApprovalsRaiseHandAndRetireOnResolved() {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(makeEvent(1, source: "custom-harness", nativeEvent: "UserPromptSubmit", request: nil, notify: false))
        let ask = makeEvent(
            2,
            source: "custom-harness",
            nativeEvent: "ApprovalAsked",
            request: "a-1",
            notify: true,
            body: "Approval needed",
            category: "needs-permission"
        )
        let askDecision = reconciler.apply(ask)
        #expect(askDecision.disposition == .accepted)
        #expect(reconciler.lifecycleEvent(ask).draft.kind == .approvalRequested)
        #expect(reconciler.openRequests(source: "custom-harness", sessionId: "s1").identified == ["a-1"])

        let resolve = makeEvent(3, source: "custom-harness", nativeEvent: "ApprovalResolved", request: "a-1", notify: false)
        _ = reconciler.apply(resolve)
        #expect(reconciler.lifecycleEvent(resolve).draft.declaredPhase == .running)
        #expect(reconciler.openRequests(source: "custom-harness", sessionId: "s1").identified.isEmpty)
    }

    @Test func idLessAnswerDoesNotRetireMultipleDeclaredWaits() {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(makeEvent(1, nativeEvent: "UserPromptSubmit", request: nil, notify: false))
        _ = reconciler.apply(makeEvent(2, nativeEvent: "QuestionAsked", request: "q-1", notify: true))
        _ = reconciler.apply(makeEvent(3, nativeEvent: "QuestionAsked", request: "q-2", notify: true))

        let idLess = makeEvent(4, nativeEvent: "QuestionAnswered", request: nil, notify: false)
        _ = reconciler.apply(idLess)
        #expect(reconciler.lifecycleEvent(idLess).draft.declaredPhase == .needsInput)
        #expect(reconciler.openRequests(source: "pi", sessionId: "s1").identified == ["q-1", "q-2"])
    }

    @Test func crossSurfaceAnswerRetiresSessionWait() {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(makeEvent(1, nativeEvent: "UserPromptSubmit", request: nil, notify: false, surfaceID: surfaceA))
        _ = reconciler.apply(makeEvent(2, nativeEvent: "QuestionAsked", request: "q-1", notify: true, surfaceID: surfaceA))

        let resolveFromB = makeEvent(3, nativeEvent: "QuestionAnswered", request: "q-1", notify: false, surfaceID: surfaceB)
        _ = reconciler.apply(resolveFromB)
        #expect(reconciler.lifecycleEvent(resolveFromB).draft.declaredPhase == .running)
        #expect(reconciler.openRequests(source: "pi", sessionId: "s1").identified.isEmpty)
    }

    @Test func repeatedRequestIdIgnoredAsStale() {
        var reconciler = AgentNotificationReconciler()
        let instance = UUID().uuidString
        let firstId = "pi-form-s1-\(instance)-1"
        let freshId = "pi-form-s1-\(instance)-2"

        _ = reconciler.apply(makeEvent(1, nativeEvent: "UserPromptSubmit", request: nil, notify: false))
        _ = reconciler.apply(makeEvent(2, nativeEvent: "QuestionAsked", request: firstId, notify: true))
        _ = reconciler.apply(makeEvent(3, nativeEvent: "QuestionAnswered", request: firstId, notify: false))
        #expect(reconciler.openRequests(source: "pi", sessionId: "s1").identified.isEmpty)

        let repeatAsk = reconciler.apply(makeEvent(4, nativeEvent: "QuestionAsked", request: firstId, notify: true))
        #expect(repeatAsk.disposition == .stale)
        #expect(reconciler.openRequests(source: "pi", sessionId: "s1").identified.isEmpty)

        let freshAsk = reconciler.apply(makeEvent(5, nativeEvent: "QuestionAsked", request: freshId, notify: true))
        #expect(freshAsk.disposition == .accepted)
        #expect(reconciler.openRequests(source: "pi", sessionId: "s1").identified == [freshId])
    }
}
