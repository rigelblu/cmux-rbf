/**
 * YMD status-highlight pass for the cmux markdown viewer — cm-15.1.
 *
 * Conceals the first supported marker emoji in each *block* — not each line: a
 * soft-wrapped paragraph carrying three markers conceals and highlights only the
 * first. On a non-heading block, the marker's colour then tints the first code
 * span at or after it as a highlight, reusing YMD's own `background()` palette
 * rather than inventing one. A code span inside a *link label* is never highlighted
 * — the highlight is a `<span>`, which the shell's link-label sanitizer replaces by
 * its textContent, destroying the `<code>` along with it.
 *
 * Headings conceal the marker and take its colour as a class on the `<hN>`,
 * never as a highlight: the shell derives heading ids from a plain-text projection
 * that does not cover extension tokens, so a token there corrupts the id (see
 * shell.html's heading renderer).
 *
 * Code immunity is structural for highlights and EXPLICIT for headings. `code` and
 * `codespan` are leaf tokens carrying no `.tokens`, so the walk never reaches a
 * marker inside backticks — but `decorateHeading` works on rendered HTML, where
 * that structure is gone, and must mask code and tag regions itself. Per-block
 * semantics also do not hold inside table cells; see `concealInTableCells`.
 *
 * Shape mirrors viewer-navigation.js: an IIFE assigning a global.
 */
/* cmux-ymd:begin — MarkdownYMDShellTests strips between these sentinels to
   build a genuinely ymd-free control arm. shellHTML() always substitutes every
   placeholder, so there is no other way to render "the same page without this
   module", and a heading-id comparison whose control still ran ymd passes
   unconditionally. Do not remove or reword the sentinels. */
(function (global) {
  "use strict";

  var COLORS = {
    "🔴": "red",
    "🟠": "orange",
    "🟡": "yellow",
    "🟢": "green",
    "🔵": "blue",
    "🟣": "purple",
    "⚫": "black",
  };

  var MARKER_RE = /[\u{1F534}\u{1F7E0}\u{1F7E1}\u{1F7E2}\u{1F535}\u{1F7E3}\u{26AB}]️?/u;

  // Inline containers we descend into. `code`/`codespan` are absent — they are
  // leaves, which is what makes code immunity structural.
  var DESCEND = { strong: 1, em: 1, del: 1, link: 1, text: 1 };

  // Blocks eligible for a highlight. An allowlist, not a `heading` denylist, so a
  // block type added to the dispatch later cannot start highlighting by accident.
  var HIGHLIGHTABLE = { paragraph: 1, list_item: 1 };

  // Counted in UTF-8 *bytes*, not JS string length: `.length` is UTF-16 code
  // units, and on an emoji-dense YMD corpus the two differ enough that a byte
  // threshold and a length threshold are not the same rule.
  //
  // 250,000 is measured, not inherited. ymd.rs uses 100,000 for an editor
  // decorating a viewport; this panel renders whole documents, and at 100,000
  // the largest brief in the corpus (106,055 bytes) was silently skipped while
  // the next one sat within 4% of the gate. Measured cost of running the pass
  // on that file is 1.5ms (4.2ms -> 5.7ms), scaling at roughly 14ns/byte, so
  // this ceiling tops out near 3.5ms — a fraction of a frame. The ceiling stays
  // because pathological input should still be excluded: ~1MB would cost ~14ms.
  // Reopen if a real document near this size measures over ~8ms.
  var MAX_YMD_HIGHLIGHT_BYTES = 250000;

  // Set per-parse by the preprocess hook; walkTokens is a no-op when false.
  var active = true;

  function byteLength(s) {
    if (typeof TextEncoder !== "undefined") return new TextEncoder().encode(s).length;
    return unescape(encodeURIComponent(s)).length;
  }

  /**
   * Palette, transcribed byte-for-byte from ymd.rs `background()`, with the
   * fixed readable foreground from `background_style`. The background lands on
   * the inner <code> so it overrides github-markdown.css's own code styling,
   * and so the highlight's foreground is fixed rather than inherited — which is
   * what lets all seven colours clear WCAG AA in both appearances.
   */
  var PALETTE_CSS = [
    ":root{--ymd-fg:#1a1a1a}",
    ".ymd-highlight code{background-color:var(--ymd-highlight-bg);color:var(--ymd-fg);border-radius:6px;padding:.1em .4em}",
    ".ymd-highlight-red{--ymd-highlight-bg:#ffcdd2}",
    ".ymd-highlight-orange{--ymd-highlight-bg:#ffe0b2}",
    ".ymd-highlight-yellow{--ymd-highlight-bg:#fff59d}",
    ".ymd-highlight-green{--ymd-highlight-bg:#c8e6c9}",
    ".ymd-highlight-blue{--ymd-highlight-bg:#bbdefb}",
    ".ymd-highlight-purple{--ymd-highlight-bg:#e1bee7}",
    ".ymd-highlight-black{--ymd-highlight-bg:#e0e0e0}",
    // Heading tint, from ymd.rs `foreground()`. Unlike the highlight — whose
    // foreground is fixed, which is what lets all seven clear AA on their own
    // background — this is text colour on the panel's canvas, so it is bound by
    // the canvas contrast. Measured on #ffffff: h1 🔵 8.63, h2 🟠 3.79,
    // h3 🟣 11.86. h1/h2/h3 are 32/24/20px and clear WCAG's 3:1 large-text bar
    // (h3 clears 4.5 outright, so the semibold-vs-bold question is moot).
    ".ymd-head-red{color:#b71c1c}",
    ".ymd-head-orange{color:#e65100}",
    // Light-mode yellow is a DATED EXCEPTION, not a contrast-derived value, and
    // it is the only place in this file where a measurement lost to a judgment.
    // Say so plainly rather than dressing it up: #f9a825 measures 1.97:1 on
    // #ffffff and ~1.69:1 on a tinted canvas. WCAG AA wants 4.5:1 at 16px. This
    // fails, knowingly. (Tom, 2026-08-01, chosen from rendered swatches.)
    //
    // Arrived at empirically, and the empiricism mattered: a brighter #fbc02d
    // (1.66:1) was tried first and rejected because it went *unreadable against
    // parts of the canvas* — cmux tints the panel background and that tint is
    // not uniform, so a ratio computed against any single flat colour was never
    // the whole story. This is the falsifier the brief recorded, fired. Treat
    // every number in this comment as "on the stock canvas", never as "for this
    // reader"; the human verdict is the authority for light mode here.
    //
    // Why the measurement could not win. Yellow is the one hue whose identity IS
    // its luminance: clearing even the 3:1 large-text bar on white needs relative
    // luminance <= 0.300, and pure yellow is 0.928 — eleven times over. So every
    // "accessible yellow" is a gold or an olive, and two earlier attempts here
    // (#8a6d00 at 4.92:1, then #9e8007 at 3.79:1) were both rejected on sight
    // for exactly that reason. The choice was never yellow-vs-contrast; it was
    // yellow-vs-not-yellow, and a fork whose sole reader picked legibility-by-
    // his-own-eyes over a ratio computed against a canvas he does not use.
    //
    // What bounds the risk: this is one heading level (h4), 16 markers in the
    // entire corpus, on a heading whose level is *already* carried by size,
    // weight and position — so the colour is redundant signal, not sole signal.
    // Reopen if that stops being true, i.e. if h4 ever becomes common or the
    // tint becomes the only thing distinguishing a level.
    //
    // Hue 37°, still clear of orange's 21° though nearer than the rejected
    // #fbc02d at 43°. There is a floor here: readability on this canvas pushes
    // yellow darker, and darker yellow walks toward orange, so the two
    // constraints pull against each other and 37° is where they balanced.
    //
    // That tension is why the dialect's own #f57f17 was NOT used despite being
    // brighter AND byte-parity: at hue 28° it has already crossed into amber and
    // collides with h2 orange — precisely the confusion the adjacent-pair
    // fixture exists to catch.
    //
    // Dark mode needs no exception — see below, where parity holds at 16.94:1.
    ".ymd-head-yellow{color:#f9a825}",
    // Brightened from ymd.rs's #1b5e20 (Material Green 900) on the same grounds
    // as yellow below: dark enough to clear a contrast bar is dark enough to
    // stop reading as the colour. 3.22:1 on #ffffff and 2.76:1 on a tinted
    // canvas — another dated exception, same reasoning and same bounds. Both
    // are named because quoting the tinted figure as if it were the stock one
    // is exactly the ambiguity the yellow comment above takes care to avoid.
    // (Tom, 2026-08-01, chosen from rendered swatches.)
    //
    // #2da44e is GitHub's own success-emphasis green, which makes it the one
    // candidate already in this panel's vocabulary: the shell renders through
    // github-markdown.css, so this green shares its provenance with the
    // stylesheet around it rather than being imported from a fourth palette.
    //
    // Hue 137°, against blue's 216°. Hue, not brightness, is what keeps the
    // seven apart at a glance — the emerald candidates at ~160° would have
    // closed the green-to-blue gap by about a fifth for no gain in legibility.
    ".ymd-head-green{color:#2da44e}",
    ".ymd-head-blue{color:#0d47a1}",
    ".ymd-head-purple{color:#4a148c}",
    ".ymd-head-black{color:#212121}",
    // A tinted heading must not swallow its own link. `color` on the <hN>
    // cascades into <a>, and YMD blue is close enough to GitHub's link accent
    // that a 🔵 heading would erase the affordance entirely — the defect that
    // ended line-tinting. Scoped to tinted headings so untinted ones are
    // untouched. Wins over the cascade by being more specific than `.md-body a`.
    '[class*="ymd-head-"] a{color:var(--fgColor-accent)}',
    "@media(prefers-color-scheme:dark){",
    ":root{--ymd-fg:#e0def4}",
    ".ymd-highlight-red{--ymd-highlight-bg:#5c3a3a}",
    ".ymd-highlight-orange{--ymd-highlight-bg:#5c4a37}",
    ".ymd-highlight-yellow{--ymd-highlight-bg:#5c5637}",
    ".ymd-highlight-green{--ymd-highlight-bg:#3a5c3a}",
    ".ymd-highlight-blue{--ymd-highlight-bg:#3a4a5c}",
    ".ymd-highlight-purple{--ymd-highlight-bg:#4a3a5c}",
    ".ymd-highlight-black{--ymd-highlight-bg:#3a3a3a}",
    // Byte-parity with ymd.rs holds here: its dark foregrounds are its own light
    // backgrounds, and every one clears 11.46–16.94 on the #0d1117 canvas, so
    // the light-mode yellow divergence has no counterpart in dark.
    ".ymd-head-red{color:#ffcdd2}",
    ".ymd-head-orange{color:#ffe0b2}",
    ".ymd-head-yellow{color:#fff59d}",
    ".ymd-head-green{color:#c8e6c9}",
    ".ymd-head-blue{color:#bbdefb}",
    ".ymd-head-purple{color:#e1bee7}",
    ".ymd-head-black{color:#e0e0e0}",
    "}",
  ].join("");

  var stylesInstalled = false;

  function installStyles(doc) {
    var d = doc || (typeof document !== "undefined" ? document : null);
    if (!d || stylesInstalled) return;
    var el = d.createElement("style");
    el.setAttribute("data-ymd-palette", "");
    el.textContent = PALETTE_CSS;
    d.head.appendChild(el);
    stylesInstalled = true;
  }

  /**
   * In-order walk yielding {token, list, index, inLink} for text and codespan
   * leaves.
   *
   * `inLink` exists because a highlight is illegal inside a link label. The highlight is
   * a `<span>`, and shell.html's `sanitizeLinkLabelHTML` allows only
   * br/code/del/em/img/s/strong there — a `<span>` is replaced by its
   * `textContent`, which destroys the `<code>` descendant the same pass just
   * kept. So `🔵 see [`README.md`](README.md)` rendered as a bare
   * `<a>README.md</a>`: marker concealed, monospace deleted, no highlight, no error.
   * Marker *discovery* still descends into links — the marker itself is only
   * text, and concealing it there has always been correct.
   */
  function flatten(list, out, inLink) {
    for (var i = 0; i < list.length; i++) {
      var t = list[i];
      if (t.type === "codespan" || t.type === "code") {
        out.push({ token: t, list: list, index: i, inLink: !!inLink });
        continue; // never descend into code
      }
      if (Array.isArray(t.tokens) && DESCEND[t.type]) {
        flatten(t.tokens, out, inLink || t.type === "link");
        continue;
      }
      if (t.type === "text") out.push({ token: t, list: list, index: i, inLink: !!inLink });
    }
    return out;
  }

  function processBlock(token) {
    if (token.__ymd || !Array.isArray(token.tokens)) return;
    token.__ymd = true;

    var flat = flatten(token.tokens, []);

    // 1. Find the first marker in a text leaf.
    var at = -1, hit = null;
    for (var i = 0; i < flat.length; i++) {
      var e = flat[i];
      if (e.token.type !== "text") continue;
      var m = MARKER_RE.exec(e.token.text || "");
      if (!m) continue;
      var name = COLORS[m[0].replace(/️/g, "")];
      if (!name) continue; // unrecognised: leave it visible
      at = i;
      hit = { name: name, index: m.index, raw: m[0], entry: e };
      break;
    }
    if (!hit) return;

    // 2. Conceal the marker and one following space.
    var t = hit.entry.token;
    var after = hit.index + hit.raw.length;
    if (t.text[after] === " ") after += 1;
    t.text = t.text.slice(0, hit.index) + t.text.slice(after);

    if (!HIGHLIGHTABLE[token.type]) return; // headings: concealed, never highlighted

    // 3. Highlight the first code span at or after the marker.
    //
    // A span inside a link label is skipped, not deferred to the next one:
    // "first code span at or after the marker" is the stated rule, and highlighting
    // a later span would quietly make it "first highlightable", which is a
    // different rule that no document expresses. So this conceals and tints
    // nothing — the same outcome the dialect already defines for a marker with
    // no code span after it, and byte-identical to the pre-feature render minus
    // the marker.
    for (var j = at; j < flat.length; j++) {
      if (flat[j].token.type !== "codespan") continue;
      // Order matters: test `inLink` only after establishing this is the first
      // code span. Breaking on any in-link leaf would also fire on a link's
      // *text*, so `🔵 [text](x) then \`b\`` would lose a highlight it should get.
      if (flat[j].inLink) break;
      var e2 = flat[j];
      e2.list[e2.index] = {
        type: "ymdHighlight",
        colour: hit.name,
        tokens: [e2.token],
        raw: "",
      };
      return;
    }
    // No code span on or after the marker — concealed, nothing tinted.
  }

  /**
   * Conceal in table cells, one marker per *cell*.
   *
   * A cell is the block here — the same relationship a list item has to its
   * list. Walking every text leaf instead made `| 🔴 x **🟢 y** |` conceal both
   * markers while the identical paragraph conceals only the first, silently
   * breaking the "one marker per block, not per line" rule this module's header
   * states. Cells take no highlight: a table is a leaf to the highlight walk, and the
   * dialect only highlights paragraphs and list items.
   *
   * The `__ymd` guard matches `processBlock`'s and exists for the same reason —
   * a second `install()` registers walkTokens twice, and without it the second
   * visit finds the cell's *next* marker and eats that one too.
   */
  function concealInTableCells(token) {
    if (token.__ymd) return;
    token.__ymd = true;

    var cells = (token.header || []).slice();
    (token.rows || []).forEach(function (r) { cells = cells.concat(r); });
    cells.forEach(function (c) {
      if (!c || !Array.isArray(c.tokens)) return;
      var flat = flatten(c.tokens, []);
      for (var i = 0; i < flat.length; i++) {
        var e = flat[i];
        if (e.token.type !== "text") continue;
        var m = MARKER_RE.exec(e.token.text || "");
        if (!m) continue;
        if (!COLORS[m[0].replace(/️/g, "")]) continue; // unrecognised: keep looking
        var a = m.index + m[0].length;
        if (e.token.text[a] === " ") a += 1;
        e.token.text = e.token.text.slice(0, m.index) + e.token.text.slice(a);
        return; // first effective marker in this cell wins
      }
    });
  }

  /**
   * Regions of rendered HTML where a marker glyph is not a marker.
   *
   * Two kinds, and both are needed:
   *
   * 1. `<code>…</code>` contents. For highlights this immunity is structural —
   *    `codespan` is a leaf token the walk never descends into — but a heading
   *    is decorated from rendered HTML, where that structure is gone.
   *
   * 2. Tags themselves, because attribute values live inside them. Masking only
   *    code let `## [t](x.md "🔴 tip")` tint a heading red with no marker
   *    visible anywhere, and deleted the emoji from `alt="🔴 done"` — a silent
   *    accessibility regression, since alt text is all a screen reader gets.
   *    Reachable from plain markdown through a link title; raw HTML makes it
   *    worse but is not required.
   *
   * Known limit: a literal `>` inside an attribute value would truncate a tag
   * range early. The shell escapes attributes on every path that builds them
   * (`escapeAttribute`), so rendered output does not contain one — this is a
   * bound, not a hole, and it is why the ranges are belt-and-braces rather than
   * a parser. Decorating from the DOM after `sanitizeRenderedHTML` would remove
   * the class of problem entirely; that is a larger change than this guard.
   */
  function maskedRanges(html) {
    var out = [], m;
    var tag = /<[^>]*>/g;
    while ((m = tag.exec(html))) out.push([m.index, m.index + m[0].length]);
    var code = /<code\b[^>]*>[\s\S]*?<\/code>/gi;
    while ((m = code.exec(html))) out.push([m.index, m.index + m[0].length]);
    return out;
  }

  /**
   * Conceal a heading's first effective marker and name its colour class.
   *
   * Headings are decorated here rather than in `walkTokens` because
   * marked 13.0.3 calls a heading renderer as `(text, level, raw)` whatever
   * arity it declares — no token reaches it, so a `walkTokens` flag is invisible
   * there. Working on `text` also keeps the pass off the slug: `raw` is a
   * separate plain-text projection of the *unmodified* tokens, so the heading id
   * is derived from input this function never touches.
   *
   * The colour lands as a class on the <hN>, never as a wrapping span. An
   * extension token inside a heading renders into the plain-text pass too —
   * measured: `Urgent \`PASS\` section` projects as
   * `Urgent <span class="ymd-highlight"><code>PASS</code></span> section` — which
   * corrupts the id and breaks #anchor links and scroll-restore.
   *
   * Returns null when nothing applies, so the caller emits its untouched
   * heading rather than a class name that means "no colour".
   */
  function decorateHeading(html) {
    if (!active) return null;
    var s = String(html == null ? "" : html);
    var ranges = maskedRanges(s);
    var re = new RegExp(MARKER_RE.source, "gu");
    var m;
    while ((m = re.exec(s))) {
      var inCode = false;
      for (var i = 0; i < ranges.length; i++) {
        if (m.index >= ranges[i][0] && m.index < ranges[i][1]) { inCode = true; break; }
      }
      if (inCode) continue;
      var name = COLORS[m[0].replace(/️/g, "")];
      if (!name) continue; // unrecognised: first *effective* marker wins
      var after = m.index + m[0].length;
      if (s[after] === " ") after += 1;
      return { html: s.slice(0, m.index) + s.slice(after), className: "ymd-head-" + name };
    }
    return null;
  }

  function install(marked, doc) {
    installStyles(doc);
    marked.use({
      hooks: {
        preprocess: function (markdown) {
          active = byteLength(markdown) <= MAX_YMD_HIGHLIGHT_BYTES;
          return markdown;
        },
      },
      walkTokens: function (token) {
        if (!active) return;
        // `heading` is absent: headings are decorated by decorateHeading() from
        // the shell's heading renderer, which is the only place the colour can
        // reach the <hN>. Concealing here as well would strip the marker before
        // that function ever sees it.
        if (token.type === "paragraph" || token.type === "list_item") {
          processBlock(token);
        }
        if (token.type === "table") {
          concealInTableCells(token);
        }
      },
      extensions: [
        {
          name: "ymdHighlight",
          renderer: function (t) {
            return (
              '<span class="ymd-highlight ymd-highlight-' + t.colour + '">' +
              this.parser.parseInline(t.tokens) +
              "</span>"
            );
          },
        },
      ],
    });
  }

  global.CmuxYMD = {
    install: install,
    decorateHeading: decorateHeading,
    COLORS: COLORS,
    PALETTE_CSS: PALETTE_CSS,
    MAX_YMD_HIGHLIGHT_BYTES: MAX_YMD_HIGHLIGHT_BYTES,
    // Always present, so a test can distinguish "armed" from "never ran".
    armed: false,
  };

  // Arm the pass. `marked` is loaded by the markedJS placeholder above this
  // script, so its absence is a load-order regression, not a runtime condition.
  //
  // Never write a literal placeholder token (double-brace + name) anywhere in
  // this file. It is inlined into the shell, and this module's substitution is
  // appended last -- so such a token survives into the built HTML unreplaced
  // and trips the "no unresolved placeholder" assertion forever, whose obvious
  // remedy is to weaken the assertion and thereby lose the real detector.
  // Record that
  // rather than throwing: shell.html's render catch degrades the whole document
  // to a raw <pre>, and a missing highlight is not worth blanking someone's page.
  //
  // `armed` exists because a quiet no-op is how this feature nearly shipped
  // inert with every unit test green — MarkdownYMDShellTests asserts it is true
  // in the real shell, which is what turns that failure mode into a red test.
  // The `typeof …use` check is deliberate: a partially-loaded `marked` passes a
  // bare truthiness test and then throws inside install(), which is exactly the
  // document-blanking path this avoids.
  if (global.marked && typeof global.marked.use === "function") {
    install(global.marked);
    global.CmuxYMD.armed = true;
  } else if (global.console) {
    console.error("[cmux-ymd] marked unavailable — YMD pass not armed");
  }
})(typeof globalThis !== "undefined" ? globalThis : this);
/* cmux-ymd:end */
