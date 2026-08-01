import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
import { Marked } from "../../Resources/markdown-viewer/marked.min.js";
import "../../Resources/markdown-viewer/ymd.js";

const YMD_PATH = new URL("../../Resources/markdown-viewer/ymd.js", import.meta.url);
const CmuxYMD = (globalThis as any).CmuxYMD;

/** A fresh marked instance with the YMD pass installed, no DOM required. */
function render(markdown: string): string {
  const marked = new Marked();
  CmuxYMD.install(marked, null);
  return marked.parse(markdown) as string;
}

/**
 * A fresh marked instance wired the way the real shell is: the YMD pass plus a
 * heading renderer that mirrors shell.html's, hook and slug included.
 *
 * `render()` deliberately does NOT do this, because the heading tint spans two
 * files and no single-file test can prove it. That is the same trap that let
 * install() be defined and never called with the whole bun suite green — the
 * suite builds its own environment, so anything the *shell* must do is invisible
 * unless a test restates it. This helper restates it; MarkdownYMDShellTests
 * proves the real shell actually does it.
 */
function renderShell(markdown: string): string {
  const marked = new Marked();
  CmuxYMD.install(marked, null);
  const slugs: Record<string, number> = {};
  marked.use({
    renderer: {
      heading(text: string, level: number, raw: string) {
        let base = String(raw || "").toLowerCase()
          .replace(/[^\w\- ]+/g, "").replace(/\s+/g, "-").replace(/^-+|-+$/g, "");
        if (!base) base = "heading";
        const n = slugs[base] || 0;
        slugs[base] = n + 1;
        const slug = n === 0 ? base : `${base}-${n}`;
        const deco = CmuxYMD.decorateHeading(text);
        const cls = deco ? ` class="${deco.className}"` : "";
        return `<h${level} id="${slug}"${cls}>${deco ? deco.html : text}</h${level}>\n`;
      },
    },
  });
  return marked.parse(markdown) as string;
}

function headingIDs(html: string): string[] {
  return [...html.matchAll(/<h[1-6] id="([^"]*)"/g)].map((m) => m[1]);
}

function highlightColours(html: string): string[] {
  return [...html.matchAll(/ymd-highlight ymd-highlight-(\w+)/g)].map((m) => m[1]);
}

/** Any of the seven supported marker glyphs still present in the output. */
function hasMarker(html: string): boolean {
  return /[\u{1F534}\u{1F7E0}\u{1F7E1}\u{1F7E2}\u{1F535}\u{1F7E3}\u{26AB}]/u.test(html);
}

// Scenario 1 — the case the 1st draft could not reach: 40 of 41 non-heading
// markers in the real corpus sit inside **bold**.
test("highlight: the marker is found wherever it sits, and the right code span is highlighted", () => {
  const item = render("- **Status:** **🟢`PASS`** item");
  expect(highlightColours(item)).toEqual(["green"]);
  expect(item).toContain("<strong>Status:</strong>");
  expect(item).toContain('<span class="ymd-highlight ymd-highlight-green"><code>PASS</code></span>');
  expect(hasMarker(item)).toBe(false);

  const para = render("**Agent verifies:** **🟢`PASS`** and more");
  expect(highlightColours(para)).toEqual(["green"]);
  expect(para).toContain("<p>");

  // Only the span after the marker is highlighted — the later one stays plain.
  const two = render("- **Agent verifies:** **🟢`PASS`** under scheme `cmux-unit`");
  expect(highlightColours(two)).toEqual(["green"]);
  expect(two).toContain("<code>cmux-unit</code>");
  expect(two).not.toContain('ymd-highlight-green"><code>cmux-unit');

  // A marker inside a link: concealed, link intact, nothing highlighted.
  const link = render("[🔵 docs](https://example.com) tail");
  expect(highlightColours(link)).toEqual([]);
  expect(link).toContain('<a href="https://example.com">docs</a>');
  expect(hasMarker(link)).toBe(false);

  // A code span *inside a link label* is never highlighted, even when it is the
  // first one after the marker. The highlight would be emitted inside the <a>, and
  // shell.html's sanitizeLinkLabelHTML allows only br/code/del/em/img/s/strong
  // in a link label — a <span> is replaced by its textContent, which destroys
  // the <code> descendant the same pass had just kept. Net effect before this
  // guard: marker concealed, monospace silently deleted, no highlight, no error.
  const linkCode = render("🔵 see [`README.md`](README.md) for more");
  expect(linkCode).toContain('<a href="README.md"><code>README.md</code></a>');
  expect(linkCode).not.toMatch(/<a[^>]*>\s*<span class="ymd-highlight/);
  expect(hasMarker(linkCode)).toBe(false);
  // Concealed but untinted, matching the documented "no code span after the
  // marker" behaviour rather than silently highlighting something further along.
  expect(highlightColours(linkCode)).toEqual([]);

  // ...and a highlightable span outside the link still wins when it comes first.
  const beforeLink = render("- **S:** **🟢`PASS`** in [`ymd.js`](x.md)");
  expect(highlightColours(beforeLink)).toEqual(["green"]);
  expect(beforeLink).toContain('<a href="x.md"><code>ymd.js</code></a>');

  // Blockquote: reached through its inner paragraph.
  const quote = render("> quoted 🔴 `X` line");
  expect(highlightColours(quote)).toEqual(["red"]);
  expect(quote).toContain("<blockquote>");
});

// Scenario 2 — the rule two earlier drafts stated wrongly.
test("per block: one marker per block, not per line", () => {
  const html = render("first 🟢 `A` line\nsecond 🔴 `B` line\nthird 🟠 `C` line");
  expect(highlightColours(html)).toEqual(["green"]);
  expect(html).toContain("<code>B</code>");
  expect(html).toContain("<code>C</code>");
  // The later markers are content, not syntax — they survive.
  expect(html).toContain("🔴");
  expect(html).toContain("🟠");

  // A blockquote is not itself a block: each inner paragraph is one.
  const quote = render("> first 🟢 `A`\n>\n> second 🔴 `B`");
  expect(highlightColours(quote)).toEqual(["green", "red"]);
});

// Scenario 3 — conceal-and-tint, never highlight. Uses renderShell because the
// heading path lives half in the shell's renderer; `render()` alone would show
// an untouched heading and prove only that walkTokens leaves headings be.
test("heading: headings conceal and tint, without a highlight", () => {
  const h2 = renderShell("## 🟠⋯ Section");
  expect(highlightColours(h2)).toEqual([]);
  expect(h2).toContain('<h2 id="section" class="ymd-head-orange">⋯ Section</h2>');
  expect(hasMarker(h2)).toBe(false);

  // Heading exclusion beats the highlight rule; the span stays a plain span.
  const withCode = renderShell("## 🟠 `CODE` heading");
  expect(highlightColours(withCode)).toEqual([]);
  expect(withCode).toContain("<code>CODE</code>");
  expect(withCode).toContain('class="ymd-head-orange"');
  expect(hasMarker(withCode)).toBe(false);

  const bare = renderShell("# 🔵");
  expect(hasMarker(bare)).toBe(false);
  expect(bare).toContain('class="ymd-head-blue"');

  // An untinted heading gains no class at all — "no colour" must not be spelled
  // as a class name, or the CSS has to carry a meaningless default.
  expect(renderShell("## Plain")).toContain('<h2 id="plain">Plain</h2>');
});

// Scenario 3b — the invariant every heading decision has been built around: the
// pass must not move an anchor id. This is the guard that made highlights illegal in
// headings, so it has to keep holding now that headings are decorated instead.
// walkTokens no longer edits heading tokens at all, so `raw` — the plain-text
// projection the slug derives from — is byte-identical with the pass on or off.
test("heading: decoration cannot move an anchor id", () => {
  const doc = [
    "# 🔵⋯ Comments",
    "## 🟠⋯ @cmux-rbf `#cm-15` [feat | read plans](x.md)",
    "### 🟣⋯ v0.6.0 — conceal the marker",
    "#### 🟡⋯ What's the situation?",
    "## 🟠⋯ Comments",          // duplicate base: exercises the -1 counter
    "## Comments",              // same base again, unmarked
    "## `🔴 literal` heading",  // marker in code: must not decorate
  ].join("\n\n");

  const tinted = headingIDs(renderShell(doc));
  const plain = headingIDs(renderShell(doc.replace(/[🔴🟠🟡🟢🔵🟣⚫]/gu, "")));
  expect(tinted).toEqual(plain);
  // Pinned to measured values, not predicted ones: `[^\w\- ]+` deletes `|` and
  // `—` outright, so the spaces around them collapse to a single `-`, and the
  // leading `-` left by a code-span heading is stripped by `^-+`.
  expect(tinted).toEqual([
    "comments", "cmux-rbf-cm-15-feat-read-plans", "v060-conceal-the-marker",
    "whats-the-situation", "comments-1", "comments-2", "literal-heading",
  ]);
});

// Scenario 2b — table cells obey the same per-block rule as everything else,
// and survive a double install.
//
// Both halves were defects. `concealInTableCells` walked every text leaf in a
// cell, so `| 🔴 x **🟢 y** |` concealed BOTH markers where the identical
// paragraph conceals only the first — the module header promises "one marker
// per block, not per line" and tables quietly did not honour it. And the table
// path had no `__ymd` re-entry guard, so under the second install the guard
// elsewhere exists to defend against, a table ate its next marker too.
test("table: one marker per cell, and a second install changes nothing", () => {
  // Per-cell, matching the paragraph rule rather than per-leaf.
  const mixed = render("| h |\n| --- |\n| 🔴 x **🟢 y** |");
  expect(mixed).toContain("🟢");
  expect(hasMarker(mixed.replace(/🟢/gu, ""))).toBe(false);

  // Each cell is its own block, so a second cell still gets its own conceal.
  const twoCells = render("| a | b |\n| --- | --- |\n| 🔴 x | 🟢 y |");
  expect(hasMarker(twoCells)).toBe(false);

  // Re-entry: installing twice must not let the pass reprocess its own output.
  const marked = new Marked();
  CmuxYMD.install(marked, null);
  CmuxYMD.install(marked, null);
  const doubled = marked.parse("| h |\n| --- |\n| 🔴 x 🟢 y |") as string;
  expect(doubled).toContain("🟢");
});

// Scenario 4 — the #zed-09 bug class this design claims is structurally
// unwritable, because `code`/`codespan` are leaf tokens.
test("code: fenced and inline code stay literal", () => {
  const fenced = render("```\n🔴 text\n```");
  expect(fenced).toContain("🔴");
  expect(highlightColours(fenced)).toEqual([]);

  const inline = render("`🔴 literal`");
  expect(inline).toContain("🔴");
  expect(highlightColours(inline)).toEqual([]);

  // A marker inside a code span is not a marker, so it cannot highlight its own span.
  const mixed = render("text `🔴 inside` tail");
  expect(highlightColours(mixed)).toEqual([]);
  expect(mixed).toContain("🔴");
});

// Scenario 5 — dialect rules and passthrough.
test("dialect: first-effective-wins, passthrough, variation selectors, tables", () => {
  const first = render("🔵 see 🟢 also `x`");
  expect(highlightColours(first)).toEqual(["blue"]);
  expect(first).toContain("🟢");

  const unsupported = render("🚀 ship it `x`");
  expect(highlightColours(unsupported)).toEqual([]);
  expect(unsupported).toContain("🚀");

  // ⚪ is not a YMD colour — the asymmetry is itself the pass/pending signal.
  const pending = render("**⚪`PENDING`**");
  expect(highlightColours(pending)).toEqual([]);
  expect(pending).toContain("⚪");
  expect(pending).toContain("<code>PENDING</code>");

  // U+FE0F variation selector still resolves.
  const vs16 = render("⚫️ `x`");
  expect(highlightColours(vs16)).toEqual(["black"]);

  // Table cells conceal but never highlight.
  const table = render("| a |\n| --- |\n| 🟢 cell |");
  expect(highlightColours(table)).toEqual([]);
  expect(hasMarker(table)).toBe(false);

  const noSpan = render("🟢 marker with no code span");
  expect(highlightColours(noSpan)).toEqual([]);
  expect(hasMarker(noSpan)).toBe(false);
});

// Scenario 6 — the ceiling, counted in UTF-8 bytes. The value is measured
// for this panel, not inherited from ymd.rs; see the constant's comment.
test("ceiling: the byte gate holds and is counted in UTF-8 bytes", () => {
  const max = CmuxYMD.MAX_YMD_HIGHLIGHT_BYTES;
  // Measured, not inherited from ymd.rs's 100,000 — at that value the largest
  // brief in the corpus (106,055 bytes) was skipped silently.
  expect(max).toBe(250000);

  const marked = "\n\n🟢 `PASS`\n";
  const overflow = "x".repeat(max + 1 - marked.length) + marked;
  expect(new TextEncoder().encode(overflow).length).toBeGreaterThan(max);
  expect(highlightColours(render(overflow))).toEqual([]);

  const under = "x".repeat(max - 200 - marked.length) + marked;
  expect(new TextEncoder().encode(under).length).toBeLessThanOrEqual(max);
  expect(highlightColours(render(under))).toEqual(["green"]);

  // Bytes, not UTF-16 units. Sized off `max` rather than a literal, so raising
  // the ceiling cannot quietly turn this case into a no-op: "é" is 1 UTF-16
  // unit and 2 UTF-8 bytes, so 0.6 * max characters is under the limit by
  // `.length` and 1.2 * max over it in bytes, at any ceiling.
  const dense = "é".repeat(Math.floor(max * 0.6)) + marked;
  expect(dense.length).toBeLessThan(max);
  expect(new TextEncoder().encode(dense).length).toBeGreaterThan(max);
  expect(highlightColours(render(dense))).toEqual([]);

  // The heading path has its own `active` check, and nothing discriminated it:
  // deleting `if (!active) return null` from decorateHeading left the whole
  // suite green, because every other ceiling assertion measures highlights. A guard
  // no test can catch is the finding, per rbf/AGENTS.md — so gate a heading on
  // an oversize document explicitly.
  const overflowHeading = "## 🟠⋯ Late heading\n\n" + "x".repeat(max + 1);
  expect(new TextEncoder().encode(overflowHeading).length).toBeGreaterThan(max);
  const gated = renderShell(overflowHeading);
  expect(gated).toContain("🟠");                    // marker survives untouched
  expect(gated).not.toContain("ymd-head-");          // and takes no tint
  // ...while the same heading under the ceiling is decorated normally.
  expect(renderShell("## 🟠⋯ Late heading")).toContain('class="ymd-head-orange"');
});

// Scenario 7 — catches the likely real defect: a colour that forgets its dark
// block or copies the light hex.
test("palette: every colour resolves light and dark, and they differ", () => {
  const css: string = CmuxYMD.PALETTE_CSS;
  const names = Object.values(CmuxYMD.COLORS) as string[];
  expect(names).toHaveLength(7);

  const dark = css.slice(css.indexOf("@media"));
  const light = css.slice(0, css.indexOf("@media"));

  for (const name of names) {
    const l = new RegExp(`\\.ymd-highlight-${name}\\{--ymd-highlight-bg:(#[0-9a-f]{6})\\}`).exec(light);
    const d = new RegExp(`\\.ymd-highlight-${name}\\{--ymd-highlight-bg:(#[0-9a-f]{6})\\}`).exec(dark);
    expect(l, `${name} missing a light background`).not.toBeNull();
    expect(d, `${name} missing a dark background`).not.toBeNull();
    expect(l![1], `${name} copies its light hex into dark`).not.toBe(d![1]);
  }

  // Transcribed byte-for-byte from ymd.rs background() / background_style().
  expect(light).toContain(".ymd-highlight-red{--ymd-highlight-bg:#ffcdd2}");
  expect(dark).toContain(".ymd-highlight-red{--ymd-highlight-bg:#5c3a3a}");
  expect(light).toContain("--ymd-fg:#1a1a1a");
  expect(dark).toContain("--ymd-fg:#e0def4");
});

// The `__ymd` re-entry guard. Mutation testing showed removing it changes
// nothing under a single install() — the guard is insurance against a *second*
// install registering walkTokens twice, which is the only way a block is
// visited more than once. Without it the second pass finds the block's next
// marker and conceals that too, silently making the rule per-visit instead of
// per-block. This is the only test that discriminates the guard.
test("re-entry: a second install does not let the pass reprocess its own output", () => {
  const marked = new Marked();
  CmuxYMD.install(marked, null);
  CmuxYMD.install(marked, null);
  const html = marked.parse("first 🟢 `A` second 🔴 `B`") as string;

  expect(highlightColours(html)).toEqual(["green"]);
  // The second marker is content and must survive a doubled pass.
  expect(html).toContain("🔴");
  expect(html).toContain("<code>B</code>");
});

// Guards finding #7 directly: the prototype exported install() and never called
// it, which would have shipped an inert feature with every test here green.
test("arming: the module arms itself when marked is present, and records when it is not", () => {
  const source = readFileSync(YMD_PATH, "utf8");
  // Run the module in a fresh context so `globalThis` inside the IIFE is a real
  // global we control, rather than this test file's. Each call re-executes the
  // module from scratch, which import caching would not.
  const load = (sandbox: Record<string, unknown>) => {
    runInNewContext(source, sandbox);
    return sandbox as any;
  };

  let used = 0;
  const armed = load({ marked: { use: () => { used += 1; } }, console });
  expect(armed.CmuxYMD.armed).toBe(true);
  expect(used).toBe(1);

  const bare = load({ console: { error: () => {} } });
  expect(bare.CmuxYMD.armed).toBe(false);

  // A half-loaded marked must not be treated as usable — calling into it would
  // throw, and the shell's render catch degrades the whole document to <pre>.
  const partial = load({ marked: {}, console: { error: () => {} } });
  expect(partial.CmuxYMD.armed).toBe(false);
});

// Scenario 10 — the heading tint. marked v13.0.3 hands a heading renderer
// (text, level, raw) unconditionally: declaring arity-1 still receives three
// positional args, so no token flag can reach it and no walkTokens mutation is
// visible there. `text` is rendered HTML, which is why decorateHeading takes a
// string and must mask code spans itself rather than lean on token structure.
test("heading tint: the marker's colour becomes a class on the heading", () => {
  const d = CmuxYMD.decorateHeading("🟠⋯ Section");
  expect(d, "no decoration returned for a marked heading").not.toBeNull();
  expect(d.className).toBe("ymd-head-orange");
  expect(d.html).toBe("⋯ Section");

  // All seven, so a colour cannot be dropped from the mapping unnoticed.
  const seen = Object.entries(CmuxYMD.COLORS as Record<string, string>).map(
    ([glyph, name]) => [CmuxYMD.decorateHeading(`${glyph} T`)?.className, `ymd-head-${name}`],
  );
  for (const [got, want] of seen) expect(got).toBe(want);

  // Unmarked and unrecognised headings decorate to nothing, not to a default.
  expect(CmuxYMD.decorateHeading("Plain heading")).toBeNull();
  expect(CmuxYMD.decorateHeading("🟤 not in the dialect")).toBeNull();
});

// Scenario 11 — code immunity, which is structural for highlights (code/codespan are
// leaf tokens) but NOT free here: decorateHeading sees rendered HTML, where a
// marker inside <code> is just text. Losing this makes `## \`🔴 x\`` conceal a
// literal the rest of the feature promises to leave alone.
test("heading tint: a marker inside a heading's code span is not a marker", () => {
  expect(CmuxYMD.decorateHeading("<code>🔴 x</code> heading")).toBeNull();

  // ...but one outside the span still counts, and the span survives intact.
  const after = CmuxYMD.decorateHeading("<code>x</code> 🔴 heading");
  expect(after?.className).toBe("ymd-head-red");
  expect(after?.html).toBe("<code>x</code> heading");

  const before = CmuxYMD.decorateHeading("🔵 lead <code>🔴 y</code>");
  expect(before?.className).toBe("ymd-head-blue");
  expect(before?.html).toBe("lead <code>🔴 y</code>");
});

// Scenario 11b — markers inside HTML *attributes* are not markers either.
// decorateHeading sees rendered HTML, so a title=/alt= value is just text to a
// naive scan: `## [t](x.md "🔴 tip")` tinted the heading red with no marker
// visible anywhere, and `alt="🔴 done"` had the emoji deleted from it — a
// silent accessibility regression, since alt text is the only thing a screen
// reader gets. Reachable from ordinary markdown via a link title.
test("heading tint: a marker inside an HTML attribute is not a marker", () => {
  // Link title — plain markdown, no raw HTML needed to reach this.
  expect(CmuxYMD.decorateHeading('<a href="x.md" title="🔴 tip">t</a> heading')).toBeNull();

  // Attribute values must come back byte-identical, emoji included.
  const img = CmuxYMD.decorateHeading('<img alt="🔴 done"> rest');
  expect(img).toBeNull();

  const span = CmuxYMD.decorateHeading('<span title="🔴">x</span> rest');
  expect(span).toBeNull();

  // A real marker in text still wins, and the attribute survives untouched.
  const mixed = CmuxYMD.decorateHeading('🟢 ok <img alt="🔴 done"> rest');
  expect(mixed?.className).toBe("ymd-head-green");
  expect(mixed?.html).toBe('ok <img alt="🔴 done"> rest');
});

// Scenario 12 — the tint is text colour, so unlike the highlight (whose foreground is
// fixed on its own background) it inherits the canvas. Measured against the
// panel's own canvases: h1 🔵 8.63/13.48, h2 🟠 3.79/14.92, h3 🟣 11.86/11.46 —
// all clear the 3:1 large-text bar their sizes earn.
//
// Light yellow does not, and this test does not pretend otherwise. h4 is 16px,
// below the large-text tier, and the shipped #f9a825 measures 1.97:1 — a dated
// exception (Tom, 2026-08-01), taken because every value that clears a contrast
// bar is a gold rather than a yellow, and two were rejected on sight proving it.
// The assertion here pins the exception so it cannot drift silently; it is not
// evidence of compliance. Dark mode needs no exception and keeps byte-parity.
test("heading palette: every colour resolves light and dark, yellow is the pinned exception", () => {
  const css: string = CmuxYMD.PALETTE_CSS;
  const dark = css.slice(css.indexOf("@media"));
  const light = css.slice(0, css.indexOf("@media"));
  const names = Object.values(CmuxYMD.COLORS) as string[];

  for (const name of names) {
    const l = new RegExp(`\\.ymd-head-${name}\\{color:(#[0-9a-f]{6})\\}`).exec(light);
    const d = new RegExp(`\\.ymd-head-${name}\\{color:(#[0-9a-f]{6})\\}`).exec(dark);
    expect(l, `${name} missing a light heading colour`).not.toBeNull();
    expect(d, `${name} missing a dark heading colour`).not.toBeNull();
    expect(l![1], `${name} copies its light hex into dark`).not.toBe(d![1]);
  }

  // Transcribed from ymd.rs foreground(); dark inverts to the light backgrounds.
  expect(light).toContain(".ymd-head-blue{color:#0d47a1}");
  expect(dark).toContain(".ymd-head-blue{color:#bbdefb}");
  // Light yellow is a dated exception (Tom, 2026-08-01): 1.97:1 on #ffffff
  // (1.66:1 was #fbc02d, tried and rejected — do not quote it as shipped),
  // below WCAG AA, chosen from rendered swatches because every value that
  // clears a contrast bar is a gold rather than a yellow. Pinned so it cannot
  // drift silently — a change here is a decision, not a tweak.
  expect(light).toContain(".ymd-head-yellow{color:#f9a825}");
  // Not the dialect's own #f57f17: at hue 28° it is an amber that collides with
  // h2 orange (hue 21°), the exact confusion the adjacent-pair fixture tests.
  expect(light).not.toContain("#f57f17");

  // A tinted heading must not swallow its own link: `color` on the <hN> would
  // otherwise cascade into <a>, which is the defect that killed line-tinting.
  expect(css).toContain("--fgColor-accent");
});
