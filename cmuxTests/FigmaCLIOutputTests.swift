import Darwin
import Foundation
import Testing

private final class FigmaCLIBundleToken {}

/// What `cmux figma open` and `goto` print, and which pane `goto` moves, read
/// from the real CLI binary talking to a stand-in socket.
///
/// **The child sees only the environment built here.** `HOME` and
/// `CFFIXED_USER_HOME` both point at a folder of the test's own: `HOME` alone
/// does not move the home folder Foundation reports. Since `cm-73.39` the CLI
/// writes no page there; the tests check that it does not. Nothing here reads Tom's `~/.config/cmux/cmux.json`
/// or reaches the real cmux socket.
@Suite("FigmaCLIOutput", .serialized)
struct FigmaCLIOutputTests {

    // MARK: - Stand-in app

    /// One browser pane, as the stand-in app reports it.
    private struct Pane: Sendable {
        let id: String
        let ref: String
        let url: String
        /// `show_omnibar` in the `browser.url.get` reply. `nil` leaves the key out.
        let showsAddressBar: Bool?
    }

    private static let editorLink = "https://www.figma.com/design/KEY/slug"

    private static func figmaPane(_ n: Int, link: String = editorLink) -> Pane {
        Pane(id: "id-\(n)", ref: "surface:\(n)", url: link, showsAddressBar: false)
    }

    private static func ordinaryPane(_ n: Int, link: String = editorLink) -> Pane {
        Pane(id: "id-\(n)", ref: "surface:\(n)", url: link, showsAddressBar: true)
    }

    private static func ok(_ result: [String: Any]) -> String {
        json(["id": NSNull(), "ok": true, "result": result])
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// The app side of `goto`: the surfaces, what each one shows, and a `navigate`.
    private static func gotoReply(_ panes: [Pane]) -> @Sendable (String, String?) -> String {
        { method, surfaceID in
            switch method {
            case "surface.list":
                var surfaces: [[String: Any]] = [["type": "terminal", "id": "term", "ref": "surface:99"]]
                surfaces += panes.map { ["type": "browser", "id": $0.id, "ref": $0.ref] }
                return ok(["surfaces": surfaces])
            case "browser.url.get":
                guard let pane = panes.first(where: { $0.id == surfaceID }) else {
                    return ok(["url": "about:blank"])
                }
                var reply: [String: Any] = ["url": pane.url]
                if let showsAddressBar = pane.showsAddressBar { reply["show_omnibar"] = showsAddressBar }
                return ok(reply)
            case "figma.goto":
                return ok(["surface_id": surfaceID ?? "", "surface_ref": "surface:moved", "side": "preview"])
            default:
                return unexpected(method, surfaceID)
            }
        }
    }

    private static func unexpected(_ method: String, _ surfaceID: String?) -> String {
        json(["id": NSNull(), "ok": false, "error": ["code": "unexpected", "message": method]])
    }

    private static func failure(_ code: String, _ message: String) -> String {
        json(["id": NSNull(), "ok": false, "error": ["code": code, "message": message]])
    }

    /// The app that cannot find the pane the request names: an error for any
    /// request carrying a `surface_id`, the usual answer for any without one.
    private static func openReplyRejectingSurface(code: String) -> @Sendable (String, String?) -> String {
        { method, surfaceID in
            guard method == "browser.open_split" else { return unexpected(method, surfaceID) }
            if surfaceID != nil { return failure(code, "Source surface not found") }
            return ok([
                "surface_id": "new-surface", "surface_ref": "surface:3",
                "pane_id": "new-pane", "pane_ref": "pane:2",
                "created_split": true
            ])
        }
    }

    private static func openReply(createdSplit: Bool, orientation: String? = nil) -> @Sendable (String, String?) -> String {
        { method, surfaceID in
            guard method == "browser.open_split" else { return unexpected(method, surfaceID) }
            return ok([
                "surface_id": "new-surface", "surface_ref": "surface:3",
                "pane_id": "new-pane", "pane_ref": "pane:2",
                "created_split": createdSplit
            ].merging(orientation.map { ["orientation": $0] } ?? [:]) { _, new in new })
        }
    }

    /// A line-framed Unix socket that answers each request through `reply` and
    /// keeps what it was asked.
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
        /// Whether a read-view page file appeared under the test's own home folder;
        /// since `cm-73.39` the app serves the page and the CLI writes none.
        let pageInstalledInTestHome: Bool
        /// The test's own home folder, as the child was told it.
        let home: String

        var gotos: [StandInSocket.Request] { requests.filter { $0.method == "figma.goto" } }
        var opens: [StandInSocket.Request] { requests.filter { $0.method == "browser.open_split" } }
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
    /// plus a 2 s grace after SIGTERM. A normal exit is not bounded past this point.
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
    /// With `listening` false the socket path is set and nothing listens on it.
    private func drive(
        _ arguments: [String],
        listening: Bool = true,
        environment extraEnvironment: [String: String] = [:],
        prepareHome: (URL) throws -> Void = { _ in },
        reply: @escaping @Sendable (String, String?) -> String = FigmaCLIOutputTests.unexpected
    ) throws -> Run {
        let fileManager = FileManager.default
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        let home = fileManager.temporaryDirectory.appendingPathComponent("cmux-figma-cli-\(id)", isDirectory: true)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try prepareHome(home) // cmux-rbf #cm-73.45
        let socketPath = "/tmp/cmux-fig-\(id).sock"
        let pageFolder = home.appendingPathComponent("Library/Application Support/cmux", isDirectory: true)
        let page = pageFolder.appendingPathComponent("figma-embed.html")
        defer {
            try? fileManager.removeItem(at: home)
            unlink(socketPath)
        }

        let standIn = listening ? try StandInSocket(path: socketPath, reply: reply) : nil
        defer { standIn?.stop() }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: try BundledCLITestSupport.bundledCLIPath(for: FigmaCLIBundleToken.self))
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
            requests: standIn?.requests ?? [],
            pageInstalledInTestHome: fileManager.fileExists(atPath: page.path),
            home: home.path
        )
    }

    private func fails(_ run: Run, with message: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(run.status == 1, "\(run.stderr)", sourceLocation: sourceLocation)
        #expect(run.stderr == "Error: \(message)\n", sourceLocation: sourceLocation)
        #expect(run.stdout.isEmpty, "\(run.stdout)", sourceLocation: sourceLocation)
    }

    private func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - open

    private static let frameLink = "https://www.figma.com/design/KEY/slug?node-id=12-2"

    @Test("open prints the house line, with placement=split for a new split")
    func openPrintsSplit() throws {
        let run = try drive(["figma", "open", Self.frameLink], reply: Self.openReply(createdSplit: true))
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.stdout == "OK surface=surface:3 pane=pane:2 placement=split\n")
        #expect(run.stderr.isEmpty, "\(run.stderr)")
    }

    @Test("open prints placement=reuse when the app reused the pane on the right")
    func openPrintsReuse() throws {
        let run = try drive(["figma", "open", Self.frameLink], reply: Self.openReply(createdSplit: false))
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.stdout == "OK surface=surface:3 pane=pane:2 placement=reuse\n")
    }

    @Test("open prints a JSON document under --json")
    func openPrintsJSON() throws {
        let run = try drive(["--json", "figma", "open", Self.frameLink], reply: Self.openReply(createdSplit: true))
        #expect(run.status == 0, "\(run.stderr)")
        let object = jsonObject(run.stdout)
        #expect(object != nil, "\(run.stdout.debugDescription)")
        #expect(object?["created_split"] as? Bool == true, "\(run.stdout)")
        #expect(object?["surface_ref"] as? String == "surface:3", "\(run.stdout)")
    }

    @Test("open asks for a pane with no address bar, loading cmux's page for a frame, writing no page file")
    func openAsksForAPaneWithNoAddressBar() throws {
        let run = try drive(["figma", "open", Self.frameLink], reply: Self.openReply(createdSplit: true))
        let params = try #require(run.opens.first?.params)
        #expect(run.opens.count == 1)
        #expect(params["show_omnibar"] as? Bool == false)
        let address = try #require(params["url"] as? String)
        #expect(address.hasPrefix("cmux-figma://cmux/figma-embed.html?embed="), "\(address)") // cmux-rbf #cm-73.39
        #expect(address.contains("figma-embed.html?embed="), "\(address)")
        let embedded = URLComponents(string: address)?.queryItems?.first { $0.name == "embed" }?.value ?? ""
        #expect(embedded.hasPrefix("https://embed.figma.com/design/KEY/slug?"), "\(embedded)")
        #expect(embedded.contains("node-id=12-2"), "\(embedded)")
        // A guard against a page writer coming back: nothing in the CLI writes one today.
        #expect(!run.pageInstalledInTestHome, "cm-73.39: the CLI writes no page; the app serves it")
    }

    @Test("open sends no theme in the address it loads")
    func openSendsNoTheme() throws {
        let run = try drive(["figma", "open", Self.frameLink], reply: Self.openReply(createdSplit: true))
        let address = try #require(run.opens.first?.params["url"] as? String)
        #expect(!address.contains("theme"), "\(address)")
    }

    @Test("open refuses --theme by name and sends nothing, so no theme can reach the address")
    func openRefusesTheme() throws {
        for extra in [["--theme", "light"], ["--theme", "dark"]] {
            let run = try drive(["figma", "open", Self.frameLink] + extra, reply: Self.openReply(createdSplit: true))
            fails(run, with: "cmux figma open does not support --theme")
            #expect(run.requests.isEmpty, "\(extra): \(run.requests.map(\.method))")
        }
    }

    @Test("open of a whole-file link, and of the Share button's node-id=0-1 link, loads Figma's editor as pasted")
    func openLoadsTheEditorForAFileLink() throws {
        for link in [Self.editorLink, Self.editorLink + "?node-id=0-1", Self.editorLink + "?node-id=0:1"] {
            let run = try drive(["figma", "open", link], reply: Self.openReply(createdSplit: true))
            let address = try #require(run.opens.first?.params["url"] as? String, "\(link)")
            #expect(address.hasPrefix("https://www.figma.com/design/KEY/slug"), "\(address)")
            #expect(!address.contains("figma-embed.html"), "\(address)")
        }
    }

    @Test("open preserves the app's landed orientation in text and JSON")
    func openReportsLandedOrientation() throws {
        for orientation in ["vertical", "horizontal"] {
            for split in [true, false] {
                let reply = Self.openReply(createdSplit: split, orientation: orientation)
                let text = try drive(["figma", "open", Self.frameLink], reply: reply)
                #expect(text.status == 0, "\(text.stderr)")
                #expect(text.stdout == "OK surface=surface:3 pane=pane:2 placement=\(split ? "split" : "reuse") orientation=\(orientation)\n")
                let json = try drive(["--json", "figma", "open", Self.frameLink], reply: reply)
                #expect(json.status == 0, "\(json.stderr)")
                #expect(jsonObject(json.stdout)?["orientation"] as? String == orientation)
            }
        }
    }

    // MARK: - goto

    @Test("goto prints exactly OK")
    func gotoPrintsOK() throws {
        let run = try drive(["figma", "goto", "12-2"], reply: Self.gotoReply([Self.figmaPane(8)]))
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.stdout == "OK\n")
        #expect(run.stderr.isEmpty, "\(run.stderr)")
    }

    @Test("goto prints a JSON document under --json")
    func gotoPrintsJSON() throws {
        let run = try drive(["--json", "figma", "goto", "12-2"], reply: Self.gotoReply([Self.figmaPane(8)]))
        #expect(run.status == 0, "\(run.stderr)")
        let result = try #require(jsonObject(run.stdout))
        #expect(result["side"] as? String == "preview")
        #expect(result["stayed"] == nil)
    }

    @Test("goto moves the Figma pane and leaves an ordinary pane on a Figma file alone")
    func gotoMovesTheFigmaPane() throws {
        let panes = [
            Self.ordinaryPane(7, link: "https://www.figma.com/design/OTHER/other"),
            Self.figmaPane(8)
        ]
        let run = try drive(["figma", "goto", "12-2"], reply: Self.gotoReply(panes))
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.gotos.count == 1, "\(run.requests.map(\.method))")
        #expect(run.gotos.first?.params["surface_id"] as? String == "id-8")
        #expect(run.gotos.first?.params["node"] as? String == "12-2")
        #expect(!run.requests.contains { $0.method == "browser.navigate" })
    }

    @Test("goto with --motion or --play passes parameters and prints OK")
    func gotoMotionAndPlayCLI() throws {
        let panes = [Self.figmaPane(8)]
        let runMotion = try drive(["figma", "goto", "12-2", "--motion"], reply: Self.gotoReply(panes))
        #expect(runMotion.status == 0, "\(runMotion.stderr)")
        #expect(runMotion.stdout == "OK\n")
        #expect(runMotion.gotos.first?.params["motion"] as? Bool == true)
        #expect(runMotion.gotos.first?.params["play"] == nil)

        let runPlay = try drive(["figma", "goto", "12-2", "--play"], reply: Self.gotoReply(panes))
        #expect(runPlay.status == 0, "\(runPlay.stderr)")
        #expect(runPlay.stdout == "OK\n")
        #expect(runPlay.gotos.last?.params["motion"] as? Bool == true)
        #expect(runPlay.gotos.last?.params["play"] as? Bool == true)
    }

    @Test("goto with --motion or --play on a board or slide deck preview is refused")
    func gotoMotionRefusedOnBoardOrDeck() throws {
        let boardPane = Self.figmaPane(8, link: "https://www.figma.com/board/KEY/my-board")
        let runBoard = try drive(["figma", "goto", "12-2", "--motion"], reply: Self.gotoReply([boardPane]))
        #expect(runBoard.status != 0)
        #expect(runBoard.stderr.contains("cmux figma goto --motion works on Figma design files only: surface surface:8 shows a FigJam board or a slide deck"))

        let slidesPane = Self.figmaPane(9, link: "https://www.figma.com/slides/KEY/my-slides")
        let runSlides = try drive(["figma", "goto", "12-2", "--play"], reply: Self.gotoReply([slidesPane]))
        #expect(runSlides.status != 0)
        #expect(runSlides.stderr.contains("cmux figma goto --play works on Figma design files only: surface surface:9 shows a FigJam board or a slide deck"))
    }

    @Test("goto with only an ordinary pane on a Figma file refuses, moves nothing and names that pane")
    func gotoRefusesAnOrdinaryPaneAndNamesIt() throws {
        let run = try drive(["figma", "goto", "12-2"], reply: Self.gotoReply([Self.ordinaryPane(8)]))
        fails(run, with: "no Figma pane is open — browser panes showing a Figma file: surface:8. "
            + "Pass --surface <handle> to move one, or run `cmux figma open <url>` first")
        #expect(run.gotos.isEmpty)
    }

    @Test("a reply with no show_omnibar counts as an ordinary pane")
    func noShowOmnibarCountsAsOrdinary() throws {
        let pane = Pane(id: "id-8", ref: "surface:8", url: Self.editorLink, showsAddressBar: nil)
        let run = try drive(["figma", "goto", "12-2"], reply: Self.gotoReply([pane]))
        fails(run, with: "no Figma pane is open — browser panes showing a Figma file: surface:8. "
            + "Pass --surface <handle> to move one, or run `cmux figma open <url>` first")
        #expect(run.gotos.isEmpty)
    }

    @Test("--surface moves an ordinary pane that shows a Figma file")
    func surfaceMovesAnOrdinaryPane() throws {
        let run = try drive(
            ["figma", "goto", "12-2", "--surface", "id-8"],
            reply: Self.gotoReply([Self.ordinaryPane(8)])
        )
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.stdout == "OK\n")
        #expect(run.gotos.first?.params["surface_id"] as? String == "id-8")
    }

    @Test("two ordinary panes on a Figma file are both named, separated by a comma")
    func twoOrdinaryPanesAreBothNamed() throws {
        let run = try drive(
            ["figma", "goto", "12-2"],
            reply: Self.gotoReply([Self.ordinaryPane(8), Self.ordinaryPane(10)])
        )
        fails(run, with: "no Figma pane is open — browser panes showing a Figma file: surface:8, surface:10. "
            + "Pass --surface <handle> to move one, or run `cmux figma open <url>` first")
        #expect(run.gotos.isEmpty)
    }

    @Test("two Figma panes and an ordinary one: the refusal lists the two and not the third")
    func twoFigmaPanesRefuseWithoutTheOrdinaryOne() throws {
        let run = try drive(
            ["figma", "goto", "12-2"],
            reply: Self.gotoReply([Self.figmaPane(8), Self.ordinaryPane(9), Self.figmaPane(10)])
        )
        fails(run, with: "more than one Figma pane is open (surface:8, surface:10) — pass --surface <handle>")
        #expect(run.gotos.isEmpty)
    }

    @Test("goto with no browser pane showing a Figma file refuses and opens nothing")
    func gotoWithNoFigmaPaneRefuses() throws {
        let other = Pane(id: "id-5", ref: "surface:5", url: "https://example.com", showsAddressBar: true)
        let run = try drive(["figma", "goto", "12-2"], reply: Self.gotoReply([other]))
        fails(run, with: "no Figma pane is open — run `cmux figma open <url>` first")
        #expect(run.gotos.isEmpty)
        #expect(run.opens.isEmpty)
    }

    @Test("--surface on a pane that is not showing a Figma file fails with its handle")
    func surfaceOnANonFigmaPaneFails() throws {
        let other = Pane(id: "id-5", ref: "surface:5", url: "https://example.com", showsAddressBar: true)
        let run = try drive(["figma", "goto", "12-2", "--surface", "id-5"], reply: Self.gotoReply([other]))
        fails(run, with: "surface id-5 is not showing a Figma file")
        #expect(run.gotos.isEmpty)
    }

    // MARK: - Which pane open splits beside

    private static let callerSurface = "11111111-2222-3333-4444-555555555555"
    private static let callerWorkspace = "66666666-7777-8888-9999-000000000000"

    @Test("open splits beside the pane the command ran in: CMUX_SURFACE_ID goes out as surface_id, alone")
    func openSendsTheCallersSurface() throws {
        let run = try drive(
            ["figma", "open", Self.frameLink],
            environment: ["CMUX_SURFACE_ID": Self.callerSurface, "CMUX_WORKSPACE_ID": Self.callerWorkspace],
            reply: Self.openReply(createdSplit: true)
        )
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.opens.count == 1, "\(run.requests.map(\.method))")
        let params = try #require(run.opens.first?.params)
        // The environment's workspace may be an old one (a tab moved since the
        // shell started), so the app finds the workspace from the pane.
        #expect(params["surface_id"] as? String == Self.callerSurface, "\(params)")
        #expect(params["workspace_id"] == nil, "\(params)")
    }

    @Test("when the app cannot find that pane, open asks once more with the environment's workspace and no pane")
    func openFallsBackWhenThePaneIsGone() throws {
        let run = try drive(
            ["figma", "open", Self.frameLink],
            environment: ["CMUX_SURFACE_ID": Self.callerSurface, "CMUX_WORKSPACE_ID": Self.callerWorkspace],
            reply: Self.openReplyRejectingSurface(code: "not_found")
        )
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.stdout == "OK surface=surface:3 pane=pane:2 placement=split\n", "\(run.stdout)")
        #expect(run.opens.count == 2, "\(run.requests.map(\.method))")
        let second = try #require(run.opens.last?.params)
        #expect(second["surface_id"] == nil, "\(second)")
        #expect(second["workspace_id"] as? String == Self.callerWorkspace, "\(second)")
    }

    @Test("with no workspace in the environment, the second request names neither")
    func openFallsBackToNeither() throws {
        let run = try drive(
            ["figma", "open", Self.frameLink],
            environment: ["CMUX_SURFACE_ID": Self.callerSurface],
            reply: Self.openReplyRejectingSurface(code: "not_found")
        )
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.opens.count == 2, "\(run.requests.map(\.method))")
        let second = try #require(run.opens.last?.params)
        #expect(second["surface_id"] == nil && second["workspace_id"] == nil, "\(second)")
    }

    @Test("any other error from the app is reported as it is, with no second request")
    func openDoesNotRetryOtherErrors() throws {
        let run = try drive(
            ["figma", "open", Self.frameLink],
            environment: ["CMUX_SURFACE_ID": Self.callerSurface, "CMUX_WORKSPACE_ID": Self.callerWorkspace],
            reply: Self.openReplyRejectingSurface(code: "invalid_params")
        )
        #expect(run.status == 1, "\(run.stdout)")
        #expect(run.stderr.hasPrefix("Error: "), "\(run.stderr)")
        #expect(run.stderr.contains("Source surface not found"), "\(run.stderr)")
        #expect(run.opens.count == 1, "\(run.requests.map(\.method))")
    }

    @Test("open sends no surface_id when --workspace names the workspace")
    func openWithWorkspaceSendsNoSurface() throws {
        let run = try drive(
            ["figma", "open", Self.frameLink, "--workspace", Self.callerWorkspace],
            environment: ["CMUX_SURFACE_ID": Self.callerSurface],
            reply: Self.openReply(createdSplit: true)
        )
        #expect(run.status == 0, "\(run.stderr)")
        let params = try #require(run.opens.first?.params)
        #expect(params["surface_id"] == nil, "\(params)")
        #expect(params["workspace_id"] as? String == Self.callerWorkspace, "\(params)")
    }

    @Test("open sends no surface_id when the command did not run inside a cmux pane")
    func openOutsideCmuxSendsNoSurface() throws {
        let run = try drive(["figma", "open", Self.frameLink], reply: Self.openReply(createdSplit: true))
        #expect(run.status == 0, "\(run.stderr)")
        let params = try #require(run.opens.first?.params)
        #expect(params["surface_id"] == nil, "\(params)")
    }

    // MARK: - goto from a terminal that was moved

    /// The app side of `goto` when the list depends on how it was asked for: a
    /// request carrying a `surface_id` is answered with `byPane` (or the error
    /// `paneError` when one is given), a request without one with `byWorkspace`.
    private static func gotoReplyByAsk(
        byPane: [Pane],
        byWorkspace: [Pane],
        paneError: (code: String, message: String)? = nil
    ) -> @Sendable (String, String?) -> String {
        let forPane = gotoReply(byPane)
        let forWorkspace = gotoReply(byWorkspace)
        let all = gotoReply(byPane + byWorkspace)
        return { method, surfaceID in
            switch method {
            case "surface.list":
                if surfaceID != nil {
                    if let paneError { return failure(paneError.code, paneError.message) }
                    return forPane(method, surfaceID)
                }
                return forWorkspace(method, surfaceID)
            default:
                return all(method, surfaceID)
            }
        }
    }

    private func lists(_ run: Run) -> [StandInSocket.Request] {
        run.requests.filter { $0.method == "surface.list" }
    }

    @Test("goto lists by the pane the command ran in, not by the environment's workspace, which may be an old one")
    func gotoListsByTheCallersPane() throws {
        let run = try drive(
            ["figma", "goto", "12-2"],
            environment: ["CMUX_SURFACE_ID": Self.callerSurface, "CMUX_WORKSPACE_ID": Self.callerWorkspace],
            reply: Self.gotoReplyByAsk(byPane: [Self.figmaPane(8)], byWorkspace: [])
        )
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.stdout == "OK\n", "\(run.stdout)")
        #expect(lists(run).count == 1, "\(run.requests.map(\.method))")
        let params = try #require(lists(run).first?.params)
        #expect(params["surface_id"] as? String == Self.callerSurface, "\(params)")
        #expect(params["workspace_id"] == nil, "\(params)")
        #expect(run.gotos.first?.params["surface_id"] as? String == "id-8")
    }

    @Test("when the app cannot find that pane, goto lists once more by the environment's workspace and goes on from that")
    func gotoFallsBackWhenThePaneIsGone() throws {
        let run = try drive(
            ["figma", "goto", "12-2"],
            environment: ["CMUX_SURFACE_ID": Self.callerSurface, "CMUX_WORKSPACE_ID": Self.callerWorkspace],
            reply: Self.gotoReplyByAsk(
                byPane: [],
                byWorkspace: [Self.figmaPane(9)],
                paneError: ("not_found", "Source surface not found")
            )
        )
        #expect(run.status == 0, "\(run.stderr)")
        #expect(lists(run).count == 2, "\(run.requests.map(\.method))")
        let second = try #require(lists(run).last?.params)
        #expect(second["surface_id"] == nil, "\(second)")
        #expect(second["workspace_id"] as? String == Self.callerWorkspace, "\(second)")
        #expect(run.gotos.first?.params["surface_id"] as? String == "id-9")
    }

    @Test("any other error from the list is reported as it is, with no second list")
    func gotoDoesNotRetryOtherListErrors() throws {
        let run = try drive(
            ["figma", "goto", "12-2"],
            environment: ["CMUX_SURFACE_ID": Self.callerSurface, "CMUX_WORKSPACE_ID": Self.callerWorkspace],
            reply: Self.gotoReplyByAsk(
                byPane: [],
                byWorkspace: [Self.figmaPane(9)],
                paneError: ("invalid_params", "Source surface refused")
            )
        )
        #expect(run.status == 1, "\(run.stdout)")
        #expect(run.stderr.contains("Source surface refused"), "\(run.stderr)")
        #expect(lists(run).count == 1, "\(run.requests.map(\.method))")
        #expect(run.gotos.isEmpty, "\(run.requests.map(\.method))")
    }

    @Test("with no CMUX_SURFACE_ID, goto lists by the environment's workspace alone, as it always did")
    func gotoWithoutACallerListsByWorkspace() throws {
        let run = try drive(
            ["figma", "goto", "12-2"],
            environment: ["CMUX_WORKSPACE_ID": Self.callerWorkspace],
            reply: Self.gotoReply([Self.figmaPane(8)])
        )
        #expect(run.status == 0, "\(run.stderr)")
        #expect(lists(run).count == 1, "\(run.requests.map(\.method))")
        let params = try #require(lists(run).first?.params)
        #expect(params.count == 1 && params["workspace_id"] as? String == Self.callerWorkspace, "\(params)")
    }

    @Test("with neither variable, goto lists with no parameters at all")
    func gotoOutsideCmuxListsWithNoParameters() throws {
        let run = try drive(["figma", "goto", "12-2"], reply: Self.gotoReply([Self.figmaPane(8)]))
        #expect(run.status == 0, "\(run.stderr)")
        let params = try #require(lists(run).first?.params)
        #expect(params.isEmpty, "\(params)")
    }

    @Test("--surface goes straight to that pane and never lists")
    func gotoWithSurfaceNeverLists() throws {
        let run = try drive(
            ["figma", "goto", "12-2", "--surface", "id-8"],
            environment: ["CMUX_SURFACE_ID": Self.callerSurface, "CMUX_WORKSPACE_ID": Self.callerWorkspace],
            reply: Self.gotoReply([Self.ordinaryPane(8)])
        )
        #expect(run.status == 0, "\(run.stderr)")
        #expect(lists(run).isEmpty, "\(run.requests.map(\.method))")
    }

    // MARK: - cm-73.45: the caller goto names, and the note that names it

    private static let noteSession = "cm7345"
    private static let notePane = "p1"

    /// The folder herdr-agent keeps its notes in, under the test's own home.
    private static func noteFolder(_ home: URL) -> URL {
        home.appendingPathComponent(".local/state/herdr-agent/panes", isDirectory: true)
    }

    private static let herdrEnvironment = ["HERDR_SESSION": noteSession, "HERDR_PANE_ID": notePane]

    private static func writeNote(_ home: URL, surface: String, pid: Int32) throws {
        let folder = noteFolder(home)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let line = "\(surface)\t\(UUID().uuidString)\t\(pid)\n"
        try line.write(to: folder.appendingPathComponent("\(noteSession).\(notePane)"), atomically: true, encoding: .utf8)
    }

    /// A stand-in for herdr's attach client: a copy of `/bin/sleep` named `herdr-agent-attach`.
    private func withAttachProcess(_ body: (Process) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cm-73.45-attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let binary = folder.appendingPathComponent("herdr-agent-attach")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: binary)
        let child = Process()
        child.executableURL = binary
        child.arguments = ["60"]
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        try body(child)
    }

    @Test("goto sends the caller it listed by as caller_surface_id")
    func gotoSendsTheCaller() throws {
        let run = try drive(
            ["figma", "goto", "12-2"],
            environment: ["CMUX_SURFACE_ID": Self.callerSurface],
            reply: Self.gotoReplyByAsk(byPane: [Self.figmaPane(8)], byWorkspace: [])
        )
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.gotos.first?.params["caller_surface_id"] as? String == Self.callerSurface, "\(run.gotos.first?.params ?? [:])")
    }

    @Test("goto --surface still names the caller, and still lists nothing")
    func gotoWithSurfaceSendsTheCaller() throws {
        let run = try drive(
            ["figma", "goto", "12-2", "--surface", "id-8"],
            environment: ["CMUX_SURFACE_ID": Self.callerSurface],
            reply: Self.gotoReply([Self.ordinaryPane(8)])
        )
        #expect(run.status == 0, "\(run.stderr)")
        #expect(lists(run).isEmpty, "\(run.requests.map(\.method))")
        #expect(run.gotos.first?.params["caller_surface_id"] as? String == Self.callerSurface)
    }

    @Test("goto with no CMUX_SURFACE_ID sends no caller_surface_id")
    func gotoWithoutACallerSendsNone() throws {
        let run = try drive(["figma", "goto", "12-2"], reply: Self.gotoReply([Self.figmaPane(8)]))
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.gotos.first?.params["caller_surface_id"] == nil)
    }

    @Test("fit sends no caller_surface_id, whatever the environment holds")
    func fitSendsNoCaller() throws {
        let run = try drive(
            ["figma", "fit"],
            environment: ["CMUX_SURFACE_ID": Self.callerSurface],
            reply: Self.fitReply([Self.figmaPane(8, link: Self.readLink)])
        )
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.gotos.count == 1, "\(run.requests.map(\.method))")
        #expect(run.gotos.first?.params["purpose"] as? String == "fit")
        #expect(run.gotos.first?.params["caller_surface_id"] == nil)
    }

    @Test("goto --surface does not fail on a CMUX_SURFACE_ID that is no surface, as before: it drops it")
    func gotoWithSurfaceIgnoresABadCaller() throws {
        let run = try drive(
            ["figma", "goto", "12-2", "--surface", "id-8"],
            environment: ["CMUX_SURFACE_ID": "garbage"],
            reply: Self.gotoReply([Self.ordinaryPane(8)])
        )
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.stdout == "OK\n", "\(run.stdout)")
        #expect(run.gotos.first?.params["caller_surface_id"] == nil)
    }

    @Test("fit --surface does not fail on a CMUX_SURFACE_ID that is no surface")
    func fitWithSurfaceIgnoresABadCaller() throws {
        let run = try drive(
            ["figma", "fit", "--surface", "id-8"],
            environment: ["CMUX_SURFACE_ID": "garbage"],
            reply: Self.fitReply([Self.figmaPane(8, link: Self.readLink)])
        )
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.gotos.first?.params["caller_surface_id"] == nil)
    }

    @Test("goto without --surface fails on a CMUX_SURFACE_ID that is no surface, as it did before")
    func gotoStillFailsOnABadCaller() throws {
        let run = try drive(
            ["figma", "goto", "12-2"],
            environment: ["CMUX_SURFACE_ID": "garbage"],
            reply: Self.gotoReply([Self.figmaPane(8)])
        )
        #expect(run.status == 1, "\(run.stdout)")
        #expect(run.stderr.contains("Invalid surface handle: garbage"), "\(run.stderr)")
        #expect(run.gotos.isEmpty)
    }

    @Test("fit without --surface fails on a CMUX_SURFACE_ID that is no surface, as it did before")
    func fitStillFailsOnABadCaller() throws {
        let run = try drive(
            ["figma", "fit"],
            environment: ["CMUX_SURFACE_ID": "garbage"],
            reply: Self.fitReply([Self.figmaPane(8)])
        )
        #expect(run.status == 1, "\(run.stdout)")
        #expect(run.stderr.contains("Invalid surface handle: garbage"), "\(run.stderr)")
    }

    @Test("a FIFO planted at the note path does not hang the command: the note is ignored")
    func fifoAtTheNotePath() throws {
        let run = try drive(
            ["figma", "goto", "12-2"],
            environment: Self.herdrEnvironment.merging(["CMUX_SURFACE_ID": Self.callerSurface]) { $1 },
            prepareHome: { home in
                let folder = Self.noteFolder(home)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                #expect(mkfifo(folder.appendingPathComponent("\(Self.noteSession).\(Self.notePane)").path, 0o600) == 0)
            },
            reply: Self.gotoReplyByAsk(byPane: [Self.figmaPane(8)], byWorkspace: [])
        )
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.gotos.first?.params["caller_surface_id"] as? String == Self.callerSurface)
    }

    @Test("a note whose pid is a live herdr-agent-attach names the caller ahead of CMUX_SURFACE_ID")
    func liveNoteNamesTheCaller() throws {
        let noted = UUID().uuidString
        try withAttachProcess { child in
            let run = try drive(
                ["figma", "goto", "12-2"],
                environment: Self.herdrEnvironment.merging(["CMUX_SURFACE_ID": Self.callerSurface]) { $1 },
                prepareHome: { try Self.writeNote($0, surface: noted, pid: child.processIdentifier) },
                reply: Self.gotoReplyByAsk(byPane: [Self.figmaPane(8)], byWorkspace: [])
            )
            #expect(run.status == 0, "\(run.stderr)")
            #expect(lists(run).first?.params["surface_id"] as? String == noted, "\(lists(run).map(\.params))")
            #expect(run.gotos.first?.params["caller_surface_id"] as? String == noted)
        }
    }

    @Test("a note whose pid is not an attach is ignored: CMUX_SURFACE_ID names the caller")
    func staleNoteIsIgnored() throws {
        let run = try drive(
            ["figma", "goto", "12-2"],
            environment: Self.herdrEnvironment.merging(["CMUX_SURFACE_ID": Self.callerSurface]) { $1 },
            prepareHome: { try Self.writeNote($0, surface: UUID().uuidString, pid: getpid()) },
            reply: Self.gotoReplyByAsk(byPane: [Self.figmaPane(8)], byWorkspace: [])
        )
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.gotos.first?.params["caller_surface_id"] as? String == Self.callerSurface)
    }

    @Test("when the app does not know the note's surface, goto retries with CMUX_SURFACE_ID and names that")
    func unknownNotedSurfaceRetries() throws {
        let noted = UUID().uuidString
        let known = Self.gotoReplyByAsk(byPane: [Self.figmaPane(8)], byWorkspace: [])
        try withAttachProcess { child in
            let run = try drive(
                ["figma", "goto", "12-2"],
                environment: Self.herdrEnvironment.merging(["CMUX_SURFACE_ID": Self.callerSurface]) { $1 },
                prepareHome: { try Self.writeNote($0, surface: noted, pid: child.processIdentifier) },
                reply: { method, surfaceID in
                    if method == "surface.list", surfaceID == noted {
                        return Self.failure("not_found", "Source surface not found")
                    }
                    return known(method, surfaceID)
                }
            )
            #expect(run.status == 0, "\(run.stderr)")
            #expect(lists(run).compactMap { $0.params["surface_id"] as? String } == [noted, Self.callerSurface])
            #expect(run.gotos.first?.params["caller_surface_id"] as? String == Self.callerSurface)
        }
    }

    // MARK: - fit

    private static let readLink = "https://embed.figma.com/design/KEY/slug?node-id=1-2&embed-host=cmux"

    /// The app side of `fit`: `goto`'s pane discovery, plus what `fit` asks beyond it. The
    /// `surface.list` that carries a `surface_id` is the visibility question; the one without
    /// is the pane discovery, and `gotoReply` answers it.
    private static func fitReply(
        _ panes: [Pane],
        selectedInPane: Bool? = true,
        selectedWorkspace: String = "ws-1",
        focus: String = "ok"
    ) -> @Sendable (String, String?) -> String {
        let base = gotoReply(panes)
        return { method, surfaceID in
            switch method {
            case "surface.list" where surfaceID != nil:
                return ok([
                    "workspace_id": "ws-1",
                    "window_id": "win-1",
                    "surfaces": panes.map {
                        ["type": "browser", "id": $0.id, "ref": $0.ref,
                         "selected_in_pane": selectedInPane.map { $0 as Any } ?? NSNull()] as [String: Any]
                    }
                ])
            case "workspace.current":
                return ok(["window_id": "win-1", "workspace_id": selectedWorkspace])
            case "browser.eval":
                return ok(["surface_id": surfaceID ?? "", "value": focus])
            case "browser.press":
                let ref = panes.first { $0.id == surfaceID }?.ref ?? "surface:?"
                return ok(["surface_id": surfaceID ?? "", "surface_ref": ref])
            default:
                return base(method, surfaceID)
            }
        }
    }

    private func presses(_ run: Run) -> [StandInSocket.Request] { run.requests.filter { $0.method == "browser.press" } }
    private func evals(_ run: Run) -> [StandInSocket.Request] { run.requests.filter { $0.method == "browser.eval" } }

    /// Nothing that moves the page or types into it was sent.
    private func sentNothingToThePage(_ run: Run, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(presses(run).isEmpty, "\(run.requests.map(\.method))", sourceLocation: sourceLocation)
        #expect(run.gotos.isEmpty, "\(run.requests.map(\.method))", sourceLocation: sourceLocation)
    }

    @Test("fit in the editor sends one ! press to the pane, after asking what has focus, and no navigation")
    func fitEditorPressesOnce() throws {
        let run = try drive(["figma", "fit"], reply: Self.fitReply([Self.figmaPane(8)]))
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.stdout == "OK\n")
        #expect(run.stderr.isEmpty, "\(run.stderr)")
        #expect(presses(run).count == 1, "\(run.requests.map(\.method))")
        #expect(presses(run).first?.params["surface_id"] as? String == "id-8")
        #expect(presses(run).first?.params["key"] as? String == "!")
        #expect(run.gotos.isEmpty)
        let methods = run.requests.map(\.method)
        let ask = methods.firstIndex(of: "browser.eval")
        let press = methods.firstIndex(of: "browser.press")
        #expect(ask != nil && press != nil && ask! < press!, "the guard asks before the press: \(methods)")
        #expect(evals(run).first?.params["script"] as? String == FigmaFit.focusGuardScript)
    }

    @Test("fit under --json carries the surface and the way it went")
    func fitJSON() throws {
        let editor = try drive(["--json", "figma", "fit"], reply: Self.fitReply([Self.figmaPane(8)]))
        let editorJSON = try #require(jsonObject(editor.stdout), "\(editor.stdout)")
        #expect(editorJSON["mode"] as? String == "editor")
        #expect((editorJSON["surface"] as? String)?.isEmpty == false, "\(editorJSON)")
        let read = try drive(["--json", "figma", "fit"], reply: Self.fitReply([Self.figmaPane(8, link: Self.readLink)]))
        let readJSON = try #require(jsonObject(read.stdout), "\(read.stdout)")
        #expect(readJSON["mode"] as? String == "read")
        #expect((readJSON["surface"] as? String)?.isEmpty == false, "\(readJSON)")
    }

    @Test("fit in the read view loads the node it shows once, with no key and no question about focus")
    func fitReadNavigatesOnce() throws {
        let run = try drive(["figma", "fit"], reply: Self.fitReply([Self.figmaPane(8, link: Self.readLink)]))
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.stdout == "OK\n")
        #expect(run.gotos.count == 1, "\(run.requests.map(\.method))")
        #expect(run.gotos.first?.params["surface_id"] as? String == "id-8")
        // The shared app-side goto owns the preview's URL; fit preserves its current node.
        #expect(run.gotos.first?.params["node"] as? String == "1-2")
        #expect(run.gotos.first?.params["purpose"] as? String == "fit")
        #expect(presses(run).isEmpty && evals(run).isEmpty, "\(run.requests.map(\.method))")
        // A guard against a page writer coming back: nothing in the CLI writes one today.
        #expect(!run.pageInstalledInTestHome, "cm-73.39: the CLI writes no page; the app serves it")
    }

    @Test("fit with no Figma pane gives goto's refusal and sends nothing to a page")
    func fitWithNoPane() throws {
        let run = try drive(["figma", "fit"], reply: Self.fitReply([]))
        fails(run, with: "no Figma pane is open — run `cmux figma open <url>` first")
        sentNothingToThePage(run)
    }

    @Test("fit with two Figma panes and no --surface gives goto's refusal; with --surface only that pane is pressed")
    func fitWithTwoPanes() throws {
        let panes = [Self.figmaPane(7), Self.figmaPane(8)]
        let refused = try drive(["figma", "fit"], reply: Self.fitReply(panes))
        fails(refused, with: "more than one Figma pane is open (surface:7, surface:8) — pass --surface <handle>")
        sentNothingToThePage(refused)

        let chosen = try drive(["figma", "fit", "--surface", "id-8"], reply: Self.fitReply(panes))
        #expect(chosen.status == 0, "\(chosen.stderr)")
        #expect(presses(chosen).count == 1)
        #expect(presses(chosen).first?.params["surface_id"] as? String == "id-8")
        #expect(evals(chosen).allSatisfy { $0.params["surface_id"] as? String == "id-8" })
    }

    @Test("fit on an editor pane that is not showing is refused by name and sends nothing")
    func fitHiddenEditor() throws {
        let behindAnotherTab = try drive(["figma", "fit"], reply: Self.fitReply([Self.figmaPane(8)], selectedInPane: false))
        fails(behindAnotherTab, with: "surface surface:8 is not showing, so fit sent no key")
        sentNothingToThePage(behindAnotherTab)
        #expect(evals(behindAnotherTab).isEmpty)

        let otherWorkspace = try drive(["figma", "fit"], reply: Self.fitReply([Self.figmaPane(8)], selectedWorkspace: "ws-2"))
        fails(otherWorkspace, with: "surface surface:8 is not showing, so fit sent no key")
        sentNothingToThePage(otherWorkspace)
    }

    /// The app answers `browser.url.get` for an alias such as `tab:8` with the pane's own id, as `v2BrowserGetURL` does.
    private static func aliasReply(
        _ alias: String,
        for pane: Pane,
        selectedInPane: Bool?
    ) -> @Sendable (String, String?) -> String {
        let base = fitReply([pane], selectedInPane: selectedInPane)
        return { method, surfaceID in
            if method == "browser.url.get", surfaceID == alias {
                return ok(["surface_id": pane.id, "url": pane.url, "show_omnibar": false])
            }
            return base(method, surfaceID)
        }
    }

    @Test("fit --surface with an alias finds the pane's row, so a hidden pane is still refused")
    func fitHiddenEditorByAlias() throws {
        let run = try drive(
            ["figma", "fit", "--surface", "tab:8"],
            reply: Self.aliasReply("tab:8", for: Self.figmaPane(8), selectedInPane: false)
        )
        fails(run, with: "surface tab:8 is not showing, so fit sent no key")
        sentNothingToThePage(run)
    }

    @Test("fit on a read-view pane that is not showing still loads the page once")
    func fitHiddenReadNavigates() throws {
        let run = try drive(
            ["figma", "fit"],
            reply: Self.fitReply([Self.figmaPane(8, link: Self.readLink)], selectedInPane: false, selectedWorkspace: "ws-2")
        )
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.gotos.count == 1, "\(run.requests.map(\.method))")
        #expect(presses(run).isEmpty)
    }

    // cmux-rbf (#cm-73.44): the app answers `invalid_state` with `data.reason: notboard` when the preview shows
    // Figma's Log in page or an error, and the CLI says it in English. Any other failure keeps its own text.
    @Test("fit on a preview that shows no board gives the English refusal, from the app's notboard reason")
    func fitRefusesAPreviewThatShowsNoBoard() throws {
        let base = Self.fitReply([Self.figmaPane(8, link: Self.readLink)])
        let notBoard: @Sendable (String, String?) -> String = { method, surfaceID in
            guard method == "figma.goto" else { return base(method, surfaceID) }
            return Self.json(["id": NSNull(), "ok": false,
                              "error": ["code": "invalid_state", "message": "Browser operation failed", "data": ["reason": "notboard"]]])
        }
        let run = try drive(["figma", "fit"], reply: notBoard)
        fails(run, with: "the Figma pane shows Figma's Log in page or an error, not a board (surface surface:8), so fit moved nothing")
        #expect(run.gotos.count == 1 && presses(run).isEmpty, "\(run.requests.map(\.method))")

        let other: @Sendable (String, String?) -> String = { method, surfaceID in
            guard method == "figma.goto" else { return base(method, surfaceID) }
            return Self.json(["id": NSNull(), "ok": false,
                              "error": ["code": "invalid_state", "message": "Something else", "data": ["reason": "elsewise"]]])
        }
        let unrelated = try drive(["figma", "fit"], reply: other)
        #expect(unrelated.status == 1)
        #expect(!unrelated.stderr.contains("Log in page"), "only the notboard reason is turned into the refusal: \(unrelated.stderr)")
    }

    @Test("fit on a FigJam board or a slide deck is refused and sends nothing, in the editor and the read view")
    func fitRefusesBoardsAndDecks() throws {
        let message = "cmux figma fit works on Figma design files only: surface surface:8 shows a FigJam board or a slide deck"
        for link in [
            "https://www.figma.com/board/KEY/slug",
            "https://www.figma.com/slides/KEY/slug",
            "https://embed.figma.com/slides/KEY/slug?node-id=1-2&embed-host=cmux"
        ] {
            let run = try drive(["figma", "fit"], reply: Self.fitReply([Self.figmaPane(8, link: link)]))
            fails(run, with: message)
            sentNothingToThePage(run)
            #expect(evals(run).isEmpty, "\(link)")
        }
    }

    @Test("fit while a text field has focus is refused and no key is sent")
    func fitRefusesWhileTyping() throws {
        let run = try drive(["figma", "fit"], reply: Self.fitReply([Self.figmaPane(8)], focus: "typing"))
        fails(run, with: "a text field in the Figma pane has focus (surface surface:8), so fit sent no key")
        #expect(evals(run).count == 1)
        sentNothingToThePage(run)
    }

    @Test("fit takes no word and refuses what it does not know, sending nothing")
    func fitArgumentsAreRefused() throws {
        let cases: [(arguments: [String], message: String)] = [
            (["figma", "fit", "12-2"], "cmux figma fit does not take an extra argument: 12-2"),
            (["figma", "fit", "--workspace", "w"], "cmux figma fit does not support --workspace"),
            (["figma", "fit", "--surface"], "--surface requires a value")
        ]
        for testCase in cases {
            let run = try drive(testCase.arguments, reply: Self.fitReply([Self.figmaPane(8)]))
            fails(run, with: testCase.message)
            #expect(run.requests.isEmpty, "\(testCase.arguments): \(run.requests.map(\.method))")
        }
    }

    // MARK: - Failures and the help

    @Test("a missing argument or subcommand fails with the message the brief promises, and sends nothing")
    func missingArgumentsFail() throws {
        let cases: [(arguments: [String], message: String)] = [
            (["figma", "open"], "cmux figma open requires a Figma file URL"),
            (["figma", "goto"], "cmux figma goto requires a node id"),
            (["figma"], "cmux figma requires a subcommand: open, goto, fit, folder"),
            (["figma", "bogus"], "unknown cmux figma subcommand 'bogus' (expected open, goto, fit, folder)"),
            (["figma", "goto", "12-2", "--surface"], "--surface requires a value")
        ]
        for testCase in cases {
            let run = try drive(testCase.arguments)
            fails(run, with: testCase.message)
            #expect(run.requests.isEmpty, "\(testCase.arguments): \(run.requests.map(\.method))")
        }
    }

    @Test("goto with a blank frame id fails like a missing one, and sends nothing")
    func blankFrameIdFails() throws {
        for blank in ["", " ", "\t"] {
            let run = try drive(["figma", "goto", blank], reply: Self.gotoReply([Self.figmaPane(8)]))
            fails(run, with: "cmux figma goto requires a node id")
            #expect(run.requests.isEmpty, "\(blank.debugDescription): \(run.requests.map(\.method))")
        }
    }

    @Test("an option the verb does not take is refused by name, and nothing is sent")
    func unknownOptionsAreRefused() throws {
        let cases: [(arguments: [String], message: String)] = [
            (["figma", "goto", "12-2", "--workspace", "workspace:1"], "cmux figma goto does not support --workspace"),
            (["figma", "open", Self.frameLink, "--surface", "surface:8"], "cmux figma open does not support --surface"),
            (["figma", "goto", "12-2", "--surfce", "surface:8"], "cmux figma goto does not support --surfce"),
            (["figma", "goto", "12-2", "--surface=surface:8"], "cmux figma goto does not support --surface=surface:8"),
            (["figma", "goto", "12-2", "--surface", "a", "--surface", "b"], "cmux figma goto accepts --surface only once"),
            (["figma", "open", Self.frameLink, "--workspace", "a", "--workspace", "b"], "cmux figma open accepts --workspace only once")
        ]
        for testCase in cases {
            let run = try drive(testCase.arguments, reply: Self.gotoReply([Self.figmaPane(8)]))
            fails(run, with: testCase.message)
            #expect(run.requests.isEmpty, "\(testCase.arguments): \(run.requests.map(\.method))")
        }
    }

    @Test("a blank value for --workspace or --surface fails like a missing one, and sends nothing")
    func blankOptionValuesFail() throws {
        let cases: [(arguments: [String], message: String)] = [
            (["figma", "open", Self.frameLink, "--workspace", ""], "--workspace requires a value"),
            (["figma", "open", Self.frameLink, "--workspace", " "], "--workspace requires a value"),
            (["figma", "goto", "12-2", "--surface", ""], "--surface requires a value"),
            (["figma", "goto", "12-2", "--surface", "\t"], "--surface requires a value")
        ]
        for testCase in cases {
            let run = try drive(
                testCase.arguments,
                environment: ["CMUX_SURFACE_ID": Self.callerSurface, "CMUX_WORKSPACE_ID": Self.callerWorkspace],
                reply: Self.gotoReply([Self.figmaPane(8)])
            )
            fails(run, with: testCase.message)
            #expect(run.requests.isEmpty, "\(testCase.arguments): \(run.requests.map(\.method))")
        }
    }

    @Test("a word after the arguments is refused, and nothing is sent")
    func extraWordsAreRefused() throws {
        let cases: [(arguments: [String], message: String)] = [
            (["figma", "goto", "12-2", "12-3"], "cmux figma goto does not take an extra argument: 12-3"),
            (["figma", "open", Self.frameLink, "extra"], "cmux figma open does not take an extra argument: extra")
        ]
        for testCase in cases {
            let run = try drive(testCase.arguments, reply: Self.gotoReply([Self.figmaPane(8)]))
            fails(run, with: testCase.message)
            #expect(run.requests.isEmpty, "\(testCase.arguments): \(run.requests.map(\.method))")
        }
    }

    @Test("a link that does not parse fails with not a URL")
    func emptyLinkIsNotAURL() throws {
        let run = try drive(["figma", "open", ""])
        fails(run, with: "not a URL: ")
        #expect(run.requests.isEmpty)
    }

    @Test("a link that is not a Figma file is refused, and nothing is sent")
    func notAFigmaFileIsRefused() throws {
        for link in [
            "https://example.com",
            "http://www.figma.com/design/KEY/slug",
            "https://www.figma.com/design/../community",
            "https://www.figma.com/proto/KEY/slug",
            "https://www.figma.com:443/design/KEY/slug",
            "https://www.figma.com:9223372036854775808/design/KEY/slug?node-id=1-2",
            "https://www.figma.com:/design/KEY/slug",
            "https://user@www.figma.com/design/KEY/slug"
        ] {
            let run = try drive(["figma", "open", link])
            fails(run, with: "not a Figma file URL: \(link)")
            #expect(run.requests.isEmpty, "\(link): \(run.requests.map(\.method))")
        }
    }

    @Test("the help prints with no socket to connect to")
    func helpPrintsWithNoSocket() throws {
        let run = try drive(["figma", "--help"], listening: false)
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.stdout.hasPrefix("cmux figma\n\nUsage: cmux figma <open|goto|fit|folder>"), "\(run.stdout)")
        for phrase in ["cmux browser click", "node-id=0-1", "no address bar", "does not count", "--workspace", "12-2", "12:2"] {
            #expect(run.stdout.contains(phrase), "\(phrase)")
        }
        #expect(!run.stdout.contains("--theme"))
        #expect(run.stderr.isEmpty, "\(run.stderr)")
    }
}
