import Darwin
import Foundation
import Testing

// cmux-rbf #cm-126.3: what `cmux agent-pane` sends and prints, from the real CLI binary.

private final class AgentPaneCLIBundleToken {}

/// The caller `show` names, its retry on `not_found`, and the lines it prints,
/// read from the real CLI binary talking to a stand-in socket, in
/// `FigmaCLIOutputTests`' style.
///
/// **The child sees only the environment built here.** `HOME` and
/// `CFFIXED_USER_HOME` both point at a folder of the test's own, which also
/// holds herdr-agent's note when a test writes one. Nothing here reads Tom's
/// files or reaches the real cmux socket.
@Suite("AgentPaneCLIOutput", .serialized)
struct AgentPaneCLIOutputTests {

    // MARK: - Stand-in app

    private static let callerSurface = "11111111-2222-3333-4444-555555555555"
    private static let page = "https://example.org/p"

    private static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func ok(_ result: [String: Any]) -> String {
        json(["id": NSNull(), "ok": true, "result": result])
    }

    private static func failure(_ code: String, _ message: String, data: [String: Any]? = nil) -> String {
        var error: [String: Any] = ["code": code, "message": message]
        if let data { error["data"] = data }
        return json(["id": NSNull(), "ok": false, "error": error])
    }

    private static func unexpected(_ method: String, _ surfaceID: String?) -> String {
        failure("unexpected", method)
    }

    private static let opened: [String: Any] = [
        "action": "opened",
        "surface_id": "agent-pane-id", "surface_ref": "surface:3",
        "pane_id": "pane-id", "pane_ref": "pane:2",
        "workspace_id": "ws-id", "workspace_ref": "workspace:1",
        "owner_surface_id": "term-id", "owner_surface_ref": "surface:1",
        "owner_stable_id": "stable-id",
        "url": page, "others": 0
    ]

    /// Answers `show` with `answer` for every surface, unless `notFound` names it.
    private static func showReply(
        _ answer: [String: Any] = opened,
        notFound: Set<String> = []
    ) -> @Sendable (String, String?) -> String {
        let text = ok(answer)
        return { method, surfaceID in
            guard method == "agent_pane.show" else { return unexpected(method, surfaceID) }
            if let surfaceID, notFound.contains(surfaceID) {
                return failure("not_found", "Surface not found", data: ["surface": surfaceID])
            }
            return text
        }
    }

    /// A line-framed Unix socket that answers each request through `reply` and
    /// keeps what it was asked.
    // The accept loop owns connections; the lock protects the only shared mutable value, recorded lines.
    private final class StandInSocket: @unchecked Sendable {
        struct Request {
            let method: String
            let params: [String: Any]
        }

        let path: String
        private let listenerFD: Int32
        private let lock = NSLock()
        private var lines: [String] = []

        init(path: String, reply: @escaping @Sendable (_ method: String, _ surfaceID: String?) -> String) throws {
            self.path = path
            unlink(path)
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            let bytes = Array(path.utf8)
            guard bytes.count < capacity else {
                Darwin.close(fd)
                throw POSIXError(.ENAMETOOLONG)
            }
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                    for index in 0..<bytes.count { buffer[index] = CChar(bitPattern: bytes[index]) }
                    buffer[bytes.count] = 0
                }
            }
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, Darwin.listen(fd, 8) == 0 else {
                let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                Darwin.close(fd)
                throw POSIXError(code)
            }
            listenerFD = fd

            CLIMockAcceptLoopRegistry.shared.start(listenerFD: fd, onConnection: { [self] clientFD in
                defer { Darwin.close(clientFD) }
                cliMockServeLineFramedConnection(clientFD: clientFD) { line in
                    self.lock.lock()
                    self.lines.append(line)
                    self.lock.unlock()
                    let request = Self.parse(line)
                    let surfaceID = request?.params["surface_id"] as? String
                    return reply(request?.method ?? "", surfaceID)
                }
            }, onListenerClosed: {})
        }

        private static func parse(_ line: String) -> Request? {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String
            else { return nil }
            return Request(method: method, params: object["params"] as? [String: Any] ?? [:])
        }

        var requests: [Request] {
            lock.lock()
            defer { lock.unlock() }
            return lines.compactMap(Self.parse)
        }

        func stop() {
            CLIMockAcceptLoopRegistry.shared.stop(listenerFD: listenerFD)
            Darwin.close(listenerFD)
            unlink(path)
        }
    }

    // MARK: - Running the CLI

    private struct Run {
        let status: Int32
        let stdout: String
        let stderr: String
        let requests: [StandInSocket.Request]

        var shows: [StandInSocket.Request] { requests.filter { $0.method == "agent_pane.show" } }
    }

    private struct ProcessTimeout: Error, CustomStringConvertible {
        let arguments: [String]
        let timeout: TimeInterval
        let processIdentifier: Int32
        let stillRunning: Bool

        var description: String {
            "cmux \(arguments.joined(separator: " ")) did not exit within \(Int(timeout)) s (pid \(processIdentifier)); "
                + "after SIGTERM and a 2 s grace it was \(stillRunning ? "still running" : "gone")"
        }
    }

    /// Runs `process` and throws, with the process named, if it outlives `timeout`
    /// plus a 2 s grace after SIGTERM.
    private static func runWithBoundedWait(
        _ process: Process,
        arguments: [String],
        timeout: TimeInterval = 30
    ) throws {
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
            throw ProcessTimeout(
                arguments: arguments,
                timeout: timeout,
                processIdentifier: process.processIdentifier,
                stillRunning: process.isRunning
            )
        }
    }

    /// Runs `cmux <arguments>` against a stand-in socket that answers through `reply`.
    private func drive(
        _ arguments: [String],
        environment extraEnvironment: [String: String] = [:],
        prepareHome: (URL) throws -> Void = { _ in },
        reply: @escaping @Sendable (String, String?) -> String = { method, surface in
            AgentPaneCLIOutputTests.unexpected(method, surface)
        }
    ) throws -> Run {
        let fileManager = FileManager.default
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        let home = fileManager.temporaryDirectory.appendingPathComponent("cmux-agent-pane-cli-\(id)", isDirectory: true)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try prepareHome(home)
        let socketPath = "/tmp/cmux-rdr-\(id).sock"
        defer {
            try? fileManager.removeItem(at: home)
            unlink(socketPath)
        }

        let standIn = try StandInSocket(path: socketPath, reply: reply)
        defer { standIn.stop() }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: try BundledCLITestSupport.bundledCLIPath(for: AgentPaneCLIBundleToken.self))
        process.arguments = arguments
        var environment = [
            "HOME": home.path,
            "CFFIXED_USER_HOME": home.path,
            "TMPDIR": home.path + "/",
            "PATH": "/usr/bin:/bin",
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_CLI_SENTRY_DISABLED": "1"
        ]
        environment.merge(extraEnvironment) { _, new in new }
        process.environment = environment
        process.currentDirectoryURL = home
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        try Self.runWithBoundedWait(process, arguments: arguments)

        return Run(
            status: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            requests: standIn.requests
        )
    }

    // MARK: - herdr-agent's note (copied from FigmaCLIOutputTests, which keeps it private)

    private static let noteSession = "cm1263"
    private static let notePane = "p1"
    private static let herdrEnvironment = ["HERDR_SESSION": noteSession, "HERDR_PANE_ID": notePane]

    private static func writeNote(_ home: URL, surface: String, pid: Int32) throws {
        let folder = home.appendingPathComponent(".local/state/herdr-agent/panes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let line = "\(surface)\t\(UUID().uuidString)\t\(pid)\n"
        try line.write(to: folder.appendingPathComponent("\(noteSession).\(notePane)"), atomically: true, encoding: .utf8)
        try HerdrAttachNoteTestSupport(
            pid: pid, notePath: folder.appendingPathComponent("\(noteSession).\(notePane)").path
        ).waitUntilLive()
    }

    /// A retained wait process under herdr's attach name, terminated only at fixture teardown.
    private func withAttachProcess(_ body: (Process) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cm-126.3-attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/zsh")
        child.arguments = ["-fc", "exec -a herdr-agent-attach /bin/sleep \"$1\"", "herdr-attach-test", "600"]
        child.environment = ["HOME": folder.path, "PATH": "/usr/bin:/bin"]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        try withExtendedLifetime(child) { try body(child) }
    }

    // MARK: - The caller

    @Test("--surface sends one show carrying that surface, and no note is read")
    func surfaceFlagNamesTheCaller() throws {
        try withAttachProcess { child in
            let run = try drive(
                ["agent-pane", "show", Self.page, "--surface", "surface:7"],
                environment: Self.herdrEnvironment.merging(["CMUX_SURFACE_ID": Self.callerSurface]) { $1 },
                prepareHome: { try Self.writeNote($0, surface: UUID().uuidString, pid: child.processIdentifier) },
                reply: Self.showReply()
            )
            #expect(run.status == 0, "\(run.stderr)")
            #expect(run.shows.count == 1, "\(run.requests.map(\.method))")
            #expect(run.shows.first?.params["surface_id"] as? String == "surface:7")
            #expect(run.shows.first?.params["url"] as? String == Self.page)
        }
    }

    @Test("with no --surface, CMUX_SURFACE_ID names the caller")
    func environmentNamesTheCaller() throws {
        let run = try drive(
            ["agent-pane", "show", Self.page],
            environment: ["CMUX_SURFACE_ID": Self.callerSurface],
            reply: Self.showReply()
        )
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.shows.count == 1)
        #expect(run.shows.first?.params["surface_id"] as? String == Self.callerSurface)
    }

    @Test("an empty explicit --surface says the value is empty and sends nothing")
    func emptySurfaceOverrideNamesMissingSurface() throws {
        let run = try drive(
            ["agent-pane", "show", Self.page, "--surface", "   "],
            environment: ["CMUX_SURFACE_ID": Self.callerSurface],
            reply: Self.showReply()
        )
        #expect(run.status == 1)
        #expect(run.stderr == "Error: --surface value is empty\n", "\(run.stderr)")
        #expect(run.requests.isEmpty)
    }

    @Test("an unknown explicit surface ref or UUID reports no such surface without trying another caller")
    func unknownSurfaceOverrideNamesMissingSurface() throws {
        for surface in ["surface:404", UUID().uuidString] {
            let run = try drive(
                ["agent-pane", "show", Self.page, "--surface", surface],
                environment: ["CMUX_SURFACE_ID": Self.callerSurface],
                reply: { method, _ in
                    guard method == "agent_pane.show" else { return Self.unexpected(method, nil) }
                    if surface == "surface:404" {
                        return Self.failure(
                            "invalid_params", "Missing or invalid surface_id or url",
                            data: ["reason": "invalid_show_params"]
                        )
                    }
                    return Self.failure("not_found", "Surface not found")
                }
            )
            #expect(run.status == 1)
            #expect(run.stderr == "Error: no such surface: \(surface)\n", "\(run.stderr)")
            #expect(run.shows.count == 1)
            #expect(run.shows.first?.params["surface_id"] as? String == surface)
        }
    }

    @Test("a malformed explicit --surface reports no such surface and a JSON code without sending a request")
    func malformedSurfaceOverrideHasJSONCode() throws {
        let run = try drive(
            ["--json", "agent-pane", "show", Self.page, "--surface", "foo"],
            environment: ["CMUX_SURFACE_ID": Self.callerSurface],
            reply: Self.showReply()
        )
        #expect(run.status == 1)
        #expect(run.stderr == "Error: no such surface: foo\n", "\(run.stderr)")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(run.stdout.utf8)) as? [String: Any])
        #expect(object["ok"] as? Bool == false)
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "not_found")
        #expect(error["message"] as? String == "no such surface: foo")
        #expect(run.requests.isEmpty)
    }

    @Test("address-like pages have helpful refusals and send nothing")
    func addressLikePagesHaveHelpfulRefusals() throws {
        for (page, message) in [
            ("view-source:https://x", "not a file, file://, https:// or http:// page: view-source:https://x"),
            ("localhost:8080", "not a file, file://, https:// or http:// page: localhost:8080; did you mean http://localhost:8080?")
        ] {
            let run = try drive(
                ["--json", "agent-pane", "show", page],
                environment: ["CMUX_SURFACE_ID": Self.callerSurface],
                reply: Self.showReply()
            )
            #expect(run.status == 1)
            #expect(run.stderr == "Error: \(message)\n", "\(run.stderr)")
            let object = try #require(try JSONSerialization.jsonObject(with: Data(run.stdout.utf8)) as? [String: Any])
            let error = try #require(object["error"] as? [String: Any])
            #expect(error["code"] as? String == "invalid_params")
            #expect(error["reason"] as? String == "bad_page")
            #expect(error["message"] as? String == message)
            #expect(run.requests.isEmpty)
        }
    }

    @Test("a relative file URL reaches agent_pane.show as an absolute file URL")
    func relativeFileURLSendsAbsoluteURL() throws {
        var expectedURL: URL?
        let run = try drive(
            ["agent-pane", "show", "file:pages/p1.html"],
            environment: ["CMUX_SURFACE_ID": Self.callerSurface],
            prepareHome: { home in
                let folder = home.appendingPathComponent("pages", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = folder.appendingPathComponent("p1.html")
                try Data("<p>relative page</p>".utf8).write(to: file)
                expectedURL = file.resolvingSymlinksInPath()
            },
            reply: Self.showReply()
        )
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.shows.count == 1)
        let expected = try #require(expectedURL)
        let sent = try #require(run.shows.first?.params["url"] as? String)
        #expect(sent.hasPrefix("file:///"), "the app received an unresolved file URL: \(sent)")
        let actual = try #require(URL(string: sent))
        #expect(actual.resolvingSymlinksInPath() == expected)
    }

    @Test("with no caller at all, show fails and sends nothing")
    func noCallerFails() throws {
        let run = try drive(["agent-pane", "show", Self.page], reply: Self.showReply())
        #expect(run.status == 1)
        #expect(run.stderr == "Error: \(AgentPaneCLIRules.noCallerMessage)\n", "\(run.stderr)")
        #expect(run.requests.isEmpty, "\(run.requests.map(\.method))")
    }

    @Test("a live note goes first; when the app doesn't know it, show retries with CMUX_SURFACE_ID")
    func notFoundRetriesWithTheNext() throws {
        let noted = UUID().uuidString
        try withAttachProcess { child in
            let run = try drive(
                ["agent-pane", "show", Self.page],
                environment: Self.herdrEnvironment.merging(["CMUX_SURFACE_ID": Self.callerSurface]) { $1 },
                prepareHome: { try Self.writeNote($0, surface: noted, pid: child.processIdentifier) },
                reply: Self.showReply(notFound: [noted])
            )
            #expect(run.status == 0, "\(run.stderr)")
            #expect(run.shows.map { $0.params["surface_id"] as? String } == [noted, Self.callerSurface])
        }
    }

    @Test("invalid_show_params has the same implicit-caller retry semantics as not_found")
    func invalidShowParamsRetriesImplicitCaller() throws {
        let noted = UUID().uuidString
        try withAttachProcess { child in
            let run = try drive(
                ["agent-pane", "show", Self.page],
                environment: Self.herdrEnvironment.merging(["CMUX_SURFACE_ID": Self.callerSurface]) { $1 },
                prepareHome: { try Self.writeNote($0, surface: noted, pid: child.processIdentifier) },
                reply: { method, surface in
                    guard method == "agent_pane.show" else { return Self.unexpected(method, surface) }
                    if surface == noted {
                        return Self.failure("invalid_params", "Unknown implicit surface", data: ["reason": "invalid_show_params"])
                    }
                    return Self.ok(Self.opened)
                }
            )
            #expect(run.status == 0, "\(run.stderr)")
            #expect(run.shows.map { $0.params["surface_id"] as? String } == [noted, Self.callerSurface])
        }
    }

    @Test("a stale implicit surface ref ends as that terminal is gone with a not_found JSON code")
    func staleImplicitRefNamesGoneTerminal() throws {
        let run = try drive(
            ["--json", "agent-pane", "show", Self.page],
            environment: ["CMUX_SURFACE_ID": "surface:404"],
            reply: { method, surface in
                guard method == "agent_pane.show" else { return Self.unexpected(method, surface) }
                return Self.failure("invalid_params", "Unknown implicit surface", data: ["reason": "invalid_show_params"])
            }
        )
        #expect(run.status == 1)
        #expect(run.stderr == "Error: that terminal is gone: surface:404\n", "\(run.stderr)")
        #expect(run.shows.count == 1)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(run.stdout.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "not_found")
        #expect(error["reason"] as? String == "not_found")
        #expect(error["message"] as? String == "that terminal is gone: surface:404")
    }

    @Test("when every caller is not_found, show fails naming the last, after one request each")
    func everyCallerNotFoundFails() throws {
        let noted = UUID().uuidString
        try withAttachProcess { child in
            let run = try drive(
                ["agent-pane", "show", Self.page],
                environment: Self.herdrEnvironment.merging(["CMUX_SURFACE_ID": Self.callerSurface]) { $1 },
                prepareHome: { try Self.writeNote($0, surface: noted, pid: child.processIdentifier) },
                reply: Self.showReply(notFound: [noted, Self.callerSurface])
            )
            #expect(run.status == 1)
            #expect(run.stderr == "Error: that terminal is gone: \(Self.callerSurface)\n", "\(run.stderr)")
            #expect(run.shows.count == 2, "\(run.shows.map(\.params))")
        }
    }

    @Test("any other error ends the loop after one request")
    func otherErrorDoesNotRetry() throws {
        let noted = UUID().uuidString
        try withAttachProcess { child in
            let run = try drive(
                ["agent-pane", "show", Self.page],
                environment: Self.herdrEnvironment.merging(["CMUX_SURFACE_ID": Self.callerSurface]) { $1 },
                prepareHome: { try Self.writeNote($0, surface: noted, pid: child.processIdentifier) },
                reply: { method, _ in
                    guard method == "agent_pane.show" else { return Self.unexpected(method, nil) }
                    return Self.failure("invalid_params", "x", data: ["reason": "not_terminal", "surface": "s", "type": "browser"])
                }
            )
            #expect(run.status == 1)
            #expect(run.stderr == "Error: the Agent Pane belongs to a terminal, and s is a browser\n", "\(run.stderr)")
            #expect(run.shows.count == 1, "\(run.shows.map(\.params))")
        }
    }

    // MARK: - What it prints

    @Test("agent-pane --help describes show, list, the caption and local-only scope without a socket request")
    func helpDescribesAgentPaneWithoutRequest() throws {
        let run = try drive(["agent-pane", "--help"])
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.stdout.contains("agent-pane show <page>"))
        #expect(run.stdout.contains("agent-pane list [--workspace <id|ref>]"))
        #expect(run.stdout.contains("Agent Pane"))
        #expect(run.stdout.contains("Not available over `cmux ssh`."))
        #expect(run.requests.isEmpty)
    }

    @Test("show prints the house line")
    func showPrintsTheHouseLine() throws {
        let run = try drive(
            ["agent-pane", "show", Self.page],
            environment: ["CMUX_SURFACE_ID": Self.callerSurface],
            reply: Self.showReply()
        )
        #expect(run.stdout == "OK surface=surface:3 pane=pane:2 workspace=workspace:1 action=opened\n")
    }

    @Test("a hold with no Agent Pane yet prints none for the surface and pane")
    func heldWithNoAgentPanePrintsNone() throws {
        var held = Self.opened
        held["action"] = "held-design-focus"
        for key in ["surface_id", "surface_ref", "pane_id", "pane_ref"] { held[key] = NSNull() }
        let run = try drive(
            ["agent-pane", "show", Self.page],
            environment: ["CMUX_SURFACE_ID": Self.callerSurface],
            reply: Self.showReply(held)
        )
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.stdout == "OK surface=none pane=none workspace=workspace:1 action=held-design-focus\n")
    }

    @Test("--json prints the answer as JSON")
    func showPrintsJSON() throws {
        let run = try drive(
            ["--json", "--id-format", "both", "agent-pane", "show", Self.page],
            environment: ["CMUX_SURFACE_ID": Self.callerSurface],
            reply: Self.showReply()
        )
        let object = try #require(try JSONSerialization.jsonObject(with: Data(run.stdout.utf8)) as? [String: Any])
        #expect(object["action"] as? String == "opened")
        #expect(object["owner_stable_id"] as? String == "stable-id")
    }

    @Test("under --json an error also prints its code and reason on stdout")
    func jsonErrorCarriesCodeAndReason() throws {
        let run = try drive(
            ["--json", "agent-pane", "show", "http://example.org/"],
            environment: ["CMUX_SURFACE_ID": Self.callerSurface],
            reply: { _, _ in Self.failure("invalid_params", "x", data: ["reason": "insecure_http", "host": "example.org"]) }
        )
        #expect(run.status == 1)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(run.stdout.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "invalid_params")
        #expect(error["reason"] as? String == "insecure_http")
    }

    @Test("a refused page changes nothing: no request is sent")
    func badPageSendsNothing() throws {
        let run = try drive(
            ["agent-pane", "show", "javascript:alert(1)"],
            environment: ["CMUX_SURFACE_ID": Self.callerSurface],
            reply: Self.showReply()
        )
        #expect(run.status == 1)
        #expect(run.stderr == "Error: not a file, file://, https:// or http:// page: javascript:alert(1)\n")
        #expect(run.requests.isEmpty)
    }

    private static func listReply(owner: String?) -> @Sendable (String, String?) -> String {
        var agentPane: [String: Any] = [
            "surface_id": "agent-pane-id", "surface_ref": "surface:3",
            "pane_id": "pane-id", "pane_ref": "pane:2",
            "workspace_id": "ws-id", "workspace_ref": "workspace:1",
            "owner_surface_id": NSNull(), "owner_surface_ref": NSNull(),
            "owner_stable_id": "99999999-8888-7777-6666-555555555555",
            "url": page
        ]
        if let owner {
            agentPane["owner_surface_id"] = "term-id"
            agentPane["owner_surface_ref"] = owner
        }
        let text = ok(["agent_panes": [agentPane]])
        return { method, _ in method == "agent_pane.list" ? text : unexpected(method, nil) }
    }

    @Test("list's text says owner=none when the owner terminal is gone, never its stable id")
    func listPrintsOwnerNone() throws {
        let run = try drive(["agent-pane", "list"], reply: Self.listReply(owner: nil))
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.stdout == "surface:3 pane=pane:2 workspace=workspace:1 owner=none url=\(Self.page)\n")
    }

    @Test("list's text names the owner terminal by its ref")
    func listPrintsOwnerRef() throws {
        let run = try drive(["agent-pane", "list"], reply: Self.listReply(owner: "surface:1"))
        #expect(run.stdout == "surface:3 pane=pane:2 workspace=workspace:1 owner=surface:1 url=\(Self.page)\n")
    }

    @Test("list with no panes prints (none)")
    func listPrintsNone() throws {
        let run = try drive(["agent-pane", "list"], reply: { method, _ in
            method == "agent_pane.list" ? Self.ok(["agent_panes": []]) : Self.unexpected(method, nil)
        })
        #expect(run.stdout == "(none)\n")
    }

    @Test("list --json forwards the workspace filter and keeps live, stable and ref fields under --id-format both")
    func listJSONForwardsWorkspaceAndPreservesIDs() throws {
        let run = try drive(
            ["--json", "--id-format", "both", "agent-pane", "list", "--workspace", "workspace:7"],
            reply: Self.listReply(owner: "surface:1")
        )
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.requests.count == 1)
        let request = try #require(run.requests.first)
        #expect(request.method == "agent_pane.list")
        #expect(request.params["workspace_id"] as? String == "workspace:7")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(run.stdout.utf8)) as? [String: Any])
        let rows = try #require(object["agent_panes"] as? [[String: Any]])
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row["surface_id"] as? String == "agent-pane-id")
        #expect(row["surface_ref"] as? String == "surface:3")
        #expect(row["owner_surface_id"] as? String == "term-id")
        #expect(row["owner_surface_ref"] as? String == "surface:1")
        #expect(row["owner_stable_id"] as? String == "99999999-8888-7777-6666-555555555555")
    }
}
