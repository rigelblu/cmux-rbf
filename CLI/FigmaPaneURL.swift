import Foundation

/// Where a `cmux figma` verb should point a browser pane, and how to get back.
///
/// **One resolver serves both verbs**, because `open` and `goto` build the same
/// URL from different starting points and the repo's shared-behaviour policy
/// asks for one path rather than two that drift.
///
/// **The surface depends on whether a node is named** (Tom, 2026-09-07). No
/// node and the pane is Figma's own editor, which has the pages, layers and
/// search a pane you are *browsing* needs. A node named and the pane is a clean
/// embed with none of that. Copying a *frame* in Figma is already the gesture
/// meaning "this one"; copying the *file* is not, so the trigger needs no flag.
enum FigmaPaneURL {

    /// What the pane should load.
    enum Destination: Equatable {
        /// Figma's editor, loaded top-level exactly as the user pasted it.
        case editor(URL)
        /// cmux's wrapper page, holding the embed in an `<iframe>`.
        ///
        /// **The wrapper is required, not stylistic** — measured 2026-09-07,
        /// the embed URL loaded top-level redirects through
        /// `www.figma.com/embed/interstitial` into the full editor, so Embed
        /// Kit only stays an embed inside a frame.
        case embed(wrapper: URL, embedded: URL)

        var url: URL {
            switch self {
            case .editor(let url): return url
            case .embed(let wrapper, _): return wrapper
            }
        }
    }

    enum Failure: Error, Equatable {
        case notAFigmaURL(String)
    }

    // MARK: - Recognising a Figma URL

    private static let embedHost = FigmaFileLink.embedHost
    /// The file's first page, in the form Figma's URLs write it and the form
    /// its own marks write.
    private static let firstPageIDs: Set<String> = ["0-1", "0:1"]
    private static let canonicalHost = "www.figma.com"

    /// `/design/<key>/<slug>` today, `/file/<key>/<slug>` on older links. The
    /// slug is kept verbatim rather than dropped — it is part of the path Figma
    /// serves, and reconstructing it from the file name is what made an earlier
    /// version of this contract unbuildable.
    ///
    /// The rule itself is ``FigmaFileLink``, shared with the app.
    static func isFigmaDocumentURL(_ url: URL) -> Bool {
        FigmaFileLink.isFileLink(url)
    }

    // MARK: - Where the wrapper lives

    /// Application Support, not the app bundle.
    ///
    /// The wrapper's URL is what `SessionBrowserPanelSnapshot` persists for the
    /// pane, so the path has to outlive both a restart and `make clean-builds`.
    /// A bundle path fails the second: a dev build's Resources live in
    /// DerivedData, which that command deletes by design, and the restored pane
    /// would then point at nothing. This directory is shared by every build for
    /// the same reason `~/.config/cmux/cmux.json` is.
    static func wrapperFileURL(
        applicationSupport: URL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/cmux", isDirectory: true)
    ) -> URL {
        applicationSupport.appendingPathComponent("figma-embed.html", isDirectory: false)
    }

    // MARK: - Forward: what to load

    /// Resolve what a pane should show for a pasted URL and an optional node.
    ///
    /// - Parameter node: an explicit node id from `goto`. When `nil` the node
    ///   is taken from the pasted URL's own `node-id`, which is what makes
    ///   "paste a frame link" work with no flag.
    static func destination(
        for pasted: URL,
        node explicitNode: String? = nil,
        wrapper: URL = wrapperFileURL()
    ) throws -> Destination {
        guard isFigmaDocumentURL(pasted) else {
            throw Failure.notAFigmaURL(pasted.absoluteString)
        }

        let node = normalizedNode(explicitNode) ?? nodeID(in: pasted)

        // No node: the editor, loaded exactly as given. Measured 2026-09-07 —
        // a bare file URL stays bare (Figma adds its slug and a `t=` token but
        // no `node-id`), so "carries a node-id" genuinely separates the two.
        guard let node else { return .editor(pasted) }

        // Figma's Share button always writes a `node-id`; with nothing selected
        // it is the file's first page, `0-1`, and that link means the file
        // (Tom, 2026-10-07). Only a pasted link: `goto 0-1` names the id on
        // purpose and gets the read view like any other id.
        if normalizedNode(explicitNode) == nil, firstPageIDs.contains(node) { return .editor(pasted) }

        let embedded = embedURL(for: pasted, node: node)
        return .embed(wrapper: wrapperURL(wrapper, embedding: embedded), embedded: embedded)
    }

    /// The embed URL: host swapped, **path kept verbatim**, parameters appended.
    ///
    /// No `scaling` — it is a *prototype*-embed parameter and does nothing on a
    /// design embed (confirmed by looking, 2026-09-05). Booleans take `0`/`1`;
    /// Figma canonicalises `false` to `1`, which is the opposite of what it
    /// looks like it does.
    static func embedURL(for pasted: URL, node: String) -> URL {
        var components = URLComponents(url: pasted, resolvingAgainstBaseURL: false)
            ?? URLComponents()
        components.scheme = "https"
        components.host = embedHost
        components.fragment = nil
        components.queryItems = [
            URLQueryItem(name: "embed-host", value: "cmux"),
            URLQueryItem(name: "footer", value: "0"),
            URLQueryItem(name: "page-selector", value: "0"),
            // Passed through in whatever form it arrived — `12-2` and `12:2`
            // both work, measured against a control 2026-09-07.
            URLQueryItem(name: "node-id", value: node)
        ]
        return components.url ?? pasted
    }

    /// The wrapper's own URL, carrying the embed URL in its query string.
    ///
    /// **This is what keeps the pane's URL a usable binding.** The pane no
    /// longer loads the embed directly, so without this the persisted URL
    /// would name only cmux's own HTML file — `goto` would have no file key to
    /// resolve and a restart could not return to the steered node. Measured
    /// 2026-09-08: a query string on a `file://` URL survives, and is what the
    /// pane reports back through `browser get url`.
    static func wrapperURL(_ wrapper: URL, embedding embedded: URL) -> URL {
        var components = URLComponents(url: wrapper, resolvingAgainstBaseURL: false)
            ?? URLComponents()
        // No theme: the page picks light or dark from the pane each time it loads.
        components.queryItems = [URLQueryItem(name: "embed", value: embedded.absoluteString)]
        return components.url ?? wrapper
    }

    // MARK: - Reverse: what the pane is bound to

    /// Recover the Figma document URL a pane is showing, from either surface.
    ///
    /// `goto` needs this: the pane's URL *is* the binding (no new persisted
    /// field), but in embed mode that URL is cmux's wrapper, so the document
    /// has to be read back out of the query string it carries.
    static func documentURL(fromPaneURL paneURL: URL, wrapper: URL = wrapperFileURL()) -> URL? {
        if isFigmaDocumentURL(paneURL) {
            return canonicalized(paneURL)
        }
        guard let embedded = embeddedURL(inWrapper: paneURL, wrapper: wrapper) else { return nil }
        return isFigmaDocumentURL(embedded) ? canonicalized(embedded) : nil
    }

    /// Whether an address is cmux's own page.
    static func isWrapperPage(_ paneURL: URL, wrapper: URL = wrapperFileURL()) -> Bool {
        paneURL.isFileURL && paneURL.standardizedFileURL.path == wrapper.standardizedFileURL.path
    }

    /// The embed URL a wrapper URL carries, if it is one of ours.
    ///
    /// **Read only from cmux's own page.** A page on any site can carry
    /// `?embed=<a Figma link>` in its address, and reading it would make that
    /// pane look like a Figma pane `goto` can navigate.
    static func embeddedURL(inWrapper paneURL: URL, wrapper: URL = wrapperFileURL()) -> URL? {
        guard isWrapperPage(paneURL, wrapper: wrapper),
              let components = URLComponents(url: paneURL, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == "embed" })?.value
        else { return nil }
        return URL(string: raw)
    }

    /// Which Figma file a link or a pane address names, as one comparable string.
    ///
    /// It is the path segment right after `/design/`, `/file/`, `/board/` or
    /// `/slides/`, so the name after the key and the kind of link do not matter:
    /// `/design/KEY/a`, `/design/KEY/renamed`, `/design/KEY` and `/file/KEY/a`
    /// are one file. A branch link, `.../KEY/branch/BRANCHKEY/...`, is its own
    /// file: the answer is `KEY/branch/BRANCHKEY`. `documentURL(fromPaneURL:)`
    /// keeps the path as given and cannot serve here.
    ///
    /// Reads a pane in either surface, as ``documentURL(fromPaneURL:wrapper:)`` does.
    static func fileKey(fromPaneURL paneURL: URL, wrapper: URL = wrapperFileURL()) -> String? {
        guard let document = documentURL(fromPaneURL: paneURL, wrapper: wrapper) else { return nil }
        // `[kind, KEY, ...]`: `isFileLink` has already held the first segment to one of the four.
        let segments = document.path.split(separator: "/").map(String.init)
        guard segments.count >= 2, !segments[1].isEmpty else { return nil }
        if segments.count >= 4, segments[2] == "branch" { return "\(segments[1])/branch/\(segments[3])" }
        return segments[1]
    }

    /// The node a pane is currently steered to, if any.
    static func node(fromPaneURL paneURL: URL, wrapper: URL = wrapperFileURL()) -> String? {
        if let embedded = embeddedURL(inWrapper: paneURL, wrapper: wrapper) { return nodeID(in: embedded) }
        return nodeID(in: paneURL)
    }

    /// Strip the embed host and its parameters back to a plain document URL, so
    /// re-steering starts from the same place a fresh paste would.
    private static func canonicalized(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.scheme = "https"
        components.host = canonicalHost
        components.queryItems = nil
        components.fragment = nil
        return components.url ?? url
    }

    // MARK: - Node ids

    private static func nodeID(in url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return normalizedNode(components.queryItems?.first(where: { $0.name == "node-id" })?.value)
    }

    private static func normalizedNode(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
