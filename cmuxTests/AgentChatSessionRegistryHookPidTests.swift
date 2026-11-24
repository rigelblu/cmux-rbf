import CMUXAgentLaunch
import CmuxMobileHost
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `cm-136.9` Scenario 39: a Claude hook's live `ppid` replaces a recorded pid
/// that is nil or dead, so the exit check never ends a Claude that is still
/// running under a restarted cmux.
@Suite
struct AgentChatSessionRegistryHookPidTests {
    private static let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"

    @MainActor
    @Test func claudeLivePpidFillsANilPid() throws {
        let (registry, surfaceID) = try makeRegistry()
        let pendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID)
        registry.noteResumeInitiated(
            sessionID: pendingID,
            source: "claude",
            surfaceID: surfaceID,
            workspaceID: "ws",
            workingDirectory: "/tmp"
        )
        #expect(registry.record(sessionID: pendingID)?.pid == nil)

        registry.noteHookEvent(event(.userPromptSubmit, source: "claude", surfaceID: surfaceID, ppid: livePID))

        #expect(registry.record(sessionID: pendingID)?.pid == livePID)
    }

    @MainActor
    @Test func claudeLivePpidReplacesADeadPid() throws {
        let (registry, surfaceID) = try makeRegistry()
        let dead = try deadPID()
        registry.noteHookEvent(event(.sessionStart, source: "claude", surfaceID: surfaceID, ppid: dead))
        #expect(registry.record(sessionID: Self.sessionID)?.pid == dead)

        registry.noteHookEvent(event(.preToolUse, source: "claude", surfaceID: surfaceID, ppid: livePID))

        #expect(registry.record(sessionID: Self.sessionID)?.pid == livePID)
    }

    @MainActor
    @Test func claudeLivePpidNeverReplacesALiveRecordedPid() throws {
        let (registry, surfaceID) = try makeRegistry()
        let otherLive = Int(getppid())
        try #require(otherLive > 0 && otherLive != livePID)
        registry.noteHookEvent(event(.sessionStart, source: "claude", surfaceID: surfaceID, ppid: livePID))

        registry.noteHookEvent(event(.preToolUse, source: "claude", surfaceID: surfaceID, ppid: otherLive))

        #expect(registry.record(sessionID: Self.sessionID)?.pid == livePID)
    }

    @MainActor
    @Test func claudeDeadPpidChangesNothing() throws {
        let (registry, surfaceID) = try makeRegistry()
        let pendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID)
        registry.noteResumeInitiated(
            sessionID: pendingID,
            source: "claude",
            surfaceID: surfaceID,
            workspaceID: "ws",
            workingDirectory: "/tmp"
        )

        registry.noteHookEvent(event(.userPromptSubmit, source: "claude", surfaceID: surfaceID, ppid: try deadPID()))

        #expect(registry.record(sessionID: pendingID)?.pid == nil)
    }

    @MainActor
    @Test func claudeRelayEventWithPpidZeroChangesNothing() throws {
        let (registry, surfaceID) = try makeRegistry()
        let dead = try deadPID()
        registry.noteHookEvent(event(.sessionStart, source: "claude", surfaceID: surfaceID, ppid: dead))

        registry.noteHookEvent(event(.preToolUse, source: "claude", surfaceID: surfaceID, ppid: 0))

        #expect(registry.record(sessionID: Self.sessionID)?.pid == dead)
    }

    @MainActor
    @Test func codexLivePpidDoesNotReplaceADeadPid() throws {
        let (registry, surfaceID) = try makeRegistry()
        let dead = try deadPID()
        registry.noteHookEvent(event(.sessionStart, source: "codex", surfaceID: surfaceID, ppid: dead))
        #expect(registry.record(sessionID: Self.sessionID)?.pid == dead)

        registry.noteHookEvent(event(.preToolUse, source: "codex", surfaceID: surfaceID, ppid: livePID))

        #expect(registry.record(sessionID: Self.sessionID)?.pid == dead)
    }

    /// The hook store lags the live event by one write: here its entry still
    /// holds the pid a restart killed. The live `ppid` must be set before the
    /// backfill runs, or the backfill adopts the dead one and the exit check
    /// ends a Claude that is running.
    @MainActor
    @Test func storeBackfillDoesNotAdoptADeadPidOverTheLivePpid() async throws {
        let home = try temporaryHome()
        let surfaceID = UUID().uuidString
        try writeClaudeHookStore(home: home, surfaceID: surfaceID, pid: try deadPID())
        let registry = AgentChatSessionRegistry(hookStore: AgentChatHookSessionStore(homeDirectory: home))

        // No transcript path on the event: only the store entry has one, so it shows the backfill ran.
        registry.noteHookEvent(event(
            .userPromptSubmit, source: "claude", surfaceID: surfaceID, ppid: livePID, transcriptPath: nil
        ))
        // The store read is deferred off-main; give it and any exit check a
        // bounded window to land, then look.
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 25_000_000)
            _ = registry.liveSession(surfaceID: surfaceID)
        }

        let record = try #require(registry.record(sessionID: Self.sessionID))
        #expect(record.pid == livePID)
        #expect(record.state != .ended)
        #expect(record.transcriptPath == "/tmp/\(Self.sessionID).jsonl")
    }

    private var livePID: Int { Int(getpid()) }

    private func event(
        _ name: WorkstreamEvent.HookEventName,
        source: String,
        surfaceID: String,
        ppid: Int,
        transcriptPath: String? = "/tmp/\(AgentChatSessionRegistryHookPidTests.sessionID).jsonl"
    ) -> WorkstreamEvent {
        WorkstreamEvent(
            sessionId: Self.sessionID,
            hookEventName: name,
            source: source,
            workspaceId: "ws",
            surfaceId: surfaceID,
            transcriptPath: transcriptPath,
            cwd: "/tmp",
            ppid: ppid,
            receivedAt: Date(timeIntervalSince1970: 120)
        )
    }

    @MainActor
    private func makeRegistry() throws -> (AgentChatSessionRegistry, String) {
        let registry = AgentChatSessionRegistry(
            hookStore: AgentChatHookSessionStore(homeDirectory: try temporaryHome())
        )
        return (registry, UUID().uuidString)
    }

    /// A reaped child: its pid is dead until the system reuses it.
    private func deadPID() throws -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return Int(process.processIdentifier)
    }

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hook-pid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeClaudeHookStore(home: URL, surfaceID: String, pid: Int) throws {
        let directory = home.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "sessions": [
                Self.sessionID: [
                    "workspaceId": "ws",
                    "surfaceId": surfaceID,
                    "cwd": "/tmp",
                    "transcriptPath": "/tmp/\(Self.sessionID).jsonl",
                    "pid": pid,
                    "updatedAt": 140.0,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("claude-hook-sessions.json"))
    }
}
