import AppKit
import SwiftUI
import WebKit

struct MarkdownWebRenderer: NSViewRepresentable {
    static let localImageURLScheme = "cmux-local-image"
    static let remoteImageURLScheme = "cmux-remote-image"

    let markdown: String
    let theme: MarkdownWebTheme
    let backgroundColor: NSColor
    let panelId: UUID
    let workspaceId: UUID
    let filePath: String
    /// Body font size in points, applied as `pageZoom` and to shell-managed SVG zoom.
    let fontSize: Double
    /// Body prose font-family name (empty = System). Applied as an inline
    /// `font-family` on the content.
    let fontFamily: String
    /// Maximum content column width, in CSS pixels.
    let maxContentWidth: Double

    /// Horizontal padding for the rendered page, in CSS pixels, or `nil` to
    /// leave the shell's own.
    ///
    /// The shell hardcodes 28px and says it does so "while still letting the
    /// panel use full width on narrow splits" — but it is fixed at every
    /// width, so that intent was never implemented. At a 900pt viewer 28px is
    /// a reading margin; in a 276pt sidebar it is a fifth of the panel, and it
    /// leaves the body text visibly out of line with the chrome above it.
    /// Default `nil` so every existing caller renders exactly as before.
    var horizontalPagePadding: Double?
    let session: MarkdownRendererSession
    let onRequestPanelFocus: () -> Void

    /// Reports the page's current text selection, or `nil` when it collapses.
    ///
    /// Opt-in, and `nil` for every existing caller so the markdown file panel
    /// renders exactly as before — the same shape `horizontalPagePadding`
    /// uses above. The Reply panel owns its own ``MarkdownRendererSession``,
    /// so the observing script cannot reach any other renderer's page.
    ///
    /// **Installed at first creation only.** `addUserScript` applies from the
    /// next document load, and the coordinator is cached per session, so a
    /// caller that starts `nil` and becomes non-`nil` later gets no script.
    /// Every caller today is one or the other for its whole life.
    var onSelectionChanged: ((MarkdownPageSelection?) -> Void)?

    /// Reports which mark the pointer is over, or `nil` when it leaves them.
    ///
    /// Hover has to colour the phrase *and* its footer row together, and only
    /// the page knows the pointer is over a phrase.
    var onMarkHoverChanged: ((UUID?) -> Void)?

    /// The marks the page should be painting right now.
    ///
    /// Pushed rather than pulled: the annotation set is the source of truth
    /// and the page is a rendering of it, so there is no page-side list that
    /// could drift from the footer's.
    var marks: [MarkdownPageMark] = []

    /// The mark to colour as active, from hovering its footer row.
    var activeMarkID: UUID?

    func makeCoordinator() -> Coordinator {
        session.coordinator(panelId: panelId, workspaceId: workspaceId, filePath: filePath)
    }

    func makeNSView(context: Context) -> WKWebView {
        if let webView = context.coordinator.webView {
            if webView.superview != nil {
                webView.removeFromSuperview()
            }
            webView.onPointerDown = onRequestPanelFocus
            webView.onLeaveWindow = { [weak coordinator = context.coordinator] in
                coordinator?.handleViewLeftWindow()
            }
            webView.onReenterWindow = { [weak coordinator = context.coordinator] in
                coordinator?.handleViewReenteredWindow()
            }
            webView.navigationDelegate = context.coordinator
            webView.uiDelegate = context.coordinator
            applyBackground(to: webView)
            applyAppearance(to: webView, isDark: theme.isDark)
            context.coordinator.setFontSize(fontSize)
            context.coordinator.setFontFamily(fontFamily)
            context.coordinator.setMaxContentWidth(maxContentWidth)
            context.coordinator.setHorizontalPagePadding(horizontalPagePadding)
            context.coordinator.setSelectionObserver(onSelectionChanged)
            context.coordinator.setMarkHoverObserver(onMarkHoverChanged)
            context.coordinator.setMarks(marks)
            context.coordinator.setActiveMark(activeMarkID)
            return webView
        }

        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        // Bridge: JS posts to `cmuxLib` to request lazy-loaded libraries
        // (mermaid / vega-lite). Swift fetches the bundled source from the
        // app bundle and injects it via evaluateJavaScript.
        config.userContentController.add(WeakMarkdownScriptMessageHandler(context.coordinator), name: "cmuxLib")
        config.setURLSchemeHandler(
            context.coordinator,
            forURLScheme: Self.localImageURLScheme
        )
        config.setURLSchemeHandler(
            context.coordinator,
            forURLScheme: Self.remoteImageURLScheme
        )
        if onSelectionChanged != nil {
            config.userContentController.addUserScript(Self.selectionObserverScript)
        }
        let webView = MarkdownWebView(frame: .zero, configuration: config)
        context.coordinator.setSelectionObserver(onSelectionChanged)
        webView.onPointerDown = onRequestPanelFocus
        webView.onLeaveWindow = { [weak coordinator = context.coordinator] in
            coordinator?.handleViewLeftWindow()
        }
        webView.onReenterWindow = { [weak coordinator = context.coordinator] in
            coordinator?.handleViewReenteredWindow()
        }
        webView.setValue(false, forKey: "drawsBackground")
        applyBackground(to: webView)
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        if #available(macOS 13.3, *) {
#if DEBUG
            webView.isInspectable = true
#else
            webView.isInspectable = false
#endif
        }
        applyAppearance(to: webView, isDark: theme.isDark)

        context.coordinator.webView = webView
        context.coordinator.setFontSize(fontSize)
        context.coordinator.setFontFamily(fontFamily)
        context.coordinator.setMaxContentWidth(maxContentWidth)
            context.coordinator.setHorizontalPagePadding(horizontalPagePadding)
        context.coordinator.loadShell(theme: theme, initialMarkdown: markdown)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Re-bind panel metadata in case SwiftUI recreated the wrapper while
        // the panel-owned renderer session kept the same coordinator.
        context.coordinator.bind(panelId: panelId, workspaceId: workspaceId, filePath: filePath)
        (nsView as? MarkdownWebView)?.onPointerDown = onRequestPanelFocus
        applyBackground(to: nsView)
        applyAppearance(to: nsView, isDark: theme.isDark)
        context.coordinator.setFontSize(fontSize)
        context.coordinator.setFontFamily(fontFamily)
        context.coordinator.setMaxContentWidth(maxContentWidth)
            context.coordinator.setHorizontalPagePadding(horizontalPagePadding)
        context.coordinator.setSelectionObserver(onSelectionChanged)
        context.coordinator.setMarkHoverObserver(onMarkHoverChanged)
        // After the markdown, never before: a repaint wraps spans around
        // text the render is about to replace.
        context.coordinator.update(markdown: markdown, theme: theme)
        context.coordinator.setMarks(marks)
        context.coordinator.setActiveMark(activeMarkID)
    }

    /// Watches the page's selection, paints the marks, and reports hover —
    /// all over the existing `cmuxLib` channel.
    ///
    /// Injected rather than added to `shell.html`: that file is shared with
    /// every markdown viewer in the app and re-opens `#cm-15`'s two human
    /// checks whenever it is touched, so the Reply panel earns its selection
    /// without editing it. `installEditableFocusTracking` in
    /// `MarkdownWebSupport` is the same move for the same reason.
    ///
    /// `selectionchange` is the event that actually covers every path —
    /// dragging, double-click, keyboard extension, and select-all — while
    /// `mouseup` alone misses the last three. It fires continuously during a
    /// drag, so the last published value is held and duplicates dropped:
    /// without that, one drag across a paragraph posts a message per frame.
    ///
    /// **Offsets are into the concatenated rendered text nodes, and the quote
    /// is `markdownOf(range)` — deliberately two different strings.** The
    /// quote is the markdown behind what the user saw, so it carries marks
    /// the offsets never counted; the offsets only have to order marks and
    /// detect overlap, and they do that in their own coordinate space.
    /// Wrapping a mark in a `<span>` adds no characters, so painting never
    /// moves an offset.
    ///
    /// `selection.toString()` still decides *whether* there is a selection at
    /// all — it is cheap, and whitespace-only reads the same either way.
    ///
    /// **The numeral is CSS-generated content, and that is load-bearing.**
    /// `content: attr(data-cmux-num)` keeps it out of `textContent`, so a
    /// numeral cannot shift the offsets of everything after it. It also
    /// cannot be forged: the shell strips every `data-cmux-*` attribute from
    /// markdown-sourced HTML (`shell.html:973`), and this script runs after
    /// that, so only cmux can put a number on the page.
    private static let selectionObserverScript = WKUserScript(
        source: """
        (() => {
          const handler = window.webkit?.messageHandlers?.cmuxLib;
          if (!handler) return;
          const MARK = "cmux-reply-mark";
          const root = () => document.getElementById("content");

          const style = document.createElement("style");
          style.textContent = `
            .${MARK} {
              background: color-mix(in srgb, var(--cmuxAccent, #0a84ff) 20%, transparent);
              border-radius: 2px;
              padding: 0 1px;
            }
            .${MARK}[data-cmux-num]::after {
              content: attr(data-cmux-num);
              font-size: 8px;
              font-weight: 600;
              vertical-align: super;
              margin-left: 1px;
              color: var(--cmuxAccent, #0a84ff);
            }
            /* **The only distinction a mark carries, now that the outline
               and the underline are gone.** Tone alone says *this is the one
               in focus* — hovered, or open in the footer's field. A border
               made every unwritten span read as an error, and there were
               usually several at once. */
            .${MARK}[data-cmux-active="1"] {
              background: var(--cmuxAccentHover, rgba(139, 92, 246, 0.28));
              color: var(--cmuxOnAccentHover, #fff);
            }
            /* One hue at a time: the numeral follows the wash it sits in. */
            .${MARK}[data-cmux-active="1"][data-cmux-num]::after { color: inherit; }
          `;
          document.head.appendChild(style);

          // Every text node a mark may cover. The reasoning disclosure is
          // excluded: it is shown and deliberately not annotatable, so a
          // selection inside it must not become an anchor.
          const textNodes = () => {
            const container = root();
            if (!container) return [];
            const walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT, {
              acceptNode(node) {
                if (!node.nodeValue) return NodeFilter.FILTER_REJECT;
                let el = node.parentElement;
                while (el && el !== container) {
                  if (el.classList && el.classList.contains("cmux-reply-thinking")) {
                    return NodeFilter.FILTER_REJECT;
                  }
                  // Page chrome, not message text. The code block's `Copy`
                  // button lives inside the block, so its label was landing
                  // in the middle of a quoted snippet *and* consuming
                  // offsets, which shifts every mark after it.
                  if (el.nodeName === "BUTTON" || el.getAttribute("aria-hidden") === "true") {
                    return NodeFilter.FILTER_REJECT;
                  }
                  el = el.parentElement;
                }
                return NodeFilter.FILTER_ACCEPT;
              }
            });
            const out = [];
            let total = 0;
            while (walker.nextNode()) {
              out.push({ node: walker.currentNode, start: total });
              total += walker.currentNode.nodeValue.length;
            }
            return out;
          };

          const unpaint = () => {
            const container = root();
            if (!container) return;
            container.querySelectorAll("." + MARK).forEach((span) => {
              const parent = span.parentNode;
              if (!parent) return;
              while (span.firstChild) parent.insertBefore(span.firstChild, span);
              parent.removeChild(span);
            });
            // Merges the text nodes a previous paint split, so the next
            // offset walk sees the same character sequence it did the first
            // time.
            container.normalize();
          };

          const wrap = (mark) => {
            // The node list is rebuilt per mark because splitting a text node
            // invalidates the entries after it. At the note counts this
            // panel holds, correctness beats the walk it saves.
            const pieces = [];
            for (const entry of textNodes()) {
              const length = entry.node.nodeValue.length;
              const from = Math.max(mark.start, entry.start);
              const to = Math.min(mark.end, entry.start + length);
              if (from >= to) continue;
              // Whitespace between blocks is in the offset space but must
              // not be painted. A selection spanning two paragraphs covers
              // the newline nodes between them, and wrapping those drew a
              // thin coloured sliver on an otherwise empty line — invisible
              // while the mark was a 28% wash, obvious the moment the fill
              // went opaque (Tom, dogfood 2026-09-07).
              //
              // Skipped at *paint* time, deliberately not excluded from
              // `textNodes()`: the walk defines the offset coordinate space,
              // and dropping nodes from it would move every offset after
              // them and invalidate marks already recorded.
              if (!entry.node.nodeValue.slice(from - entry.start, to - entry.start).trim()) continue;
              pieces.push({ node: entry.node, from: from - entry.start, to: to - entry.start });
            }
            pieces.forEach((piece, index) => {
              let target = piece.node;
              if (piece.to < target.nodeValue.length) target.splitText(piece.to);
              if (piece.from > 0) target = target.splitText(piece.from);
              const span = document.createElement("span");
              span.className = MARK;
              span.setAttribute("data-cmux-id", mark.id);
              // The numeral sits immediately after the phrase, so only the
              // last piece of a mark spanning several nodes carries it.
              if (index === pieces.length - 1) span.setAttribute("data-cmux-num", mark.number);
              const parent = target.parentNode;
              if (!parent) return;
              parent.replaceChild(span, target);
              span.appendChild(target);
            });
          };

          window.__cmuxReplyPaint = (marks) => {
            unpaint();
            // Applied newest offset first so an earlier mark's coordinates
            // are still the ones the walk just measured.
            [...marks].sort((a, b) => b.start - a.start).forEach(wrap);
            // The transient selection has done its job; the mark is the
            // durable thing now. Dropping it deliberately is also what the
            // design asks for — the caret moves to the note field, the
            // browser selection collapses, and the highlight must not go
            // with it. Leaving it live instead lets the next frame re-report
            // a selection whose nodes this paint just replaced.
            if (marks.length) {
              last = null;
              const selection = window.getSelection();
              if (selection) selection.removeAllRanges();
            }
          };

          window.__cmuxReplyActivate = (id) => {
            const container = root();
            if (!container) return;
            container.querySelectorAll("." + MARK).forEach((span) => {
              if (id && span.getAttribute("data-cmux-id") === id) {
                span.setAttribute("data-cmux-active", "1");
              } else {
                span.removeAttribute("data-cmux-active");
              }
            });
          };

          let last = null;
          // **The quote is markdown, re-emitted from the DOM.**
          //
          // `selection.toString()` returns what the page *shows*, so
          // `**highlight**` arrived as `highlight`, `` `inline code` `` lost
          // its ticks, a link lost its href, and a fenced block arrived as
          // bare lines the agent cannot tell from prose — with the `Copy`
          // button's label sitting in the middle of it (Tom, dogfood
          // 2026-09-06). The agent wrote markdown; quoting anything else asks
          // it to re-derive its own source.
          //
          // Offsets stay in the rendered coordinate space — they only order
          // marks and detect overlap, and the doc comment above says so.
          // Only the quote changes.
          const PLAIN_SKIP = { BUTTON: 1 };
          const plain = (n) => {
            if (n.nodeType === 3) return n.nodeValue;
            if (n.nodeType !== 1 || PLAIN_SKIP[n.nodeName]) return "";
            return Array.from(n.childNodes).map(plain).join("");
          };
          const longestRun = (body) => (body.match(/`+/g) || [])
            .reduce((m, r) => Math.max(m, r.length), 0);

          const emit = (node) => {
            if (node.nodeType === 3) return node.nodeValue;
            if (node.nodeType !== 1) return "";
            const tag = node.nodeName.toLowerCase();
            if (node.nodeName === "BUTTON" || node.getAttribute("aria-hidden") === "true") return "";
            if (node.classList && node.classList.contains("cmux-reply-thinking")) return "";
            const kids = () => Array.from(node.childNodes).map(emit).join("");
            switch (tag) {
              case "strong": case "b": return "**" + kids() + "**";
              case "em": case "i": return "*" + kids() + "*";
              case "del": case "s": return "~~" + kids() + "~~";
              case "br": return "\\n";
              case "a": {
                const href = node.getAttribute("href");
                const label = kids();
                return href ? "[" + label + "](" + href + ")" : label;
              }
              case "code": {
                // Inside a fence the ticks belong to the fence, not the span.
                if (node.parentElement && node.parentElement.nodeName === "PRE") return kids();
                const body = kids();
                const tick = "`".repeat(longestRun(body) + 1);
                return tick + body + tick;
              }
              case "pre": {
                const code = node.querySelector("code");
                const cls = (code && code.className) || "";
                const lang = (cls.match(/language-([\\w-]+)/) || [])[1] || "";
                const body = plain(code || node).replace(/\\n+$/, "");
                const fence = "`".repeat(Math.max(3, longestRun(body) + 1));
                return "\\n\\n" + fence + lang + "\\n" + body + "\\n" + fence + "\\n\\n";
              }
              case "li": return "\\n- " + kids().trim();
              case "blockquote":
                return "\\n\\n" + kids().trim().split("\\n").map((l) => "> " + l).join("\\n") + "\\n\\n";
              case "h1": case "h2": case "h3": case "h4": case "h5": case "h6":
                return "\\n\\n" + "#".repeat(Number(tag[1])) + " " + kids().trim() + "\\n\\n";
              case "p": case "div": case "ul": case "ol": case "table": case "tr":
                return "\\n\\n" + kids() + "\\n\\n";
              default: return kids();
            }
          };

          // `cloneContents` drops the ancestors the selection started inside,
          // so a drag that begins mid-`<strong>` would lose its markers. Put
          // the inline ones back before serializing.
          const INLINE_WRAP = { STRONG: 1, B: 1, EM: 1, I: 1, CODE: 1, A: 1, DEL: 1, S: 1 };
          const markdownOf = (range) => {
            let frag = range.cloneContents();
            let node = range.commonAncestorContainer;
            if (node.nodeType === 3) node = node.parentElement;
            const container = root();
            while (node && node !== container) {
              if (INLINE_WRAP[node.nodeName]) {
                const wrap = node.cloneNode(false);
                wrap.appendChild(frag);
                frag = document.createDocumentFragment();
                frag.appendChild(wrap);
              }
              node = node.parentElement;
            }
            const holder = document.createElement("div");
            holder.appendChild(frag);
            return emit(holder).replace(/[ \\t]+\\n/g, "\\n").replace(/\\n{3,}/g, "\\n\\n").trim();
          };

          const publish = () => {
            const container = root();
            const selection = window.getSelection();
            if (!container || !selection || selection.isCollapsed || !selection.rangeCount) {
              if (last !== null) { last = null; handler.postMessage({ action: "replySelectionChanged" }); }
              return;
            }
            const range = selection.getRangeAt(0);
            const text = selection.toString();
            // Whitespace-only is a collapse for our purposes: clicking once
            // inside a paragraph can leave a selection of a single newline,
            // and offering that as a quotable span reads as a bug.
            if (!text.trim()) {
              if (last !== null) { last = null; handler.postMessage({ action: "replySelectionChanged" }); }
              return;
            }
            let start = null;
            let end = null;
            for (const entry of textNodes()) {
              const node = entry.node;
              if (!range.intersectsNode(node)) continue;
              const from = node === range.startContainer ? range.startOffset : 0;
              const to = node === range.endContainer ? range.endOffset : node.nodeValue.length;
              if (start === null) start = entry.start + from;
              end = entry.start + to;
            }
            if (start === null || end === null || start >= end) return;
            // `text` still decides *whether* there is a selection — cheap,
            // and whitespace-only is the same answer either way. What gets
            // quoted is the markdown.
            const quote = markdownOf(range) || text;
            const key = start + ":" + end + ":" + quote;
            if (key === last) return;
            last = key;
            handler.postMessage({ action: "replySelectionChanged", quote, start, end });
          };
          // **A mark is committed when the selection settles, never while it
          // is moving.** `selectionchange` fires on every frame of a drag,
          // and painting a mark rewraps the text nodes *under the live
          // selection*, which re-anchors it — so a single drag produced a
          // mark, lost its anchor, and produced a second one from wherever
          // the selection landed. Observed in dogfood 2026-09-05: one drag
          // across "It turned" left marks on "It turn" and on "e".
          //
          // Two settle signals, because neither covers the other: `mouseup`
          // ends a drag exactly, and a debounce catches the paths that have
          // no mouseup at all — shift-arrow, double-click extension, and
          // select-all.
          let dragging = false;
          let settleTimer = null;
          const settle = (delay) => {
            if (settleTimer) clearTimeout(settleTimer);
            settleTimer = setTimeout(() => { settleTimer = null; publish(); }, delay);
          };
          document.addEventListener("mousedown", () => {
            dragging = true;
            if (settleTimer) { clearTimeout(settleTimer); settleTimer = null; }
          }, true);
          document.addEventListener("mouseup", () => {
            dragging = false;
            settle(0);
          }, true);
          document.addEventListener("selectionchange", () => {
            if (dragging) return;
            settle(250);
          }, true);

          document.addEventListener("mouseover", (event) => {
            const target = event.target instanceof Element ? event.target.closest("." + MARK) : null;
            handler.postMessage({
              action: "replyMarkHover",
              id: target ? target.getAttribute("data-cmux-id") : null
            });
          }, true);
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true
    )

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        if let retainedWebView = coordinator.webView, retainedWebView === nsView {
            return
        }
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "cmuxLib")
        nsView.navigationDelegate = nil
        nsView.uiDelegate = nil
        (nsView as? MarkdownWebView)?.onPointerDown = nil
        (nsView as? MarkdownWebView)?.onLeaveWindow = nil
        (nsView as? MarkdownWebView)?.onReenterWindow = nil
        coordinator.cancelImageLoads()
    }

    /// WebKit's `prefers-color-scheme` media query reflects the WKWebView's
    /// effective NSAppearance. Forcing it here lets us decouple the markdown
    /// panel from the system appearance and follow the cmux color scheme.
    private func applyAppearance(to webView: WKWebView, isDark: Bool) {
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        if webView.appearance !== appearance {
            webView.appearance = appearance
        }
    }

    private func applyBackground(to webView: WKWebView) {
        webView.underPageBackgroundColor = backgroundColor
        webView.wantsLayer = true
        webView.layer?.backgroundColor = backgroundColor.cgColor
        webView.layer?.isOpaque = backgroundColor.alphaComponent >= 0.999
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKURLSchemeHandler {
        var webView: MarkdownWebView?
        /// Set fresh on every SwiftUI update, because the coordinator
        /// outlives the wrapper struct that carries the closure.
        private var onSelectionChanged: ((MarkdownPageSelection?) -> Void)?
        private var onMarkHoverChanged: ((UUID?) -> Void)?
        /// The marks last pushed to the page, so a repaint is skipped when
        /// nothing changed — `updateNSView` runs on every SwiftUI pass, and
        /// repainting unwraps and rewraps every span each time.
        private var paintedMarks: [MarkdownPageMark] = []
        private var activeMarkID: UUID??
        var panelId: UUID = UUID()
        var workspaceId: UUID = UUID()
        var filePath: String = ""
        private var pendingMarkdown: String = ""
        // Seeded from the persisted default so this is correct if it is ever
        // read — but it is believed unreachable, and an earlier version of this
        // comment claimed it as a second cause of the resize flash. That claim
        // was wrong and is retracted: every read is `lastTheme ?? pendingTheme`,
        // and `lastTheme` is assigned unconditionally in `loadShell`, the only
        // caller of `loadHTMLString`. So no navigation can finish, terminate, or
        // reattach with `lastTheme` still nil, and `close()` does not clear it.
        // The flash had exactly one cause — the panel container in
        // MarkdownPanelView — and was fixed there.
        //
        // Kept rather than deleted because a wrong-looking fallback is a trap
        // for the next reader; note it would still be wrong if reached, since it
        // reads the *global* default and not this panel's `backgroundStyle`.
        private var pendingTheme: MarkdownWebTheme = .resolve(
            backgroundColor: GhosttyBackgroundTheme.currentColor(),
            style: MarkdownBackgroundSettings.resolvedDefault()
        )
        private var lastMarkdown: String? = nil
        private var lastTheme: MarkdownWebTheme? = nil
        private var lastFontFamily: String = ""
        private var lastFontSize: Double = MarkdownFontSizeSettings.defaultPointSize
        private var lastMaxContentWidth: Double = MarkdownMaxWidthSettings.defaultCSSPixels
        private var lastHorizontalPagePadding: Double?
        private var isLoaded = false
        private var isShellLoading = false
        private var webContentProcessRecoveryAttempts = 0
        private let maxWebContentProcessRecoveryAttempts = 2
        /// Whether the shell was confirmed loaded at the moment the host view
        /// last left its window. Used to distinguish a blank state caused by
        /// detaching the pane (WebKit suspending/reclaiming the detached view —
        /// recoverable) from one caused by a payload that keeps crashing
        /// WebContent while attached (a crash loop whose recovery budget must
        /// not be reset by pane reparenting).
        private var shellWasHealthyWhenDetached = false

        private struct ImageLoadResult {
            let data: Data
            let mimeType: String
        }

        private final class ImageLoad {
            var reader: Task<ImageLoadResult, Never>?
            var sender: Task<Void, Never>?

            func cancel() {
                reader?.cancel()
                sender?.cancel()
            }
        }
        private var imageLoads: [ObjectIdentifier: ImageLoad] = [:]

#if DEBUG
        var isShellLoadingForTesting: Bool {
            isShellLoading
        }

        var webContentProcessRecoveryAttemptsForTesting: Int {
            webContentProcessRecoveryAttempts
        }
#endif

        func bind(panelId: UUID, workspaceId: UUID, filePath: String) {
            self.panelId = panelId
            self.workspaceId = workspaceId
            self.filePath = filePath
        }

        /// Records the desired body font size and applies it as `pageZoom`.
        /// Stored so it can be re-applied after the shell reloads (e.g. after a
        /// web-content-process crash recovery).
        func setFontSize(_ pointSize: Double) {
            lastFontSize = pointSize
            applyFontSize()
        }

        private func applyFontSize(forceShellSync: Bool = false) {
            guard let webView else { return }
            let zoom = MarkdownFontSizeSettings.pageZoom(forPointSize: lastFontSize)
            let shouldSyncShell = forceShellSync || abs(webView.pageZoom - zoom) > 0.0001
            if abs(webView.pageZoom - zoom) > 0.0001 { webView.pageZoom = zoom }
            if shouldSyncShell { webView.evaluateJavaScript("window.__cmuxSetMarkdownZoom && window.__cmuxSetMarkdownZoom(\(Double(zoom)), \(Double(webView.bounds.width)));", completionHandler: nil) }
        }

        /// Records the desired body prose font and applies it as an inline
        /// `font-family` on the content element. Unlike `pageZoom`, this DOM
        /// style is lost when the shell reloads, so it must be re-applied in
        /// `didFinish`.
        func setFontFamily(_ family: String) {
            lastFontFamily = family
            applyFontFamily()
        }

        private func applyFontFamily() {
            guard let webView else { return }
            // JSON-encode the CSS value (empty string clears the override).
            let css = MarkdownFontFamily.cssValue(for: lastFontFamily) ?? ""
            let encoded = (try? JSONSerialization.data(withJSONObject: [css]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            let js = """
            (function(arr) {
              var content = document.getElementById('content');
              if (content) { content.style.fontFamily = arr[0]; }
            })(\(encoded));
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        /// Records the desired content column max width. This DOM style is lost
        /// when the shell reloads, so it is re-applied in `didFinish`.
        func setMaxContentWidth(_ pixels: Double) {
            lastMaxContentWidth = MarkdownMaxWidthSettings.clamp(pixels)
            applyMaxContentWidth()
        }

        private func applyMaxContentWidth() {
            guard let webView else { return }
            let width = Int(MarkdownMaxWidthSettings.clamp(lastMaxContentWidth).rounded())
            let js = """
            (function(width) {
              var content = document.getElementById('content');
              if (content) { content.style.maxWidth = width + 'px'; }
            })(\(width));
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        /// Overrides the shell's horizontal page padding, or restores it.
        ///
        /// - Parameter pixels: CSS pixels each side, or `nil` to hand the
        ///   padding back to the stylesheet.
        /// Re-points the selection observer at the current SwiftUI closure.
        ///
        /// Unconditional, unlike the other setters, which compare against a
        /// last-applied value first. A closure has no equality to compare, and
        /// a stale one captures the previous view's state — so the cheap
        /// assignment is the correct one here.
        func setMarkHoverObserver(_ observer: ((UUID?) -> Void)?) {
            onMarkHoverChanged = observer
        }

        /// Repaints the page's marks, skipping the work when nothing moved.
        ///
        /// `updateNSView` runs on every SwiftUI pass and a repaint unwraps
        /// and rewraps every span, so an unconditional call would rebuild the
        /// marks on each keystroke in the note field.
        func setMarks(_ marks: [MarkdownPageMark]) {
            guard marks != paintedMarks else { return }
            paintedMarks = marks
            guard let data = try? JSONEncoder().encode(marks),
                  let json = String(data: data, encoding: .utf8) else { return }
            evaluate("window.__cmuxReplyPaint && window.__cmuxReplyPaint(\(json));")
        }

        /// Colours one mark as hovered, or clears every one.
        ///
        /// Double optional: the outer says "never set", the inner says "set
        /// to nothing". Without the distinction the first pass would clear
        /// marks the page has not painted yet.
        func setActiveMark(_ id: UUID?) {
            guard activeMarkID != .some(id) else { return }
            activeMarkID = .some(id)
            let argument = id.map { "\"\($0.uuidString)\"" } ?? "null"
            evaluate("window.__cmuxReplyActivate && window.__cmuxReplyActivate(\(argument));")
        }

        private func evaluate(_ script: String) {
            guard let webView else { return }
            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        func setSelectionObserver(_ observer: ((MarkdownPageSelection?) -> Void)?) {
            onSelectionChanged = observer
        }

        func setHorizontalPagePadding(_ pixels: Double?) {
            guard lastHorizontalPagePadding != pixels else { return }
            lastHorizontalPagePadding = pixels
            applyHorizontalPagePadding()
        }

        private func applyHorizontalPagePadding() {
            guard let webView else { return }
            // An empty string clears an inline style and lets the stylesheet
            // win again, so the `nil` case is a real restore rather than a
            // guess at what the shell had.
            let padding = lastHorizontalPagePadding.map { "\(Int($0.rounded()))px" } ?? ""
            let js = """
            (function(padding) {
              document.body.style.paddingLeft = padding;
              document.body.style.paddingRight = padding;
            })("\(padding)");
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        func close() {
            if let webView {
                webView.stopLoading()
                webView.configuration.userContentController.removeScriptMessageHandler(forName: "cmuxLib")
                webView.navigationDelegate = nil
                webView.uiDelegate = nil
                webView.onPointerDown = nil
                webView.onLeaveWindow = nil
                webView.onReenterWindow = nil
            }
            self.webView = nil
            isLoaded = false
            isShellLoading = false
            webContentProcessRecoveryAttempts = 0
            shellWasHealthyWhenDetached = false
            cancelImageLoads()
            requestedLibs.removeAll()
        }

        func loadShell(theme: MarkdownWebTheme, initialMarkdown: String) {
            pendingMarkdown = initialMarkdown
            pendingTheme = theme
            lastTheme = theme
            requestedLibs.removeAll()
            isLoaded = false
            isShellLoading = true
            let html = MarkdownViewerAssets.shared.shellHTML(isDark: theme.isDark)
            let baseURL = URL(fileURLWithPath: filePath)
#if DEBUG
            NSLog("MarkdownPanel.loadShell filePath=\(filePath) baseURL=\(baseURL.absoluteString) htmlBytes=\(html.utf8.count)")
#endif
            webView?.loadHTMLString(html, baseURL: baseURL)
        }

        func update(markdown: String, theme: MarkdownWebTheme) {
            let themeChanged = lastTheme != theme
            let contentChanged = lastMarkdown != markdown
            let shellNeedsReload = !isLoaded && !isShellLoading
            guard themeChanged || contentChanged || shellNeedsReload else { return }

            pendingMarkdown = markdown
            pendingTheme = theme

            if themeChanged {
                lastTheme = theme
                // The WKWebView's NSAppearance change (handled in the
                // representable's update path) flips `prefers-color-scheme`
                // automatically. We still nudge the page so highlight.js
                // swaps stylesheets even if the matchMedia listener is
                // slow to fire.
                if isLoaded {
                    applyTheme(theme)
                    if !contentChanged {
                        pushMarkdown(lastMarkdown ?? pendingMarkdown)
                    }
                }
            }

            if contentChanged {
                webContentProcessRecoveryAttempts = 0
                lastMarkdown = markdown
                if isLoaded {
                    pushMarkdown(markdown)
                } else if shellNeedsReload {
                    loadShell(theme: theme, initialMarkdown: markdown)
                }
            } else if shellNeedsReload {
                if webContentProcessRecoveryAttempts < maxWebContentProcessRecoveryAttempts {
                    loadShell(theme: theme, initialMarkdown: markdown)
                }
            }
        }

        func renderedHTML(markdown: String? = nil) async -> String? {
            guard isLoaded else { return nil }
            if let markdown {
                guard await renderMarkdownForExport(markdown) else { return nil }
            }
            // We export an explicit "rendered HTML" getter from JS so callers
            // get the *content* div only, without the shell <style>/<script>.
            return await evaluateString("window.__cmuxRenderedHTML && window.__cmuxRenderedHTML()")
        }

        func renderedText() async -> String? {
            guard isLoaded else { return nil }
            return await evaluateString("window.__cmuxRenderedText && window.__cmuxRenderedText()")
        }

        private func evaluateString(_ script: String) async -> String? {
            guard let webView else { return nil }
            do {
                return try await webView.evaluateJavaScript(script) as? String
            } catch {
                return nil
            }
        }

        private func applyTheme(_ theme: MarkdownWebTheme) {
            guard let webView else { return }
            let payload = [
                "--bgColor-default": theme.background,
                "--bgColor-muted": theme.mutedBackground,
                "--bgColor-neutral-muted": theme.neutralMutedBackground,
                "--borderColor-default": theme.border,
                "--borderColor-muted": theme.mutedBorder,
                "--borderColor-neutral-muted": theme.mutedBorder,
                // Named for what they are rather than borrowed from
                // github-markdown's palette: nothing in that stylesheet
                // paints an accent, and these exist for marks cmux draws
                // itself.
                "--cmuxAccent": theme.accent,
                "--cmuxOnAccent": theme.onAccent,
                "--cmuxAccentHover": theme.accentHover,
                "--cmuxOnAccentHover": theme.onAccentHover
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            let js = """
            (function(vars) {
              var content = document.getElementById('content');
              if (!content) { return; }
              Object.keys(vars).forEach(function(name) {
                content.style.setProperty(name, vars[name]);
              });
              content.style.background = 'transparent';
              if (window.__cmuxApplyTheme) { window.__cmuxApplyTheme(); }
            })(\(json));
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        // MARK: Bridge

        private func pushMarkdown(_ markdown: String) {
            guard let webView else { return }
#if DEBUG
            NSLog("MarkdownPanel.pushMarkdown bytes=\(markdown.utf8.count)")
#endif
            guard let js = Self.renderMarkdownScript(markdown) else { return }
            webView.evaluateJavaScript(js) { _, error in
#if DEBUG
                if let error {
                    NSLog("MarkdownPanel: pushMarkdown evaluateJavaScript failed: \(error)")
                }
#endif
            }
        }

        private func renderMarkdownForExport(_ markdown: String) async -> Bool {
            guard let webView, isLoaded else { return false }
            guard let js = Self.renderMarkdownScript(markdown) else { return false }
            do {
                _ = try await webView.evaluateJavaScript(js)
                lastMarkdown = markdown
                pendingMarkdown = markdown
                return true
            } catch {
#if DEBUG
                NSLog("MarkdownPanel: renderMarkdownForExport evaluateJavaScript failed: \(error)")
#endif
                return false
            }
        }

        private static func renderMarkdownScript(_ markdown: String) -> String? {
            // Send the raw markdown through a JSON literal so we don't have
            // to hand-escape backticks/backslashes/quotes for JS.
            guard let data = try? JSONSerialization.data(withJSONObject: [markdown]),
                  let arrayLiteral = String(data: data, encoding: .utf8) else { return nil }
            return """
            (function(md) {
              if (window.__cmuxRenderMarkdown) {
                window.__cmuxRenderMarkdown(md);
                return;
              }
              var el = document.getElementById('content') || document.body;
              function esc(s) {
                var div = document.createElement('div');
                div.textContent = String(s == null ? '' : s);
                return div.innerHTML;
              }
              el.innerHTML = '<pre style=\"color:#f85149;white-space:pre-wrap\">Markdown renderer failed to initialize. Showing raw source.\\n\\n' + esc(md) + '</pre>';
            })(\(arrayLiteral)[0]);
            """
        }

        // MARK: WKScriptMessageHandler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "cmuxLib",
                  let body = message.body as? [String: Any] else { return }
            if let lib = body["lib"] as? String {
                handleLibRequest(lib)
                return
            }
            if let action = body["action"] as? String {
                if action == "replyMarkHover" {
                    let raw = body["id"] as? String
                    onMarkHoverChanged?(raw.flatMap(UUID.init(uuidString:)))
                    return
                }
                if action == "replySelectionChanged" {
                    guard let quote = body["quote"] as? String, !quote.isEmpty,
                          let start = body["start"] as? Int,
                          let end = body["end"] as? Int, start < end else {
                        onSelectionChanged?(nil)
                        return
                    }
                    onSelectionChanged?(
                        MarkdownPageSelection(quote: quote, range: start..<end)
                    )
                    return
                }
#if DEBUG
                NSLog("MarkdownPanel.bridge action=\(action) body=\(body)")
#endif
                switch action {
                case "resolveMarkdownFile":
                    guard let requestId = body["requestId"] as? String,
                          let rawPath = body["path"] as? String else { return }
                    resolveMarkdownFile(rawPath, requestId: requestId)
                case "openMarkdownFile":
                    guard let rawPath = body["path"] as? String else { return }
                    if let resolved = resolvedMarkdownFilePath(rawPath) {
                        openMarkdownFile(resolved)
                    }
                default:
                    break
                }
            }
        }

        private var requestedLibs: Set<String> = []

        // MARK: WKURLSchemeHandler

        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            guard let requestURL = urlSchemeTask.request.url else {
                urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL))
                return
            }

            let taskId = ObjectIdentifier(urlSchemeTask as AnyObject)
            let load = ImageLoad()
            imageLoads[taskId] = load
            let reader = imageLoadTask(for: requestURL)
            load.reader = reader
            let sender = Task { [weak self, weak load] in
                defer {
                    if let load, self?.imageLoads[taskId] === load {
                        self?.imageLoads[taskId] = nil
                    }
                }
                let result = await reader.value
                guard !Task.isCancelled else { return }
                let response = URLResponse(
                    url: requestURL,
                    mimeType: result.mimeType,
                    expectedContentLength: result.data.count,
                    textEncodingName: nil
                )
                urlSchemeTask.didReceive(response)
                if !result.data.isEmpty {
                    urlSchemeTask.didReceive(result.data)
                }
                urlSchemeTask.didFinish()
            }
            load.sender = sender
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
            let taskId = ObjectIdentifier(urlSchemeTask as AnyObject)
            guard let load = imageLoads.removeValue(forKey: taskId) else { return }
            load.cancel()
        }

        func cancelImageLoads() {
            let loads = imageLoads.values
            imageLoads.removeAll()
            for load in loads {
                load.cancel()
            }
        }

        func cancelLocalImageLoads() {
            cancelImageLoads()
        }

        private func imageLoadTask(for requestURL: URL) -> Task<ImageLoadResult, Never> {
            let scheme = requestURL.scheme?.lowercased()
            if scheme == MarkdownWebRenderer.localImageURLScheme {
                let fileURL = localImageFileURL(from: requestURL)
                let mimeType = fileURL
                    .flatMap { Self.localImageMimeType(for: $0.pathExtension) } ?? "image/png"
                return Task.detached(priority: .userInitiated) {
                    guard let fileURL,
                          FileManager.default.isReadableFile(atPath: fileURL.path) else {
                        return ImageLoadResult(data: Data(), mimeType: mimeType)
                    }
                    let data = (try? Data(contentsOf: fileURL)) ?? Data()
                    return ImageLoadResult(data: data, mimeType: mimeType)
                }
            }

            if scheme == MarkdownWebRenderer.remoteImageURLScheme {
                let remoteURL = MarkdownRemoteImageSecurity.remoteImageURL(from: requestURL)
                return Task.detached(priority: .userInitiated) {
                    guard let remoteURL,
                          let fetched = await MarkdownRemoteImageFetcher.fetch(remoteURL) else {
                        return ImageLoadResult(data: Data(), mimeType: "image/png")
                    }
                    return ImageLoadResult(data: fetched.data, mimeType: fetched.mimeType)
                }
            }

            return Task.detached {
                ImageLoadResult(data: Data(), mimeType: "image/png")
            }
        }

        private func localImageFileURL(from requestURL: URL) -> URL? {
            guard requestURL.scheme?.lowercased() == MarkdownWebRenderer.localImageURLScheme,
                  let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false),
                  let rawFileURL = components.queryItems?.first(where: { $0.name == "url" })?.value,
                  let fileURL = URL(string: rawFileURL),
                  fileURL.isFileURL else {
                return nil
            }

            let markdownFilePath = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !markdownFilePath.isEmpty else {
                return nil
            }

            let markdownDirectory = URL(fileURLWithPath: markdownFilePath)
                .deletingLastPathComponent()
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard markdownDirectory.path != "/" else {
                return nil
            }

            let markdownRoot = markdownDirectory.path.hasSuffix("/")
                ? markdownDirectory.path
                : markdownDirectory.path + "/"
            let standardizedURL = fileURL
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard standardizedURL.path.hasPrefix(markdownRoot),
                  Self.localImageMimeType(for: standardizedURL.pathExtension) != nil else {
                return nil
            }
            return standardizedURL
        }

        private static func localImageMimeType(for pathExtension: String) -> String? {
            switch pathExtension.lowercased() {
            case "png":
                return "image/png"
            case "jpg", "jpeg":
                return "image/jpeg"
            case "gif":
                return "image/gif"
            case "webp":
                return "image/webp"
            case "avif":
                return "image/avif"
            default:
                return nil
            }
        }

        private func resolveMarkdownFile(_ rawPath: String, requestId: String) {
            guard let webView else { return }
            let resolved = resolvedMarkdownFilePath(rawPath)
#if DEBUG
            NSLog("MarkdownPanel.resolve raw=\(rawPath) resolved=\(resolved ?? "nil")")
#endif
            let payload: [String: Any] = [
                "requestId": requestId,
                "exists": resolved != nil,
                "path": resolved ?? ""
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.__cmuxMarkdownFileResolved && window.__cmuxMarkdownFileResolved(\(json));", completionHandler: nil)
        }

        private func resolvedMarkdownFilePath(_ rawPath: String) -> String? {
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard MarkdownPanelFileLinkResolver.isMarkdownPathLike(trimmed) else { return nil }
            return MarkdownPanelFileLinkResolver.resolve(rawPath: trimmed, relativeToMarkdownFile: filePath)
        }

        private func openMarkdownFile(_ path: String) {
#if DEBUG
            NSLog("MarkdownPanel.openMarkdownFile path=\(path)")
#endif
            guard let app = AppDelegate.shared,
                  let location = app.workspaceContainingPanel(
                      panelId: panelId,
                      preferredWorkspaceId: workspaceId
                  ),
                  let paneId = location.workspace.paneId(forPanelId: panelId) else { return }
            _ = location.workspace.newMarkdownSurface(
                inPane: paneId,
                filePath: path,
                focus: true
            )
        }

        private func handleLibRequest(_ lib: String) {
            guard let webView else { return }
            // Load each library at most once per WebView lifetime. State is
            // reset only when the shell is reloaded via loadShell(); theme
            // switches reuse the already-loaded libs.
            if requestedLibs.contains(lib) { return }
            requestedLibs.insert(lib)

            let assets = MarkdownViewerAssets.shared
            let sources: [String]
            switch lib {
            case "mermaid":
                sources = [assets.lazyAsset(name: "mermaid.min", ext: "js")]
            case "vega-lite":
                // Order matters: vega first, then vega-lite, then vega-embed.
                sources = [
                    assets.lazyAsset(name: "vega.min", ext: "js"),
                    assets.lazyAsset(name: "vega-lite.min", ext: "js"),
                    assets.lazyAsset(name: "vega-embed.min", ext: "js"),
                ]
            default:
                return
            }

            // Concatenate the bundled sources into a single evaluateJavaScript
            // call, then notify the page that the lib is ready. Any parse or
            // throw in the bundle surfaces through the completion handler.
            var injection = ""
            for src in sources where !src.isEmpty {
                injection += src
                injection += "\n;"
            }
            // JSON-encode the lib name to safely splice into JS.
            let libLiteral = (try? JSONSerialization.data(withJSONObject: [lib]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            let suffix = "\nwindow.__cmuxLibLoaded && window.__cmuxLibLoaded(\(libLiteral)[0]);"
            webView.evaluateJavaScript(injection + suffix) { [weak self] _, error in
                if let error {
                    // Allow retry on next render if this attempt failed.
                    self?.requestedLibs.remove(lib)
#if DEBUG
                    NSLog("MarkdownPanel: failed to load \(lib): \(error)")
#endif
                }
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
#if DEBUG
            NSLog("MarkdownPanel.webView.didFinish")
#endif
            isShellLoading = false
            isLoaded = true
            // pageZoom is a WKWebView-level property that survives loadHTMLString,
            // but re-apply defensively after a shell reload so a crash-recovery
            // path can never drop the configured zoom.
            applyFontSize(forceShellSync: true)
            // font-family is a DOM inline style on a freshly-created #content,
            // so it MUST be re-applied after every shell (re)load.
            applyFontFamily()
            applyMaxContentWidth()
            // An inline style on `document.body`, so like font-family it MUST
            // be re-applied after every shell (re)load.
            applyHorizontalPagePadding()
            applyTheme(lastTheme ?? pendingTheme)
            // Replay last known markdown after the shell finishes loading.
            // Keep the recovery budget scoped to the current markdown payload:
            // a payload can crash after shell load during the render push.
            // Content changes reset the budget in `update(markdown:theme:)`.
            let md = lastMarkdown ?? pendingMarkdown
            lastMarkdown = md
            pushMarkdown(md)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleShellNavigationFailure(for: webView, error: error)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            handleShellNavigationFailure(for: webView, error: error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard let currentWebView = self.webView, currentWebView === webView else { return }
#if DEBUG
            NSLog("MarkdownPanel.webView.webContentProcessDidTerminate")
#endif
            isShellLoading = false
            guard webContentProcessRecoveryAttempts < maxWebContentProcessRecoveryAttempts else {
                isLoaded = false
                requestedLibs.removeAll()
                return
            }
            webContentProcessRecoveryAttempts += 1
            loadShell(
                theme: lastTheme ?? pendingTheme,
                initialMarkdown: lastMarkdown ?? pendingMarkdown
            )
        }

        /// Called when the host `MarkdownWebView` re-enters a window after
        /// having been detached (e.g. a pane drag re-parents the hosting
        /// views via `removeFromSuperview` → `addSubview`). While detached
        /// from the window WebKit can reclaim the WebContent process,
        /// leaving the panel permanently blank with no user-facing reload.
        /// Records, at the moment the host view leaves its window, whether the
        /// document was healthy. The blank state seen after re-entry is only
        /// treated as a detach artifact (and recovered with a fresh budget) if
        /// the shell was loaded when it was detached.
        func handleViewLeftWindow() {
            shellWasHealthyWhenDetached = isLoaded
        }

        func handleViewReenteredWindow() {
            // A still-loaded shell — alive but merely unpainted — is left
            // intact; the host view's repaint nudge handles that case.
            guard !isLoaded else { return }
            // Recover only when the document was healthy before the detach, so
            // a payload that exhausted its crash-recovery budget while attached
            // (a crash loop) is not granted a fresh budget by pane reparenting.
            guard shellWasHealthyWhenDetached else { return }
            shellWasHealthyWhenDetached = false
            // A reload kicked off while detached can stall (no didFinish until
            // the view is back in a window), so reload unconditionally — even
            // mid-load. A deliberate reattach is not a crash loop, so restore
            // the recovery budget so the document repaints instead of staying
            // permanently blank.
            webContentProcessRecoveryAttempts = 0
            loadShell(
                theme: lastTheme ?? pendingTheme,
                initialMarkdown: lastMarkdown ?? pendingMarkdown
            )
        }

        private func handleShellNavigationFailure(for webView: WKWebView, error: Error) {
            guard let currentWebView = self.webView, currentWebView === webView, isShellLoading else { return }
#if DEBUG
            NSLog("MarkdownPanel.webView.navigationFailed error=\(error)")
#endif
            isShellLoading = false
            isLoaded = false
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // The first load (loadHTMLString) has navigationType = .other —
            // allow it. Anything the user clicks (links, anchors, ...) we
            // route through the cmux tab/browser machinery.
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
#if DEBUG
                NSLog("MarkdownPanel.nav linkActivated url=\(url.absoluteString)")
#endif
                if isInPageFragment(url) {
                    // Same-document fragment navigation (heading anchors)
                    // scrolls the panel — keep it native.
                    decisionHandler(.allow)
                    return
                }
                // Answer WebKit first, route second. `handleExternalLink` can
                // reach `NSWorkspace.open`, which is a LaunchServices round
                // trip to launch or activate another app — and until this
                // handler returns, WebKit holds the navigation decision and
                // the window with it. Clicking a link in the Reply panel froze
                // the app for exactly that reason: the sidebar has no pane
                // panel, so its links miss the in-app browser path entirely
                // (see `handleExternalLink`) and always take the slow one.
                decisionHandler(.cancel)
                routeExternalLinkOffDelegate(url)
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // target=_blank / window.open from inside the rendered markdown.
            // Deferred for the same reason as the policy handler above: this
            // is a synchronous delegate callback, and WebKit is waiting on it.
            if let url = navigationAction.request.url {
                routeExternalLinkOffDelegate(url)
            }
            return nil
        }

        // MARK: - Link routing

        /// Routes a clicked link *after* the current WebKit delegate callback
        /// returns.
        ///
        /// The one path both delegate callbacks use, so neither can
        /// reintroduce the stall by calling ``handleExternalLink`` directly.
        /// A main-actor hop, not a background one: everything downstream
        /// touches `AppDelegate`, `Workspace`, and `NSWorkspace`.
        private func routeExternalLinkOffDelegate(_ url: URL) {
            Task { [weak self] in
                self?.handleExternalLink(url)
            }
        }

        /// Route a clicked link to a brand-new cmux browser tab in the same
        /// pane as this markdown panel — mirroring how Browser panels open
        /// child links via `openLinkInNewTab`. Falls back to the system
        /// browser only when the in-app browser is disabled or the panel
        /// can't be located in any workspace.
        ///
        /// **The Reply panel always takes that last fallback**, and silently.
        /// It is a right-sidebar mode, not a pane, so it has no panel to pass
        /// and hands over a synthetic `UUID` (`ReplyPanelView.rendererPanelID`)
        /// that `workspaceContainingPanel` can never resolve. Its `.md` links
        /// therefore do nothing at all — `openMarkdownFile` guards on the same
        /// lookup and returns — and its http links skip the in-app browser.
        /// Fixing that needs a workspace-based route rather than a panel one,
        /// and is `cm-69.1a`; only the stall it caused is fixed here.
        private func handleExternalLink(_ url: URL) {
#if DEBUG
            NSLog("MarkdownPanel.handleExternalLink url=\(url.absoluteString)")
#endif
            // First preference: links that resolve to local markdown files
            // open as markdown tabs in cmux, not in the browser.
            let fileCandidate = url.scheme == "file" ? url.path : url.absoluteString
            if let markdownPath = resolvedMarkdownFilePath(fileCandidate) {
                openMarkdownFile(markdownPath)
                return
            }

            // Schemes the in-app browser doesn't (and shouldn't) handle:
            // mailto:, tel:, slack://, vscode://, file:// non-markdown, etc.
            // Route those to the system handler so the user's default app picks them up.
            if let scheme = url.scheme?.lowercased(),
               scheme != "http", scheme != "https" {
                NSWorkspace.shared.open(url)
                return
            }

            guard BrowserAvailabilitySettings.isEnabled() else {
                NSWorkspace.shared.open(url)
                return
            }

            guard let app = AppDelegate.shared,
                  let location = app.workspaceContainingPanel(
                      panelId: panelId,
                      preferredWorkspaceId: workspaceId
                  ),
                  let paneId = location.workspace.paneId(forPanelId: panelId) else {
                // No workspace context — last-resort fallback.
                NSWorkspace.shared.open(url)
                return
            }

            _ = location.workspace.newBrowserSurface(
                inPane: paneId,
                url: url,
                focus: true
            )
        }

        private func isInPageFragment(_ url: URL) -> Bool {
            // Only same-document anchors should stay inside the WebView. With
            // a file base URL, WebKit resolves `#heading` to
            // `file:///current.md#heading`; links such as `other.md#heading`
            // must still route through the markdown-tab opener below.
            guard url.fragment != nil else { return false }
            if (url.scheme == nil || url.scheme == "about"), (url.host ?? "").isEmpty {
                return true
            }
            if url.isFileURL {
                let targetPath = (url.path as NSString).standardizingPath
                let currentPath = (filePath as NSString).standardizingPath
                let currentDirectory = ((filePath as NSString).deletingLastPathComponent as NSString).standardizingPath
                return targetPath == currentPath || targetPath == currentDirectory
            }
            return false
        }
    }
}
