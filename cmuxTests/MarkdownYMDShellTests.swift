import AppKit
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Everything the bun suite structurally cannot reach: the bun tests see
/// `marked.parse` output before `sanitizeRenderedHTML` runs, heading ids come
/// from the shell's own renderer rather than from `marked`, and the appearance
/// chain only exists in a real `WKWebView`.
@MainActor
@Suite
final class MarkdownYMDShellTests {
    /// Scenario 8 — closes the silent-failure mode where
    /// `String.replacingOccurrences` on a renamed needle is a no-op and the
    /// feature ships dead with every other test green.
    @Test
    func builtShellResolvesEveryPlaceholder() throws {
        let shell = MarkdownViewerAssets.shared.shellHTML(isDark: true)
        #expect(!shell.contains("{{"))
        // Positive control: assert the module actually landed, so this test
        // cannot pass by the shell having lost the ymd script block entirely.
        #expect(shell.contains("cmux-ymd:begin"))
        #expect(shell.contains("CmuxYMD"))
    }

    /// Guards finding #7 at the only layer that can see it. The bun tests call
    /// `install` themselves, so they stay green against a module that never
    /// arms; only the real shell proves the pass is actually wired in.
    @Test
    func theModuleArmsItselfInTheRealShell() async throws {
        try await withLoadedMarkdownShell { webView in
            let armed = try await webView.evaluateJavaScript(
                "(function(){ return !!(window.CmuxYMD && window.CmuxYMD.armed); })();"
            )
            #expect(armed as? Bool == true)
        }
    }

    /// Scenario 9, first half — a highlight survives `sanitizeRenderedHTML`, which
    /// strips `style` and `data-cmux-*` but passes `class` and `<span>`.
    @Test
    func highlightSurvivesTheSanitizer() async throws {
        try await withLoadedMarkdownShell { webView in
            let snapshot = try await renderYMDSnapshot("- **Status:** **🟢`PASS`**", in: webView)
            #expect(snapshot.highlightText == "PASS")
            #expect(snapshot.highlightClass == "ymd-highlight ymd-highlight-green")
            #expect(snapshot.bodyText.contains("🟢") == false)
        }
    }

    /// Scenario 9, second half — the reason headings conceal without a highlight.
    /// The shell derives each heading id from `raw`, a plain-text projection
    /// that does not cover extension tokens, so concealment must leave ids
    /// untouched or `#anchor` links and scroll-restore break.
    @Test
    func headingIdsAreUnchangedByThePass() async throws {
        let fixture = """
        # 🔵 Overview
        ## 🟠⋯ Section
        ### 🟢 `CODE` heading
        #### Plain heading
        ## 🟠⋯ Section
        ## Duplicate
        ## Duplicate
        # 🟣 Deep
        """

        let withYMD = try await headingIDs(rendering: fixture, ymdEnabled: true)
        let withoutYMD = try await headingIDs(rendering: fixture, ymdEnabled: false)

        #expect(withYMD.count == 8)
        #expect(withYMD == withoutYMD)
        // De-duplication must still be exercised, or this proves nothing about
        // the interesting case.
        #expect(Set(withYMD).count == withYMD.count)
    }

    /// Scenario 12 — a plain code span is quieter than upstream's, and a highlight
    /// still wins over it. The highlight rule and the panel's override have identical
    /// specificity (`.ymd-highlight code` vs `.markdown-body code`, both 0-1-1), so
    /// only source order separates them: ymd.js appends its palette to
    /// document.head after the shell's inline <style>. If that order ever flips,
    /// every highlight silently renders grey with the class still correct — which no
    /// class-level assertion anywhere in this suite would notice.
    @Test
    func plainCodeIsQuieterThanAHighlightAndTheHighlightStillWins() async throws {
        try await withLoadedMarkdownShell(appearance: .aqua) { webView in
            let result = try await webView.evaluateJavaScript(
                """
                (function() {
                  window.__cmuxRenderMarkdown(
                    'plain `code` here\\n\\n- **S:** **\\u{1F534}`FAIL`**');
                  var plain = document.querySelector('#content p code');
                  var highlight = document.querySelector('.ymd-highlight-red code');
                  if (!plain || !highlight) { return null; }
                  var p = getComputedStyle(plain).backgroundColor;
                  var m = p.match(/rgba?\\(([^)]+)\\)/);
                  var parts = m ? m[1].split(',').map(function(x){ return parseFloat(x); }) : [];
                  return {
                    plainRGB: parts.slice(0, 3).join(','),
                    plainAlpha: parts.length > 3 ? parts[3] : 1,
                    highlight: getComputedStyle(highlight).backgroundColor
                  };
                })();
                """
            )
            let raw = try #require(result as? [String: Any], "missing a plain span or a highlight")
            // Assert the intent, not the serialization: WebKit rounds the alpha
            // for display (0x26/255 = 0.149 prints as 0.15), so pinning the
            // string makes this fail on a rendering-engine detail rather than on
            // the styling. What must hold is that the overlay is GitHub's grey
            // at meaningfully less than its stock 20%.
            #expect(raw["plainRGB"] as? String == "175,184,193")
            let alpha = try #require(raw["plainAlpha"] as? Double)
            #expect(alpha < 0.18, "inline code is not quieter than upstream's 20%")
            #expect(alpha > 0.10, "inline code has faded to the point of not reading as code")
            // The highlight is unaffected: opaque palette background, still winning.
            #expect(raw["highlight"] as? String == "rgb(255, 205, 210)")
        }
    }

    /// Scenario 11 — the heading tint, at the only layer that can disprove it.
    ///
    /// `decorateHeading` is a pure function the bun suite calls directly, so all
    /// thirteen of those tests stay green against a shell whose heading renderer
    /// never calls it — the same failure shape as `install()` being defined and
    /// never invoked. This test fails if the hook is unwired, if the sanitizer
    /// strips `class` from an `<hN>`, or if the tint eats the heading's link.
    @Test
    func headingTintSurvivesTheSanitizerAndSparesLinks() async throws {
        try await withLoadedMarkdownShell(appearance: .aqua) { webView in
            let result = try await webView.evaluateJavaScript(
                """
                (function() {
                  window.__cmuxRenderMarkdown(
                    '## \\u{1F7E0}\\u22EF Section with [a link](https://example.com)');
                  var h = document.querySelector('#content h2');
                  if (!h) { return null; }
                  var a = h.querySelector('a');
                  return {
                    cls: h.getAttribute('class'),
                    id: h.id,
                    text: h.textContent,
                    headingColor: getComputedStyle(h).color,
                    linkColor: a ? getComputedStyle(a).color : null
                  };
                })();
                """
            )
            let raw = try #require(result as? [String: Any], "no <h2> rendered")
            #expect(raw["cls"] as? String == "ymd-head-orange")
            // Concealment must not have moved the anchor id.
            #expect(raw["id"] as? String == "section-with-a-link")
            let text = try #require(raw["text"] as? String)
            #expect(!text.contains("🟠"))
            #expect(text.hasPrefix("⋯ Section"))
            // ymd.rs foreground() orange, light appearance.
            #expect(raw["headingColor"] as? String == "rgb(230, 81, 0)")
            // The link keeps GitHub's accent rather than inheriting the tint. A
            // 🔵 heading would otherwise erase the link affordance outright,
            // which is the defect that ended line-tinting.
            #expect(raw["linkColor"] as? String == "rgb(9, 105, 218)")
        }
    }

    /// Scenario 10 — the whole appearance chain (`NSAppearance` →
    /// `prefers-color-scheme` → cascade), which no text-level test can reach.
    @Test
    func lightAndDarkResolveToDifferentComputedColors() async throws {
        let light = try await computedHighlightStyle(appearance: .aqua)
        #expect(light.background == "rgb(255, 205, 210)")
        #expect(light.foreground == "rgb(26, 26, 26)")

        let dark = try await computedHighlightStyle(appearance: .darkAqua)
        #expect(dark.background == "rgb(92, 58, 58)")
        #expect(dark.foreground == "rgb(224, 222, 244)")
    }

    // MARK: - Helpers

    /// Renders `fixture` and returns every heading id in document order.
    ///
    /// The `ymdEnabled: false` arm is the control for
    /// `headingIdsAreUnchangedByThePass`. `shellHTML(isDark:)` always
    /// substitutes every placeholder, so the control is built by stripping the
    /// module between its sentinels — and then *asserting* the strip worked,
    /// because a control that still ran ymd makes the comparison vacuous.
    private func headingIDs(rendering fixture: String, ymdEnabled: Bool) async throws -> [String] {
        var shell = MarkdownViewerAssets.shared.shellHTML(isDark: true)
        if !ymdEnabled {
            let begin = try #require(shell.range(of: "/* cmux-ymd:begin"))
            let end = try #require(shell.range(of: "/* cmux-ymd:end */"))
            shell.replaceSubrange(begin.lowerBound..<end.upperBound, with: "")
            // Assert the module is gone, not that its *name* is. The heading
            // renderer reaches CmuxYMD through a `typeof` guard and lives
            // outside the sentinels, so the name legitimately survives the strip
            // while the module does not — and the guard makes what is left
            // inert. Testing for the bare name instead made this fail the moment
            // a caller appeared, which is a false negative, not a real control
            // failure. `MAX_YMD_HIGHLIGHT_BYTES` is module body and nothing else.
            #expect(!shell.contains("MAX_YMD_HIGHLIGHT_BYTES"),
                    "control arm still contains the ymd module")
            #expect(!shell.contains("cmux-ymd:begin"))
            // Whatever mentions of the name survive must be guarded, or the
            // control arm would throw on a missing global instead of degrading.
            #expect(!shell.contains("CmuxYMD.decorateHeading(")
                    || shell.contains("typeof CmuxYMD !== 'undefined'"))
        }

        return try await withLoadedMarkdownShell(shell: shell) { webView in
            let armed = try await webView.evaluateJavaScript(
                "(function(){ return !!(window.CmuxYMD && window.CmuxYMD.armed); })();"
            )
            #expect(armed as? Bool == ymdEnabled, "control arm armed state is wrong")

            let data = try JSONSerialization.data(withJSONObject: [fixture])
            let literal = try #require(String(data: data, encoding: .utf8))
            let result = try await webView.evaluateJavaScript(
                """
                (function(md) {
                  window.__cmuxRenderMarkdown(md);
                  return Array.prototype.map.call(
                    document.querySelectorAll('#content h1,#content h2,#content h3,#content h4'),
                    function(h) { return h.id; }
                  );
                })(\(literal)[0]);
                """
            )
            return try #require(result as? [String])
        }
    }

    private func computedHighlightStyle(appearance: NSAppearance.Name) async throws -> HighlightStyle {
        try await withLoadedMarkdownShell(appearance: appearance) { webView in
            let result = try await webView.evaluateJavaScript(
                """
                (function() {
                  window.__cmuxRenderMarkdown('- **Status:** **\\u{1F534}`FAIL`**');
                  var el = document.querySelector('.ymd-highlight-red code');
                  if (!el) { return null; }
                  var s = getComputedStyle(el);
                  return { background: s.backgroundColor, foreground: s.color };
                })();
                """
            )
            let raw = try #require(result as? [String: Any], "no .ymd-highlight-red code element rendered")
            return HighlightStyle(
                background: try #require(raw["background"] as? String),
                foreground: try #require(raw["foreground"] as? String)
            )
        }
    }

    private func renderYMDSnapshot(_ markdown: String, in webView: WKWebView) async throws -> YMDSnapshot {
        let data = try JSONSerialization.data(withJSONObject: [markdown])
        let literal = try #require(String(data: data, encoding: .utf8))
        let result = try await webView.evaluateJavaScript(
            """
            (function(md) {
              window.__cmuxRenderMarkdown(md);
              var highlight = document.querySelector('.ymd-highlight code');
              return {
                highlightText: highlight && highlight.textContent,
                highlightClass: highlight && highlight.parentElement.getAttribute('class'),
                bodyText: document.getElementById('content').textContent
              };
            })(\(literal)[0]);
            """
        )
        let raw = try #require(result as? [String: Any])
        return YMDSnapshot(
            highlightText: raw["highlightText"] as? String,
            highlightClass: raw["highlightClass"] as? String,
            bodyText: raw["bodyText"] as? String ?? ""
        )
    }

    private func withLoadedMarkdownShell<T>(
        shell: String? = nil,
        appearance: NSAppearance.Name? = nil,
        _ body: (WKWebView) async throws -> T
    ) async throws -> T {
        let markdownURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-markdown-ymd-\(UUID().uuidString).md")
        let frame = NSRect(x: 0, y: 0, width: 1_000, height: 600)
        let webView = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
        if let appearance {
            webView.appearance = NSAppearance(named: appearance)
        }
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFrontRegardless()
        defer {
            webView.navigationDelegate = nil
            window.close()
        }

        let loadDelegate = MarkdownYMDShellLoadDelegate()
        webView.navigationDelegate = loadDelegate
        try await loadDelegate.load(
            shell ?? MarkdownViewerAssets.shared.shellHTML(isDark: appearance == .darkAqua),
            in: webView,
            baseURL: markdownURL
        )
        return try await body(webView)
    }
}

private struct YMDSnapshot {
    let highlightText: String?
    let highlightClass: String?
    let bodyText: String
}

private struct HighlightStyle {
    let background: String
    let foreground: String
}

private final class MarkdownYMDShellLoadDelegate: NSObject, WKNavigationDelegate {
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

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }
}
