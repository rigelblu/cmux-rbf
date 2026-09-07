import Darwin
import Foundation
import Testing

private final class FigmaCLIBundleToken {}

/// What `cmux figma open` and `goto` print, and which pane `goto` moves, read
/// from the real CLI binary talking to a stand-in socket.
///
/// **The child sees only the environment built here.** `HOME` and
/// `CFFIXED_USER_HOME` both point at a folder of the test's own: `HOME` alone
/// does not move the home folder Foundation reports, and the CLI writes its
/// page under that folder. Nothing here reads Tom's `~/.config/cmux/cmux.json`
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
            case "browser.navigate":
                return ok(["surface_id": surfaceID ?? "", "surface_ref": "surface:moved"])
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

    private static func openReply(createdSplit: Bool) -> @Sendable (String, String?) -> String {
        { method, surfaceID in
            guard method == "browser.open_split" else { return unexpected(method, surfaceID) }
            return ok([
                "surface_id": "new-surface", "surface_ref": "surface:3",
                "pane_id": "new-pane", "pane_ref": "pane:2",
                "created_split": createdSplit
            ])
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
        /// Whether the read view's page landed under the test's own home folder.
        let pageInstalledInTestHome: Bool
        /// The test's own home folder, as the child was told it.
        let home: String
        /// What that file holds after the command, if it exists.
        let pageContents: String?

        var navigates: [StandInSocket.Request] { requests.filter { $0.method == "browser.navigate" } }
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

    /// The page already on disk in the test's home when the command starts.
    private enum PageSeed {
        case none
        /// An old build's page.
        case stale
        /// An old build's page, in a folder the command may not write to.
        case staleInReadOnlyFolder
    }

    private static let stalePage = "<!doctype html><title>an old build</title>"

    /// Runs `cmux <arguments>` against a stand-in socket that answers through `reply`.
    /// With `listening` false the socket path is set and nothing listens on it.
    private func drive(
        _ arguments: [String],
        listening: Bool = true,
        environment extraEnvironment: [String: String] = [:],
        page seed: PageSeed = .none,
        reply: @escaping @Sendable (String, String?) -> String = FigmaCLIOutputTests.unexpected
    ) throws -> Run {
        let fileManager = FileManager.default
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        let home = fileManager.temporaryDirectory.appendingPathComponent("cmux-figma-cli-\(id)", isDirectory: true)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        let socketPath = "/tmp/cmux-fig-\(id).sock"
        let pageFolder = home.appendingPathComponent("Library/Application Support/cmux", isDirectory: true)
        let page = pageFolder.appendingPathComponent("figma-embed.html")
        defer {
            // The folder may have been made read-only; the temp home cannot be removed until it is not.
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pageFolder.path)
            try? fileManager.removeItem(at: home)
            unlink(socketPath)
        }
        if seed != .none {
            try fileManager.createDirectory(at: pageFolder, withIntermediateDirectories: true)
            try Self.stalePage.write(to: page, atomically: true, encoding: .utf8)
        }
        if seed == .staleInReadOnlyFolder {
            try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: pageFolder.path)
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
            home: home.path,
            pageContents: try? String(contentsOf: page, encoding: .utf8)
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

    @Test("open asks for a pane with no address bar, loading cmux's page for a frame, installed in the home it was given")
    func openAsksForAPaneWithNoAddressBar() throws {
        let run = try drive(["figma", "open", Self.frameLink], reply: Self.openReply(createdSplit: true))
        let params = try #require(run.opens.first?.params)
        #expect(run.opens.count == 1)
        #expect(params["show_omnibar"] as? Bool == false)
        let address = try #require(params["url"] as? String)
        #expect(address.hasPrefix("file://"), "\(address)")
        #expect(address.contains("figma-embed.html?embed="), "\(address)")
        let embedded = URLComponents(string: address)?.queryItems?.first { $0.name == "embed" }?.value ?? ""
        #expect(embedded.hasPrefix("https://embed.figma.com/design/KEY/slug?"), "\(embedded)")
        #expect(embedded.contains("node-id=12-2"), "\(embedded)")
        #expect(run.pageInstalledInTestHome, "the page was not written under the test's own home")
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
        #expect(jsonObject(run.stdout) != nil, "\(run.stdout.debugDescription)")
    }

    @Test("goto moves the Figma pane and leaves an ordinary pane on a Figma file alone")
    func gotoMovesTheFigmaPane() throws {
        let panes = [
            Self.ordinaryPane(7, link: "https://www.figma.com/design/OTHER/other"),
            Self.figmaPane(8)
        ]
        let run = try drive(["figma", "goto", "12-2"], reply: Self.gotoReply(panes))
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.navigates.count == 1, "\(run.requests.map(\.method))")
        #expect(run.navigates.first?.params["surface_id"] as? String == "id-8")
        let address = run.navigates.first?.params["url"] as? String ?? ""
        #expect(address.contains("KEY") && !address.contains("OTHER"), "\(address)")
    }

    @Test("goto with only an ordinary pane on a Figma file refuses, moves nothing and names that pane")
    func gotoRefusesAnOrdinaryPaneAndNamesIt() throws {
        let run = try drive(["figma", "goto", "12-2"], reply: Self.gotoReply([Self.ordinaryPane(8)]))
        fails(run, with: "no Figma pane is open — browser panes showing a Figma file: surface:8. "
            + "Pass --surface <handle> to move one, or run `cmux figma open <url>` first")
        #expect(run.navigates.isEmpty)
    }

    @Test("a reply with no show_omnibar counts as an ordinary pane")
    func noShowOmnibarCountsAsOrdinary() throws {
        let pane = Pane(id: "id-8", ref: "surface:8", url: Self.editorLink, showsAddressBar: nil)
        let run = try drive(["figma", "goto", "12-2"], reply: Self.gotoReply([pane]))
        fails(run, with: "no Figma pane is open — browser panes showing a Figma file: surface:8. "
            + "Pass --surface <handle> to move one, or run `cmux figma open <url>` first")
        #expect(run.navigates.isEmpty)
    }

    @Test("--surface moves an ordinary pane that shows a Figma file")
    func surfaceMovesAnOrdinaryPane() throws {
        let run = try drive(
            ["figma", "goto", "12-2", "--surface", "id-8"],
            reply: Self.gotoReply([Self.ordinaryPane(8)])
        )
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.stdout == "OK\n")
        #expect(run.navigates.first?.params["surface_id"] as? String == "id-8")
    }

    @Test("two ordinary panes on a Figma file are both named, separated by a comma")
    func twoOrdinaryPanesAreBothNamed() throws {
        let run = try drive(
            ["figma", "goto", "12-2"],
            reply: Self.gotoReply([Self.ordinaryPane(8), Self.ordinaryPane(10)])
        )
        fails(run, with: "no Figma pane is open — browser panes showing a Figma file: surface:8, surface:10. "
            + "Pass --surface <handle> to move one, or run `cmux figma open <url>` first")
        #expect(run.navigates.isEmpty)
    }

    @Test("two Figma panes and an ordinary one: the refusal lists the two and not the third")
    func twoFigmaPanesRefuseWithoutTheOrdinaryOne() throws {
        let run = try drive(
            ["figma", "goto", "12-2"],
            reply: Self.gotoReply([Self.figmaPane(8), Self.ordinaryPane(9), Self.figmaPane(10)])
        )
        fails(run, with: "more than one Figma pane is open (surface:8, surface:10) — pass --surface <handle>")
        #expect(run.navigates.isEmpty)
    }

    @Test("goto with no browser pane showing a Figma file refuses and opens nothing")
    func gotoWithNoFigmaPaneRefuses() throws {
        let other = Pane(id: "id-5", ref: "surface:5", url: "https://example.com", showsAddressBar: true)
        let run = try drive(["figma", "goto", "12-2"], reply: Self.gotoReply([other]))
        fails(run, with: "no Figma pane is open — run `cmux figma open <url>` first")
        #expect(run.navigates.isEmpty)
        #expect(run.opens.isEmpty)
    }

    @Test("--surface on a pane that is not showing a Figma file fails with its handle")
    func surfaceOnANonFigmaPaneFails() throws {
        let other = Pane(id: "id-5", ref: "surface:5", url: "https://example.com", showsAddressBar: true)
        let run = try drive(["figma", "goto", "12-2", "--surface", "id-5"], reply: Self.gotoReply([other]))
        fails(run, with: "surface id-5 is not showing a Figma file")
        #expect(run.navigates.isEmpty)
    }

    // MARK: - The page on disk

    @Test("every open puts this build's page on disk, the editor branch included")
    func openInstallsThePage() throws {
        for link in [Self.editorLink, Self.frameLink] {
            let run = try drive(["figma", "open", link], page: .stale, reply: Self.openReply(createdSplit: true))
            #expect(run.status == 0, "\(link): \(run.stderr)")
            #expect(run.pageContents == FigmaWrapperPage.html, "\(link): \(run.pageContents ?? "no file")")
        }
    }

    @Test("every goto puts this build's page on disk")
    func gotoInstallsThePage() throws {
        let run = try drive(["figma", "goto", "12-2"], page: .stale, reply: Self.gotoReply([Self.figmaPane(8)]))
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.pageContents == FigmaWrapperPage.html, "\(run.pageContents ?? "no file")")
    }

    @Test("a whole-file open still works when the page cannot be written, because nothing there loads it")
    func editorOpenSurvivesAnUnwritablePage() throws {
        let run = try drive(
            ["figma", "open", Self.editorLink],
            page: .staleInReadOnlyFolder,
            reply: Self.openReply(createdSplit: true)
        )
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.stdout == "OK surface=surface:3 pane=pane:2 placement=split\n")
        #expect(run.opens.count == 1)
        #expect(run.pageContents == Self.stalePage, "the folder was meant to stay unwritten")
    }

    @Test("a frame open fails and sends nothing when the page cannot be written")
    func frameOpenFailsOnAnUnwritablePage() throws {
        let run = try drive(
            ["figma", "open", Self.frameLink],
            page: .staleInReadOnlyFolder,
            reply: Self.openReply(createdSplit: true)
        )
        expectPageWriteFailure(run)
        #expect(run.requests.isEmpty, "\(run.requests.map(\.method))")
    }

    @Test("goto fails and moves nothing when the page cannot be written")
    func gotoFailsOnAnUnwritablePage() throws {
        let run = try drive(
            ["figma", "goto", "12-2"],
            page: .staleInReadOnlyFolder,
            reply: Self.gotoReply([Self.figmaPane(8)])
        )
        expectPageWriteFailure(run)
        #expect(run.navigates.isEmpty, "\(run.requests.map(\.method))")
    }

    /// One readable line that names the page and says the read view needs it,
    /// with Foundation's short description after it, not its whole error.
    private func expectPageWriteFailure(_ run: Run, sourceLocation: SourceLocation = #_sourceLocation) {
        let prefix = "Error: the read view cannot open without its page "
            + "\(run.home)/Library/Application Support/cmux/figma-embed.html, which cannot be written: "
        #expect(run.status == 1, "\(run.stderr)", sourceLocation: sourceLocation)
        #expect(run.stderr.hasPrefix(prefix), "\(run.stderr)", sourceLocation: sourceLocation)
        #expect(run.stderr.dropLast().contains("\n") == false, "\(run.stderr)", sourceLocation: sourceLocation)
        #expect(!run.stderr.contains("Error Domain"), "\(run.stderr)", sourceLocation: sourceLocation)
        #expect(run.stdout.isEmpty, "\(run.stdout)", sourceLocation: sourceLocation)
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
        #expect(run.navigates.first?.params["surface_id"] as? String == "id-8")
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
        #expect(run.navigates.first?.params["surface_id"] as? String == "id-9")
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
        #expect(run.navigates.isEmpty, "\(run.requests.map(\.method))")
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

    // MARK: - Failures and the help

    @Test("a missing argument or subcommand fails with the message the brief promises, and sends nothing")
    func missingArgumentsFail() throws {
        let cases: [(arguments: [String], message: String)] = [
            (["figma", "open"], "cmux figma open requires a Figma file URL"),
            (["figma", "goto"], "cmux figma goto requires a node id"),
            (["figma"], "cmux figma requires a subcommand: open, goto"),
            (["figma", "bogus"], "unknown cmux figma subcommand 'bogus' (expected open, goto)"),
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
        #expect(run.stdout.hasPrefix("cmux figma\n\nUsage: cmux figma <open|goto>"), "\(run.stdout)")
        for phrase in ["cmux browser click", "node-id=0-1", "no address bar", "does not count", "--workspace", "12-2", "12:2"] {
            #expect(run.stdout.contains(phrase), "\(phrase)")
        }
        #expect(!run.stdout.contains("--theme"))
        #expect(run.stderr.isEmpty, "\(run.stderr)")
    }
}
