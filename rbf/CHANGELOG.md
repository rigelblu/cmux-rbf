---
title: "Cmux RBF Changelog"
---

Fork releases use the version in `rbf/VERSION`; upstream release history remains in the root `CHANGELOG.md`.

# 🔵⋯ [Unreleased]
(empty)

---

# 🔵⋯ v0.11.1 (2026-08-02) — #cm-21
## 🟠⋯ Fixed for End Users
- 2026-08-02 - fix (ux) | stop being told your terminal is stuck on a theme it is not stuck on — v0.11.0's caveat fired on a **one-sided** conditional theme such as `theme = light:X`, where the terminal in fact follows the appearance: it renders `X` in light and ghostty's default in dark. The message claimed both appearances kept `X`, and named a theme the dark side never loads. **This was reachable through v0.11.0's own advice** — `cmux themes set --light X`, run without the matching `--dark`, writes exactly that value (#cm-21)

## 🟠⋯ Changed for Developers
- 2026-08-02 - fix (perf) | the Theme caveat no longer does its config read on the main thread each time the config reloads — a signal that fires on appearance switches, font-size steppers and theme-preview scrubbing, not just theme edits. The read now happens off the main actor and is delivered back to the UI when it completes (#cm-21)
- 2026-08-02 - fix (perf) | changing any ghostty setting no longer invalidates all ~45 rows of the App settings card to re-render an identical caveat (#cm-21)

## 🟠⋯ Known Limitations
- **A one-sided theme now stays silent rather than warning wrongly, and that is the deliberate stopping point.** `theme = light:X` leaves your dark appearance on ghostty's default theme, which you may not have intended — but cmux cannot tell an unfinished pair from a chosen one, and v0.11.0 shows what happens when it guesses (#cm-21)
- Themes that are aliases of one another (`Solarized Light` and `iTerm2 Solarized Light`) resolve to different names, so a terminal effectively pinned through two aliases still gets no caveat. Missing message, never a wrong one (#cm-21)
- The caveat reads the config paths cmux scans, which are the standard `~/.config/ghostty/` locations. A config located through `XDG_CONFIG_HOME` is not scanned, so a pinned theme there is never reported — a pre-existing scan-path limitation, not introduced here (#cm-21)

---

# 🔵⋯ v0.11.0 (2026-08-02) — #cm-21
## 🟠⋯ Fixed for End Users
- 2026-08-02 - fix (ux) | find out *why* your terminal keeps one background in both appearances, instead of concluding cmux is broken — when your Ghostty `theme` resolves to the same theme for light and dark, the Theme picker in Settings → App now says so and names the theme that is pinned. Set Appearance to System and the picker's System tile shows a split light/dark thumbnail — a picture of the app switching — which the terminal cannot honour while one theme is pinned to both sides. The fix is `theme = light:<one>,dark:<other>` in your Ghostty config, or `cmux themes set --light <one> --dark <other>` — **both sides, not one** (#cm-21). **Corrected in v0.11.1:** as shipped in v0.11.0 this caveat also fired on a one-sided `light:X`, where the terminal does follow the appearance

## 🟠⋯ Known Limitations
- **This does not make a pinned theme follow the appearance — it tells you that it cannot.** cmux has always supported `light:…,dark:…` and shipped `cmux themes set --light X --dark Y`; what was missing was any signal that a single unconditional `theme` silently defeats an Appearance setting of System. Choosing the pair is still yours (#cm-21)
- The line appears only under Appearance = **System**. Under an explicit Light or Dark there is nothing for the terminal to follow, so a pinned theme is exactly what you asked for (#cm-21)
- **A paired light/dark theme usually changes more than the background.** If the two themes carry different `background-image-opacity` values, the window background image `#cm-13` draws will change weight with the appearance — that is the themes' doing, not cmux's (#cm-21)
- **Colour-valued settings cannot follow the appearance at all.** Ghostty's conditional `light:`/`dark:` form exists for `theme` only, so a value like `unfocused-split-fill = #000000` tuned against a light background stays black in dark, where unfocused splits can go nearly invisible. Nothing warns about this one (#cm-21)

---

# 🔵⋯ v0.10.0 (2026-08-02) — #cm-20
## 🟠⋯ Changed for End Users
- 2026-08-02 - feat (ux) | read a coloured workspace row as a row that carries a colour, rather than as a filled swatch — the same-colour wash `#cm-10` puts behind every coloured sidebar row drops to a quiet tint. Resting `14% → 5%`, hovered `24% → 9%`, multi-selected `35% → 13%`, scaled together so the resting → hover → multi-select ladder keeps its shape instead of flattening at the bottom. The identity strip comes down with them, `95% → 85%`, and stays the strongest colour on a resting row (#cm-20)
- 2026-08-02 - fix (ux) | keep the selected workspace's strip exactly as bright while the rows around it go quiet — the active strip's tint and the resting wash were **one shared number**, so lowering the wash would have bleached the one strip that names the workspace you are in. They are now separate values, and a test pins them apart (#cm-20)

## 🟠⋯ Changed for Developers
- 2026-08-02 - docs (dx) | get handed a command you can run instead of a path that has gone stale — an agent finishing a change hands back `make run`, or `make -C <worktree> run` when it built somewhere other than your checkout. A `file://` link addresses a bundle that was *already* built, so it keeps resolving after the tree moves on and launches the previous build without saying so. `make help` carries the `-C` example too, so an agent that never opens `rbf/AGENTS.md` still sees it (#cm-19)

## 🟠⋯ Known Limitations
- **The weights are not configurable, by design.** An opacity knob was considered and declined: `#cm-10` had just removed `workspaceColors.indicatorStyle` on the argument that one good treatment beats three configurable ones, a raw float is a value nobody can set by reading it, and it is not independent of the hover/multi ladder or the strip's 3:1 contrast floor (#cm-20)
- Hover now sits at `9%`, below what *resting* used to be at `14%`. It still lifts a row measurably, but the hover→resting gap is the first thing to check if a row starts reading flat (#cm-20)
- If two near-twin workspace colours become hard to tell apart, **the strip is the thing to widen or brighten, not the wash to raise back.** Composited over the sidebar material, a nearby pair separates by well under 1.5% per channel even at `#cm-10`'s original `14%` — the wash never was the discriminator. What separates them at rest is the strip (#cm-20)

---

# 🔵⋯ v0.9.0 (2026-08-02) — #cm-17, #cm-18, #cm-19
## 🟠⋯ Added for End Users
- 2026-08-02 - feat (ux) | use the cmux you build as your everyday app instead of launching it out of a build directory — the fork installs as **cmux RBF** in `/Applications`, with its own green `RBF` banner icon, its own bundle id and its own socket. Upstream's `cmux.app` is never read, written or replaced, so it stays as the fallback and both can run at once (#cm-17)
- 2026-08-02 - feat (ux) | open the fork into the workspaces you already have, not an empty window — the first install copies your workspaces, window layout, session order and reopen history across. Re-installing never touches them again, including workspaces created since (#cm-17)
- 2026-08-02 - feat (ux) | read the whole plan before anything is written — `make install-rbf-plan` prints the target path, both bundle ids, the signing identity and the state-migration decision, and writes nothing. `make install-rbf` acts. The plain name acts and a `-plan` suffix previews, except where a plain name cannot act safely and refuses instead: `make install` now points at `install-rbf` rather than doing something far larger than "install" promises (#cm-17)
- 2026-08-02 - feat (ux) | keep your macOS permissions across every reinstall — the install signs with the stable `cmux Dev Signing` identity rather than ad-hoc, so Accessibility, Screen Recording and Full Disk Access survive instead of silently resetting each time (#cm-17)

## 🟠⋯ Fixed for End Users
- 2026-08-02 - fix (ghostty) | see each character the moment you press it — a single keypress into an idle focused pane could sit unrendered indefinitely; it now paints in the first frame. The cause was slot-zero reuse in the ghostty fork's frame rotation, so a queued frame was overwritten instead of drawn (#cm-18)

## 🟠⋯ Changed for Developers
- 2026-08-02 - feat (dx) | build and run this checkout without inventing a build-id or hunting a DerivedData path — `make run`, `make build`, `make test`. The build-id comes from your branch (`tom-rigelblu/cm-19` → `cm-19`), so two builds never collide and nobody picks a name (#cm-19)
- 2026-08-02 - feat (dx) | reclaim the disk that old builds hold — `make clean-builds-plan` lists every per-build-id DerivedData directory with its size, `make clean-builds` deletes them, keeping only the build whose app is running, the most recent reload, and your current build-id. **It does not check whether a branch still exists** — read the plan before running it. First real run reclaimed **85.8 GB across 14** build-ids (#cm-19)
- 2026-08-02 - fix (dx) | stop a build silently linking a GhosttyKit your tree does not record — a merge or rebase moves the submodule pointer while the `ghostty` working directory stays put, and the artifact cache keys on the checked-out SHA, so the build succeeded and ran the wrong renderer. It now refuses, and names the fix (#cm-19)
- 2026-08-02 - fix (dx) | stop builds breaking with "it worked yesterday" — XcodeProj was declared `from: "9.0.0"`, an open upper bound, so a freely-resolving build drifted the lockfile to a version where `XcodeProjectAdapter.swift` stops compiling. The build that *does* the drift succeeds and the next one fails. Now capped below 9.15.0 in the manifest, where every entrypoint inherits it (#cm-17)
- 2026-08-02 - fix (dx) | make `make install-rbf` find the Zig that ghostty accepts — the 0.15.2 preflight lived inside `dev.sh`, which `install-rbf.sh` never passes through, so a Release build died ~200 lines into an Xcode script phase. It is now shared, and fatal before the build rather than during it (#cm-17)

## 🟠⋯ Known Limitations
- `~/.config/cmux/cmux.json` resolves from `$HOME`, not the bundle id, so both apps share it. A settings change in one appears in the other. This is the one place the "two separate apps" model does not hold — and it is also why your shortcuts and sidebar config need no migration at all (#cm-17)
- **You will sign in to cmux RBF once, by hand.** Auth lives in the keychain under a service name derived from the bundle id, so a separate app cannot see it by construction and no file copy reaches it. An earlier draft promised sign-in carried across; it does not (#cm-17)
- **About still reports upstream's version** — `0.64.20 / 100`, identical to what upstream shows, because the fork inherited both version keys at the fork point. The install already writes a fork-owned `RBFVersion` key into the bundle, but no reader consumes it yet; until `#cm-17.3` adds one, `env | grep CMUX_BUNDLE_ID` is the authoritative answer to "which cmux am I in?"; `com.cmuxterm.app.rbf` is the fork (#cm-17)
- The `cmux` CLI on your `PATH` still resolves to upstream's app. Deliberate for now — `reload.sh` refuses to shadow the production CLI, and which app should own the name is unsettled (#cm-17)
- macOS may ask *"cmux RBF would like to access data from other apps"* — **Allow is correct.** Both apps keep their state under `~/Library/Application Support/cmux/`, a directory macOS attributes to upstream, so it reads the fork as reaching into another app's data. It is not tied to installing: it can appear on an ordinary quit and relaunch. Giving the fork its own directory would end it, and was declined for now because `"cmux"` is hardcoded as that path component at 12+ upstream-owned sites — a permanent merge surface out of proportion to one click (#cm-17)

---

# 🔵⋯ v0.8.0 (2026-08-01) — #cm-15
## 🟠⋯ Added for End Users
- 2026-08-01 - feat (ux) | read your color-coded plans in the markdown panel instead of raw marker emoji — the first 🔴🟠🟡🟢🔵🟣⚫ in a block disappears, and outside headings it tints the code span beside it, so `**🟢`PASS`**` reads as a green `PASS` highlight and a verification table scans by colour (#cm-15)
- 2026-08-01 - feat (ux) | tell your plan's sections apart by colour, not just by size — a heading keeps its marker's colour as text tint. Colour is pre-attentive where a 4px size step is not, so headings separate at scroll distance (#cm-15)
- 2026-08-01 - feat (ux) | choose what the markdown viewer paints its page on — **Terminal** leaves it transparent so your terminal background shows through, **Solid** paints the canvas GitHub's markdown styling was designed against. Per-viewer, from the `AA` popover, the command palette, Settings, or `markdown.background` in `~/.config/cmux/cmux.json` (#cm-15)
- 2026-08-01 - feat (ux) | read inline code without it shouting over the status highlights — plain code spans stepped back from GitHub's 20% grey overlay to 15%, so a highlight reads as a status and a code span reads as monospace (#cm-15)

## 🟠⋯ Known Limitations
- Markers inside fenced blocks and inline code stay literal, by design — a marker in backticks is content, not syntax.
- `⚪` is not a YMD colour: `**⚪`PENDING`**` keeps its glyph and takes no highlight, while `**🟢`PASS`**` loses its glyph and gains one. The asymmetry *is* the pass/pending signal, not an oversight.
- A marker before a code span that sits inside a link label conceals but does not tint. A highlight there would be a `<span>` inside an `<a>`, which the link-label sanitizer strips — taking the `<code>` with it.
- Light-mode yellow and green are deliberate WCAG AA exceptions (1.97:1 and 3.22:1 on `#ffffff`), accepted by dated decision. Yellow is the one hue whose identity *is* its luminance — anything dark enough to pass reads as gold, not yellow. Both sit on headings, where level is already carried by size, weight and position, so the colour is redundant signal rather than sole signal. Switching the viewer to **Solid** makes those ratios fixed and checkable.
- Documents over 250,000 bytes are skipped entirely — the pass costs ~14ns/byte, so the ceiling keeps a pathological file from spending a frame on markers.
- Heading colour never becomes a highlight. The shell derives heading ids from a plain-text projection that does not cover extension tokens, so a highlight in a heading corrupts its `#anchor` link and the scroll-restore that depends on it.

---


---

# 🔵⋯ v0.7.0 (2026-08-01) — #cm-9
## 🟠⋯ Added for End Users
- 2026-08-01 - fix (ux) | rename a Codex session once and see it in cmux — typing `/rename` in Codex now renames the cmux tab hosting it, and the workspace too when that session is the only agent working there, so one piece of work stops carrying two different names (#cm-9)
- 2026-08-01 - fix (ux) | keep the name you chose yourself — a name you set in cmux still wins over anything Codex sends, and only a rename you explicitly typed syncs; the names Codex generates on its own are ignored, and neither a redraw of the confirmation nor a scripted keystroke can trigger one (#cm-9)

- 2026-08-01 - fix (ux) | stop shells opening with a corrupted PATH — a use-after-free in the ghostty fork's spawn-environment assembly appended freed memory to every shell cmux started, which crashed Codex on startup, silently killed its hooks and MCP servers, and showed up as a background-transparency glitch; all three were the same bug (#cm-9)

## 🟠⋯ Known Limitations
- Codex 0.146.0 registers a session with cmux only when that session submits its first real prompt — it never runs a session-start hook. A `/rename` typed before you have sent Codex anything is therefore declined and nothing changes. Send one message first, and renames land from then on (#cm-9)
- Dragging a Codex tab into a different workspace stops its renames. The tab keeps working; only the rename sync goes quiet, and it comes back when the surface is recreated. Rename before you move the tab, or move it back (#cm-9)
- With two Codex sessions in one workspace whose hook payloads carry no workspace binding, each can believe it is the only agent there, so the second `/rename` can retitle the whole workspace rather than just its own tab. Tab titles are always correct; only the workspace title is affected (#cm-9)

---

# 🔵⋯ v0.6.0 (2026-08-01) — #cm-11
## 🟠⋯ Added for End Users
- 2026-08-01 - feat (ux) | give a workspace colour the meaning it already has in your head — label Teal `GOAL: Primary` and cmux shows it as **GOAL: Primary (Teal)** everywhere you pick a colour, while the colour's own name, its hex, your saved workspaces, and your scripts keep working exactly as before (#cm-11)
- 2026-08-01 - feat (ux) | see which colour a workspace already has before you change it — the colour menu checks the entry that is assigned, and shows a mixed marker when several selected workspaces disagree, instead of making you assign one and look (#cm-11)
- 2026-08-01 - feat (ux) | clear a colour by one name everywhere — the command palette entry that read *Reset Workspace Color* now reads **No Color**, matching the menu row, and that row is always offered with its own checked or mixed state (#cm-11)
- 2026-08-01 - feat (ux) | go straight from the colour menu to where labels are edited — **Edit Color Labels…** opens Settings on the Workspace Colors rows rather than leaving you to find them (#cm-11)
- 2026-08-01 - feat (ux) | keep seeing a colour a workspace is still wearing after you removed it from your palette — it appears as a temporary **Custom (#RRGGBB)** row rather than vanishing from the menu (#cm-11)

## 🟠⋯ Changed for Developers
- 2026-08-01 - feat (dx) | ask cmux which colours exist instead of guessing their names — `cmux workspace-color list [--json]` returns the raw name, label, display name, and hex of every effective palette entry. `workspace-action --help` now points at it instead of hardcoding sixteen English names that could show neither your custom entries nor your labels (#cm-11)
- 2026-08-01 - feat (dx) | assign a colour by what it means — `cmux workspace-action set-color "GOAL: Primary"` resolves an exact unique label, while raw names and hex values keep working unchanged (#cm-11)
- 2026-08-01 - feat (dx) | define labels in `~/.config/cmux/cmux.json` under `workspaceColors.labels`, keyed by raw palette name; clearing or omitting one restores the raw name (#cm-11)
- 2026-08-01 - feat (dx) | custom palette names are no longer recycled — removing `Custom 3` and adding another gives a new name, so a label, or a `cmux.json` `actions` override keyed by the old command ID, can no longer silently retarget onto a different colour (#cm-11)

## 🟠⋯ Known Limitations
- **No Color** cannot carry a label. It is an assignment state rather than a palette colour, though it still shows its own checked or mixed marker.
- `workspace-group set-color` and **Choose Custom Color…** stay hex-only. Neither accepts a raw name or a label.
- If two palette entries resolve to the same hex, both show as assigned. cmux stores a colour, not which entry you picked, so naming one winner would invent information it does not have.
- A label in `cmux.json` that is empty, over-long, duplicated, or colliding with a raw palette name is ignored and logged rather than surfaced in config review — that section has no review channel. Settings shows the same errors inline as you type.
- Labels are your own text and are never translated. The CLI and configuration documentation for this feature is English-only.
- `clear-color` remains the CLI verb for **No Color**. Renaming a shipped verb would break existing scripts, so the two spellings coexist.

---

# 🔵⋯ v0.5.0 (2026-08-01) — #cm-14
## 🟠⋯ Added for End Users
- 2026-08-01 - feat (ux) | zoom once and watch all of cmux scale together — terminals, the sidebar, tab bars, the command palette, Settings, browser panes, the markdown viewer, and text previews — instead of only the pane you happen to be in. `⇧⌘=` grows it, `⇧⌘-` shrinks it, `⇧⌘0` returns to normal (#cm-14)
- 2026-08-01 - feat (ux) | keep sizing a single pane the way you always have — `⌘=` still belongs to the pane you're in, and the two zooms compose: a pane you enlarged by hand stays proportionally larger when everything scales around it (#cm-14)
- 2026-08-01 - feat (ux) | reach the app-wide zoom from wherever you already are — the View menu, the command palette, or a keyboard shortcut you can rebind in Settings or `~/.config/cmux/cmux.json` (#cm-14)

## 🟠⋯ Known Limitations
- **Everything: Actual Size** resets the app-wide scale only. A pane you sized by hand with `⌘=` keeps its own zoom — the two axes are independent by design, so the name promises more than it does. Reset that pane with `⌘0` while it is focused.
- There is no on-screen indicator of the current zoom level. The scale stops at 200% and 50%, and at either limit the shortcut simply stops responding rather than telling you why. The percentage is visible in **Settings › App › Global Font Magnification**.
- PDF previews, image previews, and the canvas layout keep their own view zoom and do not follow the app-wide scale. Fit-to-window is a different operation from scaling text, so folding them in would fight the fit.
- The scale is stored in one shared preference. A second cmux running from another build on the same machine picks it up on its next configuration reload.
- A terminal mirrored to the phone is left at its fitted size while the app-wide scale moves, so it can briefly sit out of proportion with its neighbours. It returns to the current scale when mirroring stops.

---

# 🔵⋯ v0.4.0 (2026-07-31) — #cm-10
## 🟠⋯ Added for End Users
- 2026-07-31 - feat (ux) | recognize a workspace by its colour and see which one is active at a glance — the colour stays as an identity strip down the row's leading edge over a quiet wash, and selecting a workspace fills the row with a contrast-corrected version of its own colour instead of a generic highlight (#cm-10)
- 2026-07-31 - feat (ux) | tell two similar workspace colours apart while one is selected — the active row's strip wears a pale tint of that workspace's own colour, where before every selected row drew the same black or white edge and only the fill carried identity (#cm-10)
- 2026-07-31 - feat (ux) | the colour strip curves into the row along the row's own corner instead of ending in a blunt or rounded tip (#cm-10)

## 🟠⋯ Removed for End Users
- 2026-07-31 - feat (ux) | the **Workspace Color Indicator** setting is gone, along with the Left Rail and Solid Fill styles — workspace colours now render one way, so there is nothing to choose between (#cm-10)

## 🟠⋯ Known Limitations
- A `workspaceColors.indicatorStyle` value left in `~/.config/cmux/cmux.json` is ignored rather than reported. It selects nothing and can be deleted; cmux stays silent rather than warning about a key it retired itself.
- Increase Contrast, Reduce Transparency, and VoiceOver were not exercised for this release. The treatment is designed so the full-strength strip and opaque active fill survive them with the colour wash only supplemental, but that is unverified — and the wash is the part that composites against the translucent sidebar material those settings remove.

---

# 🔵⋯ v0.3.0 (2026-07-31) — #cm-13
## 🟠⋯ Added for End Users
- 2026-07-31 - feat (ux) | see one terminal `background-image` spanning the whole window instead of a separately cropped copy in every pane, so a split no longer breaks the picture at each divider (#cm-13)

## 🟠⋯ Fixed for End Users
- 2026-07-31 - fix (ux) | terminal background images render the right way up; every image was drawn vertically mirrored (#cm-13)

## 🟠⋯ Known Limitations
- The window-wide image is only visible when `background-opacity` is below `1`. At full opacity each pane still paints an opaque fill over the shared backdrop and hides it. Removing that per-pane fill is `#cm-12`, which is not in this release.

## 🟠⋯ Changed for Developers
- 2026-07-31 - chore (dx) | `ghostty` now resolves to `rigelblu/ghostty-rbf`, carrying `macos-background-image-from-layer` so the host can own the terminal background image

---

# 🔵⋯ v0.2.0 (2026-07-31) — #cm-3
## 🟠⋯ Added for End Users
- 2026-07-31 - feat (ux) | read a pane with one surface as a labeled caption instead of a single tab that suggests there is somewhere to switch to, with the existing tab strip returning the moment a second surface appears (#cm-3)
- 2026-07-31 - feat (ux) | see which pane you are working in at a glance — a focused single-surface caption draws a contrast-safe rule along its header, only when more than one pane is on screen and only while the window is active (#cm-3)

## 🟠⋯ Fixed for End Users
- 2026-07-31 - fix (ux) | caption text stays legible at any `background-opacity`, including `0`, instead of flipping to dark text on a dark terminal below roughly 57% (#cm-3)
- 2026-07-31 - fix (ux) | a non-active window drops its pane-focus rule instead of drawing one identical to the active state, which under the Graphite system accent made active and inactive windows pixel-identical (#cm-3)
- 2026-07-31 - fix (ux) | the pane header keeps its bottom separator in caption mode and in embedded panes that never opted into captions (#cm-3)
- 2026-07-31 - fix (ux) | clicking anywhere in an unfocused pane's header focuses it, including the area left of a centered caption, which previously did nothing (#cm-3)
- 2026-07-31 - fix (ux) | a zoomed pane no longer draws a focus rule when it is the only pane on screen (#cm-3)
- 2026-07-31 - fix (ux) | dragging a surface onto a caption pane's empty header shows where it will land before you release (#cm-3)
- 2026-07-31 - fix (ux) | a new caption fades in centered instead of flashing left-aligned for a frame and jumping (#cm-3)
- 2026-07-31 - fix (a11y) | VoiceOver can focus a pane and toggle its zoom from the caption, which previously exposed no actions (#cm-3)
- 2026-07-31 - fix (dx) | dev builds sign with a stable identity when `CMUX_DEV_CODESIGN_IDENTITY` is set, so macOS permission grants survive a rebuild instead of re-prompting every time

## 🟠⋯ Changed for Developers
- 2026-07-31 - chore (dx) | Bonsplit moved from a git submodule to a `git subtree` at `Packages/macOS/Bonsplit`, so a feature spanning cmux and Bonsplit is one repository, one diff, and one bisect
- 2026-07-31 - chore (dx) | the unused `homebrew-cmux` submodule was dropped — three submodules down to one

---

# 🔵⋯ v0.1.0 (2026-07-29) — #cm-2
## 🟠⋯ Added for End Users
- 2026-07-29 - feat (ux) | put a new terminal pane exactly where it belongs by splitting left, right, above, or below from menus, the Command Palette, pane controls, or customizable shortcuts (#cm-2)
