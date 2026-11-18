import CmuxAgentJournal
import Combine
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// cm-124.5: the app's one agent event table: what reading the global file gives, how it reloads, the two socket methods
/// that answer from it, and how a bad row reaches every window's palette.
@MainActor
@Suite(.serialized)
struct AgentEventTableStoreTests {
    private let approvalRow = #"{"agent":"claude","notification":"worker_permission_prompt","means":"approval"}"#

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-event-table-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ text: String, to path: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Polls a condition for a few seconds: a watcher reloads on the next run-loop turn after a save.
    private func eventually(_ timeout: TimeInterval = 6, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    private func evaluate(_ text: String?, previous: AgentEventTable = .builtIn) -> AgentEventTableStore.Evaluation {
        AgentEventTableStore.evaluate(data: text.map { Data($0.utf8) }, path: "/tmp/cmux.json", previous: previous)
    }

    // MARK: reading the file

    @Test func noFileOrAnEmptyOneMeansBuiltInRows() {
        let his = AgentEventTable(userRows: [.init(agent: "claude", notification: "x", means: .question)])
        #expect(evaluate(nil, previous: his).table == .builtIn)
        #expect(evaluate("", previous: his).table == .builtIn)
        #expect(evaluate(nil).issues.isEmpty)
    }

    @Test func aFileWithNoAgentEventsKeyMeansBuiltInRows() {
        let his = AgentEventTable(userRows: [.init(agent: "claude", notification: "x", means: .question)])
        #expect(evaluate(#"{"workspaceStatuses":[]}"#, previous: his).table == .builtIn, "deleting agentEvents brings the built-in rows back")
    }

    @Test func validRowsApplyAndJSONCCommentsAndTrailingCommasAreAccepted() {
        let result = evaluate("""
        {
          // a comment
          "agentEvents": [ \(approvalRow), ],
        }
        """)
        #expect(result.issues.isEmpty)
        #expect(result.table.userRows == [.init(agent: "claude", notification: "worker_permission_prompt", means: .approval)])
    }

    @Test func aBadEditKeepsTheLastValidRowsAndReportsOneIssuePerBadRow() throws {
        // (#cm-124.6) `tool` is a valid row key now, so the third row's unknown key is `event`
        let valid = evaluate(#"{"agentEvents":[\#(approvalRow)]}"#)
        let bad = evaluate("""
        {"agentEvents":[\(approvalRow),
          {"agent":"claude","notification":"x","means":"aprooval"},
          {"agent":"claude","event":"x","notification":"y","means":"question"}]}
        """, previous: valid.table)
        #expect(bad.table == valid.table, "a bad edit changes nothing")
        #expect(bad.issues.count == 2)
        #expect(bad.issues.map(\.settingName) == ["agentEvents[1]", "agentEvents[2]"])
        #expect(bad.issues.map(\.message) == ["badMeaning", "unknownKey"])
        #expect(bad.issues.allSatisfy { $0.kind == .agentEventsRow && $0.sourcePath == "/tmp/cmux.json" })
    }

    @Test func aFileThatWontParseKeepsTheLastValidRowsAndReportsNothingItself() {
        let valid = evaluate(#"{"agentEvents":[\#(approvalRow)]}"#)
        for broken in [#"{"agentEvents":[{"agent":"claude""#, "[1, 2]", "not json"] {
            let result = evaluate(broken, previous: valid.table)
            #expect(result.table == valid.table, "\(broken)")
            #expect(result.issues.isEmpty, "CmuxConfigStore shows the parse error, not this store")
        }
    }

    @Test func anAppStartedWithABadFileRunsOnBuiltInRows() {
        let result = evaluate(#"{"agentEvents":[{"agent":"claude","notification":"x","means":"aprooval"}]}"#, previous: .builtIn)
        #expect(result.table == .builtIn)
        #expect(result.issues.count == 1)
    }

    @Test func eachRuleHasItsOwnPaletteLine() {
        let cases: [(String, String)] = [
            (#"{"agentEvents":[{"agent":"claude","notification":"x","means":"aprooval"}]}"#,
             #"agentEvents[0]: means "aprooval": use question, approval, resolved or ignore"#),
            (#"{"agentEvents":[{"notification":"x","means":"ignore"}]}"#,
             #"agentEvents[0]: "agent" is missing; name one, such as "claude", or "*""#),
            // (#cm-124.6) a row with neither key is `noMatchKey` now; `missingNotification` is the empty-string case
            (#"{"agentEvents":[{"agent":"claude","notification":"","means":"ignore"}]}"#,
             #"agentEvents[0]: "notification" is missing; name a type, such as "idle_prompt""#),
            (#"{"agentEvents":[{"agent":"claude","notification":"x"}]}"#,
             #"agentEvents[0]: "means" is missing; use question, approval, resolved or ignore"#),
            (#"{"agentEvents":[{"agent":3,"notification":"x","means":"ignore"}]}"#,
             #"agentEvents[0]: "agent" must be text, such as "claude""#),
            (#"{"agentEvents":[\#(approvalRow),\#(approvalRow)]}"#,
             "agentEvents[1]: same agent and notification as agentEvents[0]; keep one"),
            // (#cm-124.6) `tool` is a row key now, so the unknown-key case uses another key and names `tool` too
            (#"{"agentEvents":[{"agent":"claude","event":"x","notification":"x","means":"ignore"}]}"#,
             #"agentEvents[0]: "event" is not a key: use agent, notification or tool, means"#),
            (#"{"agentEvents":[{"agent":"claude","notification":"x","tool":"y","means":"question"}]}"#,
             #"agentEvents[0]: a row has "notification" or "tool", not both"#),
            (#"{"agentEvents":[{"agent":"claude","means":"question"}]}"#,
             #"agentEvents[0]: a row needs "notification" (a type) or "tool" (a Claude tool)"#),
            (#"{"agentEvents":[{"agent":"claude","tool":"Write","means":"ignore"}]}"#,
             #"agentEvents[0]: means "ignore" on a tool row: use question or plan-review"#),
            (#"{"agentEvents":[{"agent":"claude","tool":"Write","means":"question"},{"agent":"claude","tool":"Write","means":"question"}]}"#,
             "agentEvents[1]: same agent and tool as agentEvents[0]; keep one"),
            (#"{"agentEvents":[{"agent":"claude","tool":"Write"}]}"#,
             #"agentEvents[0]: "means" is missing; use question or plan-review"#),
            (#"{"agentEvents":[{"agent":"claude","tool":"","means":"question"}]}"#,
             #"agentEvents[0]: "tool" is missing; name a Claude tool, like "AskUserQuestion""#),
            (#"{"agentEvents":[{"agent":"claude","tool":3,"means":"question"}]}"#,
             #"agentEvents[0]: "tool" must be text, such as "AskUserQuestion""#),
            (#"{"agentEvents":["claude"]}"#, "agentEvents[0]: a row must be an object"),
            (#"{"agentEvents":{"agent":"claude"}}"#, "agentEvents: must be a list of rows"),
        ]
        for (file, line) in cases {
            let issue = evaluate(file).issues.first
            #expect(issue.map(AgentEventTableStore.paletteDetail) == line, "\(file)")
        }
    }

    // MARK: reloading, with no relaunch

    @Test func aSavedRowTakesEffectAndABadEditAndItsFixShowAndClear() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("cmux.json").path
        let store = AgentEventTableStore(path: path, recordedUnmappedTypes: { nil })
        store.start()
        defer { store.stop() }
        #expect(store.table == .builtIn, "no file yet")

        try write(#"{"agentEvents":[\#(approvalRow)]}"#, to: path)
        #expect(await eventually { store.table.meaning(agent: "claude", notification: "worker_permission_prompt") == .approval })
        #expect(store.issues.value.isEmpty)

        try write(#"{"agentEvents":[\#(approvalRow),{"agent":"claude","notification":"x","means":"aprooval"}]}"#, to: path)
        #expect(await eventually { store.issues.value.count == 1 })
        #expect(store.table.meaning(agent: "claude", notification: "worker_permission_prompt") == .approval, "the last valid row stays")

        try write(#"{"agentEvents":[\#(approvalRow)]}"#, to: path)
        #expect(await eventually { store.issues.value.isEmpty }, "the issue is gone once the file is fixed")

        try write("{}", to: path)
        #expect(await eventually { store.table == .builtIn }, "deleting the rows brings the built-in rows back")
    }

    @Test func aRepoFileNextToTheGlobalOneIsNeverRead() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("global/cmux.json").path
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try write("{}", to: path)
        let repoDirectory = directory.appendingPathComponent("repo/.cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: repoDirectory, withIntermediateDirectories: true)
        try write(#"{"agentEvents":[{"agent":"*","notification":"permission_prompt","means":"ignore"}]}"#,
                  to: repoDirectory.appendingPathComponent("cmux.json").path)
        let store = AgentEventTableStore(path: path, recordedUnmappedTypes: { nil })
        store.start()
        defer { store.stop() }
        #expect(store.table.meaning(agent: "claude", notification: "permission_prompt") == .approval)
    }

    // MARK: the two socket methods

    /// Sends one request the way the socket worker does: off the main thread, which the worker-lane policy requires.
    private func call(_ method: String) async throws -> [String: Any] {
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": [String: Any]()]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let response = await Task.detached { TerminalController.shared.handleSocketLine(line) }.value
        return try #require(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any], "response: \(response)")
    }

    private func withStore(path: String, unmapped: @escaping @Sendable () -> [AgentUnmappedNotificationType]?,
                           _ body: (AgentEventTableStore) async throws -> Void) async rethrows {
        let previous = AgentEventTableStore.shared
        let store = AgentEventTableStore(path: path, recordedUnmappedTypes: unmapped)
        AgentEventTableStore.shared = store
        defer { AgentEventTableStore.shared = previous }
        try await body(store)
    }

    @Test func rowsAreAnsweredOnTheSocketWithHisRowsOnly() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("cmux.json").path
        try write(#"{"agentEvents":[\#(approvalRow)]}"#, to: path)
        try await withStore(path: path, unmapped: { nil }) { store in
            store.reload()
            let response = try await call("agent_events.rows")
            #expect(response["ok"] as? Bool == true, "\(response)")
            let rows = try #require((response["result"] as? [String: Any])?["rows"] as? [[String: String]])
            #expect(rows == [["agent": "claude", "notification": "worker_permission_prompt", "means": "approval"]])
        }
    }

    @Test func noRowsAreAnsweredAsAnEmptyList() async throws {
        try await withStore(path: "/nonexistent/cmux.json", unmapped: { nil }) { _ in
            let response = try await call("agent_events.rows")
            let rows = try #require((response["result"] as? [String: Any])?["rows"] as? [Any])
            #expect(rows.isEmpty)
        }
    }

    @Test func unmappedTypesAreAnsweredWithoutTheOnesARowOrABuiltInIgnoreMaps() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("cmux.json").path
        try write(#"{"agentEvents":[\#(approvalRow)]}"#, to: path)
        let recorded = [
            AgentUnmappedNotificationType(agent: "claude", type: "worker_permission_prompt", count: 3, lastSeenMs: 3_000),
            AgentUnmappedNotificationType(agent: "kimi", type: "worker_permission_prompt", count: 1, lastSeenMs: 2_000),
            AgentUnmappedNotificationType(agent: "claude", type: "push_notification", count: 4, lastSeenMs: 1_000),
        ]
        try await withStore(path: path, unmapped: { recorded }) { store in
            store.reload()
            let response = try await call("agent_events.unmapped_types")
            #expect(response["ok"] as? Bool == true, "\(response)")
            let types = try #require((response["result"] as? [String: Any])?["types"] as? [[String: Any]])
            #expect(types.count == 1)
            #expect(types.first?["agent"] as? String == "kimi")
            #expect(types.first?["type"] as? String == "worker_permission_prompt")
            #expect(types.first?["count"] as? Int == 1)
            #expect(types.first?["last_seen_ms"] as? Int == 2_000)
            #expect(Set(types.first?.keys.map { $0 } ?? []) == ["agent", "type", "count", "last_seen_ms"], "no message text")
        }
    }

    @Test func anUnavailableJournalIsAnErrorNotAnEmptyList() async throws {
        try await withStore(path: "/nonexistent/cmux.json", unmapped: { nil }) { _ in
            let response = try await call("agent_events.unmapped_types")
            #expect(response["ok"] as? Bool == false, "\(response)")
            #expect((response["error"] as? [String: Any])?["code"] as? String == "unavailable")
        }
    }

    // MARK: the palette

    @Test func aBadRowReachesTheWindowsConfigIssuesAndLeavesWhenTheFileIsFixed() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("cmux.json").path
        try write("{}", to: path)
        let previous = AgentEventTableStore.shared
        let store = AgentEventTableStore(path: path, recordedUnmappedTypes: { nil })
        AgentEventTableStore.shared = store
        defer {
            store.stop()
            AgentEventTableStore.shared = previous
        }
        let window = CmuxConfigStore(globalConfigPath: path)
        window.loadAll()
        store.start()
        #expect(window.configurationIssues.filter { $0.kind == .agentEventsRow }.isEmpty)

        try write(#"{"agentEvents":[{"agent":"claude","notification":"x","means":"aprooval"}]}"#, to: path)
        #expect(await eventually { window.configurationIssues.contains { $0.kind == .agentEventsRow } })
        let issue = try #require(window.configurationIssues.first { $0.kind == .agentEventsRow })
        #expect(AgentEventTableStore.paletteDetail(issue) == #"agentEvents[0]: means "aprooval": use question, approval, resolved or ignore"#)
        #expect(issue.sourcePath == path)

        window.loadAll()
        #expect(window.configurationIssues.contains { $0.kind == .agentEventsRow }, "a reload of the window's own file keeps them")

        try write(#"{"agentEvents":[\#(approvalRow)]}"#, to: path)
        #expect(await eventually { !window.configurationIssues.contains { $0.kind == .agentEventsRow } })
    }

    @Test func aWindowReadingAnotherFileNeverShowsTheGlobalTablesIssues() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("cmux.json").path
        try write(#"{"agentEvents":[{"agent":"claude","notification":"x","means":"aprooval"}]}"#, to: path)
        let previous = AgentEventTableStore.shared
        let store = AgentEventTableStore(path: path, recordedUnmappedTypes: { nil })
        AgentEventTableStore.shared = store
        defer {
            store.stop()
            AgentEventTableStore.shared = previous
        }
        store.reload()
        let other = CmuxConfigStore(globalConfigPath: directory.appendingPathComponent("other.json").path)
        other.loadAll()
        #expect(!other.configurationIssues.contains { $0.kind == .agentEventsRow })
    }
}
