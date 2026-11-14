import CmuxAgentJournal
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class AgentJournalLivenessTestFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("c128-life-\(UUID())")
    let workspace = UUID()
    let surface = UUID()
    let session = UUID().uuidString
    let source: String
    let key: String
    let store: AgentJournalStore
    var databaseURL: URL { directory.appendingPathComponent("journal.sqlite3") }
    var resolver: AgentSessionLivenessResolver { AgentSessionLivenessResolver(homeDirectory: directory) }

    init(source: String = "claude", kind: AgentJournalEventKind = .questionRequested,
         workspace: UUID? = nil, surface: UUID? = nil) throws {
        self.source = source
        key = source == "claude" ? "claude_code" : source
        store = try AgentJournalStore(databaseURL: directory.appendingPathComponent("journal.sqlite3"))
        _ = try store.append(AgentJournalEventDraft(kind: kind, occurredAtMs: 1, source: source,
            agentKey: key, sessionId: session, workspaceId: (workspace ?? self.workspace).uuidString,
            surfaceId: (surface ?? self.surface).uuidString,
            attention: AgentAttentionContext(requestIdentity: "question",
                notification: AgentJournalNotification(title: "Agent", subtitle: "", body: "Answer",
                    category: "needs-permission", correlationKey: "wait"))))
    }

    deinit { store.close(); try? FileManager.default.removeItem(at: directory) }

    func record(pid: Int?, identity: AgentPIDProcessIdentity? = nil,
                workspace: UUID? = nil, surface: UUID? = nil) throws {
        var record: [String: Any] = ["sessionId": session, "workspaceId": (workspace ?? self.workspace).uuidString,
            "surfaceId": (surface ?? self.surface).uuidString, "updatedAt": 1]
        if let pid { record["pid"] = pid }
        if let identity {
            record["pidStartSeconds"] = identity.startSeconds
            record["pidStartMicroseconds"] = identity.startMicroseconds
        }
        let path = directory.appendingPathComponent(".cmuxterm")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["sessions": [session: record]])
            .write(to: path.appendingPathComponent("\(source)-hook-sessions.json"))
    }

    func replay() -> (assignments: [AgentLifecycleAssignment], state: AgentLifecycleReducerState) {
        var state = AgentLifecycleReducerState()
        var notifications = AgentNotificationReconciler()
        let assignments = AgentJournalLifecycleCenter.reduceStartupReplay(store: store,
            aliases: AgentJournalAliasResolver(workspaces: [:], surfaces: [:]),
            reducer: AgentLifecycleReducer(), replayPolicy: AgentJournalReplayPolicy(),
            state: &state, notifications: &notifications, liveness: resolver)
        return (assignments, state)
    }
}

struct AgentJournalReplayLivenessTests {
    @Test(arguments: [AgentJournalEventKind.questionRequested, .errorReported])
    func confirmedDeadProcessEndsWaitOrErrorDurably(kind: AgentJournalEventKind) throws {
        #expect(PIDPresence.current(pid: 999_999) == .absent)
        let fixture = try AgentJournalLivenessTestFixture(kind: kind)
        try fixture.record(pid: 999_999)
        #expect(fixture.resolver.liveness(source: fixture.source, sessionId: fixture.session) == .dead)
        let result = fixture.replay()
        #expect(result.assignments.isEmpty)
        #expect(result.state.sessions[fixture.surface.uuidString]?[fixture.key]?[fixture.session]?.ended == true)
        let events = try fixture.store.events(afterSequence: 0, limit: 20)
        #expect(events.last?.kind == .sessionEnded)
        #expect(events.last?.draft.sessionId == fixture.session)
        #expect(events.last?.draft.nativeEvent == "StartupProcessGone")
        _ = fixture.replay()
        #expect(try fixture.store.headSequence() == 2)
    }

    @Test func liveGenerationOnAnotherPanePreservesWait() throws {
        let fixture = try AgentJournalLivenessTestFixture()
        let identity = try #require(AgentPIDProcessIdentity(pid: getpid()))
        try fixture.record(pid: Int(getpid()), identity: identity, workspace: UUID(), surface: UUID())
        #expect(fixture.resolver.liveness(source: fixture.source, sessionId: fixture.session) == .alive)
        #expect(fixture.replay().assignments.first?.phase == .needsInput)
        #expect(try fixture.store.headSequence() == 1)
    }

    @Test func reusedPIDEndsOnlyItsOldSession() throws {
        let fixture = try AgentJournalLivenessTestFixture()
        let current = try #require(AgentPIDProcessIdentity(pid: getpid()))
        let previous = AgentPIDProcessIdentity(pid: getpid(), startSeconds: current.startSeconds - 1,
            startMicroseconds: current.startMicroseconds)
        try fixture.record(pid: Int(getpid()), identity: previous)
        #expect(fixture.resolver.liveness(source: fixture.source, sessionId: fixture.session) == .dead)
        #expect(fixture.replay().assignments.isEmpty)
    }

    /// A PID can be reused after a restart. With no recorded start time a present PID cannot be told from the old agent,
    /// so it proves nothing: `.unknown`, never `.alive` and never `.dead`. Reads the real process table (this process).
    @Test func presentPIDWithNoRecordedStartTimeIsUnknown() throws {
        #expect(PIDPresence.current(pid: getpid()) == .present)
        let fixture = try AgentJournalLivenessTestFixture()
        try fixture.record(pid: Int(getpid()))
        #expect(fixture.resolver.liveness(source: fixture.source, sessionId: fixture.session) == .unknown)
    }

    @Test func missingPIDlessCorruptAndUnreadableEvidencePreserveWait() throws {
        let fixture = try AgentJournalLivenessTestFixture()
        #expect(fixture.replay().assignments.first?.phase == .needsInput)
        try fixture.record(pid: nil)
        #expect(fixture.replay().assignments.first?.phase == .needsInput)
        try fixture.record(pid: Int(getpid()))
        let unreadable = AgentSessionLivenessResolver(homeDirectory: fixture.directory,
            processIdentity: { _ in nil }, processPresence: { _ in .unknown })
        #expect(unreadable.liveness(source: fixture.source, sessionId: fixture.session) == .unknown)
        #expect(fixture.replay().assignments.first?.phase == .needsInput)
        try Data("bad json".utf8).write(to: fixture.directory.appendingPathComponent(".cmuxterm/claude-hook-sessions.json"))
        #expect(fixture.replay().assignments.first?.phase == .needsInput)
        #expect(try fixture.store.headSequence() == 1)
    }
}
