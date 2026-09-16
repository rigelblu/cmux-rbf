import AppKit
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
@Suite("Reply delivery submit key")
struct ReplyDeliverySubmitKeyTests {
    /// The submit-key upgrade is what keeps a multi-line anchored list one
    /// prompt, and it turns entirely on the agent context being a **metadata
    /// block** rather than a name.
    ///
    /// Written after getting this wrong: `ReplyPanelStore.deliver` first
    /// passed the bare string `"claude"`, which matches nothing —
    /// `matches(metadataLine:)` only reads `restoredAgent:`, `agentPIDKey:`,
    /// `initialCommand:` and `tmuxStartCommand:` prefixes. The store now uses
    /// `WorkspaceContentView.terminalAgentContext(panel:workspace:)`, the same
    /// source every other caller uses.
    ///
    /// The failure it prevents is silent: an unmatched context resolves
    /// `return`, and `cmux send` rewrites `\n` to CR and splits N lines into N
    /// submissions — so one feedback list arrives as several truncated
    /// prompts, each answered separately.
    @Test("A metadata line naming claude upgrades a multi-line submit to ctrl+enter")
    func metadataContextUpgradesTheSubmitKey() {
        let context = "restoredAgent:claude"

        #expect(TextBoxAgentDetection.isClaudeCode(context: context))
        #expect(TextBoxAgentDetection.composedPromptSubmitKey(
            containsNewline: true, context: context
        ) == "ctrl+enter")
    }

    /// The trap, pinned so it is not re-entered: an agent *name* on its own is
    /// not a context, and reads as "not Claude" rather than as an error.
    @Test("A bare agent name matches nothing and silently falls back to return")
    func bareNameIsNotAContext() {
        #expect(!TextBoxAgentDetection.isClaudeCode(context: "claude"))
        #expect(TextBoxAgentDetection.composedPromptSubmitKey(
            containsNewline: true, context: "claude"
        ) == "return")
    }

    /// Single-line payloads and non-Claude panes keep `return`, so the
    /// upgrade cannot quietly become unconditional.
    @Test("Single-line and non-Claude payloads still submit with return")
    func returnRemainsTheDefault() {
        #expect(TextBoxAgentDetection.composedPromptSubmitKey(
            containsNewline: false, context: "restoredAgent:claude"
        ) == "return")
        #expect(TextBoxAgentDetection.composedPromptSubmitKey(
            containsNewline: true, context: "restoredAgent:codex"
        ) == "return")
    }
}

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
        let tabManager: TabManager
        let workspace: Workspace
        let panelID: UUID
        let sessionID: String
        let transcriptPath: String
        let directory: URL
    }

    @MainActor
    private final class TailerStopController {
        private var nextID = 0
        private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

        var count: Int { nextID }

        func stop(_ tailer: AgentChatTranscriptTailer) async {
            let id = nextID
            nextID += 1
            await withCheckedContinuation { continuation in
                continuations[id] = continuation
            }
            await tailer.stop()
        }

        func release(_ id: Int) {
            continuations.removeValue(forKey: id)?.resume()
        }
    }

    @MainActor
    private final class TailerStopSpy {
        private(set) var count = 0

        func stop(_ tailer: AgentChatTranscriptTailer) async {
            count += 1
            await tailer.stop()
        }
    }

    @MainActor
    private final class InitialHistoryController {
        private let suspendedCall: Int
        private var nextCall = 0
        private var continuation: CheckedContinuation<Void, Never>?

        init(suspendedCall: Int) {
            self.suspendedCall = suspendedCall
        }

        var isSuspended: Bool { continuation != nil }

        func load(_ tailer: AgentChatTranscriptTailer, limit: Int) async -> ChatHistoryPage {
            let call = nextCall
            nextCall += 1
            if call == suspendedCall {
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                }
            }
            return await tailer.history(beforeSeq: nil, limit: limit)
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    /// - Parameters:
    ///   - transcript: File contents, or `nil` for a path whose file does not
    ///     exist — the "hook recorded it before the agent wrote it" case, and
    ///     the ordinary state of every new Claude session.
    ///   - registersTranscriptPath: Whether the `.sessionStart` hook carries a
    ///     transcript path. Claude's does; the record is created with `nil`
    ///     (`CLI/cmux.swift:667`) only for an agent whose start hook omits it.
    private static func withRig(
        transcript: String?,
        registersTranscriptPath: Bool = true,
        makeStore: @MainActor () -> ReplyPanelStore = { ReplyPanelStore() },
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
            tabManager: tabManager,
            workspace: workspace,
            panelID: panelID,
            sessionID: sessionID,
            transcriptPath: transcriptPath,
            directory: directory
        )
        try await body(rig, makeStore())
    }

    // MARK: - Binding

    @Test("A brand-new agent is waiting, not an error")
    func freshSessionWithNoTranscriptPathIsWaiting() async throws {
        // A record with no path at all: an agent whose start hook omits one.
        // Claude is *not* this case — measured in
        // `~/.cmuxterm/claude-hook-sessions.json`, its fresh sessions carry a
        // well-formed path whose file does not exist yet, which is the test
        // below. Both must read as waiting; neither is a fault.
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

    @Test("A transcript not written yet leaves nothing bound, so the next refresh retries")
    func absentTranscriptDoesNotWedgeTheBinding() async throws {
        // This test used to assert `.unavailable` here, and that assertion is
        // why the false error shipped: a recorded path with no file on disk is
        // the ordinary state of *every* new Claude agent, and the suite pinned
        // it as a fault. The wedge it guards against is real and still checked
        // below; only the state it expects while waiting has changed.
        //
        // This is the dogfood case: open Reply, run `claude`, and the panel
        // said "Lost track of this agent — Its transcript moved". Nothing had
        // moved; Claude records the path at session start and creates the file
        // on the first prompt.
        //
        // The wedge it also guards: the error screen reads
        // "Its transcript moved — send the agent a message and the panel
        // reconnects", and `userPromptSubmit` really does re-register the
        // path and broadcast. But `startTail` claimed `boundSessionID`
        // *before* the readability guard, so every later `refresh` returned
        // early on "already following this session" and the path was never
        // re-read. The panel stayed unavailable and only `Try again`, which
        // nils the binding itself, recovered.
        try await Self.withRig(transcript: nil) { rig, store in
            await store.refresh(workspace: rig.workspace)
            #expect(store.model.state == .waiting)

            // The agent writes its transcript; nothing else changes. Real
            // content, not an empty file: an empty one is legitimately still
            // `.waiting`, so it could not tell a retry that bound from one
            // that never ran.
            FileManager.default.createFile(
                atPath: rig.transcriptPath,
                contents: Data(Self.replyLine(id: "msg_A", text: "Hello.", uuid: "a-1").utf8)
            )

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
            // The reply is on screen: the retry bound *and* read. `!=
            // .unavailable` would also pass for the waiting state this test
            // now starts in, and so would prove nothing about the refresh.
            guard case let .showing(reading) = store.model.state else {
                Issue.record("expected the reply to render, got \(store.model.state)")
                return
            }
            #expect(reading.group.markdown == "Hello.")
        }
    }

    @Test("A turn finishing while nothing is bound retries the bind")
    func turnEndRebindsWhenTheTranscriptArrivedLate() async throws {
        // The gap the first two fixes left. `postSessionsDidChange` fires on
        // session start, first prompt, and session end only — so there is
        // exactly one retry, and it races Claude creating the file. Lose that
        // race and the panel sat on "Waiting for the first message" through a
        // whole completed turn, which is what Tom saw at 4:50 PM: a full reply
        // in the terminal, the panel still waiting.
        //
        // A turn ending is the one moment content is certain to exist, and the
        // store already listens for it — it just never re-bound on it.
        try await Self.withRig(transcript: nil) { rig, store in
            await store.refresh(workspace: rig.workspace)
            #expect(store.model.state == .waiting)

            FileManager.default.createFile(
                atPath: rig.transcriptPath,
                contents: Data(Self.replyLine(id: "msg_A", text: "Late.", uuid: "a-1").utf8)
            )
            NotificationCenter.default.post(
                name: .agentChatSessionTurnDidFinish,
                object: nil,
                userInfo: [AgentChatTurnFinishedKeys.sessionID: rig.sessionID]
            )

            await Self.waitUntil { Self.markdown(store)?.contains("Late.") == true }
            #expect(
                Self.markdown(store)?.contains("Late.") == true,
                "the panel should re-bind when a turn ends while nothing is bound"
            )
        }
    }

    @Test("Switching workspaces does not let stale A suppress B's late transcript")
    func workspaceSwitchRetriesTheSelectedSession() async throws {
        let stops = TailerStopController()
        try await Self.withRig(
            transcript: Self.replyLine(id: "msg_A", text: "A-REPLY", uuid: "a-1"),
            makeStore: {
                ReplyPanelStore(tailerStopper: { await stops.stop($0) })
            }
        ) { rigA, store in
            await store.refresh(workspace: rigA.workspace)
            #expect(store.boundSessionID == rigA.sessionID)
            #expect(Self.markdown(store)?.contains("A-REPLY") == true)

            let workspaceB = rigA.tabManager.addWorkspace(select: true)
            defer {
                if rigA.tabManager.tabs.contains(where: { $0.id == workspaceB.id }) {
                    rigA.tabManager.closeWorkspace(workspaceB)
                }
            }
            let paneB = try #require(workspaceB.bonsplitController.allPaneIds.first)
            let panelB = try #require(workspaceB.newTerminalSurface(inPane: paneB, focus: true)?.id)
            let sessionB = "reply-panel-store-b-\(UUID().uuidString)"
            let transcriptB = rigA.directory.appendingPathComponent("transcript-b.jsonl").path
            let service = try #require(TerminalController.shared.agentChatTranscriptService)
            service.noteHookEvent(WorkstreamEvent(
                sessionId: sessionB,
                hookEventName: .sessionStart,
                source: "claude",
                workspaceId: workspaceB.id.uuidString,
                surfaceId: panelB.uuidString,
                transcriptPath: nil,
                cwd: rigA.directory.path,
                ppid: nil,
                receivedAt: Date()
            ))

            let switchTask = Task { await store.refresh(workspace: workspaceB) }
            await Self.waitUntil { stops.count == 1 }
            #expect(stops.count == 1)
            #expect(store.boundSessionID == nil)
            #expect(store.boundPanelID == nil)
            #expect(
                Self.markdown(store)?.contains("A-REPLY") == true,
                "the outgoing presentation may remain visible, but it must be inactive"
            )

            FileManager.default.createFile(
                atPath: transcriptB,
                contents: Data(Self.replyLine(id: "msg_B", text: "B-REPLY", uuid: "b-1").utf8)
            )
            service.noteHookEvent(WorkstreamEvent(
                sessionId: sessionB,
                hookEventName: .userPromptSubmit,
                source: "claude",
                workspaceId: workspaceB.id.uuidString,
                surfaceId: panelB.uuidString,
                transcriptPath: transcriptB,
                cwd: rigA.directory.path,
                ppid: nil,
                receivedAt: Date()
            ))
            NotificationCenter.default.post(
                name: .agentChatSessionTurnDidFinish,
                object: nil,
                userInfo: [AgentChatTurnFinishedKeys.sessionID: sessionB]
            )

            // The registry is authoritative immediately, but the bind is
            // still suspended retiring A. Both material wakes cross that
            // suspension; no third event is posted after it resumes.
            stops.release(0)
            await switchTask.value
            await Self.waitUntil { Self.markdown(store)?.contains("B-REPLY") == true }

            #expect(
                Self.markdown(store)?.contains("B-REPLY") == true,
                "workspace B's completed reply should replace workspace A without a third wake"
            )
            #expect(store.boundSessionID == sessionB)
            #expect(store.boundPanelID == panelB)
        }
    }

    @Test("A waiting workspace replaces A and binds when B's own turn finishes")
    func selectedWaitingWorkspaceOwnsItsRetry() async throws {
        try await Self.withRig(
            transcript: Self.replyLine(id: "msg_A", text: "A-REPLY", uuid: "a-1")
        ) { rigA, store in
            await store.refresh(workspace: rigA.workspace)

            let workspaceB = rigA.tabManager.addWorkspace(select: true)
            defer {
                if rigA.tabManager.tabs.contains(where: { $0.id == workspaceB.id }) {
                    rigA.tabManager.closeWorkspace(workspaceB)
                }
            }
            let paneB = try #require(workspaceB.bonsplitController.allPaneIds.first)
            let panelB = try #require(workspaceB.newTerminalSurface(inPane: paneB, focus: true)?.id)
            let sessionB = "reply-panel-store-b-\(UUID().uuidString)"
            let transcriptB = rigA.directory.appendingPathComponent("transcript-b-waiting.jsonl").path
            let service = try #require(TerminalController.shared.agentChatTranscriptService)
            service.noteHookEvent(WorkstreamEvent(
                sessionId: sessionB,
                hookEventName: .sessionStart,
                source: "claude",
                workspaceId: workspaceB.id.uuidString,
                surfaceId: panelB.uuidString,
                transcriptPath: transcriptB,
                cwd: rigA.directory.path,
                ppid: nil,
                receivedAt: Date()
            ))

            await store.refresh(workspace: workspaceB)
            #expect(store.model.state == .waiting)
            #expect(store.boundSessionID == nil)
            #expect(store.boundPanelID == nil)
            #expect(store.draftScope == nil)

            FileManager.default.createFile(
                atPath: transcriptB,
                contents: Data(Self.replyLine(id: "msg_B", text: "B-REPLY", uuid: "b-1").utf8)
            )
            NotificationCenter.default.post(
                name: .agentChatSessionTurnDidFinish,
                object: nil,
                userInfo: [AgentChatTurnFinishedKeys.sessionID: sessionB]
            )

            await Self.waitUntil { Self.markdown(store)?.contains("B-REPLY") == true }
            #expect(Self.markdown(store)?.contains("B-REPLY") == true)
            #expect(store.boundSessionID == sessionB)
            #expect(store.boundPanelID == panelB)
        }
    }

    @Test("A stale A-to-B bind cannot publish after the user returns to A")
    func staleWorkspaceBindCannotPublishAfterReturning() async throws {
        let stops = TailerStopSpy()
        // Call 0 loads A. Call 1 is B and is held after its tailer starts.
        // The return to A is call 2 and may settle while B remains suspended.
        let history = InitialHistoryController(suspendedCall: 1)
        try await Self.withRig(
            transcript: Self.replyLine(id: "msg_A", text: "A-REPLY", uuid: "a-1"),
            makeStore: {
                ReplyPanelStore(
                    tailerStopper: { await stops.stop($0) },
                    initialHistoryLoader: { await history.load($0, limit: $1) }
                )
            }
        ) { rigA, store in
            await store.refresh(workspace: rigA.workspace)

            let workspaceB = rigA.tabManager.addWorkspace(select: true)
            defer {
                if rigA.tabManager.tabs.contains(where: { $0.id == workspaceB.id }) {
                    rigA.tabManager.closeWorkspace(workspaceB)
                }
            }
            let paneB = try #require(workspaceB.bonsplitController.allPaneIds.first)
            let panelB = try #require(workspaceB.newTerminalSurface(inPane: paneB, focus: true)?.id)
            let transcriptB = rigA.directory.appendingPathComponent("transcript-b-return.jsonl").path
            FileManager.default.createFile(
                atPath: transcriptB,
                contents: Data(
                    Self.replyLine(id: "msg_B", text: "B-REPLY", uuid: "b-1").utf8
                )
            )
            let service = try #require(TerminalController.shared.agentChatTranscriptService)
            service.noteHookEvent(WorkstreamEvent(
                sessionId: "reply-panel-store-b-\(UUID().uuidString)",
                hookEventName: .sessionStart,
                source: "claude",
                workspaceId: workspaceB.id.uuidString,
                surfaceId: panelB.uuidString,
                transcriptPath: transcriptB,
                cwd: rigA.directory.path,
                ppid: nil,
                receivedAt: Date()
            ))

            let staleSwitch = Task { await store.refresh(workspace: workspaceB) }
            await Self.waitUntil { history.isSuspended }
            #expect(history.isSuspended)
            #expect(stops.count == 1, "B should have retired A before reading history")

            // B has created and started its candidate tailer, then suspended
            // before publication. Returning to A creates a newer revision;
            // when B resumes it must stop that candidate without publishing.
            await store.refresh(workspace: rigA.workspace)
            #expect(store.boundSessionID == rigA.sessionID)
            #expect(store.boundPanelID == rigA.panelID)
            #expect(Self.markdown(store)?.contains("A-REPLY") == true)

            history.release()
            await staleSwitch.value

            #expect(store.boundSessionID == rigA.sessionID)
            #expect(store.boundPanelID == rigA.panelID)
            #expect(Self.markdown(store)?.contains("A-REPLY") == true)
            #expect(Self.markdown(store)?.contains("B-REPLY") != true)
            #expect(stops.count == 2, "the superseded B candidate tailer must also stop")
        }
    }

    @Test("Only the waiting target retries, and bound metadata churn does not restart it")
    func retryAndMetadataChurnAreTargetScoped() async throws {
        let stops = TailerStopSpy()
        try await Self.withRig(
            transcript: nil,
            makeStore: {
                ReplyPanelStore(tailerStopper: { await stops.stop($0) })
            }
        ) { rig, store in
            await store.refresh(workspace: rig.workspace)
            #expect(store.model.state == .waiting)

            FileManager.default.createFile(
                atPath: rig.transcriptPath,
                contents: Data(
                    Self.replyLine(id: "msg_target", text: "TARGET-REPLY", uuid: "a-1").utf8
                )
            )

            // A foreign turn ending must not turn a now-readable waiting
            // target into a bound one. The matching turn is the authority.
            NotificationCenter.default.post(
                name: .agentChatSessionTurnDidFinish,
                object: nil,
                userInfo: [AgentChatTurnFinishedKeys.sessionID: "foreign-session"]
            )
            try? await Task.sleep(for: .milliseconds(100))
            #expect(store.model.state == .waiting)
            #expect(store.boundSessionID == nil)

            NotificationCenter.default.post(
                name: .agentChatSessionTurnDidFinish,
                object: nil,
                userInfo: [AgentChatTurnFinishedKeys.sessionID: rig.sessionID]
            )
            await Self.waitUntil { Self.markdown(store)?.contains("TARGET-REPLY") == true }
            #expect(store.boundSessionID == rig.sessionID)

            #expect(rig.workspace.setPanelCustomTitle(panelId: rig.panelID, title: "Renamed"))
            await Self.waitUntil { store.identity == "Renamed" }
            NotificationCenter.default.post(name: .agentChatSessionsDidChange, object: nil)
            for _ in 0..<10 { await Task.yield() }

            #expect(store.identity == "Renamed")
            #expect(store.boundSessionID == rig.sessionID)
            #expect(stops.count == 0, "same-target metadata must not replace the live tailer")
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

    // MARK: - The turn gate

    /// Sets one lifecycle state on the bound pane, the way the hook CLI's
    /// push does.
    ///
    /// Still used, but no longer as the gate's *input*. On a cold open the
    /// lifecycle is the only thing that can say whether the newest reply is
    /// still growing, so it decides the model's opening settle — and then
    /// stops mattering.
    private static func setLifecycle(
        _ state: AgentHibernationLifecycleState,
        rig: Rig
    ) {
        rig.workspace.agentLifecycleStatesByPanelId[rig.panelID] = ["test": state]
    }

    private static let draft = ReplyAnnotationSet(
        annotations: [ReplyAnnotation(quote: "a span", note: "make this a question", range: 0..<6)]
    )

    /// **Paste is never refused.** It types into a composer the user is
    /// looking at and submits nothing, so what goes in there is their call —
    /// including notes about a reply ten turns back, and notes written before
    /// the agent restarted. Carrying feedback forward is a thing to want, not
    /// a mistake to prevent.
    ///
    /// This reverses the rule six tests here used to pin. They were correct
    /// encodings of a design that has been replaced, so they are deleted with
    /// it rather than after it (Tom, 2026-09-05).
    @Test("A paste is taken while the turn is still in progress")
    func pasteIsTakenWhileWriting() async throws {
        try await Self.withRig(transcript: Self.oneReply()) { rig, store in
            Self.setLifecycle(.running, rig: rig)
            await store.refresh(workspace: rig.workspace)

            #expect(store.model.isNewestTurnWriting)
            #expect(store.deliver(Self.draft, editedText: nil, workspace: rig.workspace, submit: false))
        }
    }

    /// The turn gate: it stops the button that submits, and only that one.
    @Test("A send is refused while the turn is still in progress")
    func sendIsRefusedWhileWriting() async throws {
        try await Self.withRig(transcript: Self.oneReply()) { rig, store in
            Self.setLifecycle(.running, rig: rig)
            await store.refresh(workspace: rig.workspace)

            #expect(!store.canSubmit)
            #expect(!store.deliver(Self.draft, editedText: nil, workspace: rig.workspace, submit: true))
        }
    }

    /// The reversal that matters most, pinned so it cannot come back.
    ///
    /// `needsInput` is Claude's **resting** state as often as its blocking
    /// one — the Notification hook and the `AskUserQuestion` PreToolUse push
    /// the same key with the same value (`CLI/cmux.swift:25252` vs `:25524`),
    /// so nothing downstream can separate "finished" from "waiting on a
    /// prompt". The old gate read it and stood Send down, which meant the
    /// feature was dead whenever it was most usable.
    ///
    /// The gate now asks whether the newest **turn** has ended, which
    /// `needsInput` says nothing about either way.
    @Test("A waiting agent gates nothing, because the lifecycle is no longer the gate")
    func needsInputGatesNothing() async throws {
        try await Self.withRig(transcript: Self.oneReply()) { rig, store in
            Self.setLifecycle(.needsInput, rig: rig)
            await store.refresh(workspace: rig.workspace)

            #expect(!store.model.isNewestTurnWriting)
            #expect(store.canSubmit)
            #expect(store.deliver(Self.draft, editedText: nil, workspace: rig.workspace, submit: true))
        }
    }

    /// A pane that has pushed no hook event yet reports `unknown`, and the
    /// settle rule already reads that as not-running.
    @Test("An unknown lifecycle settles the opening turn rather than holding it")
    func unknownSettlesTheOpeningTurn() async throws {
        try await Self.withRig(transcript: Self.oneReply()) { rig, store in
            Self.setLifecycle(.unknown, rig: rig)
            await store.refresh(workspace: rig.workspace)

            #expect(store.canSubmit)
        }
    }

    /// The gate passing is not enough: an empty draft must not paste an empty
    /// string, which reads as cmux having malfunctioned rather than as nothing
    /// having been written.
    ///
    /// **A marked span with no note is not that case, and this test used to
    /// say it was.** It asserted the refusal as intended behaviour, which is
    /// how `deliver`'s guard survived being fixed at the button — pressing an
    /// enabled `Paste` typed nothing and left the clipboard untouched (Tom,
    /// dogfood 2026-09-06). `Paste` lands in a composer, so an unwritten note
    /// is a sentence the user finishes there. Only `Paste & Send`, which has
    /// no composer step, still wants an instruction.
    @Test("Only a genuinely empty draft is refused; an unwritten note still pastes")
    func emptyDraftIsRefused() async throws {
        try await Self.withRig(transcript: Self.oneReply()) { rig, store in
            Self.setLifecycle(.idle, rig: rig)
            await store.refresh(workspace: rig.workspace)

            let markedOnly = ReplyAnnotationSet(annotations: [
                ReplyAnnotation(quote: "a span", note: "  ", range: 0..<6)
            ])

            #expect(store.canSubmit)
            // Nothing marked at all: still refused, both ways.
            #expect(!store.deliver(ReplyAnnotationSet(), editedText: nil, workspace: rig.workspace, submit: false))
            #expect(!store.deliver(ReplyAnnotationSet(), editedText: nil, workspace: rig.workspace, submit: true))

            // Marked, unwritten: pastes...
            #expect(store.deliver(markedOnly, editedText: nil, workspace: rig.workspace, submit: false))
            // ...and the payload is the quote, so it is not an empty string.
            #expect(markedOnly.serialized().contains("a span"))
            // ...but does not send, because nothing has been asked.
            #expect(!store.deliver(markedOnly, editedText: nil, workspace: rig.workspace, submit: true))
        }
    }

    /// `#cm-93`: once the paste preview is edited, the box is what gets sent —
    /// `#cm-69`'s 2026-09-04 *"exactly what Paste will send"* — so the payload
    /// on the clipboard is the edited text, not the marks' serialization.
    @Test("An edited preview is what gets pasted, not the marks' serialization")
    func editedPreviewIsThePayload() async throws {
        try await Self.withRig(transcript: Self.oneReply()) { rig, store in
            Self.setLifecycle(.idle, rig: rig)
            await store.refresh(workspace: rig.workspace)

            let edited = "1.\n> \"a span\" please reword this"
            #expect(edited != Self.draft.serialized())
            #expect(store.deliver(Self.draft, editedText: edited, workspace: rig.workspace, submit: false))
            #expect(NSPasteboard.general.string(forType: .string) == edited)
        }
    }

    /// Tom, 2026-09-14 (Q2): a blank edited box is refused like an empty draft,
    /// and a refusal leaves the clipboard as it was.
    @Test("A blank edited preview is refused and leaves the clipboard alone")
    func blankEditedPreviewIsRefused() async throws {
        try await Self.withRig(transcript: Self.oneReply()) { rig, store in
            Self.setLifecycle(.idle, rig: rig)
            await store.refresh(workspace: rig.workspace)

            let sentinel = "clipboard before #cm-93 \(UUID().uuidString)"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(sentinel, forType: .string)

            #expect(!store.deliver(Self.draft, editedText: " \n ", workspace: rig.workspace, submit: false))
            #expect(!store.deliver(Self.draft, editedText: "", workspace: rig.workspace, submit: true))
            #expect(NSPasteboard.general.string(forType: .string) == sentinel)
        }
    }

    /// With nothing bound there is no pane to type into. Not a refusal — an
    /// impossibility, and `deliver` reports it by resolving nothing.
    @Test("Nothing bound means nothing can be delivered")
    func unboundDeliversNothing() async throws {
        try await Self.withRig(transcript: "") { _, store in
            #expect(!store.deliver(Self.draft, editedText: nil, workspace: nil, submit: false))
            #expect(!store.deliver(Self.draft, editedText: nil, workspace: nil, submit: true))
        }
    }

    /// One assistant line, so the model has a newest turn the gate can be
    /// asked about. An empty transcript has none, and `isNewestTurnWriting`
    /// is then false for a reason that says nothing about the gate.
    private static func oneReply() -> String {
        longTranscript(lines: 1)
    }

    private static func markdown(_ store: ReplyPanelStore) -> String? {
        guard case let .showing(reading) = store.model.state else { return nil }
        return reading.group.markdown
    }
}

/// The Reply header's pin — `#cm-91`.
///
/// Unpinned, a send hides the right sidebar; pinned, it stays. The decision
/// lives on the store so a test can reach it — no test drives
/// `ReplyPanelView`, so where `send` calls it is checked by hand.
@MainActor
@Suite("Reply pin")
struct ReplyPanelPinTests {
    @Test("A new panel starts unpinned")
    func newStoreIsUnpinned() {
        #expect(ReplyPanelStore().isPinned == false)
    }

    @Test("Unpinned, a delivered send closes the sidebar")
    func unpinnedDeliveredCloses() {
        let store = ReplyPanelStore()
        store.isPinned = false
        #expect(store.closesSidebarAfterSend(delivered: true) == true)
    }

    @Test("A refused send never closes the sidebar")
    func refusedNeverCloses() {
        let store = ReplyPanelStore()
        store.isPinned = false
        #expect(store.closesSidebarAfterSend(delivered: false) == false)
        store.isPinned = true
        #expect(store.closesSidebarAfterSend(delivered: false) == false)
    }

    @Test("Pinned, a delivered send keeps the sidebar open")
    func pinnedKeepsOpen() {
        let store = ReplyPanelStore()
        store.isPinned = true
        #expect(store.closesSidebarAfterSend(delivered: true) == false)
    }
}
