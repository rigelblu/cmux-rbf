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

    /// cmux's resolved appearance. Never `system` — that follows macOS, and
    /// cmux carries an independent browser theme, so a dark Ghostty under a
    /// light macOS would otherwise render the bright rectangle the parameter
    /// exists to prevent.
    enum Theme: String {
        case light
        case dark
    }

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

    private static let figmaHosts: Set<String> = ["figma.com", "www.figma.com", "embed.figma.com"]
    private static let embedHost = "embed.figma.com"
    private static let canonicalHost = "www.figma.com"

    /// `/design/<key>/<slug>` today, `/file/<key>/<slug>` on older links. The
    /// slug is kept verbatim rather than dropped — it is part of the path Figma
    /// serves, and reconstructing it from the file name is what made an earlier
    /// version of this contract unbuildable.
    private static let documentPathPrefixes = ["/design/", "/file/", "/board/", "/slides/"]

    static func isFigmaDocumentURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), figmaHosts.contains(host) else { return false }
        return documentPathPrefixes.contains { url.path.hasPrefix($0) }
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
        theme: Theme,
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

        let embedded = embedURL(for: pasted, node: node, theme: theme)
        return .embed(wrapper: wrapperURL(wrapper, embedding: embedded, theme: theme), embedded: embedded)
    }

    /// The embed URL: host swapped, **path kept verbatim**, parameters appended.
    ///
    /// No `scaling` — it is a *prototype*-embed parameter and does nothing on a
    /// design embed (confirmed by looking, 2026-09-05). Booleans take `0`/`1`;
    /// Figma canonicalises `false` to `1`, which is the opposite of what it
    /// looks like it does.
    static func embedURL(for pasted: URL, node: String, theme: Theme) -> URL {
        var components = URLComponents(url: pasted, resolvingAgainstBaseURL: false)
            ?? URLComponents()
        components.scheme = "https"
        components.host = embedHost
        components.fragment = nil
        components.queryItems = [
            URLQueryItem(name: "embed-host", value: "cmux"),
            URLQueryItem(name: "footer", value: "0"),
            URLQueryItem(name: "page-selector", value: "0"),
            URLQueryItem(name: "theme", value: theme.rawValue),
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
    static func wrapperURL(_ wrapper: URL, embedding embedded: URL, theme: Theme) -> URL {
        var components = URLComponents(url: wrapper, resolvingAgainstBaseURL: false)
            ?? URLComponents()
        components.queryItems = [
            // The wrapper paints this behind the iframe so the instant before
            // Figma's skeleton appears is not a white flash under a dark theme.
            URLQueryItem(name: "theme", value: theme.rawValue),
            URLQueryItem(name: "embed", value: embedded.absoluteString)
        ]
        return components.url ?? wrapper
    }

    // MARK: - Reverse: what the pane is bound to

    /// Recover the Figma document URL a pane is showing, from either surface.
    ///
    /// `goto` needs this: the pane's URL *is* the binding (no new persisted
    /// field), but in embed mode that URL is cmux's wrapper, so the document
    /// has to be read back out of the query string it carries.
    static func documentURL(fromPaneURL paneURL: URL) -> URL? {
        if isFigmaDocumentURL(paneURL) {
            return canonicalized(paneURL)
        }
        guard let embedded = embeddedURL(inWrapper: paneURL) else { return nil }
        return isFigmaDocumentURL(embedded) ? canonicalized(embedded) : nil
    }

    /// The embed URL a wrapper URL carries, if it is one of ours.
    static func embeddedURL(inWrapper paneURL: URL) -> URL? {
        guard let components = URLComponents(url: paneURL, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == "embed" })?.value
        else { return nil }
        return URL(string: raw)
    }

    /// The node a pane is currently steered to, if any.
    static func node(fromPaneURL paneURL: URL) -> String? {
        if let embedded = embeddedURL(inWrapper: paneURL) { return nodeID(in: embedded) }
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
