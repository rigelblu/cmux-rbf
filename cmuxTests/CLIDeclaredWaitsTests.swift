import CmuxAgentJournal
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Step 2 behavioral proofs for declared waits (`QuestionAsked`/`QuestionAnswered`/
/// `ApprovalAsked`/`ApprovalResolved`), E29 id-less answer drops, cross-surface attribution,
/// and Pi's `"cmux_declared_waits": 1` reply capability (#cm-124.2).
@Suite(.serialized)
struct CLIDeclaredWaitsTests {
    private final class Harness: @unchecked Sendable {
        let support = CLINotifyProcessIntegrationRegressionTests()
        let runner = CMUXCLIErrorOutputRegressionTests()
        let cliPath: String
        let socketPath: String
        let listenerFD: Int32
        let state = CLINotifyProcessIntegrationRegressionTests.MockSocketServerState()
        let root: URL
        let debugLogURL: URL
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surface1 = "22222222-2222-2222-2222-222222222222"
        let surface2 = "33333333-3333-3333-3333-333333333333"
        var sequence: Int64 = 0
        var runCount = 0
        var reconciler = AgentNotificationReconciler()

        init(_ name: String) throws {
            cliPath = try support.bundledCLIPath()
            socketPath = support.makeSocketPath(name)
            listenerFD = try support.bindUnixSocket(at: socketPath)
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-dw-\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            debugLogURL = root.appendingPathComponent("debug.log", isDirectory: false)
            let wId = workspaceId
            let s1 = surface1
            let s2 = surface2
            let sup = support
            support.startDetachedMockServer(listenerFD: listenerFD, state: state) { line in
                guard let payload = sup.jsonObject(line) else { return "OK" }
                guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                    return sup.malformedRequestResponse(id: payload["id"] as? String, raw: line)
                }
                switch method {
                case "workspace.list":
                    return sup.v2Response(id: id, ok: true, result: [
                        "workspaces": [["id": wId, "ref": "workspace:1", "index": 0, "selected": true]],
                    ])
                case "surface.list":
                    return sup.v2Response(id: id, ok: true, result: [
                        "surfaces": [
                            ["id": s1, "ref": "surface:1", "index": 1, "focused": true],
                            ["id": s2, "ref": "surface:2", "index": 2, "focused": false],
                        ],
                    ])
                case "feed.push", "surface.resume.set", "surface.resume.clear":
                    return sup.v2Response(id: id, ok: true, result: [:])
                default:
                    return sup.v2Response(id: id, ok: false, error: [
                        "code": "unrecognized_method",
                        "message": "unexpected method: \(method)",
                    ])
                }
            }
        }

        deinit {
            CLIMockAcceptLoopRegistry.shared.stop(listenerFD: listenerFD)
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        func environment(
            surface: String? = nil,
            workspaceOverride: String? = nil,
            includeTargetEnv: Bool = true
        ) -> [String: String] {
            var env: [String: String] = [
                "HOME": root.path,
                "CFFIXED_USER_HOME": root.path,
                "PWD": root.path,
                "TMPDIR": root.path,
                "XDG_CONFIG_HOME": root.appendingPathComponent(".config").path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                "CMUX_CLAUDE_HOOK_STATE_PATH": root.appendingPathComponent("claude-hook-sessions.json").path,
                "CMUX_DEBUG_LOG": debugLogURL.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            ]
            if includeTargetEnv {
                env["CMUX_WORKSPACE_ID"] = workspaceOverride ?? workspaceId
                if let surfaceOverride = surface, surfaceOverride.isEmpty {
                    // Omit CMUX_SURFACE_ID completely when surfaceOverride is empty.
                } else {
                    env["CMUX_SURFACE_ID"] = surface ?? surface1
                }
            }
            return env
        }

        func run(
            _ arguments: [String],
            payload: [String: Any],
            surface: String? = nil,
            workspaceOverride: String? = nil,
            includeTargetEnv: Bool = true,
            expectZeroStatus: Bool = true
        ) throws -> (result: CMUXCLIErrorOutputRegressionTests.ProcessRunResult, drafts: [AgentJournalEventDraft], notifications: [String]) {
            let before = state.snapshot().count
            let data = try JSONSerialization.data(withJSONObject: payload)
            // The stdin payload goes through a file and `exec`, so the child is spawned and reaped by the suite's
            // posix_spawn/waitpid runner. Foundation.Process's exit notification arrived late in this app-hosted
            // suite: status 0 and full stdout, yet `timedOut` after the whole budget (#cm-124.2).
            runCount += 1
            let stdinURL = root.appendingPathComponent("stdin-\(runCount).json", isDirectory: false)
            try data.write(to: stdinURL)
            var childEnvironment = CLIChildEnvironment(appHostEnvironment: ProcessInfo.processInfo.environment)
                .normalizing(environment(
                    surface: surface,
                    workspaceOverride: workspaceOverride,
                    includeTargetEnv: includeTargetEnv
                ))
            childEnvironment["CMUX_DW_STDIN"] = stdinURL.path
            let res = runner.runProcess(
                executablePath: "/bin/sh",
                arguments: ["-c", "exec \"$0\" \"$@\" < \"$CMUX_DW_STDIN\"", cliPath] + arguments,
                environment: childEnvironment,
                timeout: 30
            )
            let newLines = Array(state.snapshot().dropFirst(before))
            #expect(!res.timedOut, "timedOut args=\(arguments.joined(separator: " ")) stderr=\(res.stderr) lines=\(newLines)")
            if expectZeroStatus {
                #expect(res.status == 0, "status=\(res.status) args=\(arguments.joined(separator: " ")) stderr=\(res.stderr)")
            }
            let drafts = newLines.compactMap { line -> AgentJournalEventDraft? in
                guard line.hasPrefix("agent_journal_append ") else { return nil }
                return try? JSONDecoder().decode(
                    AgentJournalEventDraft.self,
                    from: Data(line.dropFirst("agent_journal_append ".count).utf8)
                )
            }
            for draft in drafts {
                sequence += 1
                _ = reconciler.apply(AgentJournalEvent(
                    sequence: sequence,
                    committedAtMs: 1000 + sequence,
                    draft: draft
                ))
            }
            let notifications = newLines.filter { $0.hasPrefix("notify_target_async ") }
            return (res, drafts, notifications)
        }

        func debugLogContents() -> String {
            (try? String(contentsOf: debugLogURL, encoding: .utf8)) ?? ""
        }
    }

    @Test func piHookReplyCarriesDeclaredWaitsOnEarlyExitAndSuccess() throws {
        let h = try Harness("a5if")

        // A5i(f) pre-socket early exit: no flags, no CMUX_WORKSPACE_ID/CMUX_SURFACE_ID -> "{cmux_declared_waits:1}".
        let preSocket = try h.run(
            ["hooks", "pi", "notification"],
            payload: [:],
            includeTargetEnv: false
        )
        let preSocketObj = try #require(
            try JSONSerialization.jsonObject(with: Data(preSocket.result.stdout.utf8)) as? [String: Any],
            "pre-socket early reply stdout: \(preSocket.result.stdout)"
        )
        #expect(preSocketObj["cmux_declared_waits"] as? Int == 1)

        // A5i(f) live-socket env-only early exit: unresolved CMUX_WORKSPACE_ID without flags/CMUX_SURFACE_ID.
        let envOnlyEarly = try h.run(
            ["hooks", "pi", "notification"],
            payload: [:],
            surface: "",
            workspaceOverride: "00000000-0000-4000-8000-000000000000"
        )
        let envOnlyObj = try #require(
            try JSONSerialization.jsonObject(with: Data(envOnlyEarly.result.stdout.utf8)) as? [String: Any],
            "env-only early reply stdout: \(envOnlyEarly.result.stdout)"
        )
        #expect(envOnlyObj["cmux_declared_waits"] as? Int == 1)

        // Strict target contract preserved: explicit nonexistent --workspace/--surface exits 69 with empty stdout.
        let strictFail = try h.run(
            [
                "hooks", "pi", "notification",
                "--workspace", "00000000-0000-4000-8000-000000000000",
                "--surface", "00000000-0000-4000-8000-000000000001",
            ],
            payload: [:],
            expectZeroStatus: false
        )
        #expect(strictFail.result.status == 69)
        #expect(strictFail.result.stdout.isEmpty)

        // A5i(f) normal success: session-start and notification carry the capability key.
        let start = try h.run(
            ["hooks", "pi", "session-start", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": "h-f", "hook_event_name": "SessionStart", "cwd": h.root.path]
        )
        let startObj = try #require(
            try JSONSerialization.jsonObject(with: Data(start.result.stdout.utf8)) as? [String: Any],
            "start reply stdout: \(start.result.stdout)"
        )
        #expect(startObj["cmux_declared_waits"] as? Int == 1)

        let notify = try h.run(
            ["hooks", "pi", "notification", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": "h-f", "hook_event_name": "QuestionAsked", "request_id": "q-f"]
        )
        let notifyObj = try #require(
            try JSONSerialization.jsonObject(with: Data(notify.result.stdout.utf8)) as? [String: Any],
            "notify reply stdout: \(notify.result.stdout)"
        )
        #expect(notifyObj["cmux_declared_waits"] as? Int == 1)

        // Non-pi regression: omp keeps exact "{}\n" on both early exit and success.
        let ompPreSocket = try h.run(
            ["hooks", "omp", "notification"],
            payload: [:],
            includeTargetEnv: false
        )
        #expect(ompPreSocket.result.stdout == "{}\n")

        let omp = try h.run(
            ["hooks", "omp", "session-start", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": "o-1", "hook_event_name": "SessionStart", "cwd": h.root.path]
        )
        #expect(omp.result.stdout == "{}\n")
    }

    @Test func piLoneWaitIgnoresIdLessQuestionAnsweredAndLogsDrop() throws {
        let h = try Harness("pi-e29")
        _ = try h.run(
            ["hooks", "pi", "session-start", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": "h-s1", "hook_event_name": "SessionStart", "cwd": h.root.path]
        )
        _ = try h.run(
            ["hooks", "pi", "notification", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": "h-s1", "hook_event_name": "QuestionAsked", "request_id": "q-5"]
        )
        #expect(h.reconciler.openRequests(source: "pi", sessionId: "h-s1").identified == ["q-5"])

        let idLess = try h.run(
            ["hooks", "pi", "notification", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": "h-s1", "hook_event_name": "QuestionAnswered"]
        )
        #expect(idLess.drafts.isEmpty, "id-less QuestionAnswered must drop without journaling, saw \(idLess.drafts)")
        #expect(h.reconciler.openRequests(source: "pi", sessionId: "h-s1").identified == ["q-5"])
        #expect(h.debugLogContents().contains("declared answer without request_id dropped"))
    }

    @Test func claudeLoneWaitIgnoresIdLessQuestionAnsweredAndLogsDrop() throws {
        let h = try Harness("claude-e29")
        _ = try h.run(
            ["hooks", "claude", "session-start", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": "c-s1", "hook_event_name": "SessionStart", "cwd": h.root.path]
        )
        _ = try h.run(
            ["hooks", "claude", "notification", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": "c-s1", "hook_event_name": "QuestionAsked", "request_id": "c-5"]
        )
        #expect(h.reconciler.openRequests(source: "claude", sessionId: "c-s1").identified == ["c-5"])

        let idLess = try h.run(
            ["hooks", "claude", "notification", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": "c-s1", "hook_event_name": "QuestionAnswered"]
        )
        #expect(idLess.drafts.isEmpty, "id-less QuestionAnswered must drop on Claude route, saw \(idLess.drafts)")
        #expect(h.reconciler.openRequests(source: "claude", sessionId: "c-s1").identified == ["c-5"])
        #expect(h.debugLogContents().contains("declared answer without request_id dropped"))
    }

    @Test func piMessageLessDeclaredAskUsesFixedBodyNotStoredReply() throws {
        let h = try Harness("pi-body")
        _ = try h.run(
            ["hooks", "pi", "session-start", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": "h-s1", "hook_event_name": "SessionStart", "cwd": h.root.path]
        )
        _ = try h.run(
            ["hooks", "pi", "notification", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: [
                "session_id": "h-s1",
                "hook_event_name": "Notification",
                "message": "OLD-REPLY",
                "notification": ["type": "stop"],
            ]
        )

        let qAsk = try h.run(
            ["hooks", "pi", "notification", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": "h-s1", "hook_event_name": "QuestionAsked", "request_id": "q-1"]
        )
        let qNotifications = qAsk.drafts.compactMap { $0.attention?.notification }
        let qNotify = try #require(qNotifications.first)
        #expect(qNotify.body == "Agent is asking a question")
        #expect(qNotify.body != "OLD-REPLY")
        #expect(qNotify.category == "idle-reminder")
        #expect(h.reconciler.openRequests(source: "pi", sessionId: "h-s1").identified == ["q-1"])

        let aAsk = try h.run(
            ["hooks", "pi", "notification", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": "h-s1", "hook_event_name": "ApprovalAsked", "request_id": "a-1"]
        )
        let aNotifications = aAsk.drafts.compactMap { $0.attention?.notification }
        let aNotify = try #require(aNotifications.first)
        #expect(aNotify.body == "Approval needed")
        #expect(aNotify.category == "needs-permission")
        #expect(Set(h.reconciler.openRequests(source: "pi", sessionId: "h-s1").identified) == ["q-1", "a-1"])

        _ = try h.run(
            ["hooks", "pi", "notification", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": "h-s1", "hook_event_name": "QuestionAnswered", "request_id": "q-1"]
        )
        #expect(h.reconciler.openRequests(source: "pi", sessionId: "h-s1").identified == ["a-1"])

        _ = try h.run(
            ["hooks", "pi", "notification", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": "h-s1", "hook_event_name": "ApprovalResolved", "request_id": "a-1"]
        )
        #expect(h.reconciler.openRequests(source: "pi", sessionId: "h-s1").identified.isEmpty)
    }

    /// The body is the event's top-level `message` and nothing else (design, `.2` block): `title`, `body`, `text`,
    /// a nested `notification.message` and the rest give the fixed text instead (#cm-124.2).
    @Test(arguments: ["pi", "claude"])
    func declaredAskBodyComesOnlyFromTopLevelMessage(agent: String) throws {
        let h = try Harness("body-keys-\(agent)")
        let session = "k-s1"
        _ = try h.run(
            ["hooks", agent, "session-start", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": session, "hook_event_name": "SessionStart", "cwd": h.root.path]
        )
        func ask(_ id: String, _ event: String, extra: [String: Any]) throws -> String? {
            var payload: [String: Any] = ["session_id": session, "hook_event_name": event, "request_id": id]
            payload.merge(extra) { _, new in new }
            let run = try h.run(
                ["hooks", agent, "notification", "--workspace", h.workspaceId, "--surface", h.surface1],
                payload: payload
            )
            return run.drafts.compactMap { $0.attention?.notification }.first?.body
        }
        #expect(try ask("k-1", "QuestionAsked", extra: ["title": "TITLE-ONLY", "body": "BODY-ONLY", "text": "TEXT-ONLY"])
            == "Agent is asking a question")
        #expect(try ask("k-2", "QuestionAsked", extra: ["notification": ["message": "NESTED-ONLY"], "prompt": "PROMPT-ONLY"])
            == "Agent is asking a question")
        #expect(try ask("k-3", "ApprovalAsked", extra: ["description": "DESC-ONLY", "summary": "SUMMARY-ONLY"])
            == "Approval needed")
        #expect(try ask("k-4", "QuestionAsked", extra: ["message": "Pick one", "title": "IGNORED"]) == "Pick one")
    }

    /// A declared ask is never demoted by the Antigravity background-work gate: category and pending come
    /// from the declared kind (#cm-124.2).
    @Test func declaredAskOnAntigravityWithBackgroundWorkStillOpensWait() throws {
        let h = try Harness("antigravity-ask")
        _ = try h.run(
            ["hooks", "antigravity", "session-start", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": "a-s1", "hook_event_name": "SessionStart", "cwd": h.root.path]
        )
        let ask = try h.run(
            ["hooks", "antigravity", "notification", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": "a-s1", "hook_event_name": "QuestionAsked", "request_id": "aq-1", "fullyIdle": false]
        )
        #expect(ask.drafts.contains { $0.kind == .questionRequested }, "kinds: \(ask.drafts.map(\.kind))")
        #expect(h.reconciler.openRequests(source: "antigravity", sessionId: "a-s1").identified == ["aq-1"])

        let approval = try h.run(
            ["hooks", "antigravity", "notification", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": "a-s1", "hook_event_name": "ApprovalAsked", "request_id": "aa-1", "fullyIdle": false]
        )
        #expect(approval.drafts.contains { $0.kind == .approvalRequested }, "kinds: \(approval.drafts.map(\.kind))")
        #expect(Set(h.reconciler.openRequests(source: "antigravity", sessionId: "a-s1").identified) == ["aq-1", "aa-1"])
    }

    /// The CLI's guards cover every spelling the mapper maps (`question_answered`, `approval_asked`, …), not only the
    /// canonical names: a lone wait survives an id-less `question_answered`, and `approval_asked` with no message
    /// shows the fixed text, never the stored reply (#cm-124.2, review R1).
    @Test(arguments: ["pi", "claude"])
    func misspelledDeclaredNamesKeepEveryGuard(agent: String) throws {
        let h = try Harness("spelling-\(agent)")
        let session = "m-s1"
        _ = try h.run(
            ["hooks", agent, "session-start", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": session, "hook_event_name": "SessionStart", "cwd": h.root.path]
        )
        _ = try h.run(
            ["hooks", agent, "notification", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": session, "hook_event_name": "QuestionAsked", "request_id": "q-1"]
        )
        #expect(h.reconciler.openRequests(source: agent, sessionId: session).identified == ["q-1"])

        let idLess = try h.run(
            ["hooks", agent, "notification", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": session, "hook_event_name": "question_answered"]
        )
        #expect(idLess.drafts.isEmpty, "an id-less question_answered must drop without journaling, saw \(idLess.drafts)")
        #expect(h.reconciler.openRequests(source: agent, sessionId: session).identified == ["q-1"])
        #expect(h.debugLogContents().contains("declared answer without request_id dropped"))

        let approval = try h.run(
            ["hooks", agent, "notification", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": session, "hook_event_name": "approval_asked", "request_id": "a-1"]
        )
        let body = approval.drafts.compactMap { $0.attention?.notification }.first?.body
        #expect(body == "Approval needed", "approval_asked with no message must show the fixed text, saw \(String(describing: body))")
    }

    /// A declared ask needs a string `request_id`, like its answer: without one it is dropped and logged, because
    /// no declared answer could close it (#cm-124.2, review R4).
    @Test(arguments: ["pi", "claude"])
    func declaredAskWithoutAStringRequestIdIsDroppedAndLogged(agent: String) throws {
        let h = try Harness("ask-no-id-\(agent)")
        let session = "n-s1"
        _ = try h.run(
            ["hooks", agent, "session-start", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": session, "hook_event_name": "SessionStart", "cwd": h.root.path]
        )
        let idLess = try h.run(
            ["hooks", agent, "notification", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": session, "hook_event_name": "QuestionAsked"]
        )
        #expect(idLess.drafts.isEmpty, "an id-less QuestionAsked must drop without journaling, saw \(idLess.drafts)")
        #expect(h.debugLogContents().contains("declared ask without request_id dropped"))

        let numeric = try h.run(
            ["hooks", agent, "notification", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": session, "hook_event_name": "ApprovalAsked", "request_id": 123]
        )
        #expect(numeric.drafts.isEmpty, "a numeric request_id counts as none, saw \(numeric.drafts)")
        #expect(h.reconciler.openRequests(source: agent, sessionId: session).count == 0)

        let proper = try h.run(
            ["hooks", agent, "notification", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": session, "hook_event_name": "QuestionAsked", "request_id": "q-1"]
        )
        #expect(proper.drafts.contains { $0.kind == .questionRequested })
        #expect(h.reconciler.openRequests(source: agent, sessionId: session).identified == ["q-1"])
    }

    @Test func claudeDeclaredWaitsRespectKindAndFixedBody() throws {
        let h = try Harness("claude-body")
        _ = try h.run(
            ["hooks", "claude", "session-start", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": "c-s1", "hook_event_name": "SessionStart", "cwd": h.root.path]
        )

        let ask1 = try h.run(
            ["hooks", "claude", "notification", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": "c-s1", "hook_event_name": "QuestionAsked", "request_id": "c-1", "message": "OLD-ASK"]
        )
        let n1List = ask1.drafts.compactMap { $0.attention?.notification }
        let n1 = try #require(n1List.first)
        #expect(n1.body == "OLD-ASK")
        #expect(n1.category == "idle-reminder")
        #expect(h.reconciler.openRequests(source: "claude", sessionId: "c-s1").identified == ["c-1"])

        _ = try h.run(
            ["hooks", "claude", "notification", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": "c-s1", "hook_event_name": "QuestionAnswered", "request_id": "c-1"]
        )
        #expect(h.reconciler.openRequests(source: "claude", sessionId: "c-s1").identified.isEmpty)

        // Message-less ask must not reuse stored "OLD-ASK".
        let ask4 = try h.run(
            ["hooks", "claude", "notification", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": "c-s1", "hook_event_name": "QuestionAsked", "request_id": "c-4"]
        )
        let n4List = ask4.drafts.compactMap { $0.attention?.notification }
        let n4 = try #require(n4List.first)
        #expect(n4.body == "Agent is asking a question")
        #expect(n4.body != "OLD-ASK")

        // Approval with completion words keeps approval kind and category.
        let ask6 = try h.run(
            ["hooks", "claude", "notification", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": "c-s1", "hook_event_name": "ApprovalAsked", "request_id": "c-6", "message": "Task completed?"]
        )
        let n6List = ask6.drafts.compactMap { $0.attention?.notification }
        let n6 = try #require(n6List.first)
        #expect(n6.body == "Task completed?")
        #expect(n6.category == "needs-permission")
        #expect(ask6.drafts.contains { $0.kind == .approvalRequested })
    }

    @Test func crossSurfaceDeclaredAnswerAttributesToSessionMappedSurface() throws {
        let h = try Harness("cross-surface")
        // Pi leg
        _ = try h.run(
            ["hooks", "pi", "session-start", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": "h-s1", "hook_event_name": "SessionStart", "cwd": h.root.path]
        )
        _ = try h.run(
            ["hooks", "pi", "notification", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": "h-s1", "hook_event_name": "QuestionAsked", "request_id": "q-1"]
        )
        let piAnswer = try h.run(
            ["hooks", "pi", "notification", "--workspace", h.workspaceId, "--surface", h.surface2],
            payload: ["session_id": "h-s1", "hook_event_name": "QuestionAnswered", "request_id": "q-1"],
            surface: h.surface2
        )
        let piResolveDraft = try #require(piAnswer.drafts.first { $0.kind == .attentionResolved })
        #expect(piResolveDraft.surfaceId == h.surface1)
        #expect(h.reconciler.openRequests(source: "pi", sessionId: "h-s1").identified.isEmpty)

        // Claude leg
        _ = try h.run(
            ["hooks", "claude", "session-start", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": "c-s1", "hook_event_name": "SessionStart", "cwd": h.root.path]
        )
        _ = try h.run(
            ["hooks", "claude", "notification", "--workspace", h.workspaceId, "--surface", h.surface1],
            payload: ["session_id": "c-s1", "hook_event_name": "QuestionAsked", "request_id": "c-1"]
        )
        let claudeAnswer = try h.run(
            ["hooks", "claude", "notification", "--workspace", h.workspaceId, "--surface", h.surface2],
            payload: ["session_id": "c-s1", "hook_event_name": "QuestionAnswered", "request_id": "c-1"],
            surface: h.surface2
        )
        let claudeResolveDraft = try #require(claudeAnswer.drafts.first { $0.kind == .attentionResolved })
        #expect(claudeResolveDraft.surfaceId == h.surface1)
        #expect(h.reconciler.openRequests(source: "claude", sessionId: "c-s1").identified.isEmpty)
    }
}
