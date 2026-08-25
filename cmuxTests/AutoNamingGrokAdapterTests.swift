import Darwin
import Foundation
import Testing

/// Behavior tests for the Grok chat-history adapter: extraction from native
/// `chat_history.jsonl`, injected metadata filtering, and shared-engine parity.
@Suite struct AutoNamingGrokAdapterTests {
    private let engine = AutoNamingEngine()

    private func historyLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    @Test func extractsUserAndAssistantMessagesFromChatHistory() {
        let lines = [
            historyLine(["type": "system", "content": "You are Grok"]),
            historyLine(["type": "user", "content": "Fix the Grok session restore bug"]),
            historyLine(["type": "assistant", "content": "I will inspect the resume path."]),
            historyLine(["role": "assistant", "content": [["type": "text", "text": "The restore command is patched."]]]),
            "not json"
        ]

        let messages = engine.extractGrokMessages(fromChatHistoryLines: lines)
        #expect(messages == [
            AutoNamingTranscriptMessage(role: "user", text: "Fix the Grok session restore bug"),
            AutoNamingTranscriptMessage(role: "assistant", text: "I will inspect the resume path."),
            AutoNamingTranscriptMessage(role: "assistant", text: "The restore command is patched.")
        ])
    }

    @Test func userQueryTagWinsOverInjectedMetadata() {
        let userContent = """
        <user_info>
        OS Version: macos 26.4
        </user_info>
        <git_status>
        Current branch: feat/auto-name
        </git_status>
        <user_query>
        Add Grok workspace naming
        </user_query>
        """
        let lines = [
            historyLine(["type": "user", "content": userContent]),
            historyLine(["type": "assistant", "content": "Done."])
        ]

        let messages = engine.extractGrokMessages(fromChatHistoryLines: lines)
        #expect(messages.first == AutoNamingTranscriptMessage(role: "user", text: "Add Grok workspace naming"))
    }

    @Test func sharedEnginePipelineParityWithGrokContent() throws {
        let lines = [
            historyLine(["type": "user", "content": "Name workspaces from Grok history"]),
            historyLine(["type": "assistant", "content": "I will use chat_history.jsonl."])
        ]
        let messages = engine.extractGrokMessages(fromChatHistoryLines: lines)
        let context = try #require(engine.buildContext(from: messages))
        let prompt = engine.buildPrompt(currentTitle: "Old title", context: context)
        #expect(prompt.contains("Name workspaces from Grok history"))
        #expect(prompt.contains("The current title is: Old title"))

        let decision = engine.throttleDecision(
            snapshot: AutoNamingSessionSnapshot(),
            transcriptLineCount: engine.config.minTranscriptLines,
            now: Date(timeIntervalSince1970: 1_000_000)
        )
        #expect(decision == .proceed(baseline: engine.config.minTranscriptLines))
    }
}

/// Behavior tests for the Antigravity 1.1.20 transcript adapter. The fixture
/// preserves the record shapes captured from a real fully-idle turn on
/// 2026-08-25, with all conversation text replaced before it entered the repo.
@Suite struct AutoNamingAntigravityAdapterTests {
    private let engine = AutoNamingEngine()

    private func transcriptLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func capturedTranscriptLines() throws -> [String] {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/antigravity-1.1.20-transcript.jsonl")
        return try String(contentsOf: fixtureURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
    }

    @Test func extractsOnlyCompletedHumanConversationInOrder() throws {
        let lines = try capturedTranscriptLines()

        #expect(engine.extractAntigravityMessages(fromTranscriptLines: lines) == [
            AutoNamingTranscriptMessage(
                role: "user",
                text: "Explain safe Antigravity transcript naming."
            ),
            AutoNamingTranscriptMessage(
                role: "assistant",
                text: "Use the bounded transcript and shared title authority."
            )
        ])
    }

    @Test func rejectsToolNoiseMalformedUnknownIncompleteAndNonStringContent() {
        let excluded = [
            transcriptLine(["source": "MODEL", "type": "RUN_COMMAND", "status": "DONE", "content": "cat secrets"]),
            transcriptLine(["source": "MODEL", "type": "PLANNER_RESPONSE", "status": "RUNNING", "content": "unfinished"]),
            transcriptLine(["source": "MODEL", "type": "PLANNER_RESPONSE", "status": "DONE", "content": NSNull()]),
            transcriptLine(["source": "USER_EXPLICIT", "type": "FUTURE_USER_KIND", "status": "DONE", "content": "unknown"]),
            transcriptLine(["source": "SYSTEM", "type": "CONVERSATION_HISTORY", "status": "DONE", "content": "history"]),
            "not json",
            "{"
        ]

        #expect(engine.extractAntigravityMessages(fromTranscriptLines: excluded).isEmpty)
    }

    @Test func completionBoundaryRequiresExplicitFullyIdleForAntigravity() {
        #expect(genericAgentAutoNamingEventEligible(agentName: "antigravity", fullyIdle: true))
        #expect(!genericAgentAutoNamingEventEligible(agentName: "antigravity", fullyIdle: false))
        #expect(!genericAgentAutoNamingEventEligible(agentName: "antigravity", fullyIdle: nil))
        #expect(genericAgentAutoNamingEventEligible(agentName: "grok", fullyIdle: nil))
    }

    @Test func requiresAnExplicitExistingSupportedNamingAgent() {
        #expect(explicitSupportedAutoNamingAgent("codex") == "codex")
        #expect(explicitSupportedAutoNamingAgent("  claude  ") == "claude")
        #expect(explicitSupportedAutoNamingAgent(nil) == nil)
        #expect(explicitSupportedAutoNamingAgent("auto") == nil)
        #expect(explicitSupportedAutoNamingAgent("antigravity") == nil)
        #expect(explicitSupportedAutoNamingAgent("gemini") == nil)
    }

    @Test func readsOnlyCanonicalCurrentConversationTranscript() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-antigravity-transcript-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let conversationID = "conversation-123"
        let transcript = root
            .appendingPathComponent(".gemini/antigravity-cli/brain/\(conversationID)/.system_generated/logs", isDirectory: true)
            .appendingPathComponent("transcript_full.jsonl", isDirectory: false)
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let finalLine = transcriptLine([
            "source": "MODEL",
            "type": "PLANNER_RESPONSE",
            "status": "DONE",
            "content": "Safe final response"
        ])
        let oversizedFirstLine = String(repeating: "x", count: 256)
        try Data("\(oversizedFirstLine)\n\(finalLine)\n".utf8).write(to: transcript)

        let snapshot = try #require(AntigravityTranscriptReader.read(
            transcriptPath: transcript.path,
            conversationID: conversationID,
            homeDirectory: root.path,
            maxBytes: 192
        ))
        #expect(snapshot.lines == [finalLine, ""])
        #expect(snapshot.fileSize > 192)

        #expect(AntigravityTranscriptReader.read(
            transcriptPath: transcript.path,
            conversationID: "another-conversation",
            homeDirectory: root.path,
            maxBytes: 192
        ) == nil)
    }

    @Test func rejectsSymlinkedTranscriptComponents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-antigravity-symlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let conversationID = "conversation-456"
        let brain = root.appendingPathComponent(".gemini/antigravity-cli/brain", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: brain, withIntermediateDirectories: true)
        let outsideLogs = outside.appendingPathComponent(".system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideLogs, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(
            to: outsideLogs.appendingPathComponent("transcript_full.jsonl", isDirectory: false)
        )
        try FileManager.default.createSymbolicLink(
            at: brain.appendingPathComponent(conversationID, isDirectory: true),
            withDestinationURL: outside
        )
        let forgedPath = brain
            .appendingPathComponent(conversationID, isDirectory: true)
            .appendingPathComponent(".system_generated/logs/transcript_full.jsonl", isDirectory: false)

        #expect(AntigravityTranscriptReader.read(
            transcriptPath: forgedPath.path,
            conversationID: conversationID,
            homeDirectory: root.path,
            maxBytes: 512 * 1024
        ) == nil)
    }

    @Test func rejectsSymlinkedFinalTranscript() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-antigravity-file-symlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let conversationID = "conversation-file-symlink"
        let logs = root
            .appendingPathComponent(".gemini/antigravity-cli/brain/\(conversationID)/.system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.jsonl", isDirectory: false)
        try Data("{}\n".utf8).write(to: outside)
        let transcript = logs.appendingPathComponent("transcript_full.jsonl", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: transcript, withDestinationURL: outside)

        #expect(AntigravityTranscriptReader.read(
            transcriptPath: transcript.path,
            conversationID: conversationID,
            homeDirectory: root.path,
            maxBytes: 512 * 1024
        ) == nil)
    }

    @Test func rejectsRootEscapeEvenWhenCanonicalTranscriptIsReadable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-antigravity-root-escape-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let conversationID = "conversation-root-escape"
        let canonical = root
            .appendingPathComponent(".gemini/antigravity-cli/brain/\(conversationID)/.system_generated/logs", isDirectory: true)
            .appendingPathComponent("transcript_full.jsonl", isDirectory: false)
        try FileManager.default.createDirectory(
            at: canonical.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}\n".utf8).write(to: canonical)
        let outside = root.appendingPathComponent("outside/transcript_full.jsonl", isDirectory: false)
        try FileManager.default.createDirectory(
            at: outside.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}\n".utf8).write(to: outside)

        #expect(AntigravityTranscriptReader.read(
            transcriptPath: outside.path,
            conversationID: conversationID,
            homeDirectory: root.path,
            maxBytes: 512 * 1024
        ) == nil)
    }

    @Test func rejectsNonRegularFinalHandle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-antigravity-invalid-path-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let conversationID = "conversation-789"
        let canonicalLogs = root
            .appendingPathComponent(".gemini/antigravity-cli/brain/\(conversationID)/.system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: canonicalLogs, withIntermediateDirectories: true)
        let directoryAtTranscriptPath = canonicalLogs
            .appendingPathComponent("transcript_full.jsonl", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryAtTranscriptPath, withIntermediateDirectories: true)

        #expect(AntigravityTranscriptReader.read(
            transcriptPath: directoryAtTranscriptPath.path,
            conversationID: conversationID,
            homeDirectory: root.path,
            maxBytes: 512 * 1024
        ) == nil)
    }

    @Test func finalHandlePolicyRequiresNonEmptyRegularFile() {
        var regular = stat()
        regular.st_mode = mode_t(S_IFREG)
        regular.st_size = 1
        #expect(AntigravityTranscriptReader.isNonEmptyRegularFile(regular))

        var directory = stat()
        directory.st_mode = mode_t(S_IFDIR)
        directory.st_size = 1
        #expect(!AntigravityTranscriptReader.isNonEmptyRegularFile(directory))

        regular.st_size = 0
        #expect(!AntigravityTranscriptReader.isNonEmptyRegularFile(regular))
    }
}
