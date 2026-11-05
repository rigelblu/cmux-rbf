import CmuxSettings
import Foundation

extension CMUXCLI {

    /// One copy of the subcommand help, because `cmux help <topic>` prints the
    /// general usage and returns, so the topic text is only ever reached
    /// through `cmux figma --help` — and a second copy would be the one nobody
    /// updates.
    var figmaUsage: String { FigmaUsage.text }

    /// `cmux figma open <url>`, `cmux figma goto <node>` and `cmux figma fit`.
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
            throw CLIError(message: "cmux figma requires a subcommand: open, goto, fit, folder")
        }
        let subcommand = args.removeFirst().lowercased()
        if ["help", "--help", "-h"].contains(subcommand) {
            print(figmaUsage)
            return
        }

        guard subcommand == "open" || subcommand == "goto" || subcommand == "fit" else {
            throw CLIError(message: "unknown cmux figma subcommand '\(subcommand)' (expected open, goto, fit, folder)")
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
        } else if subcommand == "goto" {
            try runFigmaGoto(
                node: parsed.word,
                surfaceOverride: parsed.option,
                motion: parsed.motion,
                play: parsed.play,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat
            )
        } else {
            try runFigmaFit(
                node: parsed.word,
                surfaceOverride: parsed.option,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat
            )
        }
    }

    // MARK: - folder

    /// `cmux figma folder`, `folder set <folder-url> [--dir <path>]`, `folder clear [--dir <path>]`
    /// and `folder list`.
    ///
    /// **No socket and no app.** The folders are strings in `cmux.json`, so
    /// these read and write the file from this process, as
    /// `cmux window default-display` does, and `run()` dispatches them before it
    /// resolves a socket. `open` and `goto` still need the app.
    ///
    /// **Which folder answers is `FigmaFolderChoice`,** the rule the Figma button's menu runs
    /// too, asked about this process's working directory. **An agent never reads a broken
    /// setting as "not set".** The read goes through ``JSONConfigStore/strictRoot()``,
    /// which says why a file could not be read, and a stored value that is not text, or a
    /// link that no longer passes, is exit 1 with the fix named, whether it is the entry for
    /// this directory or the default. `set` writes over a broken value at the key, which is
    /// what the `Fix it:` line promises, and stops on a file that is not valid JSON, because
    /// the strict read runs before any write. `set --dir` and `clear --dir` write through
    /// `FigmaFolders.plan`, the plan the menu's Set and Remove use.
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

        func linkObject(_ link: FigmaFolderLink) -> [String: Any] {
            ["project_id": link.projectId, "plan_key": link.planKey, "url": link.url]
        }

        func folderJSON(_ link: FigmaFolderLink?) -> String {
            guard let link else { return jsonString(["default_folder": NSNull()]) }
            return jsonString(["default_folder": linkObject(link)])
        }

        let folder = FigmaDefaultFolder(root: root)
        let home = FigmaFolderPath.homeDirectory

        /// The default as `list` and `--json` show it: its object, `null` for not set, or an error.
        func defaultJSON() -> Any {
            switch folder.state {
            case .notSet: return NSNull()
            case .set(let link): return linkObject(link)
            case .refused(let refusal): return ["error": FigmaFolderText.reason(refusal)]
            case .notText: return ["error": "it is not text."]
            }
        }

        func foldersEntries() throws -> FigmaFolderEntries {
            switch FigmaFolderChoice.strictEntries(root: root) {
            case .success(let entries): return entries
            case .failure: throw CLIError(message: FigmaFolderText.foldersNotObject)
            }
        }

        /// The directory `--dir` names, made absolute from the shell form of the working
        /// directory and required to exist. Its resolved form is the key both writers use.
        func directoryForms(_ argument: String) throws -> FigmaFolderPath.Forms {
            let working = FigmaFolderPath.cliForms(
                pwd: ProcessInfo.processInfo.environment["PWD"],
                cwd: FileManager.default.currentDirectoryPath
            )
            let shell = FigmaFolderPath.shellForm(argument, relativeTo: working.shell, home: home)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: shell, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw CLIError(message: FigmaFolderText.notADirectory(shell))
            }
            return FigmaFolderPath.Forms(shell: shell, resolved: FigmaFolderPath.resolvedForm(shell))
        }

        switch action {
        case .read:
            let working = FigmaFolderPath.cliForms(
                pwd: ProcessInfo.processInfo.environment["PWD"],
                cwd: FileManager.default.currentDirectoryPath
            )
            let choice: FigmaFolderChoice
            switch FigmaFolderChoice.strict(root: root, forms: working, home: home) {
            case .success(let answered): choice = answered
            case .failure: throw CLIError(message: FigmaFolderText.foldersNotObject)
            }
            switch choice {
            case .none:
                print(jsonOutput
                    ? jsonString(["default_folder": NSNull(), "folder": NSNull()])
                    : FigmaFolderText.notSet)
            case .folder(let link, let source):
                var directory: Any = NSNull()
                var directoryText = "default"
                if case .directory(let found) = source {
                    directory = found
                    directoryText = found
                }
                if jsonOutput {
                    var answered = linkObject(link)
                    answered["directory"] = directory
                    print(jsonString(["default_folder": defaultJSON(), "folder": answered]))
                } else {
                    print(FigmaFolderText.read(
                        projectId: link.projectId,
                        planKey: link.planKey,
                        url: link.url,
                        directory: directoryText
                    ))
                }
            case .refused(let refusal, let source):
                throw CLIError(message: unusable(FigmaFolderText.reason(refusal), source))
            case .notText(let source):
                throw CLIError(message: unusable("it is not text.", source))
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

        case .setIn(let raw, let argument):
            let link: FigmaFolderLink
            switch FigmaFolderLink.check(raw) {
            case .success(let checked): link = checked
            case .failure(let refusal): throw CLIError(message: FigmaFolderText.refusedSet(refusal))
            }
            let forms = try directoryForms(argument)
            // The resolved key is checked, so a symlink to `/Volumes` is refused too.
            if FigmaFolderPath.isNeverSet(resolved: forms.resolved) {
                throw CLIError(message: FigmaFolderText.cannotSetFor(forms.resolved))
            }
            // A `figma.folders` that is not an object is written over, as the default's set does.
            let entries = (try? FigmaFolderChoice.strictEntries(root: root).get()) ?? .empty
            let plan = FigmaFolders.plan(.set(link), directory: forms.resolved, entries: entries, home: home)
            do {
                try await FigmaFolders.apply(plan, to: store)
            } catch {
                throw CLIError(message: "could not save to \(path): \(error.localizedDescription)")
            }
            if jsonOutput {
                var answered = linkObject(link)
                answered["directory"] = forms.resolved
                print(jsonString(["folder": answered]))
            } else {
                print(FigmaFolderText.setDirectory(
                    directory: forms.resolved,
                    projectId: link.projectId,
                    planKey: link.planKey
                ))
            }

        case .clearIn(let argument):
            let forms = try directoryForms(argument)
            let entries = (try? FigmaFolderChoice.strictEntries(root: root).get()) ?? .empty
            let plan = FigmaFolders.plan(.clear, directory: forms.resolved, entries: entries, home: home)
            do {
                try await FigmaFolders.apply(plan, to: store)
            } catch {
                throw CLIError(message: "could not save to \(path): \(error.localizedDescription)")
            }
            if jsonOutput {
                print(jsonString(["folder": NSNull(), "directory": forms.resolved]))
            } else if plan == .nothing {
                print(FigmaFolderText.notClearedDirectory(directory: forms.resolved))
            } else {
                let after = FigmaFolders.entries(after: plan, from: entries)
                let now: FigmaFolderText.Now
                switch FigmaFolderChoice.answer(forms: forms, entries: after, defaultState: folder.state, home: home) {
                case .folder(_, from: .default): now = .defaultFolder
                case .folder(_, from: .directory(let found)): now = .folderSetFor(found)
                case .none: now = .drafts
                case .refused(_, from: .default), .notText(from: .default): now = .defaultUnusable
                case .refused(_, from: .directory(let found)), .notText(from: .directory(let found)):
                    now = .folderUnusable(found)
                }
                print(FigmaFolderText.clearedDirectory(directory: forms.resolved, now: now))
            }

        case .list:
            let entries = try foldersEntries()
            var rows: [(directory: String, link: FigmaFolderLink?, error: String?)] = []
            for (directory, entry) in entries.entries.sorted(by: { $0.key < $1.key }) {
                // A key that is not a full path matches no directory, so it never works: say so.
                guard FigmaFolderPath.keyForms(directory, home: home) != nil else {
                    rows.append((directory, nil, FigmaFolderText.keyNotAFullPath))
                    continue
                }
                switch entry {
                case .link(let text):
                    switch FigmaFolderLink.check(text) {
                    case .success(let link): rows.append((directory, link, nil))
                    case .failure(let refusal): rows.append((directory, nil, FigmaFolderText.reason(refusal)))
                    }
                case .notText:
                    rows.append((directory, nil, "it is not text."))
                }
            }
            if jsonOutput {
                let listed: [[String: Any]] = rows.map { row in
                    if let link = row.link {
                        var object = linkObject(link)
                        object["directory"] = row.directory
                        return object
                    }
                    return ["directory": row.directory, "error": row.error ?? ""]
                }
                print(jsonString(["folders": listed, "default_folder": defaultJSON()]))
            } else if rows.isEmpty, case .notSet = folder.state {
                print(FigmaFolderText.noFolders)
            } else {
                var lines: [String] = []
                for row in rows {
                    lines.append(row.directory)
                    lines.append("  " + (row.link?.url ?? "error: \(row.error ?? "")"))
                }
                lines.append("default")
                switch folder.state {
                case .notSet: lines.append("  not set")
                case .set(let link): lines.append("  " + link.url)
                case .refused(let refusal): lines.append("  error: " + FigmaFolderText.reason(refusal))
                case .notText: lines.append("  error: it is not text.")
                }
                print(lines.joined(separator: "\n"))
            }
        }
    }

    /// The error for a broken answer: the entry's, or the default's in the words `cm-73.6` gave it.
    private func unusable(_ reason: String, _ source: FigmaFolderChoice.Source) -> String {
        switch source {
        case .default: return FigmaFolderText.unusable(reason: reason)
        case .directory(let key): return FigmaFolderText.unusableEntry(reason: reason, key: key)
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
        // cmux-rbf #cm-73.45: the app also records that pane's terminal as the
        // owner, so the caller is named by herdr-agent's note before
        // `CMUX_SURFACE_ID` (`figmaCallerSurfaces`).
        let callers = workspaceOverride == nil ? try figmaCallerSurfaces(client: client, strict: true) : []

        // A shell keeps the workspace and pane it started in: a tab moved to
        // another workspace keeps its old `CMUX_WORKSPACE_ID`, and a pane that
        // has closed leaves a stale id. So the pane goes out alone, and the app
        // finds its workspace from it. Only when the app answers `not_found`
        // try the next caller, and after the last ask the way `open` always
        // did: the environment's workspace, no pane. Any other answer is
        // reported as it is, and a value that is not a pane id at all
        // (`CMUX_SURFACE_ID=garbage`) fails above, as it does for the sibling
        // verbs. cmux always exports a UUID there.
        var placed: [String: Any]?
        for caller in callers {
            var beside = params
            beside["surface_id"] = caller
            do {
                placed = try client.sendV2(method: "browser.open_split", params: beside)
                break
            } catch let error as CLIError where error.v2Code == "not_found" {
                continue
            }
        }
        let payload = try placed
            ?? client.sendV2(method: "browser.open_split", params: withWorkspace(params, workspace))
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        // The house line `browser open-split` already prints, so automation
        // that already parses one parses the other.
        let surfaceText = formatHandle(payload, kind: "surface", idFormat: idFormat) ?? "unknown"
        let paneText = formatHandle(payload, kind: "pane", idFormat: idFormat) ?? "unknown"
        let placement = ((payload["created_split"] as? Bool) == true) ? "split" : "reuse"
        let orientation = (payload["orientation"] as? String).map { " orientation=\($0)" } ?? ""
        print("OK surface=\(surfaceText) pane=\(paneText) placement=\(placement)\(orientation)")
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
        motion: Bool,
        play: Bool,
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        // A blank id is a missing one: `goto "$NODE"` with the variable unset
        // must not turn a read view into the editor.
        guard let node, !node.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError(message: "cmux figma goto requires a node id")
        }

        // cmux-rbf #cm-73.45: the caller also goes out as `caller_surface_id`, so
        // the app records it as the pane's owner.
        // `--surface` never read `CMUX_SURFACE_ID` before, so a bad one there is dropped, not an error.
        let callers = try figmaCallerSurfaces(client: client, strict: surfaceOverride == nil)
        let pane = try resolveBoundFigmaPane(
            surfaceOverride: surfaceOverride,
            callers: callers,
            client: client
        )

        if motion || play {
            let flag = play ? "--play" : "--motion"
            guard FigmaFit.isDesignFile(pane.document) else {
                throw CLIError(
                    message: "cmux figma goto \(flag) works on Figma design files only: surface \(pane.handle) shows a FigJam board or a slide deck"
                )
            }
        }

        // Keep the existing wrapper installation/preflight contract; the app owns page selection.
        _ = try figmaDestination(for: pane.document, node: node, motion: motion)
        var params: [String: Any] = [
            "surface_id": pane.surfaceID,
            "node": node
        ]
        if motion { params["motion"] = true }
        if play { params["play"] = true }
        if let caller = pane.callerSurface { params["caller_surface_id"] = caller }
        let payload = try client.sendV2(
            method: "figma.goto",
            params: params
        )
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        // Deliberately just `OK`: anything more lands in the transcript the
        // user is reading.
        print("OK")
    }

    // MARK: - fit

    /// How long `fit` waits before it presses `⇧1` in the editor, so boards the agent
    /// has just moved are on screen. Measured 2026-10-20: they show within 0.3 s of an
    /// edit through the Figma MCP, so a second is ample. The wait lives here, so the
    /// app holds no timer.
    private static let figmaFitSettleSeconds: TimeInterval = 1.0

    /// `cmux figma fit [--surface <ref>] [--node <id>]`: fit, or move the preview to that node in place.
    ///
    /// **Two ways, with the shared app-side goto for the preview.** In Figma's editor it sends `browser.press`
    /// with `!`, the trusted `⇧1`; in the read view, which has no zoom to fit, it sends `figma.goto` with
    /// `purpose: fit`, which the app answers with the panel's re-fit: Figma's own frame redraws in place on
    /// the node it shows (`cm-73.44`). Which way, and every refusal, is
    /// ``FigmaFit/decide(handle:paneAddress:document:isShowing:)``.
    ///
    /// **A trusted `!` types into Figma's text editing** (measured 2026-10-20), which
    /// would edit the file, so the editor way first asks the page what has focus and
    /// sends no key when it is a text field.
    private func runFigmaFit(
        node requestedNode: String?,
        surfaceOverride: String?,
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        // `fit` names no caller to the app: it points the pane at no new board.
        let pane = try resolveBoundFigmaPane(
            surfaceOverride: surfaceOverride,
            callers: try figmaCallerSurfaces(client: client, strict: surfaceOverride == nil),
            client: client
        )
        let decision = FigmaFit.decide(
            handle: pane.handle,
            paneAddress: pane.address,
            document: pane.document,
            isShowing: figmaPaneIsShowing(surfaceID: pane.surfaceID, canonicalID: pane.canonicalID, client: client)
        )

        let payload: [String: Any]
        switch decision {
        case .refuse(let message):
            throw CLIError(message: message)

        case .reloadNode(let shownNode):
            _ = try figmaDestination(for: pane.document, node: shownNode)
            var params: [String: Any] = ["surface_id": pane.surfaceID, "node": shownNode, "purpose": "fit"]
            // Only an explicit --node requests a move. The shown node may be an instance-layer id.
            if let requestedNode { params["fit_node"] = requestedNode }
            do {
                payload = try client.sendV2(
                    method: "figma.goto",
                    params: params
                )
            } catch let error as CLIError where error.v2Code == "invalid_state" && error.v2Reason == FigmaFit.notBoardReason {
                // cmux-rbf (#cm-73.44): the preview shows Figma's Log in page or an error, which a redraw would break.
                throw CLIError(message: FigmaFit.notBoardRefusal(handle: pane.handle))
            }

        case .pressFit:
            Thread.sleep(forTimeInterval: Self.figmaFitSettleSeconds)
            let focus = try client.sendV2(
                method: "browser.eval",
                params: ["surface_id": pane.surfaceID, "script": FigmaFit.focusGuardScript]
            )
            if FigmaFit.isTyping(focus["value"]) {
                throw CLIError(message: FigmaFit.typingRefusal(handle: pane.handle))
            }
            payload = try client.sendV2(
                method: "browser.press",
                params: ["surface_id": pane.surfaceID, "key": FigmaFit.fitKey]
            )
        }

        if jsonOutput {
            var out = formatIDs(payload, mode: idFormat) as? [String: Any] ?? [:]
            out["surface"] = formatHandle(payload, kind: "surface", idFormat: idFormat) ?? pane.handle
            out["mode"] = decision.mode?.rawValue
            print(jsonString(out))
            return
        }
        // Just `OK`, as `goto` answers: anything more lands in the transcript the user is reading.
        print("OK")
    }

    /// Whether a pane is on screen, read from `surface.list` and `workspace.current`.
    ///
    /// A pane that is not selected in its pane, or whose workspace is not the
    /// selected one in its window, is not showing. Neither field reads the window
    /// itself, and a reply that lacks a field says nothing, so any answer this
    /// cannot read counts as showing: a refusal that is wrong blocks the person, a press that is
    /// wrong only frames the wrong size.
    private func figmaPaneIsShowing(surfaceID: String, canonicalID: String, client: SocketClient) -> Bool {
        guard let listed = try? client.sendV2(method: "surface.list", params: ["surface_id": surfaceID]) else {
            return true
        }
        let rows = listed["surfaces"] as? [[String: Any]] ?? []
        // Matched by the canonical id, so `--surface tab:3` or a lower-case UUID still finds its row.
        let row = rows.first { ($0["id"] as? String) == canonicalID || ($0["ref"] as? String) == surfaceID }
        var currentParams: [String: Any] = [:]
        if let window = listed["window_id"] as? String { currentParams["window_id"] = window }
        let current = try? client.sendV2(method: "workspace.current", params: currentParams)
        return FigmaFit.isShowing(
            selectedInPane: row?["selected_in_pane"] as? Bool,
            workspaceID: listed["workspace_id"] as? String,
            selectedWorkspaceID: current?["workspace_id"] as? String
        )
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
        callers: [String],
        client: SocketClient
    ) throws -> BoundFigmaPane {
        var addresses: [String: URL] = [:]
        var canonicalIDs: [String: String] = [:]
        func pane(ofSurface id: String, handle: String) -> FigmaGotoPicker.Pane? {
            guard let payload = try? client.sendV2(
                method: "browser.url.get",
                params: ["surface_id": id]
            ) else { return nil }
            guard let raw = payload["url"] as? String, let url = URL(string: raw) else { return nil }
            addresses[id] = url
            canonicalIDs[id] = payload["surface_id"] as? String
            return FigmaGotoPicker.Pane(
                id: id,
                handle: handle,
                document: FigmaPaneURL.documentURL(fromPaneURL: url),
                showsAddressBar: payload["show_omnibar"] as? Bool
            )
        }

        if let surfaceOverride {
            guard let document = pane(ofSurface: surfaceOverride, handle: surfaceOverride)?.document,
                  let address = addresses[surfaceOverride] else {
                throw CLIError(message: "surface \(surfaceOverride) is not showing a Figma file")
            }
            return BoundFigmaPane(
                surfaceID: surfaceOverride,
                canonicalID: canonicalIDs[surfaceOverride] ?? surfaceOverride,
                handle: surfaceOverride,
                document: document,
                address: address,
                callerSurface: figmaFirstKnownCaller(callers, client: client)
            )
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
        var listed: [String: Any]?
        var callerSurface: String?
        for caller in callers {
            do {
                listed = try client.sendV2(method: "surface.list", params: ["surface_id": caller])
                callerSurface = caller
                break
            } catch let error as CLIError where error.v2Code == "not_found" {
                continue
            }
        }
        let listing = try listed ?? client.sendV2(method: "surface.list", params: params)
        let surfaces = listing["surfaces"] as? [[String: Any]] ?? []

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
            guard let document = pane.document, let address = addresses[pane.id] else {
                throw CLIError(message: "surface \(pane.handle) is not showing a Figma file")
            }
            return BoundFigmaPane(
                surfaceID: pane.id,
                canonicalID: canonicalIDs[pane.id] ?? pane.id,
                handle: pane.handle,
                document: document,
                address: address,
                callerSurface: callerSurface
            )
        case .refuse(let message):
            throw CLIError(message: message)
        }
    }

    /// A Figma pane `goto` or `fit` found: the id the socket takes, the name a person
    /// can paste, the Figma file it shows, and the address it shows it at (the editor
    /// on Figma's own host, or cmux's read-view page).
    struct BoundFigmaPane {
        let surfaceID: String
        /// The pane's UUID as `browser.url.get` answers it, whatever alias or case `surfaceID` was given in.
        let canonicalID: String
        let handle: String
        let document: URL
        let address: URL
        /// cmux-rbf #cm-73.45: the first caller the app knew, or `nil`. `goto` sends it as
        /// `caller_surface_id`; `fit` ignores it.
        let callerSurface: String?
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

    /// One destination call serves both verbs. The read view's page is served
    /// by the app from memory (`cm-73.39`), so nothing is written here.
    private func figmaDestination(
        for pasted: URL,
        node: String?,
        motion: Bool = false
    ) throws -> FigmaPaneURL.Destination {
        do {
            return try FigmaPaneURL.destination(for: pasted, node: node, motion: motion)
        } catch FigmaPaneURL.Failure.notAFigmaURL(let raw) {
            throw CLIError(message: "not a Figma file URL: \(raw)")
        }
    }
}
