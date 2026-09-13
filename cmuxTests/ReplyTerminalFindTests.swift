import AppKit
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `#cm-89` — the page finds a phrase the terminal showed and publishes it
/// through the same path a hand drag uses.
///
/// **Installs the shipped `selectionObserverScript`, never a copy** — the same
/// rule `MarkdownReplyLineBreakTests` states for its script: a hand-copied
/// literal would keep passing after the real one drifted.
///
/// What a test here observes is the message the page posts on `cmuxLib`,
/// because that is the only thing the Reply view ever sees: `quote`, `start`,
/// `end`. The find's own return value is checked alongside, since the view
/// shows `Not in the newest message` on anything but `"published"`.
@MainActor
@Suite
final class ReplyTerminalFindTests {
    /// (a) A phrase inside one paragraph: offsets count displayed characters.
    @Test
    func findsAPhraseAndPostsItsOffsets() async throws {
        let outcome = try await find("quick brown", in: "The quick brown fox")

        #expect(outcome.result == "published")
        #expect(outcome.posted?.quote == "quick brown")
        #expect(outcome.posted?.start == 4)
        #expect(outcome.posted?.end == 15)
    }

    /// (b) The terminal's wrap arrives as a newline plus indent; the page has
    /// one space. This is the **needle** side of the collapse — the page here
    /// already has single spaces, so (b') below is what covers the page side.
    @Test
    func aWrappedTerminalSelectionMatchesThePagesSingleSpace() async throws {
        let outcome = try await find("quick\n    brown", in: "The quick brown fox")

        #expect(outcome.result == "published")
        #expect(outcome.posted?.start == 4)
        #expect(outcome.posted?.end == 15)
    }

    /// (b') The reverse: the page has a line break where the needle has a space.
    @Test
    func thePagesLineBreakMatchesASpaceInTheNeedle() async throws {
        let outcome = try await find("line continued", in: "first line\ncontinued here")

        #expect(outcome.result == "published")
        #expect(outcome.posted?.start == 6)
        #expect(outcome.posted?.end == 20)
    }

    /// (c) Several matches: the first one wins.
    @Test
    func theFirstOfSeveralMatchesWins() async throws {
        let outcome = try await find("fox", in: "one fox, two fox")

        #expect(outcome.result == "published")
        #expect(outcome.posted?.start == 4)
        #expect(outcome.posted?.end == 7)
    }

    /// (d) The reasoning disclosure is not the answer. **The case that bites
    /// is the same words in both** — an agent's reasoning often previews the
    /// sentence it then writes. Searching the disclosure too would match its
    /// copy first, `publish` would refuse a selection with no annotatable
    /// text, and the real phrase in the answer would never be tried.
    ///
    /// A phrase that exists *only* in the disclosure cannot test this:
    /// `publish` refuses it either way. Measured by mutation 2026-09-13.
    /// Markup copied from `ReplyMessageGroup.renderedMarkdown(thinkingLabel:)`.
    @Test
    func aPhraseAlsoInTheThinkingDisclosureIsFoundInTheAnswer() async throws {
        let markdown = """
        <details class="cmux-reply-thinking">
        <summary>Show thinking</summary>

        I should rename the helper first.

        </details>

        Then rename the helper first.
        """
        let outcome = try await find("rename the helper first", in: markdown)

        #expect(outcome.result == "published")
        #expect(outcome.posted?.quote == "rename the helper first")
    }

    /// (e) A code block's `Copy` button is chrome, not message text — the same
    /// shape as (d). The paragraph after the block starts with `the`, so a
    /// search that read the button would match `Copy` + `the` across the two
    /// and quote only `the`. The first version of this fixture put `Copy the`
    /// straight after the button, which both versions matched identically —
    /// caught by mutation 2026-09-13.
    @Test
    func aWordAlsoOnACopyButtonIsFoundInTheAnswer() async throws {
        let markdown = "```swift\nlet value = 1\n```\n\nthe file, then Copy the file"
        let outcome = try await find("Copy the", in: markdown)

        // The fixture is only meaningful if the shell really drew the button.
        #expect(outcome.copyButtons == 1)
        #expect(outcome.result == "published")
        #expect(outcome.posted?.quote == "Copy the")
    }

    /// (f) A phrase inside `<strong>` quotes as markdown, exactly as a hand
    /// drag would.
    @Test
    func aPhraseInBoldQuotesAsMarkdown() async throws {
        let outcome = try await find("very important", in: "This is **very important** now")

        #expect(outcome.result == "published")
        #expect(outcome.posted?.quote == "**very important**")
    }

    @Test
    func absentTextIsNotFound() async throws {
        let outcome = try await find("nowhere to be seen", in: "The quick brown fox")

        #expect(outcome.result == "notFound")
        #expect(outcome.posted == nil)
    }

    // MARK: - Harness

    private func find(_ needle: String, in markdown: String) async throws -> FindOutcome {
        let recorder = ReplyTerminalFindRecorder()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(recorder, name: "cmuxLib")
        configuration.userContentController.addUserScript(MarkdownWebRenderer.selectionObserverScript)

        let markdownURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-reply-find-\(UUID().uuidString).md")
        let frame = NSRect(x: 0, y: 0, width: 1_000, height: 600)
        let webView = WKWebView(frame: frame, configuration: configuration)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFrontRegardless()
        defer {
            webView.navigationDelegate = nil
            configuration.userContentController.removeScriptMessageHandler(forName: "cmuxLib")
            window.close()
        }

        let loader = ReplyTerminalFindLoadDelegate()
        webView.navigationDelegate = loader
        try await loader.load(MarkdownViewerAssets.shared.shellHTML(isDark: true), in: webView, baseURL: markdownURL)

        let data = try JSONSerialization.data(withJSONObject: [markdown, needle])
        let literal = try #require(String(data: data, encoding: .utf8))
        let result = try await webView.evaluateJavaScript(
            """
            (function(args) {
              window.__cmuxRenderMarkdown(args[0]);
              var buttons = document.querySelectorAll('.cmux-code-copy-button').length;
              return { result: window.__cmuxReplyFind(args[1]), copyButtons: buttons };
            })(\(literal));
            """
        )
        // Messages from the page arrive on a later main-queue turn.
        for _ in 0..<20 where recorder.selection == nil {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let raw = result as? [String: Any]
        return FindOutcome(
            result: raw?["result"] as? String,
            copyButtons: raw?["copyButtons"] as? Int ?? -1,
            posted: recorder.selection
        )
    }
}

private struct FindOutcome {
    let result: String?
    let copyButtons: Int
    let posted: PostedSelection?
}

private struct PostedSelection {
    let quote: String
    let start: Int
    let end: Int
}

private final class ReplyTerminalFindRecorder: NSObject, WKScriptMessageHandler {
    var selection: PostedSelection?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              body["action"] as? String == "replySelectionChanged",
              let quote = body["quote"] as? String,
              let start = body["start"] as? Int,
              let end = body["end"] as? Int else { return }
        selection = PostedSelection(quote: quote, start: start, end: end)
    }
}

private final class ReplyTerminalFindLoadDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ html: String, in webView: WKWebView, baseURL: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
