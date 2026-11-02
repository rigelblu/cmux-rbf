import Foundation
import Testing

// cmux-rbf #cm-126.3: `cmux agent-pane show`'s page rule and its messages.

/// The rules the command file only calls. The caller isn't here: `cm-73.45`'s
/// helper picks it, and `HerdrPaneNoteTests` and `FigmaCallerSurfaceTests` cover it.
@Suite("AgentPaneCLIRules")
struct AgentPaneCLIRulesTests {

    private func page(_ raw: String, exists: Set<String> = []) -> Result<URL, AgentPaneCLIRules.PageRefusal> {
        AgentPaneCLIRules.page(raw, cwd: "/work/dir", fileExists: { exists.contains($0) }, isDirectory: { _ in false })
    }

    @Test("a relative path is made absolute against the current directory")
    func relativePathIsMadeAbsolute() throws {
        let url = try page("pages/p1.html", exists: ["/work/dir/pages/p1.html"]).get()
        #expect(url == URL(fileURLWithPath: "/work/dir/pages/p1.html"))
        #expect(url.isFileURL)
    }

    @Test("a colon inside a relative filename is a file path")
    func colonInRelativeFilenameIsAPath() throws {
        let url = try page("report:v2.html", exists: ["/work/dir/report:v2.html"]).get()
        #expect(url == URL(fileURLWithPath: "/work/dir/report:v2.html"))
        #expect(page("missing:v2.html") == .failure(.noSuchFile("/work/dir/missing:v2.html")))
        #expect(page("custom://example.org/p") == .failure(.badPage("custom://example.org/p")))
    }

    @Test("view-source stays an unsupported address rather than a missing filename")
    func viewSourceHasAddressRefusal() {
        #expect(page("view-source:https://x") == .failure(.badPage("view-source:https://x")))
    }

    @Test("a missing host and port suggests http while existing colon filenames remain files")
    func missingHostPortSuggestsHTTP() throws {
        guard case .failure(let refusal) = page("localhost:8080") else {
            Issue.record("a missing host:port was accepted")
            return
        }
        #expect(AgentPaneCLIRules.message(for: refusal)
            == "not a file, file://, https:// or http:// page: localhost:8080; did you mean http://localhost:8080?")
        #expect(try page("localhost:8080", exists: ["/work/dir/localhost:8080"]).get()
            == URL(fileURLWithPath: "/work/dir/localhost:8080"))
        #expect(try page("report:v2.html", exists: ["/work/dir/report:v2.html"]).get()
            == URL(fileURLWithPath: "/work/dir/report:v2.html"))
        #expect(page("folder/name:8080") == .failure(.noSuchFile("/work/dir/folder/name:8080")))
    }

    @Test("a relative file URL is made absolute against the supplied current directory")
    func relativeFileURLIsMadeAbsolute() throws {
        let url = try page("file:pages/p1.html", exists: ["/work/dir/pages/p1.html"]).get()
        #expect(url.absoluteString == "file:///work/dir/pages/p1.html")
        #expect(url.isFileURL)
    }

    @Test("a tilde file URL is resolved exactly like its bare path before sending")
    func tildeFileURLIsMadeAbsolute() throws {
        var checked: [String] = []
        let url = try AgentPaneCLIRules.page(
            "file:~/cm126-tilde-rule.html", cwd: "/work/dir",
            fileExists: { checked.append($0); return true }, isDirectory: { _ in false }
        ).get()
        let bare = try AgentPaneCLIRules.page(
            "~/cm126-tilde-rule.html", cwd: "/work/dir", fileExists: { _ in true }, isDirectory: { _ in false }
        ).get()
        #expect(url.absoluteString.hasPrefix("file:///"))
        #expect(url == bare)
        #expect(checked == [url.path], "the checked path and sent URL differ")
    }

    @Test("a tilde directory file URL has the same not-file refusal as its bare path")
    func tildeDirectoryFileURLMatchesBarePath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let expected: Result<URL, AgentPaneCLIRules.PageRefusal> = .failure(.notFile(home))
        for raw in ["file:~/", "~/"] {
            let result = AgentPaneCLIRules.page(
                raw, cwd: "/work/dir", fileExists: { _ in true }, isDirectory: { _ in true }
            )
            #expect(result == expected, "\(raw) must name the account's home directory")
        }
    }

    @Test("a file URL refuses a remote host and accepts localhost")
    func fileURLHostMustBeLocal() throws {
        #expect(page("file://host/x.html", exists: ["/x.html"]) == .failure(.badPage("file://host/x.html")))
        #expect(try page("file://localhost/x.html", exists: ["/x.html"]).get().path == "/x.html")
    }

    @Test("a file URL collapses repeated leading slashes before sending")
    func fileURLSlashesAreCanonical() throws {
        let url = try page("file:////tmp/x.html?q=1#f", exists: ["/tmp/x.html"]).get()
        #expect(url.absoluteString == "file:///tmp/x.html?q=1#f")
    }

    @Test("a file URL with no path is refused as an address")
    func emptyFileURLHasAddressRefusal() {
        for raw in ["file:", "FILE:", "file://name", "file://localhost"] {
            #expect(page(raw) == .failure(.badPage(raw)))
        }
    }

    @Test("directories are not pages, while a regular file remains accepted")
    func directoryIsNotAFilePage() throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent("cm126-directory-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }
        for raw in [folder.path, folder.absoluteString, "."] {
            let result = AgentPaneCLIRules.page(raw, cwd: folder.path)
            guard case .failure(let refusal) = result else {
                Issue.record("a directory was accepted as a page: \(raw)")
                continue
            }
            #expect(AgentPaneCLIRules.message(for: refusal) == "not a file: \(folder.path)")
        }
        let file = folder.appendingPathComponent("page.html")
        try Data("<p>file</p>".utf8).write(to: file)
        #expect(try AgentPaneCLIRules.page(file.path, cwd: folder.path).get() == file)
    }

    @Test("an absolute path that exists is a file URL")
    func absolutePathIsAFileURL() throws {
        #expect(try page("/tmp/p1.html", exists: ["/tmp/p1.html"]).get() == URL(fileURLWithPath: "/tmp/p1.html"))
    }

    @Test("a missing file is refused with its absolute path")
    func missingFileIsRefused() {
        #expect(page("/nope.html") == .failure(.noSuchFile("/nope.html")))
        #expect(page("nope.html") == .failure(.noSuchFile("/work/dir/nope.html")))
        #expect(page("file:///nope.html") == .failure(.noSuchFile("/nope.html")))
    }

    @Test("file, https and http URLs are kept")
    func allowedSchemesAreKept() throws {
        #expect(try page("file:///tmp/p1.html", exists: ["/tmp/p1.html"]).get().absoluteString == "file:///tmp/p1.html")
        #expect(try page("https://example.org").get().absoluteString == "https://example.org")
        #expect(try page("HTTPS://example.org/a").get().absoluteString == "HTTPS://example.org/a")
        #expect(try page("http://localhost:8000/p1.html").get().absoluteString == "http://localhost:8000/p1.html")
    }

    @Test("any other scheme is refused, as is a web URL with no host")
    func otherSchemesAreRefused() {
        #expect(page("javascript:alert(1)") == .failure(.badPage("javascript:alert(1)")))
        #expect(page("data:text/html,x") == .failure(.badPage("data:text/html,x")))
        #expect(page("about:blank") == .failure(.badPage("about:blank")))
        #expect(page("cmux-figma://cmux/figma-embed.html") == .failure(.badPage("cmux-figma://cmux/figma-embed.html")))
        #expect(page("https:///nohost") == .failure(.badPage("https:///nohost")))
        #expect(page("   ") == .failure(.badPage("   ")))
    }

    @Test("a Figma editor address is refused")
    func figmaEditorIsRefused() {
        #expect(page("https://www.figma.com/design/KEY/x?node-id=1-2") == .failure(.figmaAddress))
        #expect(page("https://figma.com/file/KEY/x") == .failure(.figmaAddress))
    }

    @Test("cmux's legacy read-view page is refused")
    func readViewIsRefused() {
        let wrapper = FigmaPaneURL.wrapperFileURL()
        #expect(page(wrapper.absoluteString + "?embed=x", exists: [wrapper.path]) == .failure(.figmaAddress))
    }

    @Test("Figma's embed host in a page of the agent's own is not a Figma address")
    func embedHostIsAllowed() throws {
        #expect(try page("https://embed.figma.com/design/KEY/x?node-id=1-2").get().host == "embed.figma.com")
    }

    @Test("each page refusal has its message")
    func pageRefusalMessages() {
        #expect(AgentPaneCLIRules.message(for: .badPage("javascript:alert(1)"))
            == "not a file, file://, https:// or http:// page: javascript:alert(1)")
        #expect(AgentPaneCLIRules.message(for: .noSuchFile("/nope.html")) == "no such file: /nope.html")
        #expect(AgentPaneCLIRules.message(for: .figmaAddress)
            == "a Figma address goes to your Figma pane, not the Agent Pane: put the board in a page of your own "
                + "(Figma's embed in an iframe) and show that page")
        #expect(AgentPaneCLIRules.noCallerMessage
            == "cmux agent-pane show needs the agent's terminal: run it in a cmux terminal or pass --surface")
    }

    private func failure(
        _ code: String,
        reason: String? = nil,
        message: String = "diagnostic",
        surface: String? = nil,
        type: String? = nil,
        host: String? = nil,
        url: String? = nil,
        page: String? = nil
    ) -> String {
        AgentPaneCLIRules.message(for: .init(
            code: code, message: message, reason: reason, surface: surface, type: type, host: host, url: url, page: page
        ))
    }

    @Test("not_found names the last surface tried")
    func notFoundMessage() {
        #expect(failure("not_found", surface: "surface:4") == "that terminal is gone: surface:4")
    }

    @Test("not_terminal names the surface and its type")
    func notTerminalMessage() {
        #expect(failure("invalid_params", reason: "not_terminal", surface: "surface:2", type: "browser")
            == "the Agent Pane belongs to a terminal, and surface:2 is a browser")
    }

    @Test("in_dock, browser_off and figma_address have their messages")
    func reasonMessages() {
        #expect(failure("unsupported", reason: "in_dock")
            == "the Agent Pane opens beside a terminal in a workspace, not in the Dock")
        #expect(failure("unavailable", reason: "browser_off")
            == "cmux's browser is off in Settings, so the Agent Pane can't open")
        #expect(failure("invalid_params", reason: "figma_address") == AgentPaneCLIRules.figmaAddressMessage)
        #expect(failure("invalid_params", reason: "bad_scheme", page: "about:blank")
            == "not a file, file://, https:// or http:// page: about:blank")
    }

    @Test("insecure_http names the host")
    func insecureHTTPMessage() {
        #expect(failure("invalid_params", reason: "insecure_http", host: "example.org")
            == "http:// opens only for localhost or a host on cmux's insecure-HTTP list (Settings): example.org. "
                + "Use https:// or a local file")
    }

    @Test("browser_url_blocked passes the app's own message through, after the URL")
    func urlBlockedMessage() {
        #expect(failure("browser_url_blocked", message: "Blocked by the embedded-browser URL policy", url: "https://example.com/")
            == "the embedded browser's URL policy blocks https://example.com/: Blocked by the embedded-browser URL policy")
    }

    @Test("internal_error carries the diagnostic, and an unknown code falls back to the socket's text")
    func internalAndUnknownMessages() {
        #expect(failure("internal_error", message: "split failed")
            == "the Agent Pane couldn't open, and nothing was changed: split failed")
        #expect(failure("invalid_params", message: "Missing or invalid url") == "invalid_params: Missing or invalid url")
    }
}
