import CMUXAgentLaunch
import CmuxAgentJournal
import Foundation
import Darwin
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct ClaudeHookAttentionResolutionTests {
    private typealias Fixture = ClaudeHookAttentionTestFixture

    @Test func installedSettingsRouteQuestionAndPlanAndAllCompletions() throws {
        let fixture = try Fixture()
        let result = try fixture.process(["hooks", "claude", "inject-settings"])
        let settings = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let hooks = try #require(settings["hooks"] as? [String: [[String: Any]]])
        let groups = try #require(hooks["PostToolUse"])
        #expect(groups.contains { ($0["matcher"] as? String) == "" })
        let forms = groups.first { ($0["matcher"] as? String) == "AskUserQuestion|ExitPlanMode" }
        let commands = (forms?["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String } ?? []
        #expect(commands.contains { $0.contains("hooks feed --source claude") })
    }

    @Test(arguments: ["AskUserQuestion", "ExitPlanMode"])
    func bypassFormCompletionResolvesNativeToolIdentity(tool: String) throws {
        let fixture = try Fixture()
        try fixture.run(["hooks", "feed", "--source", "claude"], event: "PostToolUse", tool: tool, toolID: "native-tool")
        let wire = try #require(fixture.context.state.snapshot().compactMap { line -> [String: Any]? in
            guard let data = line.data(using: .utf8), let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  frame["method"] as? String == "feed.push", let params = frame["params"] as? [String: Any] else { return nil }
            return params["event"] as? [String: Any]
        }.first)
        let event = try JSONDecoder().decode(WorkstreamEvent.self, from: JSONSerialization.data(withJSONObject: wire))
        let draft = try #require(AgentFeedSemanticInput(event: event, agentKey: "claude_code",
            workspaceID: UUID(uuidString: fixture.context.workspaceId), surfaceID: UUID(uuidString: fixture.context.surfaceId)).draft())
        #expect(draft.kind == .attentionResolved)
        #expect(draft.attention?.requestIdentity == "native-tool")
    }

    @Test(arguments: ["Bash", "AskUserQuestion", "ExitPlanMode"])
    func matchingCompletionResolvesOnlyRecordedFeedWait(tool: String) throws {
        let fixture = try Fixture()
        let wait = try fixture.permission(tool: tool)
        #expect(try fixture.completions(tool: "Other").isEmpty)
        #expect(try fixture.completions(tool: tool, input: ["command": "other"]).isEmpty)
        let resolved = try fixture.completions(tool: tool)
        #expect(resolved.count == 1)
        let answer = try #require(resolved.first)
        #expect(answer.attention?.requestIdentity == wait.id)
        #expect(!answer.pendingWork)
        fixture.append(answer)
        #expect(fixture.reconciler.openRequests(source: "claude", sessionId: "session").count == 0)
        #expect(try fixture.completions(tool: tool).isEmpty)
    }

    @Test func oldCompletionCannotRetireNewerWait() throws {
        let fixture = try Fixture()
        let first = try fixture.permission()
        fixture.answerByKey()
        let second = try fixture.permission(tool: "Edit", input: ["file_path": "/tmp/second"])
        let old = try #require(try fixture.completions().first)
        #expect(old.attention?.requestIdentity == first.id)
        #expect(fixture.append(old).invalidatedCorrelationKeys.isEmpty)
        #expect(fixture.reconciler.openRequests(source: "claude", sessionId: "session").identified == [second.id])
        let current = try #require(try fixture.completions(tool: "Edit", input: ["file_path": "/tmp/second"]).first)
        #expect(fixture.append(current).invalidatedCorrelationKeys == [second.id])
        #expect(fixture.reconciler.openRequests(source: "claude", sessionId: "session").count == 0)
    }

    @Test func helperCompletionCannotRetireMainThreadWait() throws {
        let fixture = try Fixture()
        _ = try fixture.permission()
        #expect(try fixture.completions(helper: "h1").isEmpty)
        #expect(fixture.reconciler.openRequests(source: "claude", sessionId: "session").count == 1)
        let own = try #require(try fixture.completions().first)
        fixture.append(own)
        #expect(fixture.reconciler.openRequests(source: "claude", sessionId: "session").count == 0)
    }

    @Test func helperFeedIngressUsesFreshFeedIdentityForEachWait() throws {
        let fixture = try Fixture()
        for _ in 0..<2 {
            let wait = try fixture.permission(helper: "h1")
            #expect(wait.draft.attention?.requestIdentity == wait.id)
            let answer = try #require(try fixture.completions(helper: "h1").first)
            fixture.append(answer)
            #expect(fixture.reconciler.openRequests(source: "claude", sessionId: "session").count == 0)
        }
    }

    @Test(arguments: [("prompt-submit", "UserPromptSubmit"), ("stop", "Stop"), ("session-end", "SessionEnd")])
    func turnBoundaryClearsPendingPairing(boundary: (String, String)) throws {
        let fixture = try Fixture()
        _ = try fixture.permission()
        try fixture.run(["hooks", "claude", boundary.0], event: boundary.1)
        #expect(try fixture.completions().isEmpty)
    }
    @Test func pairingExistsAndCompletesWhilePermissionFeedCallStillBlocks() throws {
        let fixture = try Fixture()
        let arrived = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let context = fixture.context
        CLIMockAcceptLoopRegistry.shared.start(listenerFD: context.listenerFD, onConnection: { fd in
            defer { Darwin.close(fd) }
            cliMockServeLineFramedConnection(clientFD: fd) { line in
                context.state.append(line)
                guard let data = line.data(using: .utf8),
                      let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = frame["id"] as? String, let method = frame["method"] as? String else { return "OK" }
                if method == "feed.push", let params = frame["params"] as? [String: Any],
                   (params["wait_timeout_seconds"] as? Double ?? 0) > 0 {
                    arrived.signal()
                    _ = release.wait(timeout: .now() + 10)
                }
                if method == "surface.list" {
                    return fixture.support.surfaceListResponse(id: id, surfaceId: context.surfaceId)
                }
                return fixture.support.v2Response(id: id, ok: true, result: [:])
            }
        }, onListenerClosed: {})
        let process = Process()
        process.executableURL = URL(fileURLWithPath: context.cliPath)
        process.arguments = ["hooks", "feed", "--source", "claude"]
        process.environment = fixture.environment
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = context.root
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        defer {
            release.signal()
            do { try fixture.waitForExit(process, exited: exited) }
            catch { Issue.record(error) }
        }
        stdin.fileHandleForWriting.write(Data(#"{"session_id":"session","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"sleep 20"}}"#.utf8))
        try stdin.fileHandleForWriting.close()
        #expect(arrived.wait(timeout: .now() + 5) == .success)
        let url = context.root.appendingPathComponent("claude-hook-sessions.json")
        let state = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let session = (state?["sessions"] as? [String: [String: Any]])?["session"]
        #expect((session?["pendingClaudePermissions"] as? [[String: Any]])?.count == 1)
        #expect(try fixture.completions().count == 1)
    }

    // MARK: - The queued PostToolUse path (cm-128.1)

    /// A server that answers every request ok, so `hooks enqueue` completes. Requests still land in `context.state`.
    private func acceptEverything(_ fixture: Fixture) {
        let context = fixture.context
        CLIMockAcceptLoopRegistry.shared.start(listenerFD: context.listenerFD, onConnection: { fd in
            defer { Darwin.close(fd) }
            cliMockServeLineFramedConnection(clientFD: fd) { line in
                context.state.append(line)
                guard let data = line.data(using: .utf8),
                      let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = frame["id"] as? String, let method = frame["method"] as? String else { return "OK" }
                if method == "surface.list" {
                    return fixture.support.surfaceListResponse(id: id, surfaceId: context.surfaceId)
                }
                return fixture.support.v2Response(id: id, ok: true, result: [:])
            }
        }, onListenerClosed: {})
    }

    /// The command `inject-settings` installs for Claude's `PostToolUse`, run as Claude runs it: through `sh`, with the
    /// payload on stdin. Returns what the hook admitted to the app, the `agent.hook.enqueue` request's params.
    private func enqueueThroughInstalledPostToolUse(_ fixture: Fixture, payload: String) throws -> [String: Any] {
        let result = try fixture.process(["hooks", "claude", "inject-settings"])
        let settings = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let hooks = try #require(settings["hooks"] as? [String: [[String: Any]]])
        let command = try #require(hooks["PostToolUse"]?.lazy.compactMap { group -> String? in
            (group["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String }
                .first { $0.contains("hooks enqueue claude post-tool-use") }
        }.first)
        acceptEverything(fixture)
        let before = fixture.context.state.snapshot().count
        var environment = fixture.environment
        environment["CMUX_BUNDLED_CLI_PATH"] = fixture.context.cliPath
        let ran = runCodexHookProcess(executablePath: "/bin/sh", arguments: ["-c", command],
            environment: environment, standardInput: payload, timeout: 8)
        #expect(!ran.timedOut, Comment(rawValue: ran.stderr))
        #expect(ran.status == 0, Comment(rawValue: ran.stderr))
        let request = fixture.context.state.snapshot().dropFirst(before).compactMap { line -> [String: Any]? in
            guard let data = line.data(using: .utf8),
                  let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  frame["method"] as? String == "agent.hook.enqueue" else { return nil }
            return frame
        }.first
        // Without the queued policy entry the CLI refuses before it sends anything, and the shell wrapper
        // swallows the refusal: exit 0, `{}`, nothing on the socket.
        return try #require(request?["params"] as? [String: Any],
            "the installed PostToolUse command never reached agent.hook.enqueue; stderr: \(ran.stderr)")
    }

    private func postToolUsePayload(tool: String, input: [String: Any], responseBytes: Int = 0,
                                    helper: String? = nil) throws -> String {
        var object: [String: Any] = ["session_id": "session", "hook_event_name": "PostToolUse",
                                     "tool_name": tool, "tool_input": input]
        if let helper { object["agent_id"] = helper }
        if responseBytes > 0 { object["tool_response"] = ["content": String(repeating: "r", count: responseBytes)] }
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    /// What the app does with an admitted event: it runs the CLI's handler for it, with the admitted payload on stdin.
    private func deliver(_ params: [String: Any], _ fixture: Fixture) throws -> [AgentJournalEventDraft] {
        let event = try #require(AgentHookDeliveryEvent(params: params))
        let before = fixture.context.state.snapshot().count
        let result = try fixture.process(Array(event.deliveryArguments), input: event.payload)
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        return fixture.context.state.snapshot().dropFirst(before).compactMap { line in
            guard line.hasPrefix("agent_journal_append ") else { return nil }
            return try? JSONDecoder().decode(AgentJournalEventDraft.self, from: Data(line.dropFirst("agent_journal_append ".count).utf8))
        }.filter { $0.kind == .attentionResolved }
    }

    /// The installed command, run as Claude runs it, reaches the queue, and the app's delivery routes it to
    /// the handler the direct call reaches. The handler tests alone ran `hooks claude post-tool-use` directly and never
    /// went through `hooks enqueue`, which refused the subcommand.
    @Test func installedPostToolUseCommandReachesTheHandlerThroughTheQueue() throws {
        let fixture = try Fixture()
        let wait = try fixture.permission()
        let params = try enqueueThroughInstalledPostToolUse(fixture,
            payload: try postToolUsePayload(tool: "Bash", input: ["command": "sleep 20"]))
        #expect(params["agent"] as? String == "claude")
        #expect(params["subcommand"] as? String == "post-tool-use")
        let event = try #require(AgentHookDeliveryEvent(params: params))
        #expect(event.deliveryArguments == ["hooks", "claude", "post-tool-use"])
        let resolved = try deliver(params, fixture)
        #expect(resolved.count == 1)
        #expect(resolved.first?.attention?.requestIdentity == wait.id)
    }

    /// A `PostToolUse` whose payload goes over the 64 KiB queue limit is compacted, and compaction drops most
    /// of `tool_input`. The pairing must still match, so the fingerprint travels from before the compaction.
    @Test func oversizedPostToolUseStillResolvesItsWaitThroughTheQueue() throws {
        let fixture = try Fixture()
        let input = ["file_path": "/tmp/large", "new_string": String(repeating: "n", count: 70 * 1_024)]
        let wait = try fixture.permission(tool: "Edit", input: input)
        let params = try enqueueThroughInstalledPostToolUse(fixture,
            payload: try postToolUsePayload(tool: "Edit", input: input, responseBytes: 80 * 1_024))
        let admitted = try #require(params["payload"] as? String)
        #expect(admitted.utf8.count <= AgentHookDeliveryPolicy.maximumPayloadBytes, "the payload was compacted")
        let resolved = try deliver(params, fixture)
        #expect(resolved.count == 1, "the compacted completion did not match its pairing")
        #expect(resolved.first?.attention?.requestIdentity == wait.id)
    }

    /// Claude's `AskUserQuestion` completion carries its request's `questions` plus the `answers` and `annotations` (shapes
    /// copied from a live run), so the whole `tool_input` differs between the request and the completion. The pairing must
    /// still match, on `questions` alone.
    @Test func askUserQuestionCompletionWithAnswersStillResolvesItsWait() throws {
        let fixture = try Fixture()
        let questions: [[String: Any]] = [[
            "question": "Proceed with the sleep and the subagent probe?", "header": "Proceed", "multiSelect": false,
            "options": [["label": "Yes (Recommended)", "description": "Runs the full sequence"],
                        ["label": "No", "description": "Stops here"]],
        ]]
        let wait = try fixture.permission(tool: "AskUserQuestion", extra: ["tool_input": ["questions": questions]])
        let params = try enqueueThroughInstalledPostToolUse(fixture, payload: try postToolUsePayload(
            tool: "AskUserQuestion",
            input: ["questions": questions,
                    "answers": ["Proceed with the sleep and the subagent probe?": "Yes (Recommended)"],
                    "annotations": [String: Any]()]))
        let resolved = try deliver(params, fixture)
        #expect(resolved.count == 1, "the completion with answers did not match the question's pairing")
        #expect(resolved.first?.attention?.requestIdentity == wait.id)
    }

    /// A helper subagent's oversized completion. The pairing matches `agent_id` strictly, and compaction used to
    /// drop that key, so a helper's large Edit or Bash completion never paired.
    @Test func oversizedHelperPostToolUseKeepsItsAgentIdAndResolvesItsWait() throws {
        let fixture = try Fixture()
        let input = ["file_path": "/tmp/large-helper", "new_string": String(repeating: "h", count: 70 * 1_024)]
        let wait = try fixture.permission(tool: "Edit", input: input, helper: "h1")
        let params = try enqueueThroughInstalledPostToolUse(fixture,
            payload: try postToolUsePayload(tool: "Edit", input: input, responseBytes: 80 * 1_024, helper: "h1"))
        let admitted = try #require(params["payload"] as? String)
        #expect(admitted.utf8.count <= AgentHookDeliveryPolicy.maximumPayloadBytes, "the payload was compacted")
        let compact = try #require(try JSONSerialization.jsonObject(with: Data(admitted.utf8)) as? [String: Any])
        #expect(compact["agent_id"] as? String == "h1", "compaction dropped the helper's agent_id")
        let resolved = try deliver(params, fixture)
        #expect(resolved.count == 1, "the helper's compacted completion did not match its pairing")
        #expect(resolved.first?.attention?.requestIdentity == wait.id)
    }

    /// Every hook `inject-settings` routes through the queue must be accepted by the queued policy, or the CLI refuses it
    /// and the shell wrapper hides the refusal.
    @Test func everyInstalledQueuedClaudeHookIsAcceptedByTheQueuedPolicy() throws {
        let fixture = try Fixture()
        let result = try fixture.process(["hooks", "claude", "inject-settings"])
        let settings = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let hooks = try #require(settings["hooks"] as? [String: [[String: Any]]])
        var routed = Set<String>()
        for command in hooks.values.flatMap({ $0 }).flatMap({ ($0["hooks"] as? [[String: Any]]) ?? [] }).compactMap({ $0["command"] as? String }) {
            guard let range = command.range(of: "hooks enqueue claude ") else { continue }
            routed.insert(String(command[range.upperBound...].prefix { !$0.isWhitespace && $0 != ";" }))
        }
        #expect(routed.contains("post-tool-use"))
        for subcommand in routed {
            #expect(AgentHookDeliveryPolicy().supportsQueuedDelivery(agent: "claude", subcommand: subcommand),
                "installed `hooks enqueue claude \(subcommand)` is refused by the queued policy")
        }
    }
}
