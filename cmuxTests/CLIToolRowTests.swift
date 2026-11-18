import CmuxAgentJournal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// cm-124.6: Claude's tool rows on the CLI paths: the `PreToolUse` branch keyed on the app's stamp, the `PostToolUse`
/// resolution, and the Feed hook's early exit that reads the global file itself. Each child runs with a scratch `HOME`,
/// `CFFIXED_USER_HOME` and `XDG_CONFIG_HOME` (the fixture sets all three), so Tom's real `cmux.json` is never read.
@Suite(.serialized)
struct CLIToolRowTests {
    private let tool = "CmuxDemoTool"
    private let toolUseId = "toolu_demo1"

    // MARK: helpers

    private func decode(_ lines: [String]) -> [AgentJournalEventDraft] {
        lines.compactMap { line in
            guard line.hasPrefix("agent_journal_append ") else { return nil }
            return try? JSONDecoder().decode(AgentJournalEventDraft.self, from: Data(line.dropFirst("agent_journal_append ".count).utf8))
        }
    }

    private struct Run {
        let lines: [String]
        let drafts: [AgentJournalEventDraft]
        let stdout: String
        let elapsed: TimeInterval
    }

    @discardableResult
    private func runHook(
        _ fixture: ClaudeHookAttentionTestFixture,
        _ arguments: [String],
        event: String,
        tool: String,
        mode: String = "auto",
        toolUseId: String? = "toolu_demo1",
        input: [String: Any] = [:],
        toolKey: String = "tool_name"
    ) throws -> Run {
        let before = fixture.context.state.snapshot().count
        var payload: [String: Any] = [
            "session_id": "session", "hook_event_name": event, toolKey: tool,
            "tool_input": input, "permission_mode": mode, "cwd": fixture.context.root.path,
        ]
        if let toolUseId { payload["tool_use_id"] = toolUseId }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let start = Date()
        let result = try fixture.process(arguments, input: json)
        let elapsed = Date().timeIntervalSince(start)
        #expect(!result.timedOut, "\(result.stderr)")
        #expect(result.status == 0, "\(result.stderr)")
        let lines = Array(fixture.context.state.snapshot().dropFirst(before))
        return Run(lines: lines, drafts: decode(lines), stdout: result.stdout, elapsed: elapsed)
    }

    private func preToolUse(
        _ fixture: ClaudeHookAttentionTestFixture, tool: String, mode: String = "auto", stamp: String?,
        input: [String: Any] = [:], toolKey: String = "tool_name"
    ) throws -> Run {
        if let stamp { fixture.extraEnvironment["CMUX_AGENT_TOOL_MEANS"] = stamp }
        defer { fixture.extraEnvironment["CMUX_AGENT_TOOL_MEANS"] = nil }
        return try runHook(fixture, ["hooks", "claude", "pre-tool-use"], event: "PreToolUse", tool: tool, mode: mode,
                           input: input, toolKey: toolKey)
    }

    private func isBellStatus(_ line: String) -> Bool {
        line.hasPrefix("set_status claude_code ") && line.contains("--icon=bell.fill")
    }

    private func isRunningStatus(_ line: String) -> Bool {
        line.hasPrefix("set_status claude_code ") && !line.contains("--icon=bell.fill")
    }

    private func writeRows(_ fixture: ClaudeHookAttentionTestFixture, _ text: String) throws {
        let directory = fixture.context.root.appendingPathComponent(".config/cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: directory.appendingPathComponent("cmux.json"), atomically: true, encoding: .utf8)
    }

    private func rowsFile(_ rows: String) -> String {
        // JSONC on purpose: the hook reads the file through doctor's parse, comments included.
        "{\n  // a stand-in until Claude ships a new asking tool\n  \"agentEvents\": [\(rows)]\n}\n"
    }

    // MARK: PreToolUse, a row tool (A11e; E54, E56)

    @Test(arguments: ["auto", "default", "bypassPermissions", "acceptEdits"], ["question", "plan-review"])
    func aRowToolRaisesTheHandAndOneBannerInEveryPermissionMode(mode: String, word: String) throws {
        let fixture = try ClaudeHookAttentionTestFixture()
        let run = try preToolUse(fixture, tool: tool, mode: mode, stamp: word)
        let kind: AgentJournalEventKind = word == "question" ? .questionRequested : .planReviewRequested
        let waits = run.drafts.filter { $0.kind == kind }
        #expect(waits.count == 2, "the journal append and the banner's append: \(run.lines)")
        for wait in waits {
            #expect(wait.detail == "tool-row:\(tool)", "both appends carry the marker")
            #expect(wait.attention?.requestIdentity == toolUseId)
            #expect(wait.nativeEvent == "PreToolUse")
        }
        let banners = waits.compactMap(\.attention?.notification)
        #expect(banners.count == 1, "exactly one banner")
        #expect(banners.first?.title == "Claude Code · Needs your answer")
        #expect(banners.first?.body == "Waiting for input")
        #expect(run.lines.contains(where: isBellStatus), "the Needs input status in \(mode) mode: \(run.lines)")
        #expect(!run.lines.contains(where: isRunningStatus), "no Running status for a row tool")
        #expect(!run.drafts.contains { $0.kind == .turnStarted || $0.kind == .stateChanged }, "no Running for a row tool")
    }

    @Test func aRowToolKeepsTheNeedsInputLifecycleInTheSessionRecord() throws {
        let fixture = try ClaudeHookAttentionTestFixture()
        _ = try preToolUse(fixture, tool: tool, stamp: "question")
        let data = try Data(contentsOf: fixture.context.root.appendingPathComponent("claude-hook-sessions.json"))
        let state = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let record = try #require((state["sessions"] as? [String: Any])?["session"] as? [String: Any])
        #expect(record["agentLifecycle"] as? String == "needsInput")
        #expect(record["lastBody"] as? String == "Waiting for input")
    }

    @Test(arguments: ["", "approval", "idle", "ignore", "QUESTION"])
    func aStampThatIsNotARowWordIsNoStamp(stamp: String) throws {
        let fixture = try ClaudeHookAttentionTestFixture()
        let run = try preToolUse(fixture, tool: tool, stamp: stamp)
        #expect(!run.drafts.contains { $0.kind == .questionRequested || $0.kind == .planReviewRequested })
        #expect(!run.lines.contains(where: isBellStatus))
    }

    @Test func aToolWithNoStampTakesTheRunningTailAsToday() throws {
        let fixture = try ClaudeHookAttentionTestFixture()
        let run = try preToolUse(fixture, tool: tool, stamp: nil)
        #expect(!run.drafts.contains { $0.kind == .questionRequested || $0.kind == .planReviewRequested })
        #expect(run.drafts.contains { $0.kind == .stateChanged || $0.kind == .turnStarted }, "\(run.lines)")
        #expect(run.lines.contains(where: isRunningStatus), "the Running status is sent: \(run.lines)")
        #expect(!run.lines.contains(where: isBellStatus))
    }

    @Test func aHisRowThatChangesABuiltInWordTakesTheRowPathWithNoQuestionText() throws {
        let fixture = try ClaudeHookAttentionTestFixture()
        let run = try preToolUse(
            fixture, tool: "AskUserQuestion", mode: "default", stamp: "plan-review",
            input: ["questions": [["question": "Which color?", "header": "Color", "options": [["label": "Red"]]]]]
        )
        let waits = run.drafts.filter { $0.kind == .planReviewRequested }
        #expect(waits.count == 2)
        #expect(waits.allSatisfy { $0.detail == "tool-row:AskUserQuestion" })
        #expect(waits.compactMap(\.attention?.notification).first?.body == "Waiting for input", "no question text for a row tool")
        #expect(run.lines.contains(where: isBellStatus), "the row path publishes in default mode")
    }

    // MARK: PreToolUse, the built-in tools exactly as today (A11a's local half; E53)

    @Test(arguments: ["AskUserQuestion", "ExitPlanMode"], ["auto", "default", "bypassPermissions"])
    func aBuiltInToolWithNoStampIsExactlyToday(builtIn: String, mode: String) throws {
        let fixture = try ClaudeHookAttentionTestFixture()
        let input: [String: Any] = builtIn == "AskUserQuestion"
            ? ["questions": [["question": "Which color?", "header": "Color", "options": [["label": "Red"], ["label": "Blue"]]]]]
            : ["plan": "# Plan: echo hi\n\n## Step\n1. Run echo hi"]
        let run = try preToolUse(fixture, tool: builtIn, mode: mode, stamp: nil, input: input)
        let kind: AgentJournalEventKind = builtIn == "AskUserQuestion" ? .questionRequested : .planReviewRequested
        let waits = run.drafts.filter { $0.kind == kind }
        #expect(waits.allSatisfy { $0.detail == nil }, "no tool-row marker on a built-in tool")
        let bypass = mode == "bypassPermissions"
        #expect(waits.count == (bypass ? 2 : 1), "the banner's append only in bypass mode: \(run.lines)")
        #expect(run.lines.contains(where: isBellStatus) == bypass, "status only in bypass mode")
        let body = waits.compactMap(\.attention?.notification).first?.body
        if bypass {
            #expect(body?.contains(builtIn == "AskUserQuestion" ? "Which color" : "echo hi") == true, "its own text: \(body ?? "nil")")
        } else {
            #expect(body == nil)
        }
        #expect(!run.lines.contains(where: isRunningStatus))
    }

    @Test func aStampedToolWithOnlyTheCamelCaseNameTakesTheRowPathAsTheAppDecided() throws {
        let fixture = try ClaudeHookAttentionTestFixture()
        let run = try preToolUse(fixture, tool: tool, stamp: "question", toolKey: "toolName")
        #expect(run.drafts.filter { $0.kind == .questionRequested }.count == 2, "\(run.lines)")
        #expect(run.lines.contains(where: isBellStatus))
    }

    @Test(arguments: ["AskUserQuestion", "ExitPlanMode"])
    func aBuiltInToolWithOnlyTheCamelCaseNameAndNoStampKeepsTodaysPath(builtIn: String) throws {
        let fixture = try ClaudeHookAttentionTestFixture()
        let run = try preToolUse(fixture, tool: builtIn, stamp: nil, toolKey: "toolName")
        #expect(!run.drafts.contains { $0.kind == .questionRequested || $0.kind == .planReviewRequested },
                "today's branch reads only tool_name, so this takes the Running tail")
    }

    // MARK: the join with the reconciler (round 2, #2)

    /// The drafts a row tool's `PreToolUse` records, as the reconciler reads them: the same file feeds
    /// `AgentNotificationReconcilerTests`, so the CLI and the reconciler are joined by a test.
    static func joinFixtureURL(from file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packages/macOS/CmuxAgentJournal/Tests/CmuxAgentJournalTests/Fixtures/tool-row-pre-tool-use-drafts.json")
    }

    private func scrubbed(_ draft: AgentJournalEventDraft, cwd: String) -> AgentJournalEventDraft {
        var copy = draft
        copy.eventId = "EVENT"
        copy.occurredAtMs = 0
        if var notification = copy.attention?.notification {
            if notification.subtitle == URL(fileURLWithPath: cwd).lastPathComponent { notification.subtitle = "CWD" }
            copy.attention?.notification = notification
        }
        return copy
    }

    @Test func theDraftsAClaudeRowToolRecordsAreTheOnesTheReconcilerFixtureHolds() throws {
        let fixture = try ClaudeHookAttentionTestFixture()
        let run = try preToolUse(fixture, tool: tool, stamp: "question")
        let recorded = run.drafts.filter { $0.kind == .questionRequested }.map { scrubbed($0, cwd: fixture.context.root.path) }
        let actualJSON = String(decoding: try JSONEncoder().encode(recorded), as: UTF8.self)
        let url = Self.joinFixtureURL()
        guard let data = try? Data(contentsOf: url) else {
            Issue.record("missing \(url.path); recorded drafts: \(actualJSON)")
            return
        }
        let expected = try JSONDecoder().decode([AgentJournalEventDraft].self, from: data)
        #expect(recorded == expected, "recorded: \(actualJSON)")
    }

    // MARK: PostToolUse (A11e; E54's drop)

    @Test func aRowToolsPostToolUseResolvesItsWaitByToolUseId() throws {
        let fixture = try ClaudeHookAttentionTestFixture()
        let pre = try preToolUse(fixture, tool: tool, stamp: "question")
        for draft in pre.drafts { fixture.append(draft) }
        #expect(fixture.reconciler.openRequests(source: "claude", sessionId: "session").identified == [toolUseId])

        fixture.extraEnvironment["CMUX_AGENT_TOOL_MEANS"] = "question"
        let post = try runHook(fixture, ["hooks", "claude", "post-tool-use"], event: "PostToolUse", tool: tool)
        let resolved = post.drafts.filter { $0.kind == .attentionResolved }
        #expect(resolved.count == 1, "\(post.lines)")
        #expect(resolved.first?.attention?.requestIdentity == toolUseId)
        #expect(resolved.first?.nativeEvent == "PostToolUse")
        for draft in post.drafts { fixture.append(draft) }
        #expect(fixture.reconciler.openRequests(source: "claude", sessionId: "session").count == 0, "the wait is retired")
    }

    @Test func aPostToolUseWithNoStampResolvesNothing() throws {
        let fixture = try ClaudeHookAttentionTestFixture()
        _ = try preToolUse(fixture, tool: tool, stamp: "question")
        let post = try runHook(fixture, ["hooks", "claude", "post-tool-use"], event: "PostToolUse", tool: tool)
        #expect(!post.drafts.contains { $0.kind == .attentionResolved })
    }

    @Test func aStampedPostToolUseWithNoToolUseIdResolvesNothing() throws {
        let fixture = try ClaudeHookAttentionTestFixture()
        _ = try preToolUse(fixture, tool: tool, stamp: "question")
        fixture.extraEnvironment["CMUX_AGENT_TOOL_MEANS"] = "question"
        let post = try runHook(fixture, ["hooks", "claude", "post-tool-use"], event: "PostToolUse", tool: tool, toolUseId: nil)
        #expect(!post.drafts.contains { $0.kind == .attentionResolved })
    }

    // MARK: the Feed hook's early exit (A11d; E55, E60)

    private func feedPermission(_ fixture: ClaudeHookAttentionTestFixture, tool: String) throws -> Run {
        try runHook(fixture, ["hooks", "feed", "--source", "claude"], event: "PermissionRequest", tool: tool,
                    input: ["command": "echo hi"])
    }

    private func feedPushCount(_ run: Run) -> Int {
        run.lines.filter { $0.contains("\"method\":\"feed.push\"") }.count
    }

    @Test func aRowToolsPermissionGetsEmptyAtOnceWithNothingOnTheSocket() throws {
        let fixture = try ClaudeHookAttentionTestFixture()
        try writeRows(fixture, rowsFile(#"{ "agent": "claude", "tool": "CmuxDemoTool", "means": "question" }"#))
        let run = try feedPermission(fixture, tool: tool)
        #expect(run.stdout == "{}\n")
        #expect(run.lines.isEmpty, "nothing on the socket, no Feed card: \(run.lines)")
        #expect(run.elapsed < 0.5, "returned in \(run.elapsed) s")
    }

    @Test func aStarRowReachesClaudeToo() throws {
        let fixture = try ClaudeHookAttentionTestFixture()
        try writeRows(fixture, rowsFile(#"{ "agent": "*", "tool": "CmuxDemoTool", "means": "plan-review" }"#))
        let run = try feedPermission(fixture, tool: tool)
        #expect(run.stdout == "{}\n")
        #expect(run.lines.isEmpty)
    }

    @Test func withNoRowsAToolGetsTodaysApprovalCardAndAskUserQuestionItsCard() throws {
        let fixture = try ClaudeHookAttentionTestFixture()
        let demo = try feedPermission(fixture, tool: tool)
        #expect(feedPushCount(demo) >= 1, "today's approval card: \(demo.lines)")
        let ask = try feedPermission(fixture, tool: "AskUserQuestion")
        #expect(feedPushCount(ask) >= 1, "today's question card: \(ask.lines)")
    }

    @Test(arguments: [
        "{ not json",
        #"{ "agentEvents": [ { "agent": "claude", "tool": "CmuxDemoTool", "means": "ignore" } ] }"#,
        #"{ "agentEvents": [ { "agent": "claude", "tool": "CmuxDemoTool", "means": "question" }, { "agent": "claude", "means": "question" } ] }"#,
        #"{ "agentEvents": "nope" }"#,
        "",
    ])
    func aBadOrEmptyFileFallsBackToTheBuiltInRowsSoTheToolKeepsItsApprovalCard(file: String) throws {
        let fixture = try ClaudeHookAttentionTestFixture()
        try writeRows(fixture, file)
        let run = try feedPermission(fixture, tool: tool)
        #expect(feedPushCount(run) >= 1, "today's approval card: \(run.lines)")
    }

    @Test func aToolRowNamesTheToolExactly() throws {
        let fixture = try ClaudeHookAttentionTestFixture()
        try writeRows(fixture, rowsFile(#"{ "agent": "claude", "tool": "cmuxdemotool", "means": "question" }"#))
        let run = try feedPermission(fixture, tool: tool)
        #expect(feedPushCount(run) >= 1, "a different case is a different tool")
    }

    /// The two ends of one decision: the `PreToolUse` branch publishes the status and the banner for a row tool in every
    /// mode, because its `PermissionRequest` (the hook the upstream comment says "owns the status/bell" outside bypass mode)
    /// gets `{}` and publishes nothing. If either end changes alone, a row tool shows two banners or none.
    @Test(arguments: ["auto", "default", "acceptEdits", "bypassPermissions"])
    func aRowToolsBannerComesFromItsPreToolUseAloneAndItsPermissionRequestPublishesNothing(mode: String) throws {
        let fixture = try ClaudeHookAttentionTestFixture()
        try writeRows(fixture, rowsFile(#"{ "agent": "claude", "tool": "CmuxDemoTool", "means": "question" }"#))
        let pre = try preToolUse(fixture, tool: tool, mode: mode, stamp: "question")
        let permission = try runHook(fixture, ["hooks", "feed", "--source", "claude"], event: "PermissionRequest", tool: tool, mode: mode)
        #expect(permission.stdout == "{}\n")
        #expect(permission.lines.isEmpty, "the permission hook publishes nothing: \(permission.lines)")
        let banners = (pre.drafts + permission.drafts).compactMap(\.attention?.notification)
        #expect(banners.count == 1, "one banner for the call, from PreToolUse: \(pre.lines)")
        #expect(pre.lines.contains(where: isBellStatus), "and the Needs input status, from PreToolUse, in \(mode) mode")
    }

    @Test func aRowThatRestatesABuiltInWordKeepsTheFeedCard() throws {
        let fixture = try ClaudeHookAttentionTestFixture()
        try writeRows(fixture, rowsFile(#"{ "agent": "claude", "tool": "AskUserQuestion", "means": "question" }"#))
        let run = try feedPermission(fixture, tool: "AskUserQuestion")
        #expect(feedPushCount(run) >= 1)
    }

    @Test func aRowThatChangesABuiltInWordGivesItEmpty() throws {
        let fixture = try ClaudeHookAttentionTestFixture()
        try writeRows(fixture, rowsFile(#"{ "agent": "claude", "tool": "AskUserQuestion", "means": "plan-review" }"#))
        let run = try feedPermission(fixture, tool: "AskUserQuestion")
        #expect(run.stdout == "{}\n")
        #expect(run.lines.isEmpty)
    }

    @Test func onlyAPermissionRequestIsAnsweredEmpty() throws {
        let fixture = try ClaudeHookAttentionTestFixture()
        try writeRows(fixture, rowsFile(#"{ "agent": "claude", "tool": "CmuxDemoTool", "means": "question" }"#))
        // A `PostToolUse` Feed event for the row tool keeps today's path; the early exit is for the permission only.
        let run = try runHook(fixture, ["hooks", "feed", "--source", "claude"], event: "PostToolUse", tool: tool)
        #expect(run.stdout == "{}\n")
        // Today's path forwards the event as telemetry before it exits `{}`; the early exit forwards nothing. Without this
        // line the test passes with the `PermissionRequest` condition removed.
        #expect(!run.lines.isEmpty, "the PostToolUse was forwarded, not answered by the early exit: \(run.lines)")
    }

    // MARK: relay (a remote Claude keeps the built-in rows)

    /// A TCP listener on 127.0.0.1 that counts connections: the relay-shaped socket path (`host:port`) a remote CLI is given.
    /// Its accept thread polls a stop flag, and `close()` waits for the thread to finish before it closes the descriptor, so no
    /// thread can outlive the descriptor and accept on a number another suite has reused.
    private final class ConnectionCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var accepted = 0
        private var stopped = false
        private let finished = DispatchSemaphore(value: 0)
        private var listener: Int32 = -1
        private(set) var port: UInt16 = 0

        init() throws {
            listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = 0
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0, Darwin.listen(listener, 8) == 0 else { throw POSIXError(.EADDRINUSE) }
            var bound4 = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &bound4) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(listener, $0, &length) }
            }
            port = UInt16(bigEndian: bound4.sin_port)
            _ = Darwin.fcntl(listener, F_SETFL, Darwin.fcntl(listener, F_GETFL) | O_NONBLOCK)
            let fd = listener
            Thread.detachNewThread { [self] in
                defer { finished.signal() }
                while true {
                    lock.lock(); let done = stopped; lock.unlock()
                    if done { return }
                    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    guard Darwin.poll(&descriptor, 1, 50) > 0 else { continue }
                    let client = Darwin.accept(fd, nil, nil)
                    if client < 0 { continue }
                    lock.lock(); accepted += 1; lock.unlock()
                    Darwin.close(client)
                }
            }
        }

        var count: Int { lock.lock(); defer { lock.unlock() }; return accepted }

        func close() {
            lock.lock(); stopped = true; lock.unlock()
            _ = finished.wait(timeout: .now() + 2)
            Darwin.close(listener)
        }
    }

    @Test func aRelayBackedCLINeverAnswersEmptyForARowToolWhateverItsOwnFileHolds() throws {
        let fixture = try ClaudeHookAttentionTestFixture()
        try writeRows(fixture, rowsFile(#"{ "agent": "claude", "tool": "CmuxDemoTool", "means": "question" }"#))
        let relay = try ConnectionCounter()
        defer { relay.close() }
        fixture.extraEnvironment["CMUX_SOCKET_PATH"] = "127.0.0.1:\(relay.port)"
        fixture.extraEnvironment["CMUX_RELAY_ID"] = "relay-test"
        fixture.extraEnvironment["CMUX_RELAY_TOKEN"] = String(repeating: "ab", count: 32)
        let result = try fixture.process(["hooks", "feed", "--source", "claude"], input: """
        {"session_id":"session","hook_event_name":"PermissionRequest","tool_name":"CmuxDemoTool","tool_input":{},"cwd":"\(fixture.context.root.path)"}
        """, timeout: 20)
        #expect(!result.timedOut)
        #expect(relay.count >= 1, "the hook went on to its normal path and tried the relay; the early exit makes no socket call")
    }

    // MARK: `cmux config doctor` (A11g; E59, E61)

    private func doctor(_ fixture: ClaudeHookAttentionTestFixture, file: String, json: Bool = false) throws
        -> CLINotifyProcessIntegrationRegressionTests.ProcessRunResult {
        try writeRows(fixture, file)
        return try fixture.process(json ? ["config", "doctor", "--json"] : ["config", "doctor"])
    }

    @Test func doctorNamesEachBadToolRowAndTheWarningLikeTheRender() throws {
        let fixture = try ClaudeHookAttentionTestFixture()
        // docs: screen-designs/cm-124 render 15, rows 0..5
        let rows = [
            #"{ "agent": "claude", "notification": "x", "tool": "Write", "means": "question" }"#,
            #"{ "agent": "claude", "tool": "Write", "means": "ignore" }"#,
            #"{ "agent": "claude", "tool": "Edit", "means": "question" }"#,
            #"{ "agent": "claude", "tool": "Edit", "means": "plan-review" }"#,
            #"{ "agent": "codex", "tool": "Bash", "means": "question" }"#,
            #"{ "agent": "claude", "means": "question" }"#,
        ].joined(separator: ",\n")
        let result = try doctor(fixture, file: rowsFile(rows))
        let lines = result.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let expected = [
            #"agentEvents[0]: a row has "notification" or "tool", not both"#,
            #"agentEvents[1]: means "ignore" on a tool row: use question or plan-review"#,
            "agentEvents[3]: same agent and tool as agentEvents[2]; keep one",
            #"agentEvents[5]: a row needs "notification" (a type) or "tool" (a Claude tool)"#,
            "warning: agentEvents[4] does nothing: only Claude's tools reach a tool row",
            "agentEvents: this edit isn't applied; cmux keeps the last valid rows",
        ]
        let start = try #require(lines.firstIndex(of: expected[0]), "\(result.stdout)")
        #expect(Array(lines[start..<(start + expected.count)]) == expected, "\(result.stdout)")
        #expect(result.status != 0, "a bad row makes doctor exit non-zero")
    }

    @Test func doctorWarnsForAToolRowOfAnotherAgentAndExitsZero() throws {
        let fixture = try ClaudeHookAttentionTestFixture()
        let result = try doctor(fixture, file: rowsFile(#"{ "agent": "codex", "tool": "Bash", "means": "question" }"#))
        #expect(result.stdout.contains("agentEvents: 1 row, valid"), "\(result.stdout)")
        #expect(result.stdout.contains("warning: agentEvents[0] does nothing: only Claude's tools reach a tool row"), "\(result.stdout)")
        #expect(result.status == 0, "\(result.stdout) \(result.stderr)")
    }

    @Test func doctorAcceptsAGoodToolRowAndBothWords() throws {
        let fixture = try ClaudeHookAttentionTestFixture()
        let rows = #"{ "agent": "claude", "tool": "Write", "means": "question" }, { "agent": "*", "tool": "Edit", "means": "plan-review" }"#
        let result = try doctor(fixture, file: rowsFile(rows))
        #expect(result.stdout.contains("agentEvents: 2 rows, valid"), "\(result.stdout)")
        #expect(!result.stdout.contains("warning:"))
        #expect(result.status == 0)
    }

    @Test func doctorJSONCarriesTheToolRowRuleNamesAndWarnings() throws {
        let fixture = try ClaudeHookAttentionTestFixture()
        let rows = [
            #"{ "agent": "claude", "notification": "x", "tool": "Write", "means": "question" }"#,
            #"{ "agent": "claude", "tool": "Write", "means": "ignore" }"#,
            #"{ "agent": "claude", "means": "question" }"#,
            #"{ "agent": "claude", "tool": "Edit", "means": "question" }"#,
            #"{ "agent": "claude", "tool": "Edit", "means": "question" }"#,
            #"{ "agent": "codex", "tool": "Bash", "means": "question" }"#,
        ].joined(separator: ",")
        let result = try doctor(fixture, file: rowsFile(rows), json: true)
        let report = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any], "\(result.stdout)")
        let findings = try #require(report["findings"] as? [[String: Any]])
        let events = try #require(findings.compactMap { $0["agent_events"] as? [String: Any] }.first)
        let issues = try #require(events["issues"] as? [[String: Any]])
        #expect(issues.compactMap { $0["rule"] as? String } == ["bothMatchKeys", "badToolMeaning", "noMatchKey", "duplicateToolRow"])
        let warnings = try #require(events["warnings"] as? [[String: Any]])
        #expect(warnings.first?["message"] as? String == "agentEvents[5] does nothing: only Claude's tools reach a tool row")
    }
}
