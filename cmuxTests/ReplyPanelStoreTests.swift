import CMUXAgentLaunch
import CmuxAgentChat
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behaviour tests for `ReplyPanelStore` — the async, stateful half of the
/// Reply panel.
///
/// It had none until two cold reviews of `cm-69.1` found four defects and all
/// four lived here, while `ReplyPanelModel` (38 tests) came back clean. The
/// pure state machine was the easy half to test and the wrong half to trust:
/// binding, paging, and transcript lifecycle are where the panel meets the
/// real world, and none of it was covered.
@MainActor
// Serialized deliberately. The rig swaps `AppDelegate.shared` and
// `TerminalController.shared.agentChatTranscriptService` — process-wide
// singletons — and Swift Testing runs tests in parallel by default, so two
// of these racing each other clobber the registry the other is asserting on.
// The first symptom was a control test resolving `.noAgent` while the test
// beside it resolved fine.
@Suite(.serialized) struct ReplyPanelStoreTests {

    /// Everything `ReplyPanelStore.refresh` reaches for through singletons.
    ///
    /// The store resolves its registry through
    /// `TerminalController.shared.agentChatTranscriptService`, so a test has
    /// to stand one up and put it back. `PiFeedOwnershipTests` established
    /// this shape; this is the same rig with a transcript path under test.
    private struct Rig {
        let workspace: Workspace
        let panelID: UUID
        let sessionID: String
        let transcriptPath: String
        let directory: URL
    }

    /// - Parameter transcript: File contents, or `nil` for a path whose file
    ///   does not exist — the "hook recorded it before it was written" case.
    /// - Parameters:
    ///   - transcript: Contents to write, or `nil` to leave the file absent.
    ///   - registersTranscriptPath: Whether the `.sessionStart` hook carries a
    ///     transcript path. **Real Claude does not** — the record is created
    ///     with `transcriptPath: nil` (`CLI/cmux.swift:667`) and the path
    ///     arrives with the first prompt. This rig defaulted to sending one,
    ///     which is why no test caught a brand-new agent rendering the
    ///     "transcript moved" error.
    private static func withRig(
        transcript: String?,
        registersTranscriptPath: Bool = true,
        _ body: (Rig, ReplyPanelStore) async throws -> Void
    ) async throws {
        let previousAppDelegate = AppDelegate.shared
        let previousService = TerminalController.shared.agentChatTranscriptService
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        appDelegate.tabManager = tabManager

        let workspace = tabManager.addWorkspace(select: true)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let panelID = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reply-panel-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let transcriptPath = directory.appendingPathComponent("transcript.jsonl").path
        if let transcript {
            FileManager.default.createFile(
                atPath: transcriptPath,
                contents: Data(transcript.utf8)
            )
        }

        let registry = AgentChatSessionRegistry()
        let service = AgentChatTranscriptService(
            registry: registry,
            hasEventSubscribers: { false },
            emitEventPayload: { _ in }
        )
        TerminalController.shared.agentChatTranscriptService = service

        defer {
            TerminalController.shared.agentChatTranscriptService = previousService
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
            try? FileManager.default.removeItem(at: directory)
        }

        let sessionID = "reply-panel-store-\(UUID().uuidString)"
        service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: workspace.id.uuidString,
            surfaceId: panelID.uuidString,
            transcriptPath: registersTranscriptPath ? transcriptPath : nil,
            cwd: directory.path,
            ppid: nil,
            receivedAt: Date()
        ))

        let rig = Rig(
            workspace: workspace,
            panelID: panelID,
            sessionID: sessionID,
            transcriptPath: transcriptPath,
            directory: directory
        )
        try await body(rig, ReplyPanelStore())
    }

    // MARK: - Binding

    @Test("A brand-new agent is waiting, not an error")
    func freshSessionWithNoTranscriptPathIsWaiting() async throws {
        // Found in dogfood: open Reply, run `claude`, and the panel says
        // "Lost track of this agent — Its transcript moved". Nothing moved.
        // The session-start hook carries no transcript path, so the record is
        // created with nil (`CLI/cmux.swift:667`) and the path only arrives
        // with the first prompt. `startTail` folded "no path recorded yet"
        // into the same branch as "the file is gone", which made a false error
        // the first thing shown for every new agent — and left `waiting`, the
        // state written for exactly this, unreachable in practice.
        try await Self.withRig(transcript: nil, registersTranscriptPath: false) { rig, store in
            // Premise, asserted rather than assumed: the record really carries
            // no path. Otherwise this would pass for the wrong reason.
            let registry = try #require(
                TerminalController.shared.agentChatTranscriptService?.registry
            )
            let record = try #require(
                registry.currentOrMostRecentSession(surfaceID: rig.panelID.uuidString)
            )
            #expect(record.transcriptPath == nil)

            await store.refresh(workspace: rig.workspace)

            #expect(store.model.state == .waiting)
        }
    }

    @Test("A transcript that cannot be read leaves nothing bound, so the next refresh retries")
    func unreadableTranscriptDoesNotWedgeTheBinding() async throws {
        // The exact path the error screen tells the user to take. It reads
        // "Its transcript moved — send the agent a message and the panel
        // reconnects", and `userPromptSubmit` really does re-register the
        // path and broadcast. But `startTail` claimed `boundSessionID`
        // *before* the readability guard, so every later `refresh` returned
        // early on "already following this session" and the path was never
        // re-read. The panel stayed unavailable and only `Try again`, which
        // nils the binding itself, recovered.
        try await Self.withRig(transcript: nil) { rig, store in
            await store.refresh(workspace: rig.workspace)
            #expect(store.model.state == .unavailable)

            // The agent writes its transcript; nothing else changes.
            FileManager.default.createFile(atPath: rig.transcriptPath, contents: Data())

            // Premises, asserted rather than assumed: the record really does
            // carry the path, and the path really is readable now. Without
            // these a rig that never had a path would look like a wedge.
            let registry = try #require(
                TerminalController.shared.agentChatTranscriptService?.registry
            )
            let record = try #require(
                registry.currentOrMostRecentSession(surfaceID: rig.panelID.uuidString)
            )
            #expect(record.transcriptPath == rig.transcriptPath)
            #expect(FileManager.default.isReadableFile(atPath: rig.transcriptPath))

            await store.refresh(workspace: rig.workspace)
            #expect(store.model.state != .unavailable)
        }
    }

    @Test("A readable transcript binds on the first refresh")
    func readableTranscriptBinds() async throws {
        // The control for the test above: with the file present from the
        // start, one refresh is enough. Without this, a fix that simply
        // never reported `.unavailable` would pass the other test.
        try await Self.withRig(transcript: "") { rig, store in
            await store.refresh(workspace: rig.workspace)
            #expect(store.model.state != .unavailable)
            #expect(store.model.state != .noAgent)
        }
    }

    private static func canStepBack(_ store: ReplyPanelStore) -> Bool {
        guard case let .showing(reading) = store.model.state else { return false }
        return reading.canStepBack
    }

    /// A transcript long enough that the tailer refuses to serve its head.
    ///
    /// `AgentChatTranscriptTailer` backfills at most `maxInitialLines` (2000)
    /// and then reports `headTruncated`, which is the state this exercises.
    /// Every line shares one `message.id`, so the whole thing is a single
    /// reply — that keeps the walk to the cache head a handful of steps
    /// instead of two thousand, without changing the paging behaviour.
    private static func longTranscript(lines: Int) -> String {
        (0..<lines).map { index in
            let object: [String: Any] = [
                "parentUuid": "u-1",
                "isSidechain": false,
                "type": "assistant",
                "message": [
                    "model": "claude-fable-5",
                    "id": "msg_one_long_reply",
                    "type": "message",
                    "role": "assistant",
                    "content": [["type": "text", "text": "line \(index)"]],
                    "stop_reason": "tool_use",
                ],
                "uuid": "a-\(index)",
                "timestamp": "2026-06-12T05:08:20.730Z",
                "sessionId": "s-1",
            ]
            let data = try! JSONSerialization.data(withJSONObject: object)
            return String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n") + "\n"
    }

    // MARK: - Paging

    @Test("Stepping back stops at the head of a truncated backfill")
    func stepBackStopsAtTruncatedHead() async throws {
        // The tailer serves the newest 2000 lines and reports `hasMore: true`
        // forever after, because older transcript really does exist on disk
        // that it will never serve. Its own doc says the client is expected
        // to recognise the resulting empty page. This one did not: it re-noted
        // `hasMore: true`, so `canStepBack` stayed lit and every press bought
        // a page read that could never succeed — the arrow enabled forever,
        // doing nothing, with no explanation.
        try await Self.withRig(transcript: Self.longTranscript(lines: 2100)) { rig, store in
            await store.refresh(workspace: rig.workspace)
            #expect(Self.canStepBack(store))

            // Generous bound: the cache is 2000 lines and a page is 300, so
            // the head is reached well inside this. If `canStepBack` is still
            // true afterwards it is never going to go false.
            for _ in 0..<20 where Self.canStepBack(store) {
                await store.stepBack()
            }

            #expect(!Self.canStepBack(store))
        }
    }

    /// One assistant line whose reply id and text are both given.
    private static func replyLine(id: String, text: String, uuid: String) -> String {
        let object: [String: Any] = [
            "parentUuid": "u-1",
            "isSidechain": false,
            "type": "assistant",
            "message": [
                "model": "claude-fable-5",
                "id": id,
                "type": "message",
                "role": "assistant",
                "content": [["type": "text", "text": text]],
                "stop_reason": "tool_use",
            ],
            "uuid": uuid,
            "timestamp": "2026-06-12T05:08:20.730Z",
            "sessionId": "s-1",
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Waits for a condition the file watcher drives, or gives up.
    ///
    /// The watcher throttles at 200ms and drains on its own task, so there is
    /// no completion to await. Polling with a ceiling keeps the test honest:
    /// it fails on the assertion rather than hanging.
    private static func waitUntil(
        _ condition: () -> Bool,
        timeout: Duration = .seconds(5)
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    // MARK: - Transcript rewritten under the panel

    @Test("A rewritten transcript re-renders from the new file")
    func rewrittenTranscriptRerenders() async throws {
        // `--resume` and compaction replace the file. The tailer notices,
        // re-reads the replacement into its cache, and emits a `didReset`
        // batch that is *empty* — nothing was appended. The store cleared its
        // mirror and stopped there, so the panel dropped to "Waiting for the
        // first reply / Nothing has been written this session" with the whole
        // conversation sitting one `history` call away. False, and routine.
        let before = Self.replyLine(id: "msg_before", text: "Before the resume.", uuid: "a-1")
            + Self.replyLine(id: "msg_before2", text: "Still before.", uuid: "a-2")
            + Self.replyLine(id: "msg_before3", text: "Also before.", uuid: "a-3")

        try await Self.withRig(transcript: before) { rig, store in
            await store.refresh(workspace: rig.workspace)
            #expect(Self.markdown(store)?.contains("Also before.") == true)

            // Shorter than what was read, so the tailer sees a truncation and
            // resets — the same path a compaction takes.
            let after = Self.replyLine(id: "msg_after", text: "After the resume.", uuid: "b-1")
            try Data(after.utf8).write(to: URL(fileURLWithPath: rig.transcriptPath))

            await Self.waitUntil { Self.markdown(store)?.contains("After the resume.") == true }

            #expect(store.model.state != .waiting)
            #expect(Self.markdown(store)?.contains("After the resume.") == true)
        }
    }

    private static func markdown(_ store: ReplyPanelStore) -> String? {
        guard case let .showing(reading) = store.model.state else { return nil }
        return reading.group.markdown
    }
}
