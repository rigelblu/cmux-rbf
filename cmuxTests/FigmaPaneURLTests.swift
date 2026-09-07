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

    private func resolve(_ raw: String, node: String? = nil) throws -> FigmaPaneURL.Destination {
        try FigmaPaneURL.destination(
            for: URL(string: raw)!,
            node: node,
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

    // MARK: - The Share button's link

    @Test("a pasted link whose node-id is the file's first page opens the editor, as pasted")
    func pastedFirstPageOpensEditor() throws {
        for query in ["node-id=0-1", "node-id=0:1", "node-id=0%3A1", "t=abc&node-id=0-1"] {
            let pasted = URL(string: Self.fileURL.absoluteString + "?" + query)!
            #expect(try resolve(pasted.absoluteString) == .editor(pasted), "\(query)")
        }
    }

    @Test("an explicit 0-1 from goto still opens the read view")
    func explicitFirstPageOpensReadView() throws {
        for form in ["0-1", "0:1"] {
            let destination = try resolve(Self.fileURL.absoluteString, node: form)
            guard case .embed(_, let embedded) = destination else {
                Issue.record("expected an embed for goto \(form), got \(destination)")
                return
            }
            #expect(query(embedded, "node-id") == form)
        }
    }

    @Test("an explicit 0-1 beats a pasted link's own node, which is then not the Share button's")
    func explicitFirstPageBeatsThePastedNode() throws {
        let destination = try resolve(Self.fileURL.absoluteString + "?node-id=12-7", node: "0-1")
        guard case .embed(_, let embedded) = destination else {
            Issue.record("expected an embed, got \(destination)")
            return
        }
        #expect(query(embedded, "node-id") == "0-1")
    }

    @Test("only the first page's id is the Share button's; every other id opens the read view")
    func otherIdsOpenTheReadView() throws {
        for id in ["12-7", "0-10", "10-1", "1-1", "0-2", "00-1", "0-1x"] {
            let destination = try resolve(Self.fileURL.absoluteString + "?node-id=" + id)
            guard case .embed = destination else {
                Issue.record("expected an embed for \(id), got \(destination)")
                return
            }
        }
    }

    // MARK: - No theme from the CLI

    @Test("the address `open` sends carries no theme")
    func addressCarriesNoTheme() throws {
        let destination = try resolve(Self.fileURL.absoluteString, node: "12-2")
        guard case .embed(let wrapper, let embedded) = destination else {
            Issue.record("expected an embed")
            return
        }
        #expect(query(embedded, "theme") == nil)
        #expect(query(wrapper, "theme") == nil)
    }

    @Test("the embed address carries the three parameters that shape the read view")
    func embedCarriesTheReadViewParameters() throws {
        let destination = try resolve(Self.fileURL.absoluteString, node: "12-2")
        guard case .embed(_, let embedded) = destination else {
            Issue.record("expected an embed")
            return
        }
        #expect(query(embedded, "embed-host") == "cmux")
        #expect(query(embedded, "footer") == "0")
        #expect(query(embedded, "page-selector") == "0")
    }

    // MARK: - `embed=` is read only from cmux's own page

    @Test("a page that is not cmux's own is not read for an embed address")
    func foreignPagesAreNotRead() {
        let figma = Self.fileURL.absoluteString
        let encoded = figma.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        for raw in [
            "https://example.com/?embed=\(encoded)",
            "https://example.com/figma-embed.html?embed=\(encoded)",
            "file:///tmp/elsewhere/figma-embed.html?embed=\(encoded)",
            "http://www.figma.com/design/KEY/slug?embed=\(encoded)"
        ] {
            let url = URL(string: raw)!
            #expect(FigmaPaneURL.embeddedURL(inWrapper: url) == nil, "\(raw)")
            #expect(FigmaPaneURL.documentURL(fromPaneURL: url) == nil, "\(raw)")
        }
    }

    @Test("cmux's own page, at its real location, is read for an embed address")
    func ownPageIsRead() throws {
        var components = URLComponents(url: FigmaPaneURL.wrapperFileURL(), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "embed", value: Self.fileURL.absoluteString)]
        let url = try #require(components.url)
        #expect(FigmaPaneURL.embeddedURL(inWrapper: url) == Self.fileURL)
        #expect(FigmaPaneURL.documentURL(fromPaneURL: url) == Self.fileURL)
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
        #expect(FigmaPaneURL.embeddedURL(inWrapper: wrapper, wrapper: Self.wrapper) == embedded)
    }

    @Test("goto recovers the document from a pane showing the wrapper")
    func documentRecoveredFromWrapper() throws {
        let destination = try resolve(Self.fileURL.absoluteString, node: "12-2")
        let recovered = FigmaPaneURL.documentURL(fromPaneURL: destination.url, wrapper: Self.wrapper)
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
        let document = try #require(FigmaPaneURL.documentURL(fromPaneURL: first.url, wrapper: Self.wrapper))
        let second = try FigmaPaneURL.destination(for: document, node: "34-5", wrapper: Self.wrapper)

        guard case .embed(_, let embedded) = second else {
            Issue.record("expected an embed")
            return
        }
        #expect(embedded.path == "/design/MVdKSLWiPvKNyWab361uJ2/cm-73---figma-native-pane")
        #expect(query(embedded, "node-id") == "34-5")
        #expect(FigmaPaneURL.node(fromPaneURL: second.url, wrapper: Self.wrapper) == "34-5")
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
                    wrapper: Self.wrapper
                )
            }
        }
    }

    @Test("an http link is refused, because only https is a Figma file link")
    func httpLinkIsRefused() {
        for raw in [
            "http://www.figma.com/design/MVdKSLWiPvKNyWab361uJ2/slug",
            "http://figma.com/design/MVdKSLWiPvKNyWab361uJ2/slug",
            "http://embed.figma.com/design/MVdKSLWiPvKNyWab361uJ2/slug"
        ] {
            #expect(throws: FigmaPaneURL.Failure.self) {
                _ = try FigmaPaneURL.destination(
                    for: URL(string: raw)!,
                    wrapper: Self.wrapper
                )
            }
        }
    }

    @Test("a path holding `..` is refused, written plain or percent-encoded")
    func dotDotPathIsRefused() {
        for raw in [
            "https://www.figma.com/design/../community",
            "https://www.figma.com/design/KEY/../../community",
            "https://www.figma.com/design/%2e%2e/community",
            "https://www.figma.com/design/%2E%2E%2Fcommunity"
        ] {
            #expect(throws: FigmaPaneURL.Failure.self) {
                _ = try FigmaPaneURL.destination(
                    for: URL(string: raw)!,
                    wrapper: Self.wrapper
                )
            }
        }
    }

    @Test("all four kinds of Figma file link are accepted")
    func allFourKindsAreAccepted() throws {
        for kind in ["design", "file", "board", "slides"] {
            let pasted = "https://www.figma.com/\(kind)/MVdKSLWiPvKNyWab361uJ2/slug"
            #expect(try resolve(pasted) == .editor(URL(string: pasted)!), "\(kind)")
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
