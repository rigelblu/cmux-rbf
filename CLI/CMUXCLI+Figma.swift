import CmuxSettings
import Foundation

extension CMUXCLI {

    /// One copy of the subcommand help, because `cmux help <topic>` prints the
    /// general usage and returns, so the topic text is only ever reached
    /// through `cmux figma --help` — and a second copy would be the one nobody
    /// updates.
    var figmaUsage: String { FigmaUsage.text }

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
            throw CLIError(message: "cmux figma requires a subcommand: open, goto, folder")
        }
        let subcommand = args.removeFirst().lowercased()
        if ["help", "--help", "-h"].contains(subcommand) {
            print(figmaUsage)
            return
        }

        guard subcommand == "open" || subcommand == "goto" else {
            throw CLIError(message: "unknown cmux figma subcommand '\(subcommand)' (expected open, goto, folder)")
        }
        let parsed: FigmaArguments.Parsed
        do {
            parsed = try FigmaArguments.parse(verb: subcommand, args: args)
        } catch let failure as FigmaArguments.Failure {
            throw CLIError(message: failure.message)
        }

        if subcommand == "open" {
            try runFigmaOpen(
                link: parsed.word,
                workspaceOverride: parsed.option,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat
            )
        } else {
            try runFigmaGoto(
                node: parsed.word,
                surfaceOverride: parsed.option,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat
            )
        }
    }

    // MARK: - folder

    /// `cmux figma folder`, `folder set <folder-url>` and `folder clear`.
    ///
    /// **No socket and no app.** The folder is one string in `cmux.json`, so
    /// these read and write the file from this process, as
    /// `cmux window default-display` does, and `run()` dispatches them before it
    /// resolves a socket. `open` and `goto` still need the app.
    ///
    /// **An agent never reads a broken setting as "not set".** The read goes
    /// through ``JSONConfigStore/strictRoot()``, which says why a file could not
    /// be read, and a stored value that is not text, or a link that no longer
    /// passes, is exit 1 with the fix named. `set` writes over a broken value at
    /// the key, which is what the `Fix it:` line promises, and stops on a file
    /// that is not valid JSON, because the strict read runs before any write.
    func runFigmaFolderCommand(commandArgs: [String], jsonOutput: Bool) async throws {
        let action: FigmaFolderArguments.Action
        do {
            action = try FigmaFolderArguments.parse(commandArgs)
        } catch let failure as FigmaFolderArguments.Failure {
            throw CLIError(message: failure.message)
        }

        let store = JSONConfigStore(fileURL: CmuxConfigLocation().userConfigFile)
        let key = SettingCatalog().figma.defaultFolder
        let path = store.fileURL.path

        let root: [String: Any]
        do {
            root = try store.strictRoot()
        } catch JSONConfigStoreStrictReadError.notValidJSON {
            throw CLIError(message: "could not read \(path): it is not valid JSON.")
        } catch JSONConfigStoreStrictReadError.unreadable(let reason) {
            throw CLIError(message: "could not read \(path): \(reason)")
        }

        func folderJSON(_ link: FigmaFolderLink?) -> String {
            guard let link else { return jsonString(["default_folder": NSNull()]) }
            return jsonString([
                "default_folder": [
                    "project_id": link.projectId,
                    "plan_key": link.planKey,
                    "url": link.url
                ]
            ])
        }

        let folder = FigmaDefaultFolder(root: root)

        switch action {
        case .read:
            switch folder.state {
            case .notSet:
                print(jsonOutput ? folderJSON(nil) : FigmaFolderText.notSet)
            case .set(let link):
                print(jsonOutput
                    ? folderJSON(link)
                    : FigmaFolderText.read(projectId: link.projectId, planKey: link.planKey, url: link.url))
            case .refused(let refusal):
                throw CLIError(message: FigmaFolderText.unusable(reason: FigmaFolderText.reason(refusal)))
            case .notText:
                throw CLIError(message: FigmaFolderText.unusable(reason: "it is not text."))
            }

        case .set(let raw):
            let link: FigmaFolderLink
            switch FigmaFolderLink.check(raw) {
            case .success(let checked): link = checked
            case .failure(let refusal): throw CLIError(message: FigmaFolderText.refusedSet(refusal))
            }
            // The value already stored is not written again: the file keeps its
            // bytes and its modified time.
            let stored = key.path.lookup(in: root) as? String
            if stored != link.url {
                do {
                    try await store.set(link.url, for: key)
                } catch {
                    throw CLIError(message: "could not save to \(path): \(error.localizedDescription)")
                }
            }
            print(jsonOutput
                ? folderJSON(link)
                : FigmaFolderText.set(projectId: link.projectId, planKey: link.planKey))

        case .clear:
            // Nothing is written unless there is something to remove, so a clear with
            // nothing set never creates the file or strips the comments of one. A `figma`
            // that is neither an object nor `null` is removed whole: the key cannot be
            // removed from inside it, and every read would stay broken.
            do {
                switch folder.clearAction {
                case .nothing:
                    break
                case .removeKey:
                    try await store.reset(key)
                case .removeFigma:
                    try await store.reset(JSONKey<String>(id: key.path.components[0], defaultValue: ""))
                }
            } catch {
                throw CLIError(message: "could not save to \(path): \(error.localizedDescription)")
            }
            print(jsonOutput ? folderJSON(nil) : FigmaFolderText.cleared)
        }
    }

    // MARK: - open

    private func runFigmaOpen(
        link raw: String?,
        workspaceOverride: String?,
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        guard let raw else {
            throw CLIError(message: "cmux figma open requires a Figma file URL")
        }
        guard let pasted = URL(string: raw) else {
            throw CLIError(message: "not a URL: \(raw)")
        }

        let destination = try figmaDestination(for: pasted, node: nil)

        var params: [String: Any] = [
            "url": destination.url.absoluteString,
            "focus": false,
            // The two flags that make the pane chrome-free. Nothing
            // user-facing reaches them today; `cm-73.4` exposes them generally.
            "show_omnibar": false,
            "transparent_background": true
        ]
        let workspace = try figmaWorkspaceHandle(explicit: workspaceOverride, client: client)
        // Beside the pane this command ran in, as `browser open-split` does for
        // `--surface`. Without it the app splits beside the workspace's focused
        // pane. `--workspace` names another workspace, where this pane is not.
        let callerSurface = workspaceOverride == nil
            ? try normalizeSurfaceHandle(ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"], client: client)
            : nil

        let payload: [String: Any]
        if let callerSurface {
            // A shell keeps the workspace and pane it started in: a tab moved to
            // another workspace keeps its old `CMUX_WORKSPACE_ID`, and a pane that
            // has closed leaves a stale id. So the pane goes out alone, and the app
            // finds its workspace from it. Only when the app answers `not_found`
            // ask again the way `open` always did: the environment's workspace, no
            // pane. Any other answer is reported as it is, and a value that is not
            // a pane id at all (`CMUX_SURFACE_ID=garbage`) fails above, as it does
            // for the sibling verbs. cmux always exports a UUID there.
            var beside = params
            beside["surface_id"] = callerSurface
            do {
                payload = try client.sendV2(method: "browser.open_split", params: beside)
            } catch let error as CLIError where error.v2Code == "not_found" {
                payload = try client.sendV2(method: "browser.open_split", params: withWorkspace(params, workspace))
            }
        } else {
            payload = try client.sendV2(method: "browser.open_split", params: withWorkspace(params, workspace))
        }
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

    private func withWorkspace(_ params: [String: Any], _ workspace: String?) -> [String: Any] {
        var params = params
        if let workspace { params["workspace_id"] = workspace }
        return params
    }

    // MARK: - goto

    private func runFigmaGoto(
        node: String?,
        surfaceOverride: String?,
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        // A blank id is a missing one: `goto "$NODE"` with the variable unset
        // must not turn a read view into the editor.
        guard let node, !node.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError(message: "cmux figma goto requires a node id")
        }

        let (surfaceID, document) = try resolveBoundFigmaPane(
            surfaceOverride: surfaceOverride,
            client: client
        )
        let destination = try figmaDestination(for: document, node: node)

        let payload = try client.sendV2(
            method: "browser.navigate",
            params: ["surface_id": surfaceID, "url": destination.url.absoluteString]
        )
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        // Deliberately just `OK`: anything more lands in the transcript the
        // user is reading.
        print("OK")
    }

    /// Find the pane a `goto` should steer.
    ///
    /// **The pane's URL is the binding** — no new persisted field — so this
    /// reads it back rather than consulting a store. It has to understand both
    /// surfaces: an editor URL names the document directly, while a wrapper URL
    /// carries it in the `embed` query parameter. Which pane counts is
    /// ``FigmaGotoPicker``'s rule, so a test can hold it with no socket.
    private func resolveBoundFigmaPane(
        surfaceOverride: String?,
        client: SocketClient
    ) throws -> (surfaceID: String, document: URL) {
        func pane(ofSurface id: String, handle: String) -> FigmaGotoPicker.Pane? {
            guard let payload = try? client.sendV2(
                method: "browser.url.get",
                params: ["surface_id": id]
            ) else { return nil }
            guard let raw = payload["url"] as? String, let url = URL(string: raw) else { return nil }
            return FigmaGotoPicker.Pane(
                id: id,
                handle: handle,
                document: FigmaPaneURL.documentURL(fromPaneURL: url),
                showsAddressBar: payload["show_omnibar"] as? Bool
            )
        }

        if let surfaceOverride {
            guard let document = pane(ofSurface: surfaceOverride, handle: surfaceOverride)?.document else {
                throw CLIError(message: "surface \(surfaceOverride) is not showing a Figma file")
            }
            return (surfaceOverride, document)
        }

        // Ask for the list by the pane this command ran in, as `open` does: a
        // shell keeps the workspace it started in, so after its tab is moved
        // `CMUX_WORKSPACE_ID` names a workspace the Figma pane is not in. Only
        // when the app answers `not_found` (the pane has closed) list the way
        // `goto` always did. Any other error is reported as it is.
        var params: [String: Any] = [:]
        if let workspace = try figmaWorkspaceHandle(explicit: nil, client: client) {
            params["workspace_id"] = workspace
        }
        let listed: [String: Any]
        if let callerSurface = try normalizeSurfaceHandle(
            ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"],
            client: client
        ) {
            do {
                listed = try client.sendV2(method: "surface.list", params: ["surface_id": callerSurface])
            } catch let error as CLIError where error.v2Code == "not_found" {
                listed = try client.sendV2(method: "surface.list", params: params)
            }
        } else {
            listed = try client.sendV2(method: "surface.list", params: params)
        }
        let surfaces = listed["surfaces"] as? [[String: Any]] ?? []

        var panes: [FigmaGotoPicker.Pane] = []
        for surface in surfaces where (surface["type"] as? String) == "browser" {
            guard let id = surface["id"] as? String ?? (surface["surface_id"] as? String) else { continue }
            // Print what the house prints — `surface:8`, not a UUID. The
            // message tells the caller to pass `--surface <handle>`, so it
            // has to hand back something they can actually paste.
            let handle = (surface["ref"] as? String) ?? id
            if let pane = pane(ofSurface: id, handle: handle) { panes.append(pane) }
        }

        switch FigmaGotoPicker.pick(panes) {
        case .move(let pane):
            // `pick` only moves a pane that shows a Figma file.
            guard let document = pane.document else {
                throw CLIError(message: "surface \(pane.handle) is not showing a Figma file")
            }
            return (pane.id, document)
        case .refuse(let message):
            throw CLIError(message: message)
        }
    }

    // MARK: - Shared

    /// Resolve a workspace the way the rest of the CLI does: `--workspace`, else
    /// `CMUX_WORKSPACE_ID`, through ``normalizeWorkspaceHandle``.
    ///
    /// That call turns an index into an id and nothing more: a UUID or a ref
    /// comes back as given, unchecked. A stale id (driving a tagged app from
    /// another app's terminal, say) still dies at the socket with
    /// `not_found: Workspace not found`.
    private func figmaWorkspaceHandle(explicit: String?, client: SocketClient) throws -> String? {
        let raw = explicit ?? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
        guard let raw, !raw.isEmpty else { return nil }
        return try normalizeWorkspaceHandle(raw, client: client, allowCurrent: true)
    }

    /// One destination call serves both verbs, and installing the wrapper is
    /// part of it — an embed URL that names a page which is not on disk would
    /// render an empty pane with nothing to explain it.
    ///
    /// **Every verb tries the write**, so the page on disk is this build's and
    /// an old build's page cannot outlive the next `open` or `goto`. Only a
    /// destination that loads the page needs the write to work: if it fails
    /// for the editor, nothing there reads the page, and the command goes on.
    private func figmaDestination(
        for pasted: URL,
        node: String?
    ) throws -> FigmaPaneURL.Destination {
        let destination: FigmaPaneURL.Destination
        do {
            destination = try FigmaPaneURL.destination(for: pasted, node: node)
        } catch FigmaPaneURL.Failure.notAFigmaURL(let raw) {
            throw CLIError(message: "not a Figma file URL: \(raw)")
        }
        do {
            try FigmaWrapperPage.install()
        } catch {
            if case .embed = destination {
                throw CLIError(message: "the read view cannot open without its page "
                    + "\(FigmaPaneURL.wrapperFileURL().path), which cannot be written: "
                    + error.localizedDescription)
            }
        }
        return destination
    }
}
