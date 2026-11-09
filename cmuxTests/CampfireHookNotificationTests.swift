import Darwin
import Foundation
import Testing

@Suite("Campfire hook notifications")
struct CampfireHookNotificationTests {
    @Test func permissionNotificationLocalizesAndMarksNeedsInput() throws {
        let context = try makeHookContext(name: "campfire-permission-lifecycle")
        defer { context.cleanup() }

        let sessionId = "campfire-permission-session"
        let launchEnvironment = agentLaunchEnvironment(
            context: context,
            kind: "campfire",
            executable: "/usr/local/bin/campfire"
        )
        startAgentHookMockServerAccepting(context: context, connectionLimit: 64)

        let prompt = runAgentHook(
            context: context,
            agent: "campfire",
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"continue"}"#,
            extraEnvironment: launchEnvironment
        )
        #expect(prompt.timedOut == false, Comment(rawValue: prompt.stderr))
        #expect(prompt.status == 0, Comment(rawValue: prompt.stderr))

        let notificationStart = context.state.snapshot().count
        let notification = runAgentHook(
            context: context,
            agent: "campfire",
            subcommand: "notification",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"Notification","campfire_event_type":"permission.asked","display_name":"Alice","capability":"shell:exec"}"#,
            extraEnvironment: launchEnvironment
        )
        #expect(notification.timedOut == false, Comment(rawValue: notification.stderr))
        #expect(notification.status == 0, Comment(rawValue: notification.stderr))

        let notificationCommands = Array(context.state.snapshot().dropFirst(notificationStart))
        // cmux-rbf: changed on purpose (#cm-128.5: .4 left it stale). This suite's mock records the journal append and never
        // turns it into a `notify_target_async` line, and .4 moved the title and subtitle. The line now comes from the
        // production reconciler and claim (`AgentHookTestNotificationPipeline`, fed every command in order), so it proves
        // the ping is delivered, not just that a candidate was built.
        let pipeline = AgentHookTestNotificationPipeline()
        let delivered = context.state.snapshot().flatMap { pipeline.effects(for: $0) }
        #expect(
            delivered.contains {
                $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Campfire · Needs your approval|")
                    && $0.contains("|Alice asked for permission to run a shell command|c=needs-permission;p=0")
            },
            "Campfire permission notification should be localized and notification-gated in Swift, saw \(notificationCommands)"
        )
        #expect(
            AgentJournalAppendCapture.captures(in: notificationCommands).contains { capture in
                capture.kind == "agent.approval.requested"
                    && capture.agentKey == "campfire"
                    && capture.workspaceId == context.workspaceId
                    && capture.surfaceId == context.surfaceId
            },
            "Campfire permission notification must journal a needs-input approval request, saw \(notificationCommands)"
        )

        let stateURL = context.root.appendingPathComponent("campfire-hook-sessions.json")
        let state = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        let sessions = try #require(state["sessions"] as? [String: Any])
        let record = try #require(sessions[sessionId] as? [String: Any])
        #expect(record["agentLifecycle"] as? String == "needsInput")
    }

    /// cm-128.5 (Scenario 79): Campfire's kind comes from its typed `campfire_event_type`, not from the words in its summary.
    private func campfireNotificationCommands(eventType: String) throws -> (commands: [String], delivered: [String], record: [String: Any]) {
        let context = try makeHookContext(name: "campfire-\(eventType.prefix(4))")
        defer { context.cleanup() }
        let sessionId = "campfire-typed-session"
        let launchEnvironment = agentLaunchEnvironment(context: context, kind: "campfire", executable: "/usr/local/bin/campfire")
        startAgentHookMockServerAccepting(context: context, connectionLimit: 64)
        let prompt = runAgentHook(
            context: context, agent: "campfire", subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"continue"}"#,
            extraEnvironment: launchEnvironment)
        #expect(prompt.status == 0, Comment(rawValue: prompt.stderr))
        let start = context.state.snapshot().count
        let notification = runAgentHook(
            context: context, agent: "campfire", subcommand: "notification",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"Notification","campfire_event_type":"\#(eventType)","display_name":"Alice"}"#,
            extraEnvironment: launchEnvironment)
        #expect(notification.timedOut == false, Comment(rawValue: notification.stderr))
        #expect(notification.status == 0, Comment(rawValue: notification.stderr))
        let stateURL = context.root.appendingPathComponent("campfire-hook-sessions.json")
        let state = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        let record = try #require((state["sessions"] as? [String: Any])?[sessionId] as? [String: Any])
        // Every command in order through the production reconciler: what it accepts is what the app would deliver.
        let pipeline = AgentHookTestNotificationPipeline()
        let delivered = context.state.snapshot().flatMap { pipeline.effects(for: $0) }
        return (Array(context.state.snapshot().dropFirst(start)), delivered, record)
    }

    @Test func joinRequestJournalsAnApprovalRequest() throws {
        let result = try campfireNotificationCommands(eventType: "join.requested")
        #expect(
            AgentJournalAppendCapture.captures(in: result.commands).contains { $0.kind == "agent.approval.requested" && $0.agentKey == "campfire" },
            "join.requested must journal a needs-input approval request, saw \(result.commands)"
        )
        #expect(result.record["agentLifecycle"] as? String == "needsInput")
    }

    @Test func relayErrorKeepsItsPingAsAPlainMessageAndRaisesNoTriangle() throws {
        let result = try campfireNotificationCommands(eventType: "relay.error")
        let captures = AgentJournalAppendCapture.captures(in: result.commands)
        #expect(captures.contains { $0.kind == "agent.message.published" && $0.agentKey == "campfire" },
                "relay.error must journal a plain message, saw \(result.commands)")
        #expect(!captures.contains { $0.kind == "agent.error.reported" }, "relay.error must not enter the error row, saw \(result.commands)")
        #expect(result.delivered.contains { $0.contains("Campfire relay connection failed") },
                "relay.error must keep its ping, saw \(result.commands)")
        #expect(!result.commands.contains { $0.hasPrefix("set_status campfire ") && $0.contains("exclamationmark.triangle.fill") },
                "relay.error must write no error pill, saw \(result.commands)")
        #expect(result.record["lastNotificationStatus"] as? String != "error")
    }

    private final class BundleProbe {}

    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    private final class MockSocketServerState: @unchecked Sendable {
        private let lock = NSLock()
        private var commands: [String] = []

        func append(_ command: String) {
            lock.lock()
            commands.append(command)
            lock.unlock()
        }

        func snapshot() -> [String] {
            lock.lock()
            let value = commands
            lock.unlock()
            return value
        }
    }

    private struct HookContext {
        let cliPath: String
        let socketPath: String
        let listenerFD: Int32
        let state: MockSocketServerState
        let root: URL
        let workspaceId: String
        let surfaceId: String

        func cleanup() {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeHookContext(name: String) throws -> HookContext {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-\(name)-\(UUID().uuidString)", isDirectory: true)
        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-\(name.prefix(6))-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).sock")
            .path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return HookContext(
            cliPath: try BundledCLITestSupport.bundledCLIPath(for: BundleProbe.self),
            socketPath: socketPath,
            listenerFD: try bindUnixSocket(at: socketPath),
            state: MockSocketServerState(),
            root: root,
            workspaceId: "11111111-1111-1111-1111-111111111111",
            surfaceId: "22222222-2222-2222-2222-222222222222"
        )
    }

    private func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw posixError("socket")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = Array(path.utf8)
        guard utf8.count < maxPathLength else {
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "socket path is too long: \(path)",
            ])
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { buffer in
                for index in 0..<utf8.count {
                    buffer[index] = CChar(bitPattern: utf8[index])
                }
                buffer[utf8.count] = 0
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw posixError("bind")
        }
        guard Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw posixError("listen")
        }
        return fd
    }

    private func agentLaunchEnvironment(
        context: HookContext,
        kind: String,
        executable: String,
        arguments: [String]? = nil
    ) -> [String: String] {
        [
            "CMUX_AGENT_LAUNCH_KIND": kind,
            "CMUX_AGENT_LAUNCH_EXECUTABLE": executable,
            "CMUX_AGENT_LAUNCH_CWD": context.root.path,
            "CMUX_AGENT_LAUNCH_ARGV_B64": base64NULSeparated(arguments ?? [executable]),
        ]
    }

    private func runAgentHook(
        context: HookContext,
        agent: String,
        subcommand: String,
        standardInput: String,
        extraEnvironment: [String: String] = [:]
    ) -> ProcessRunResult {
        var environment = [
            "HOME": context.root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": context.root.path,
            "CMUX_SOCKET_PATH": context.socketPath,
            "CMUX_WORKSPACE_ID": context.workspaceId,
            "CMUX_SURFACE_ID": context.surfaceId,
            "CMUX_AGENT_HOOK_STATE_DIR": context.root.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
        ]
        environment.merge(extraEnvironment, uniquingKeysWith: { _, new in new })

        return runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", agent, subcommand],
            environment: environment,
            standardInput: standardInput,
            timeout: 5
        )
    }

    private func startAgentHookMockServerAccepting(
        context: HookContext,
        connectionLimit: Int
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var accepted = 0
            while accepted < connectionLimit {
                var clientAddr = sockaddr_un()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.accept(context.listenerFD, sockaddrPtr, &clientAddrLen)
                    }
                }
                if clientFD < 0 {
                    if errno == EINTR { continue }
                    return
                }
                accepted += 1

                DispatchQueue.global(qos: .userInitiated).async {
                    defer { Darwin.close(clientFD) }
                    var pending = Data()
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let count = Darwin.read(clientFD, &buffer, buffer.count)
                        if count < 0 {
                            if errno == EINTR { continue }
                            return
                        }
                        if count == 0 { return }
                        pending.append(buffer, count: count)
                        while let newlineRange = pending.firstRange(of: Data([0x0A])) {
                            let lineData = pending.subdata(in: 0..<newlineRange.lowerBound)
                            pending.removeSubrange(0...newlineRange.lowerBound)
                            guard let line = String(data: lineData, encoding: .utf8) else { continue }
                            context.state.append(line)
                            let response = agentHookMockResponse(line: line, context: context) + "\n"
                            _ = response.withCString { ptr in
                                Darwin.write(clientFD, ptr, strlen(ptr))
                            }
                        }
                    }
                }
            }
        }
    }

    private func agentHookMockResponse(line: String, context: HookContext) -> String {
        guard let payload = jsonObject(line) else {
            return "OK"
        }
        guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
            return malformedRequestResponse(id: payload["id"] as? String, raw: line)
        }
        switch method {
        case "surface.list":
            return v2Response(
                id: id,
                ok: true,
                result: ["surfaces": [["id": context.surfaceId, "ref": "surface:1", "focused": true]]]
            )
        case "feed.push":
            return v2Response(id: id, ok: true, result: [:])
        case "surface.resume.set":
            return v2Response(id: id, ok: true, result: ["resume_binding": [:]])
        case "surface.resume.clear":
            return v2Response(id: id, ok: true, result: ["cleared": true])
        default:
            return v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
        }
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        standardInput: String,
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }
        stdinPipe.fileHandleForWriting.write(Data(standardInput.utf8))
        try? stdinPipe.fileHandleForWriting.close()

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSignal.wait(timeout: .now() + 1)
            }
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessRunResult(
            status: process.isRunning ? SIGKILL : process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }

    private func base64NULSeparated(_ values: [String]) -> String {
        var data = Data()
        for value in values {
            data.append(contentsOf: value.utf8)
            data.append(0)
        }
        return data.base64EncodedString()
    }

    private func v2Response(
        id: String,
        ok: Bool,
        result: [String: Any]? = nil,
        error: [String: Any]? = nil
    ) -> String {
        var payload: [String: Any] = ["id": id, "ok": ok]
        if let result { payload["result"] = result }
        if let error { payload["error"] = error }
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [])
        return String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }

    private func malformedRequestResponse(id: String? = nil, raw: String) -> String {
        v2Response(
            id: id ?? "unknown",
            ok: false,
            error: ["code": "malformed_request", "message": "invalid or non-JSON payload", "raw": raw]
        )
    }

    private func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }

    private func posixError(_ operation: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
            NSLocalizedDescriptionKey: "\(operation) failed with errno \(errno)",
        ])
    }
}
