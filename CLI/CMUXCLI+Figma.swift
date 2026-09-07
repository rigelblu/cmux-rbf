import Foundation

extension CMUXCLI {

    /// One copy of the subcommand help, because `cmux help <topic>` prints the
    /// general usage and returns, so the topic text is only ever reached
    /// through `cmux figma --help` — and a second copy would be the one nobody
    /// updates.
    var figmaUsage: String {
        """
        Usage: cmux figma <open|goto> [args] [--theme light|dark]

        Open a Figma design as a chrome-free pane and steer it.

        Subcommands:
          open <file-url>   Open the pane. With no node in the URL this is Figma's
                            editor; with a node it is a framed, read-only embed.
          goto <node-id>    Point the open Figma pane at a node. Accepts 12-2 or 12:2.
                            --surface <handle> when more than one Figma pane is open.
        """
    }

    /// `cmux figma open <url>` and `cmux figma goto <node>`.
    ///
    /// **Why a verb rather than a flag on `browser`.** The agent calling this
    /// should not have to know that a Figma pane is a browser pane, which host
    /// the embed lives on, or which of two surfaces a node id selects. cmux
    /// builds the URL — reversing that later means the agent has already
    /// learned the wrong habit and the corpus of transcripts teaches it.
    func runFigmaCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        var args = commandArgs
        guard !args.isEmpty else {
            throw CLIError(message: "cmux figma requires a subcommand: open, goto")
        }
        let subcommand = args.removeFirst().lowercased()
        if ["help", "--help", "-h"].contains(subcommand) {
            print(figmaUsage)
            return
        }

        let theme = try figmaThemeOption(&args)
        let surfaceOverride = try figmaStringOption(&args, named: "--surface")
        let workspaceOverride = try figmaStringOption(&args, named: "--workspace")

        switch subcommand {
        case "open":
            try runFigmaOpen(
                args: args,
                theme: theme,
                workspaceOverride: workspaceOverride,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat
            )
        case "goto":
            try runFigmaGoto(
                args: args,
                theme: theme,
                surfaceOverride: surfaceOverride,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat
            )
        default:
            throw CLIError(message: "unknown cmux figma subcommand '\(subcommand)' (expected open, goto)")
        }
    }

    // MARK: - open

    private func runFigmaOpen(
        args: [String],
        theme: FigmaPaneURL.Theme,
        workspaceOverride: String?,
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        guard let raw = args.first(where: { !$0.hasPrefix("--") }) else {
            throw CLIError(message: "cmux figma open requires a Figma file URL")
        }
        guard let pasted = URL(string: raw) else {
            throw CLIError(message: "not a URL: \(raw)")
        }

        let destination = try figmaDestination(for: pasted, node: nil, theme: theme)

        var params: [String: Any] = [
            "url": destination.url.absoluteString,
            "focus": false,
            // The two flags that make the pane chrome-free. Nothing
            // user-facing reaches them today; `cm-73.4` exposes them generally.
            "show_omnibar": false,
            "transparent_background": true
        ]
        if let workspace = try figmaWorkspaceHandle(explicit: workspaceOverride, client: client) {
            params["workspace_id"] = workspace
        }

        let payload = try client.sendV2(method: "browser.open_split", params: params)
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        // The house line `browser open-split` already prints, so automation
        // that already parses one parses the other.
        let surfaceText = formatHandle(payload, kind: "surface", idFormat: idFormat) ?? "unknown"
        let paneText = formatHandle(payload, kind: "pane", idFormat: idFormat) ?? "unknown"
        let placement = ((payload["created_split"] as? Bool) == true) ? "split" : "reuse"
        print("OK surface=\(surfaceText) pane=\(paneText) placement=\(placement)")
    }

    // MARK: - goto

    private func runFigmaGoto(
        args: [String],
        theme: FigmaPaneURL.Theme,
        surfaceOverride: String?,
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        guard let node = args.first(where: { !$0.hasPrefix("--") }) else {
            throw CLIError(message: "cmux figma goto requires a node id")
        }

        let (surfaceID, document) = try resolveBoundFigmaPane(
            surfaceOverride: surfaceOverride,
            client: client
        )
        let destination = try figmaDestination(for: document, node: node, theme: theme)

        let payload = try client.sendV2(
            method: "browser.navigate",
            params: ["surface_id": surfaceID, "url": destination.url.absoluteString]
        )
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        // Deliberately just `OK`: an agent calls this mid-sentence in a loop,
        // and anything it prints lands in the transcript the user is reading.
        print("OK")
    }

    /// Find the pane a `goto` should steer.
    ///
    /// **The pane's URL is the binding** — no new persisted field — so this
    /// reads it back rather than consulting a store. It has to understand both
    /// surfaces: an editor URL names the document directly, while a wrapper URL
    /// carries it in the `embed` query parameter.
    private func resolveBoundFigmaPane(
        surfaceOverride: String?,
        client: SocketClient
    ) throws -> (surfaceID: String, document: URL) {
        func document(ofSurface id: String) -> URL? {
            guard let payload = try? client.sendV2(
                method: "browser.url.get",
                params: ["surface_id": id]
            ) else { return nil }
            guard let raw = payload["url"] as? String, let url = URL(string: raw) else { return nil }
            return FigmaPaneURL.documentURL(fromPaneURL: url)
        }

        if let surfaceOverride {
            guard let document = document(ofSurface: surfaceOverride) else {
                throw CLIError(message: "surface \(surfaceOverride) is not showing a Figma file")
            }
            return (surfaceOverride, document)
        }

        var params: [String: Any] = [:]
        if let workspace = try figmaWorkspaceHandle(explicit: nil, client: client) {
            params["workspace_id"] = workspace
        }
        let listed = try client.sendV2(method: "surface.list", params: params)
        let surfaces = listed["surfaces"] as? [[String: Any]] ?? []

        var matches: [(id: String, handle: String, document: URL)] = []
        for surface in surfaces where (surface["type"] as? String) == "browser" {
            guard let id = surface["id"] as? String ?? (surface["surface_id"] as? String) else { continue }
            guard let document = document(ofSurface: id) else { continue }
            // Print what the house prints — `surface:8`, not a UUID. The
            // message tells the caller to pass `--surface <handle>`, so it
            // has to hand back something they can actually paste.
            let handle = (surface["ref"] as? String) ?? id
            matches.append((id, handle, document))
        }

        switch matches.count {
        case 0:
            throw CLIError(message: "no Figma pane is open — run `cmux figma open <url>` first")
        case 1:
            return (matches[0].id, matches[0].document)
        default:
            let handles = matches.map(\.handle).joined(separator: ", ")
            throw CLIError(
                message: "more than one Figma pane is open (\(handles)) — pass --surface <handle>"
            )
        }
    }

    // MARK: - Shared

    /// Resolve a workspace the way the rest of the CLI does.
    ///
    /// **Reading `CMUX_WORKSPACE_ID` straight out of the environment was the
    /// defect.** The default itself is right — `browser open-split` documents
    /// it — but skipping ``normalizeWorkspaceHandle`` means a stale id (driving
    /// a tagged app from another app's terminal, say) dies with a raw
    /// `not_found: Workspace not found` from the socket instead of anything a
    /// caller can act on.
    private func figmaWorkspaceHandle(explicit: String?, client: SocketClient) throws -> String? {
        let raw = explicit ?? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
        guard let raw, !raw.isEmpty else { return nil }
        return try normalizeWorkspaceHandle(raw, client: client, allowCurrent: true)
    }

    /// One destination call serves both verbs, and installing the wrapper is
    /// part of it — an embed URL that names a page which is not on disk would
    /// render an empty pane with nothing to explain it.
    private func figmaDestination(
        for pasted: URL,
        node: String?,
        theme: FigmaPaneURL.Theme
    ) throws -> FigmaPaneURL.Destination {
        let destination: FigmaPaneURL.Destination
        do {
            destination = try FigmaPaneURL.destination(for: pasted, node: node, theme: theme)
        } catch FigmaPaneURL.Failure.notAFigmaURL(let raw) {
            throw CLIError(message: "not a Figma file URL: \(raw)")
        }
        if case .embed = destination {
            try FigmaWrapperPage.install()
        }
        return destination
    }

    /// `--theme light|dark`.
    ///
    /// **Explicit, and defaulting to dark, because cmux cannot answer this
    /// itself yet.** The design called for cmux's own resolved appearance and
    /// said it "costs nothing, because `cmux diff` already does it CLI-side" —
    /// it does not: `cmux diff` builds a light *and* a dark theme and lets the
    /// viewer choose, so there is no resolved value on this side and no socket
    /// method reporting one. Never `system`, which follows macOS rather than
    /// cmux, so the flag still satisfies the decision it implements.
    private func figmaThemeOption(_ args: inout [String]) throws -> FigmaPaneURL.Theme {
        guard let raw = try figmaStringOption(&args, named: "--theme") else { return .dark }
        guard let theme = FigmaPaneURL.Theme(rawValue: raw.lowercased()) else {
            throw CLIError(message: "--theme takes light or dark, got '\(raw)'")
        }
        return theme
    }

    private func figmaStringOption(_ args: inout [String], named name: String) throws -> String? {
        guard let index = args.firstIndex(of: name) else { return nil }
        guard index + 1 < args.count else {
            throw CLIError(message: "\(name) requires a value")
        }
        let value = args[index + 1]
        args.removeSubrange(index...(index + 1))
        return value
    }
}
