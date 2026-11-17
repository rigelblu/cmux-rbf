import Foundation
import Testing
@testable import CmuxAgentJournal

/// cm-124.5: the journal's record of notification types no row maps, which `cmux config doctor` lists.
struct AgentUnmappedNotificationTypesTests {
    private let marker = AgentNotificationTypeMarker.prefix

    private func withStore(_ body: (AgentJournalStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("unmapped-types-\(UUID().uuidString)", isDirectory: true)
        let store = try AgentJournalStore(databaseURL: directory.appendingPathComponent("journal.sqlite3"))
        defer {
            store.close()
            try? FileManager.default.removeItem(at: directory)
        }
        try body(store)
    }

    private func draft(
        _ kind: AgentJournalEventKind = .stateChanged, source: String = "claude", detail: String?,
        banner: String? = nil, at occurredAtMs: Int64 = 1_000
    ) -> AgentJournalEventDraft {
        AgentJournalEventDraft(
            kind: kind, occurredAtMs: occurredAtMs, source: source, agentKey: source, sessionId: "session",
            workspaceId: UUID().uuidString, surfaceId: UUID().uuidString, nativeEvent: "Notification", detail: detail,
            attention: AgentAttentionContext(notification: banner.map {
                AgentJournalNotification(title: "Claude Code", subtitle: "", body: $0, category: "other")
            }))
    }

    /// What one hook event journals when it has a body: the CLI's emit row and the banner row.
    private func hookEvent(_ store: AgentJournalStore, type: String, source: String = "claude", at ms: Int64 = 1_000,
                           message: String = "A worker wants to run Bash") throws {
        let committed = Date(timeIntervalSince1970: Double(ms) / 1000)
        _ = try store.append(draft(source: source, detail: marker + type, at: ms), committedAt: committed)
        _ = try store.append(draft(source: source, detail: marker + type, banner: message, at: ms), committedAt: committed)
    }

    @Test func aHookEventWithABodyCountsOnceNotTwice() throws {
        try withStore { store in
            try hookEvent(store, type: "worker_permission_prompt")
            try hookEvent(store, type: "worker_permission_prompt")
            try hookEvent(store, type: "worker_permission_prompt")
            let found = try store.unmappedNotificationTypes()
            #expect(found.count == 1)
            #expect(found.first?.agent == "claude")
            #expect(found.first?.type == "worker_permission_prompt")
            #expect(found.first?.count == 3, "six rows, three notifications")
        }
    }

    @Test func aHookEventWithNoBodyIsOneRowAndStillCounts() throws {
        try withStore { store in
            _ = try store.append(draft(detail: marker + "agent_needs_input"))
            #expect(try store.unmappedNotificationTypes().first?.count == 1)
        }
    }

    @Test func groupsByAgentAndTypeAndListsNewestFirst() throws {
        try withStore { store in
            try hookEvent(store, type: "a_type", at: 1_000)
            try hookEvent(store, type: "b_type", source: "kimi", at: 3_000)
            try hookEvent(store, type: "a_type", source: "kimi", at: 2_000)
            let found = try store.unmappedNotificationTypes()
            #expect(found.map { "\($0.agent) \($0.type)" } == ["kimi b_type", "kimi a_type", "claude a_type"])
            #expect(found.allSatisfy { $0.count == 1 })
        }
    }

    @Test func lastSeenIsWhenTheLastOneWasJournaled() throws {
        try withStore { store in
            try hookEvent(store, type: "a_type", at: 1_700_000_000_123)
            #expect(try store.unmappedNotificationTypes().first?.lastSeenMs == 1_700_000_000_123)
        }
    }

    @Test(arguments: [nil, "", "notification-type:", "grok-internal-notification", "worker_permission_prompt",
                      "cursor-shell-completed"] as [String?])
    func rowsWithNoMarkerOrNoTypeAreNotListed(detail: String?) throws {
        try withStore { store in
            _ = try store.append(draft(detail: detail))
            _ = try store.append(draft(detail: detail, banner: "A message"))
            #expect(try store.unmappedNotificationTypes().isEmpty)
        }
    }

    @Test(arguments: [AgentJournalEventKind.questionRequested, .attentionResolved])
    func aTypedQuestionOrAnswerIsMappedNotUnmapped(kind: AgentJournalEventKind) throws {
        try withStore { store in
            _ = try store.append(draft(kind, detail: marker + "x_type"))
            #expect(try store.unmappedNotificationTypes().isEmpty)
        }
    }

    @Test func aTypeARowMapsLeavesTheListAndBuiltInIgnoresNeverEnterIt() throws {
        try withStore { store in
            try hookEvent(store, type: "worker_permission_prompt")
            try hookEvent(store, type: "push_notification")
            let recorded = try store.unmappedNotificationTypes()
            #expect(recorded.count == 2)
            #expect(AgentEventTable.builtIn.unmapped(recorded).map(\.type) == ["worker_permission_prompt"])
            let mapped = AgentEventTable(userRows: [.init(agent: "claude", notification: "worker_permission_prompt", means: .approval)])
            #expect(mapped.unmapped(recorded).isEmpty)
            let otherAgent = AgentEventTable(userRows: [.init(agent: "kimi", notification: "worker_permission_prompt", means: .approval)])
            #expect(otherAgent.unmapped(recorded).map(\.type) == ["worker_permission_prompt"], "a row for kimi maps nothing for claude")
        }
    }

    @Test func theRecordCarriesNoMessageText() throws {
        try withStore { store in
            try hookEvent(store, type: "worker_permission_prompt", message: "SECRET-BODY-TEXT")
            let found = try store.unmappedNotificationTypes()
            #expect(!"\(found)".contains("SECRET-BODY-TEXT"))
        }
    }
}
