import AppKit
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `#cm-75` — the Reply panel renders an agent's single newlines as line breaks.
///
/// The shell configures `marked` with `breaks: false` (`shell.html:1109-1117`),
/// which is right for a markdown *file* and wrong for an agent's reply. The
/// fix installs ``MarkdownWebRenderer/lineBreakScript`` into the Reply
/// renderer's own configuration.
///
/// **The WebKit tests install the shipped script, never a copy.** Naming
/// `MarkdownWebRenderer.lineBreakScript` is what makes the assertions cover
/// the source that actually ships — a hand-copied literal would keep passing
/// after the real script drifted. It is also the whole reason that script is
/// `internal` — and, since `#cm-89`, why `selectionObserverScript` is too.
///
/// ``theOptInIsOffForCallSitesThatDoNotAskForIt()`` is the one exception to
/// that sentence: it installs nothing and touches no WebKit. It guards the
/// property's *default*, which no WebKit test in this repo can reach.
///
/// **The control is one variable.** `renderedContent(_:lineBreaks:)` builds
/// the same shell, the same markdown, the same evaluation — the script's
/// presence in the configuration is the only difference between the two legs.
/// It cannot be run "against the unfixed code": a test naming
/// `lineBreakScript` does not compile without it.
@MainActor
@Suite
final class MarkdownReplyLineBreakTests {
    /// Scenario 1 — a reply's newlines survive to the page as `<br>`.
    @Test
    func singleNewlinesInAParagraphRenderAsLineBreaks() async throws {
        let rendered = try await renderedContent("1\n2\n3", lineBreaks: true)

        #expect(rendered.breakCount == 2)
        #expect(rendered.firstParagraphHTML == "1<br>2<br>3")
    }

    /// Scenario 2 — the control. Same harness, script omitted from the
    /// configuration; this is the red proof, and the behaviour Tom reported.
    @Test
    func withoutTheScriptTheSameNewlinesCollapseToSpaces() async throws {
        let rendered = try await renderedContent("1\n2\n3", lineBreaks: false)

        #expect(rendered.breakCount == 0)
        #expect(rendered.firstParagraphHTML == "1\n2\n3")
    }

    /// Scenario 3 — block structure is untouched, **and the second
    /// `marked.use` merges rather than replaces.**
    ///
    /// `marked` holds the block tree, so a fence, a table and a list are
    /// parsed before `breaks` ever applies. This is the assertion behind
    /// choosing a `marked` option over a Swift text transform, which would
    /// have had to re-derive all of it.
    ///
    /// **"Block structure" means the boundaries, not the text inside them.**
    /// `breaks` governs a soft break inside any paragraph-level content —
    /// which includes a wrapped list item and a wrapped blockquote, not only
    /// a top-level paragraph. Those *do* change, deliberately, and
    /// ``wrappedListItemsBreakToo()`` below asserts it. This test's fixture
    /// uses single-line list items on purpose; an earlier version left that
    /// unsaid, so the test name read as "lists are unaffected", which is
    /// false.
    ///
    /// **It is also the merge test, and the only one.** Only the
    /// `lineBreaks: true` leg runs the second `marked.use`. Were that a
    /// replace, that leg would lose the shell's own `code` renderer and the
    /// fence would come back `class="language-swift"` with a trailing newline
    /// instead of `class="hljs language-swift"` without one — so the two legs
    /// would diverge and this equality would fail. Measured against the
    /// bundled `marked.min.js`, not assumed.
    ///
    /// A codespan assertion cannot do this job: the shell's `processAllTokens`
    /// hook and `codespan` renderer produce output that survives a DOM
    /// round-trip identically to stock `marked` for every input probed — the
    /// hook is defensive against a future `marked`, not a present difference.
    /// An earlier version of this suite asserted `contentHTML.contains("<code")`
    /// and could not fail at all: the shell's own render-error path emits
    /// `<pre><code>` too (`shell.html:1836-1840`), so it passed even when
    /// `marked.parse` threw.
    @Test
    func fenceAndTableStructureIsIdenticalEitherWay() async throws {
        let markdown = """
        ```swift
        let a = 1
        let b = 2
        ```

        | one | two |
        | --- | --- |
        | 1   | 2   |

        - first
        - second
        """

        let withBreaks = try await renderedContent(markdown, lineBreaks: true)
        let withoutBreaks = try await renderedContent(markdown, lineBreaks: false)

        #expect(withBreaks.contentHTML == withoutBreaks.contentHTML)
        #expect(withBreaks.breakCount == 0)
    }

    /// A newline *inside* a list item breaks too — and that is the point,
    /// not a leak.
    ///
    /// An agent writing a two-line bullet meant two lines. The block
    /// structure is still untouched: the `<ul>` and `<li>` boundaries are
    /// identical either way, and only the text inside one item gains a
    /// `<br>`. Asserted rather than assumed, because the sibling test's
    /// fixture cannot reach this case and its name used to imply it had.
    @Test
    func wrappedListItemsBreakToo() async throws {
        let markdown = """
        - first line
          continued line
        - second
        """

        let withBreaks = try await renderedContent(markdown, lineBreaks: true)
        let withoutBreaks = try await renderedContent(markdown, lineBreaks: false)

        #expect(withBreaks.breakCount == 1)
        #expect(withoutBreaks.breakCount == 0)
        // Structure identical, text inside one item not.
        #expect(withBreaks.contentHTML.contains("<li>first line<br>continued line</li>"))
        #expect(withoutBreaks.contentHTML.contains("<li>first line\ncontinued line</li>"))
    }

    /// The opt-in is **off** unless a call site asks for it.
    ///
    /// Kills the one cheap mutation the WebKit tests structurally cannot:
    /// flip `rendersLineBreaks`'s default to `true` and every other test in
    /// this repo stays green, because they all drive a bare `WKWebView` and
    /// never run `makeNSView`. The markdown *file* panel
    /// (`MarkdownPanelView.swift:98`) reaches the renderer through exactly
    /// this memberwise call with the argument omitted, so this asserts the
    /// real path rather than a literal.
    ///
    /// Its two siblings stay uncovered and that is stated, not hidden:
    /// dropping the `if rendersLineBreaks` guard in `makeNSView`, or the
    /// `rendersLineBreaks: true` argument in `ReplyPanelView.replyBody`,
    /// survives every automated test here. Nothing in `cmuxTests` constructs
    /// or hosts `ReplyPanelView`, and `replyBody` is private. Human
    /// Scenarios 6 and 8 are their only cover.
    @Test
    func theOptInIsOffForCallSitesThatDoNotAskForIt() {
        let renderer = MarkdownWebRenderer(
            markdown: "# Existing\n",
            theme: MarkdownWebTheme.resolve(backgroundColor: .windowBackgroundColor),
            backgroundColor: .windowBackgroundColor,
            isVisibleInUI: true,
            panelId: UUID(),
            workspaceId: UUID(),
            filePath: "",
            fontSize: 15,
            fontFamily: MarkdownFontFamily.systemDefault,
            maxContentWidth: MarkdownMaxWidthSettings.defaultCSSPixels,
            session: MarkdownRendererSession(),
            onRequestPanelFocus: {}
        )

        #expect(renderer.rendersLineBreaks == false)
    }

    // MARK: - Harness

    private func renderedContent(
        _ markdown: String,
        lineBreaks: Bool
    ) async throws -> RenderedContent {
        let configuration = WKWebViewConfiguration()
        if lineBreaks {
            configuration.userContentController.addUserScript(MarkdownWebRenderer.lineBreakScript)
        }

        let markdownURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-reply-line-break-\(UUID().uuidString).md")
        let frame = NSRect(x: 0, y: 0, width: 1_000, height: 600)
        let webView = WKWebView(frame: frame, configuration: configuration)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.orderFrontRegardless()
        defer {
            webView.navigationDelegate = nil
            window.close()
        }

        let loadDelegate = MarkdownReplyLineBreakLoadDelegate()
        webView.navigationDelegate = loadDelegate
        try await loadDelegate.load(
            MarkdownViewerAssets.shared.shellHTML(isDark: true),
            in: webView,
            baseURL: markdownURL
        )

        let data = try JSONSerialization.data(withJSONObject: [markdown])
        let literal = try #require(String(data: data, encoding: .utf8))
        let result = try await webView.evaluateJavaScript(
            """
            (function(md) {
              window.__cmuxRenderMarkdown(md);
              var content = document.getElementById('content');
              var paragraph = content && content.querySelector('p');
              return {
                contentHTML: content ? content.innerHTML : '',
                firstParagraphHTML: paragraph ? paragraph.innerHTML : '',
                breakCount: content ? content.querySelectorAll('br').length : -1
              };
            })(\(literal)[0]);
            """
        )
        let raw = try #require(result as? [String: Any])
        return RenderedContent(
            contentHTML: raw["contentHTML"] as? String ?? "",
            firstParagraphHTML: raw["firstParagraphHTML"] as? String ?? "",
            breakCount: raw["breakCount"] as? Int ?? -1
        )
    }
}

private struct RenderedContent {
    let contentHTML: String
    let firstParagraphHTML: String
    let breakCount: Int
}

private final class MarkdownReplyLineBreakLoadDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ html: String, in webView: WKWebView, baseURL: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(.failure(error))
    }
}
