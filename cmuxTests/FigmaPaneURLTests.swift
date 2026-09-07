import Foundation
import Testing

/// Behaviour of the `cmux figma` URL contract.
///
/// Written test-with-code, because a new pure type cannot compile otherwise —
/// so the evidence here is the mutation campaign recorded in `#cm-73`'s brief,
/// not a red-first run.
@Suite("FigmaPaneURL")
struct FigmaPaneURLTests {

    private static let wrapper = URL(fileURLWithPath: "/tmp/cmux-test/figma-embed.html")
    private static let fileURL = URL(string: "https://www.figma.com/design/MVdKSLWiPvKNyWab361uJ2/cm-73---figma-native-pane")!

    private func resolve(_ raw: String, node: String? = nil, theme: FigmaPaneURL.Theme = .dark) throws -> FigmaPaneURL.Destination {
        try FigmaPaneURL.destination(
            for: URL(string: raw)!,
            node: node,
            theme: theme,
            wrapper: Self.wrapper
        )
    }

    // MARK: - Which surface

    @Test("a file URL with no node opens the editor, exactly as pasted")
    func noNodeOpensEditorUnchanged() throws {
        let pasted = Self.fileURL
        let destination = try resolve(pasted.absoluteString)
        #expect(destination == .editor(pasted))
    }

    @Test("a node in the pasted URL opens the framed embed")
    func nodeInPastedURLOpensEmbed() throws {
        let destination = try resolve(Self.fileURL.absoluteString + "?node-id=12-2")
        guard case .embed = destination else {
            Issue.record("expected an embed, got \(destination)")
            return
        }
    }

    @Test("an explicit node beats whatever the pasted URL carried")
    func explicitNodeWins() throws {
        let destination = try resolve(Self.fileURL.absoluteString + "?node-id=12-2", node: "99-1")
        guard case .embed(_, let embedded) = destination else {
            Issue.record("expected an embed, got \(destination)")
            return
        }
        #expect(query(embedded, "node-id") == "99-1")
    }

    @Test("a node id passes through in whatever form it arrived")
    func nodeFormIsPreserved() throws {
        for form in ["12-2", "12:2"] {
            let destination = try resolve(Self.fileURL.absoluteString, node: form)
            guard case .embed(_, let embedded) = destination else {
                Issue.record("expected an embed for \(form)")
                return
            }
            #expect(query(embedded, "node-id") == form)
        }
    }

    // MARK: - The embed URL

    @Test("the embed swaps the host and keeps the path verbatim, slug and all")
    func embedKeepsPathVerbatim() throws {
        let destination = try resolve(Self.fileURL.absoluteString, node: "12-2")
        guard case .embed(_, let embedded) = destination else {
            Issue.record("expected an embed")
            return
        }
        #expect(embedded.host == "embed.figma.com")
        #expect(embedded.path == "/design/MVdKSLWiPvKNyWab361uJ2/cm-73---figma-native-pane")
    }

    @Test("the embed carries cmux's resolved theme, never `system`")
    func embedCarriesResolvedTheme() throws {
        for theme in [FigmaPaneURL.Theme.light, .dark] {
            let destination = try resolve(Self.fileURL.absoluteString, node: "12-2", theme: theme)
            guard case .embed(let wrapper, let embedded) = destination else {
                Issue.record("expected an embed")
                return
            }
            #expect(query(embedded, "theme") == theme.rawValue)
            // The wrapper paints the same value behind the iframe, so the
            // moment before Figma's skeleton lands is not a white flash.
            #expect(query(wrapper, "theme") == theme.rawValue)
        }
    }

    @Test("the embed sends no `scaling` — it is inert on a design embed")
    func embedSendsNoScaling() throws {
        let destination = try resolve(Self.fileURL.absoluteString, node: "12-2")
        guard case .embed(_, let embedded) = destination else {
            Issue.record("expected an embed")
            return
        }
        #expect(query(embedded, "scaling") == nil)
    }

    // MARK: - The pane's URL is the binding

    @Test("the wrapper URL carries the embed URL, so the pane's URL stays a usable binding")
    func wrapperCarriesTheEmbedURL() throws {
        let destination = try resolve(Self.fileURL.absoluteString, node: "12-2")
        guard case .embed(let wrapper, let embedded) = destination else {
            Issue.record("expected an embed")
            return
        }
        #expect(FigmaPaneURL.embeddedURL(inWrapper: wrapper) == embedded)
    }

    @Test("goto recovers the document from a pane showing the wrapper")
    func documentRecoveredFromWrapper() throws {
        let destination = try resolve(Self.fileURL.absoluteString, node: "12-2")
        let recovered = FigmaPaneURL.documentURL(fromPaneURL: destination.url)
        #expect(recovered == Self.fileURL)
    }

    @Test("goto recovers the document from a pane showing the editor, tracking token and all")
    func documentRecoveredFromEditor() throws {
        // What Figma actually leaves in the bar after loading a bare file URL,
        // measured 2026-09-08: it adds the slug and a `t=` token, no node-id.
        let live = URL(string: Self.fileURL.absoluteString + "?t=hERjtUAfzKGDErfX-0")!
        #expect(FigmaPaneURL.documentURL(fromPaneURL: live) == Self.fileURL)
    }

    @Test("re-steering a bound pane keeps the file and changes only the node")
    func reSteerKeepsFileChangesNode() throws {
        let first = try resolve(Self.fileURL.absoluteString, node: "12-2")
        let document = try #require(FigmaPaneURL.documentURL(fromPaneURL: first.url))
        let second = try FigmaPaneURL.destination(for: document, node: "34-5", theme: .dark, wrapper: Self.wrapper)

        guard case .embed(_, let embedded) = second else {
            Issue.record("expected an embed")
            return
        }
        #expect(embedded.path == "/design/MVdKSLWiPvKNyWab361uJ2/cm-73---figma-native-pane")
        #expect(query(embedded, "node-id") == "34-5")
        #expect(FigmaPaneURL.node(fromPaneURL: second.url) == "34-5")
    }

    // MARK: - Refusals

    @Test("a URL that is not a Figma document is refused")
    func nonFigmaURLIsRefused() {
        for raw in [
            "https://example.com/design/abc",
            "https://www.figma.com/files/recent",
            "https://notfigma.com/design/abc/slug"
        ] {
            #expect(throws: FigmaPaneURL.Failure.self) {
                _ = try FigmaPaneURL.destination(
                    for: URL(string: raw)!,
                    theme: .dark,
                    wrapper: Self.wrapper
                )
            }
        }
    }

    @Test("the wrapper lives outside the app bundle, so it survives clean-builds")
    func wrapperLivesInApplicationSupport() {
        let url = FigmaPaneURL.wrapperFileURL()
        #expect(url.isFileURL)
        #expect(url.path.contains("Application Support"))
        #expect(!url.path.contains(".app/Contents"))
    }

    // MARK: -

    private func query(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }
}
