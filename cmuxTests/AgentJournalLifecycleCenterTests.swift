import CmuxAgentJournal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent journal lifecycle center")
struct AgentJournalLifecycleCenterTests {
    @MainActor
    @Test func aPreferenceFilteredMonitoringStopSpendsNoReceiptBeforeTheDrain() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            _ = try #require(AppDelegate.shared)
            let fixture = try AgentNotificationRegressionTests().makeFixture()
            defer { fixture.restore() }
            let defaults = UserDefaults.standard
            let key = "notificationAgentTurnComplete"
            let previous = defaults.object(forKey: key)
            defaults.set("whenIdle", forKey: key)
            defer {
                if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            fixture.source.surfaceResumeBindingsByPanelId[fixture.panelId] = SurfaceResumeBindingSnapshot(
                kind: "claude", command: "claude --resume session", checkpointId: "session", source: "agent-hook")
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let center = AgentJournalLifecycleCenter(databaseURL: root.appendingPathComponent("journal.sqlite"))
            let workspaceID = fixture.source.id.uuidString
            let surfaceID = fixture.panelId.uuidString
            var sequence: Int64 = 0
            func draft(_ kind: AgentJournalEventKind, pending: Bool = false, prompt: String? = nil) -> AgentJournalEventDraft {
                sequence += 1
                return AgentJournalEventDraft(kind: kind, occurredAtMs: sequence, source: "claude", agentKey: "claude_code",
                    sessionId: "session", workspaceId: workspaceID, surfaceId: surfaceID,
                    pendingWork: pending, attention: AgentAttentionContext(eventIdentity: prompt,
                        notification: kind == .turnCompleted ? AgentJournalNotification(title: "Claude", subtitle: "",
                            body: "Finished", category: "turn-complete") : nil))
            }
            _ = await center.admitNotification(draft(.turnStarted, prompt: "typed"))
            let watching = draft(.turnCompleted, pending: true)
            #expect(AgentJournalLifecycleCenter.notificationTargetIsCurrent(watching))
            #expect(!AgentNotificationDelivery().allows(category: .turnComplete, pending: true))
            #expect(!(await center.admitNotification(watching)))
            // Keep this completion on the same identity so an early claim would make it fail.
            #expect(await center.admitNotification(draft(.turnCompleted)))
            #expect(!(await center.admitNotification(draft(.turnCompleted))))
            _ = await center.admitNotification(draft(.turnStarted, prompt: "drain"))
            #expect(await center.admitNotification(draft(.turnCompleted)))
        }
    }

    /// (#cm-124.5) A new type's one ping is spent only when its banner can show. In a muted workspace, or in the pane
    /// focused in the frontmost cmux, it is held back unspent, and the next notification of that type is the one ping.
    @MainActor
    @Test(arguments: ["muted", "focused"])
    func aNewTypePingThatCannotShowSpendsNoReceipt(_ reason: String) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            _ = try #require(AppDelegate.shared)
            let fixture = try AgentNotificationRegressionTests().makeFixture()
            defer { fixture.restore() }
            fixture.source.surfaceResumeBindingsByPanelId[fixture.panelId] = SurfaceResumeBindingSnapshot(
                kind: "claude", command: "claude --resume session", checkpointId: "session", source: "agent-hook")
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let center = AgentJournalLifecycleCenter(databaseURL: root.appendingPathComponent("journal.sqlite"))
            let workspaceID = fixture.source.id.uuidString
            let surfaceID = fixture.panelId.uuidString
            var sequence: Int64 = 0
            func ping() -> AgentJournalEventDraft {
                sequence += 1
                return AgentJournalEventDraft(kind: .stateChanged, occurredAtMs: sequence, source: "claude",
                    agentKey: "claude_code", sessionId: "session", workspaceId: workspaceID,
                    surfaceId: surfaceID, detail: AgentNotificationTypeMarker.detail(forType: "cm124_held"),
                    attention: AgentAttentionContext(notification: AgentJournalNotification(
                        title: "Claude Code · New notification type: cm124_held", subtitle: "",
                        body: "A worker wants to run Bash", category: "other")))
            }
            @MainActor func holdBack(_ on: Bool) {
                if reason == "muted" { fixture.source.isMuted = on } else { AppFocusState.overrideIsFocused = on }
            }
            #expect(AgentJournalLifecycleCenter.notificationTargetIsCurrent(ping()))
            #expect(fixture.manager.selectedTabId == fixture.source.id)
            #expect(fixture.manager.focusedSurfaceId(for: fixture.source.id) == fixture.panelId)
            holdBack(true)
            defer { holdBack(false) }
            #expect(!(await center.admitNotification(ping())), "\(reason): a ping that cannot show spent the receipt")
            holdBack(false)
            #expect(await center.admitNotification(ping()), "\(reason): the first ping that can show was refused")
            #expect(!(await center.admitNotification(ping())), "\(reason): the type pinged twice")
        }
    }

    /// (#cm-124.5) Only a new type's ping is held back. Any other notification in the focused pane is still claimed,
    /// and the store's own focus rule keeps it inside cmux, as before. A typed question carries the same type marker
    /// as the new-type ping (`AgentEventTable.decide`), so it is the case that tells the two apart.
    @MainActor
    @Test(arguments: ["turn-complete", "typed-question"])
    func aFocusedPaneStillClaimsEveryOtherNotification(_ kind: String) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            _ = try #require(AppDelegate.shared)
            let fixture = try AgentNotificationRegressionTests().makeFixture()
            defer { fixture.restore() }
            let defaults = UserDefaults.standard
            let key = "notificationAgentTurnComplete"
            let previous = defaults.object(forKey: key)
            defaults.set("whenIdle", forKey: key)
            defer {
                if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            fixture.source.surfaceResumeBindingsByPanelId[fixture.panelId] = SurfaceResumeBindingSnapshot(
                kind: "claude", command: "claude --resume session", checkpointId: "session", source: "agent-hook")
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let center = AgentJournalLifecycleCenter(databaseURL: root.appendingPathComponent("journal.sqlite"))
            let workspaceID = fixture.source.id.uuidString
            let surfaceID = fixture.panelId.uuidString
            var sequence: Int64 = 0
            func draft(_ kind: AgentJournalEventKind, prompt: String? = nil, detail: String? = nil,
                       notification: AgentJournalNotification? = nil) -> AgentJournalEventDraft {
                sequence += 1
                return AgentJournalEventDraft(kind: kind, occurredAtMs: sequence, source: "claude", agentKey: "claude_code",
                    sessionId: "session", workspaceId: workspaceID, surfaceId: surfaceID, detail: detail,
                    attention: AgentAttentionContext(eventIdentity: prompt, notification: notification))
            }
            AppFocusState.overrideIsFocused = true
            #expect(fixture.manager.selectedTabId == fixture.source.id)
            #expect(fixture.manager.focusedSurfaceId(for: fixture.source.id) == fixture.panelId)
            _ = await center.admitNotification(draft(.turnStarted, prompt: "typed"))
            let other = kind == "turn-complete"
                ? draft(.turnCompleted, notification: AgentJournalNotification(title: "Claude", subtitle: "",
                    body: "Finished", category: "turn-complete"))
                : draft(.questionRequested, detail: AgentNotificationTypeMarker.detail(forType: "elicitation_dialog"),
                    notification: AgentJournalNotification(title: "Claude", subtitle: "", body: "Pick one", category: "other"))
            #expect(await center.admitNotification(other), "\(kind): the focused pane's notification was held back")
        }
    }

    @Test func appendCommandRejectsDeclaredMonitoringAtDecode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("journal.sqlite")
        let center = AgentJournalLifecycleCenter(databaseURL: url)
        let draft = AgentJournalEventDraft(kind: .stateChanged, occurredAtMs: 1, source: "claude", agentKey: "claude_code",
            sessionId: "session", workspaceId: UUID().uuidString, surfaceId: UUID().uuidString, declaredPhase: .monitoring)
        let json = try #require(String(data: JSONEncoder().encode(draft), encoding: .utf8))
        #expect(center.handleAppendCommand(json) == "ERROR: invalid agent journal event")
        let store = try AgentJournalStore(databaseURL: url)
        defer { store.close() }
        #expect(try store.headSequence() == 0)
    }

    @Test func appendCommandCommitsDurablyAndReplaysIdempotently() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-journal-center-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("journal.sqlite3", isDirectory: false)
        let center = AgentJournalLifecycleCenter(databaseURL: url)
        #expect(center.isAvailable)

        let draft = AgentJournalEventDraft(
            eventId: "event-1",
            kind: .turnStarted,
            occurredAtMs: 1,
            source: "claude",
            agentKey: "claude_code",
            sessionId: "session-1",
            workspaceId: UUID().uuidString,
            surfaceId: UUID().uuidString
        )
        let json = try #require(String(data: JSONEncoder().encode(draft), encoding: .utf8))
        #expect(center.handleAppendCommand(json) == "OK 1")
        // The reply is the durable receipt: a retry with the same event id
        // replays the original sequence instead of double-writing.
        #expect(center.handleAppendCommand(json) == "OK 1 replayed")
        #expect(center.handleAppendCommand("not json").hasPrefix("ERROR:"))
        #expect(center.handleAppendCommand("").hasPrefix("ERROR:"))

        // The committed event survives independent reopen (what startup
        // replay reads after a relaunch).
        let store = try AgentJournalStore(databaseURL: url)
        #expect(try store.headSequence() == 1)
        let events = try store.events(afterSequence: 0, limit: 10)
        #expect(events.count == 1)
        #expect(events.first?.draft == draft)
        store.close()
    }

    @Test func guessedTargetsAreRejectedAtAdmission() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-journal-center-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("journal.sqlite3", isDirectory: false)
        let center = AgentJournalLifecycleCenter(databaseURL: url)
        var draft = AgentJournalEventDraft(
            eventId: "event-guessed",
            kind: .approvalRequested,
            occurredAtMs: 1,
            source: "codex",
            agentKey: "codex",
            workspaceId: UUID().uuidString,
            surfaceId: UUID().uuidString
        )
        draft.unattributedReason = "target-unresolved"
        let json = try #require(String(data: JSONEncoder().encode(draft), encoding: .utf8))
        #expect(center.handleAppendCommand(json).hasPrefix("ERROR:"))
    }

    @Test func unavailableJournalReportsError() {
        let center = AgentJournalLifecycleCenter(databaseURL: nil)
        #expect(!center.isAvailable)
        #expect(center.handleAppendCommand("{}") == "ERROR: agent journal unavailable")
    }
    @Test func cancelledAndTerminatedAdmissionsAlwaysResume() async {
        let cancelled = AgentNotificationAdmissionWaiters()
        let id = UUID()
        cancelled.cancel(id)
        let cancelledResult = await withCheckedContinuation { continuation in
            cancelled.register(id, continuation: continuation)
        }
        #expect(cancelledResult == false)
        cancelled.forget(id)

        let terminated = AgentNotificationAdmissionWaiters()
        let result = await withCheckedContinuation { continuation in
            terminated.register(UUID(), continuation: continuation)
            terminated.finish()
        }
        #expect(result == false)
        let afterTermination = await withCheckedContinuation { continuation in
            terminated.register(UUID(), continuation: continuation)
        }
        #expect(afterTermination == false)
    }

    @Test func completedAdmissionCannotResumeTwice() async {
        let admissions = AgentNotificationAdmissionWaiters()
        let id = UUID()
        let result = await withCheckedContinuation { continuation in
            admissions.register(id, continuation: continuation)
            admissions.complete(id, accepted: true)
            admissions.complete(id, accepted: false)
            admissions.finish()
        }
        #expect(result == true)
    }
}
