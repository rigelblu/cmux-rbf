---
title: "Cmux RBF"
---

This directory holds this flavour's docs, scripts, changelog, and version metadata. The upstream cmux README and changelog remain at the repository root.

# 🔵⋯ Use

Dev builds and tests use the existing `cmux Dev Signing` certificate by default, including noninteractive agent shells. `CMUX_DEV_CODESIGN_IDENTITY` selects another existing identity. Missing identities or failed stable signing stop the build instead of silently reverting to ad-hoc signing and invalidating permissions.

New build IDs also need the terminal running `make` to have Full Disk Access so the preseed can copy your existing approved dev grants. Without it, builds still work, but a new ID may ask for external-drive access. Run candidate builds from their source checkout with `make -C <absolute-checkout-path> run`; `BUILD_ID` only names the output slot.

`make run` and tagged `reload.sh --launch` start the native app directly under the invoking terminal. When that terminal already has Full Disk Access, tagged builds retain its permission context: you do not need to add each build ID to FDA. Tags still keep their own bundle IDs, sockets and saved workspaces, and the app survives the launching shell closing. Launch from the approved terminal to use this behavior.

An independent Finder launch has its own permission context. The “access data from other apps” consent expires when the app quits, so it can appear there without an FDA grant for that app; preseed cannot make this session consent permanent. See [Apple's privacy explanation](https://developer.apple.com/videos/play/wwdc2023/10053/). Stable signing also preserves any FDA grant you already gave an app. If that grant predates stable signing, removing and re-adding the current app refreshes its obsolete signing requirement.

This is for my personal use and shared publicly for those curious. I'm not accepting issues or contributions here.

# 🔵⋯ Context
This is my ~~fork~~ flavour of [cmux](https://github.com/manaflow-ai/cmux): a terminal workspace adapted around how I organize and move through active work.

# 🔵⋯ Features
## 🟠⋯ Mark up what your agent said and send the notes back as one prompt

Select a passage in a rendered reply and it becomes a tinted, numbered phrase. Write what should change about it, mark another, and the notes collect into a numbered list under the reply — in the order you marked them, not the order they appear in the message.

- **`Paste` types the whole thing into the agent's composer without submitting**, at any point in a turn, so you can add a sentence before you send it. It also copies the payload to your clipboard, because Claude Code collapses a long paste to `[Pasted text #1 +4 lines]` and nothing can detect that from outside.
- **`Paste & Send` submits it, and waits for the turn to end first.** One prompt, not several — a multi-line payload is submitted with the agent's own multi-line key rather than a bare `return`.
- **`⤢` opens a preview of exactly what will be sent**, editable, at the panel's real width. It is one-way: nothing parses your edits back, so collapsing after an edit discards them.
- **The quote is the markdown you selected, not the words as drawn** — a span inside a bold run arrives as `**bold**` and a selected code block keeps its fence, so the agent sees text it can find in its own output.
- **`✕` on a hovered row removes that note and renumbers the rest at once.**
- **Known limitation — a note is not checked against the message it was written on.** If the session rebinds or the transcript is rewritten in between, the note is still pasteable and still says what you meant. A deliberate call: what you wrote is what you wanted to say, and refusing it would lose writing.
- **Known limitation — stepping away from a reply and back leaves its highlights unpainted.** The notes are still listed; the tinted spans are not redrawn, because telling two identical quotes apart needs something that does not exist yet.

## 🟠⋯ Read your agent's last reply without scrolling the terminal back

A **Reply** mode in the right sidebar, beside Files / Find / Vault / Feed / Dock. It shows the newest thing your agent said, rendered as markdown rather than as terminal text you have to scroll past.

- **`◄ n of N ►` steps back through earlier replies, and stops after the last five.** The panel is for the messages you would actually correct, not for walking a whole session — so the walk has a limit, and when it reaches it the header says **`Showing last`** beside the counter. Without that, a greyed `◄` would read as *"the conversation started here"*, which is false with replies still behind it.
- **A reply carrying notes you have not sent never counts against the limit, and always stays reachable.** The worst thing this panel could do is lose something you wrote, so the cap is not allowed to strand it. A marked reply also **holds you there** when a newer one lands — only an unmarked one follows the newest.
- **The counter is re-based on what you can reach: the newest reply reads `5 of 5`, and the oldest you can step back to reads `1 of 5`.** `N` is the number you configured, and grows past it only while one of your own marks is holding an older reply alive.
- **Set how far `◄` walks with `reply.maxMessagesBack` in `~/.config/cmux/cmux.json`.** It defaults to 5, and there is no Settings row — the default is right unless you go looking. A missing, zero, negative or non-numeric value falls back to 5 rather than being quietly corrected to something you did not ask for.
- **A reply is one turn, not one API response.** A prompt whose answer runs a tool part-way through shows as a single reply, matching the terminal. The API ends a response wherever the agent stops to call a tool — a break you never asked for and cannot see.
- **It follows the last agent pane you focused**, and keeps following it when you click a browser or an editor. The header names the tab, falling back to the agent's name.
- **Reasoning sits behind a "Show thinking" disclosure**, shown but not part of the reply's text.
- **Known limitation — the panel has no way to focus it, so start with the mouse.** `◄ ►` always work. The arrow keys work too, but only once the keyboard is already inside the panel — which today happens as a side effect of marking a span, and nothing else puts it there. Until a click can focus the panel, an arrow pressed while you are only reading goes to the agent's terminal instead.
- **Known limitation — a link opens in your system browser, and a `.md` link does nothing.** The panel has no pane of its own to route a link through, so it misses cmux's in-app browser.

## 🟠⋯ Even your split widths or heights in one action, instead of dragging each divider

**Equalize Splits** (⌃⇧⌘=) has always evened everything at once. Often that is more than you meant: you have your columns the way you want them and only the stack inside one of them has drifted.

- **Equalize Split Widths** evens only the side-by-side columns. **Equalize Split Heights** evens only the stacked panes. Whichever you don't name keeps the proportions you dragged.
- Both live in the **View** menu and the command palette. **Equalize Splits** is unchanged and still evens both in one press.
- **Neither claims a key by default** — the chord space around ⌃⇧⌘= is taken, and the all-splits version covers the common case. Bind them in **Settings → Keyboard Shortcuts**, or in `cmux.json`.
- **Known limitation:** in canvas mode the menu and palette move the hidden split tree, visible only after you leave canvas, while a bound shortcut acts on the canvas. Inherited from upstream's Equalize Splits.

## 🟠⋯ Arrange your splits into a common layout pattern in one action

A layout you keep rebuilding by hand — one big pane with narrower companions — is four names in **View → Arrange Splits**.

- **Main First (2:1:…)**, **Main Last (…:1:2)**, **Minor First (0.5:1:…)**, **Minor Last (…:1:0.5)**.
- **The patterns adapt to however many splits you have** rather than fitting a fixed count. Minor Last lands three columns at 40/40/20; Main First lands two at 67/33; the same name means the same intent at any span count.
- **Only dividers move.** No pane ever changes position — rearranging the panes themselves is a separate thing.
- **A split running the other way counts as one span** and keeps its own internal proportions. Re-ratio your columns and a stack living inside one of them is left exactly as it was.
- **Known limitation:** divider positions are clamped to 0.1–0.9, so past about five spans a Minor share lands at the clamp rather than its true ratio. You get a valid layout, just not the one the ratio names.

### 🟣⋯ Write your own patterns

The four built-ins are the common cases, not the only ones. Add your own under `panes.arrangePatterns` in `cmux.json`:

```json
"panes": {
  "arrangePatterns": {
    "Reading":  "2:1",
    "Triptych": "1:1:0.5"
  }
}
```

- They appear in **View → Arrange Splits** and the command palette, live and with no restart, reading **Editor (3:1) (Custom)** so you can tell yours from the four built-ins. In the menu they sit below a divider; in the palette they interleave with the built-ins — a built-in can land between two of yours — so the label is the only signal there.
- **The notation is the menu's own** — the hints already read `Minor Last (1:…:0.5)`, so what you read is what you type.
- **They adapt like the built-ins do.** The second weight repeats in place to fill: `2:1` is `2:1:1` at three spans; `1:1:0.5` is `1:1:1:1:0.5` at five. Writing exactly as many weights as you have splits always gives you exactly what you typed.
- **A pattern you got wrong drops on its own.** Fewer than two weights, or any that is non-numeric, zero, negative, or infinite, removes that one pattern and leaves the rest — including all four built-ins — working.
- **Menu and palette only.** Binding a custom pattern to a key is not supported yet; the built-ins' own keys are unaffected.

## 🟠⋯ Open one web link in your default browser, without changing where the next one opens

Terminal links follow whatever routing you configured — usually into a cmux browser tab. Sometimes you want *this one* link in Safari or Chrome instead, and nothing about that decision should stick.

- **From the terminal:** right-click a recognized web link and choose **Open in Default Browser**. It opens that exact URL and changes no setting; the next `⌘`-click routes as before.
- **From a cmux browser tab:** an external-link button sits immediately after the address bar. Narrow the pane and the same command moves to the top of **More Actions**. Either way the cmux tab stays open on the same page — nothing is handed off or closed.
- The action appears only on real web targets. File paths, `mailto:`, custom schemes, and malformed or hostless URLs leave the menu unchanged; in browser chrome the button stays visible but disabled, so the toolbar never rearranges itself under you.
- The browser action uses the page that is **loaded**, not what you have half-typed in the address bar. Editing the address bar retargets nothing until you press Return.
- **Known limitation:** on a remote workspace whose proxy endpoint has not resolved yet, the action can open a page that was requested but never finished loading. Local workspaces are unaffected.

## 🟠⋯ Keep one browser pane loaded so you find it where you left it

A browser pane idle for five minutes reloads when you come back to it — Memory Saver's default, and usually the right trade. A Figma canvas or a long doc pays for that trade every time you return.

- Turn on **Keep Page Loaded** for a pane you don't want reclaimed: a toolbar button when the pane is wide, an item in the `⋯` overflow menu when it's compact.
- Off by default — nothing changes until you turn it on, and the setting survives a restart.
- It exempts the pane from the timer only, not from an actual low-memory emergency; the system can still reclaim it if it needs to.

## 🟠⋯ Use the cmux you build as your everyday app

The flavour installs as **cmux RBF** in `/Applications`, with its own green `RBF` banner icon, its own bundle id and its own socket — so it is something you open from the Dock rather than something you launch out of a build directory. Upstream's `cmux.app` is never read, written or replaced; it stays as the fallback, and both can run at once. `make install-rbf-plan` prints the whole plan and writes nothing; `make install-rbf` does it.

- The first install copies your workspaces, window layout, session order and reopen history across, so it opens into the setup you already have. Re-installing never touches them again, including workspaces created since.
- `~/.config/cmux/cmux.json` resolves from `$HOME`, not the bundle id, so shortcuts and sidebar config are shared with upstream automatically and permanently — no migration, and no drift.
- **You will sign in once, by hand.** Auth lives in the keychain under a service name derived from the bundle id, so a separate app cannot see it by construction. No file copy reaches it.
- macOS permissions survive every reinstall, because the install signs with a stable identity rather than ad-hoc. An ad-hoc signature changes the designated requirement each time, which silently drops every grant.
- **Running `make install-rbf` from inside cmux RBF works.** The build runs where you are; the 2-second swap hands off to a detached helper that quits the app — ending every shell and agent it hosts — swaps, relaunches the new build, and confirms by notification, with the transcript in `~/Library/Logs/cmux-rbf/install.log`. From any other terminal the whole install runs inline with live output, exactly as before.
- **About still reports upstream's version** — both version keys were inherited at the fork point. A fork-owned version key (`RBFVersion`) is already written into the installed bundle, but nothing reads it yet; until `#cm-17.3` lands that reader, `env | grep CMUX_BUNDLE_ID` answers "which cmux am I in?"; `com.cmuxterm.app.rbf` is the flavour.
- If a state clone half-completes, `rbf/scripts/migrate-rbf-state.sh` is the way back — it reports and guards each store separately, and re-clones only what is missing.

## 🟠⋯ Resume an agent on the model and effort you left it on

A restored Claude pane comes back on the model and reasoning effort you were **last using**, not the ones the pane was originally launched with. Switch with `/model` or `/effort` mid-session, restart cmux, and the session picks up where you left it. Nothing to turn on.

- **The saving is the prompt cache, not the setting.** A session restored onto a different model cannot reuse its cached context, so the whole conversation re-enters as fresh input — you pay to rebuild context you already had, on a model you did not pick. That cost, not the wrong label in the status line, is why this is worth a release.
- **cmux stopped doing something rather than started doing something.** Claude Code restores its own model and effort on `--resume` — the command it prints when you exit is a bare `claude --resume <id>` — but an explicit flag overrides that restore. cmux was rebuilding the resume command from the process arguments it captured at snapshot time, replaying a choice you had since revoked. It now emits the command Claude itself prescribes.
- **Launch flags still work.** Starting a pane with `--model` or `--effort` puts it on those; only the *replay on resume* is gone.
- **Claude only.** codex, gemini, cursor, amp, opencode, kimi and grok are deliberately unchanged. Whether a tool restores its own model is an empirical fact about that tool, and only Claude has been tested — a wrong guess here would silently discard a model you asked for.
- **Resuming from the Sessions panel still names a model.** That path builds its command a different way, reading the last-known model from the session transcript. It does not have the bug this fixes — it reads the *current* model, not the launch-time one — but it means cmux currently has two answers to "how do we resume Claude". A later release reconciles them.

## 🟠⋯ Read a colour-coded plan as colour, not as raw emoji

If your notes mark status with 🔴🟠🟡🟢🔵🟣⚫, the markdown panel reads them as formatting instead of showing them as glyphs. The first marker in a block disappears; outside a heading it tints the code span beside it, so `**🟢`PASS`**` becomes a green `PASS` highlight and a verification table scans by colour. A heading keeps its marker's colour as text tint — colour is pre-attentive where a 4px size step is not, so sections separate at scroll distance.

- Markers inside fenced blocks and inline code stay literal. A marker in backticks is content, not syntax.
- `⚪` is not a YMD colour, so `**⚪`PENDING`**` keeps its glyph and takes no highlight while `**🟢`PASS`**` loses its and gains one. That asymmetry *is* the pass/pending signal.
- One marker per block, not per line — including inside a table cell.
- A marker before a code span that sits inside a link conceals but does not tint. A highlight there would be stripped by the link sanitizer, taking your `<code>` formatting with it.
- Headings never take a highlight. Heading ids come from a plain-text projection that cannot see it, so a highlight there would break `#anchor` links and scroll-restore.
- Documents over 250,000 bytes are skipped entirely, so a pathological file never spends a frame on markers.
- Light-mode yellow and green are deliberate contrast exceptions. Yellow is the one hue whose identity *is* its luminance — anything dark enough to pass WCAG AA reads as gold rather than yellow — and both sit on headings, where the level is already carried by size and position.

## 🟠⋯ Choose what the markdown viewer paints the page on

**Terminal** leaves the page transparent so your terminal background shows through, matching whatever theme you run. **Solid** paints the canvas GitHub's markdown styling was designed against, so the page reads the same on every theme — and its contrast becomes a fixed number rather than a function of your terminal colours.

- Per-viewer: one panel can be solid while another stays on the terminal.
- Reachable from the `AA` popover, the command palette (**Toggle Markdown Background**), Settings, or `markdown.background` in `~/.config/cmux/cmux.json`.
- Defaults to **Terminal**, so nothing changes until you ask it to.
- Choosing the canvas never changes light-vs-dark. That still follows your terminal.

## 🟠⋯ Rename a Codex session once and see it in cmux

Type `/rename` in a Codex session and the cmux tab hosting it takes the same name — and the workspace too, when that session is its only agent. With sibling agents, the rename stays on its own tab. One piece of work stops carrying two different names without claiming its neighbours.

- Only a rename you type syncs. The names Codex generates for itself are ignored, a redraw of the confirmation will not retrigger one, and neither will a keystroke sent over the cmux socket rather than typed.
- A name you set in cmux yourself still wins, and stays until you clear it.
- Ordinary `codex` launches from cmux-integrated zsh, bash, and fish keep using cmux's wrapper even if later shell setup changes `PATH`. A Codex process that was already running without hooks must exit and relaunch; cmux stays running.
- **The session has to have said something first.** Codex registers a session with cmux at its first real prompt, so a `/rename` typed before you have sent it any message is declined and nothing happens. Send one message, then rename.
- Two smaller gaps are documented in `docs/workspace-auto-naming.md`: dragging a Codex tab into another workspace stops its rename sync until the surface is recreated, and arrow-edited or pasted `/rename` commands may fail closed. Press Escape and type the rename again without arrow keys.

## 🟠⋯ Name and edit a workspace colour
Give workspace colours your own meaning — such as **GOAL: Primary (Tangerine)** — and see which one is assigned whenever you open the chooser. A custom colour can have an editable display name, while an optional label says what the colour means. Both leave its stable raw identity, such as `Custom 11`, available to existing workspaces and scripts.

- Meaning comes first and the custom display name stays in parentheses. With no label, you see the display name; with neither, you see the stable raw name.
- The colour menu marks what is already assigned — checked for one workspace, mixed when several selected workspaces disagree — instead of making you assign one and look.
- **Edit Color Labels…** at the foot of the menu opens Settings on the Workspace Colors rows, rather than leaving you to find them.
- **No Color** is always offered and carries its own state. The command palette calls it **No Color** too, so one action has one name; `clear-color` remains its CLI spelling.
- A colour a workspace still wears after you removed it from the palette appears as a temporary **Custom (#RRGGBB)** row rather than vanishing.
- Edit custom names and hex values in Settings. You can also set names in `~/.config/cmux/cmux.json` under `workspaceColors.displayNames`; clearing one restores the raw colour name. Labels remain under `workspaceColors.labels`.
- Custom palette hex values must be unique. Existing imported duplicates remain visible so you can repair them, but a new duplicate is rejected.
- When an edited custom hex has one palette owner, matching explicit workspace and group assignments follow it automatically. If an imported duplicate makes the old value ambiguous, only the chosen palette entry changes. Config-derived named or literal colours are never rewritten.
- Automation reads the palette with `cmux workspace-color list [--json]` and can assign by raw name, custom display name, or label: `cmux workspace-action set-color "GOAL: Primary"`.
- **No Color** itself cannot be labelled, `workspace-group set-color` stays hex-only, and if two entries share a hex both show as assigned — cmux stores a colour, not which entry you picked.

## 🟠⋯ Tell a group header from the workspaces inside it at a glance

Every workspace-group header carries a band across its whole row, so the container is visible without hunting for a small folder icon. A coloured group uses its colour; a group with no colour gets a neutral band. Set that colour from the header's **Group Color** menu (below). The active group's band deepens while member workspaces keep their narrow leading strip, so container and contents remain different shapes.

- Always on; no setting or migration.
- Works in both sidebar renderers and in normal Light and Dark appearances.
- Group names follow the appearance of their bands, including live Light ↔ Dark changes. v0.17.1 retires v0.17.0's black-on-dark limitation.
- **Unverified:** Reduce Transparency and Increase Contrast. Tom accepted releasing without those two checks.

## 🟠⋯ Give a workspace group a colour without dropping to the CLI

Right-click a group header and pick **Group Color**. It offers the same palette a workspace does, semantic labels included, and the header band takes the colour at once. Before this, the colour existed but the only way to set one was the `workspace.group.set_color` socket command.

- The checkmark marks the colour **you** picked. A colour arriving from a `cmux.json` cwd config is drawn on the band but never ticked in the menu.
- **No Color** clears the group's own colour. If `cmux.json` colours the anchor's cwd, that configured colour then shows through — so **No Color** can read as ticked beside a still-coloured band. The menu answers "what did you set", the band answers "what renders".
- A group's icon is still not reachable from the app; `iconSymbol` has no UI.
- Always on; no setting or migration. Both sidebar renderers carry the menu, but in practice you only ever see the AppKit one: `sidebar-appkit-list-experiment` is pinned **on** by upstream's control plane, and a local override is inert while a remote value is cached (`Sources/FeatureFlags.swift:576`). The SwiftUI list is reachable only on a machine that has never cached one — so the menu is there, and nobody has watched it work.

## 🟠⋯ Scan your standalone workspaces by what their colour means

Workspaces that carry a colour but sit outside any group now gather under compact, collapsible colour headers. When a colour has a semantic label, that label is the complete title — **Focus**, **Review** — because the adjacent swatch already shows the colour. Without a label, the title falls back to the custom display name or raw palette name. The flat run of loose rows becomes a list you can scan by meaning. Real workspace groups and uncoloured workspaces are left exactly as they were.

- **A colour section is not a group.** It has a chevron, a swatch, and a title, and nothing else — no folder icon, no workspace number, no active state, no group actions. Membership is derived from the colour, so there is nothing to maintain.
- **Real group membership always wins.** A coloured workspace inside a group stays in that group; only loose workspaces gather. Recolouring a group member changes its colour and moves nothing.
- Sections are keyed by hex, so renaming or clearing a colour's label retitles the header without disturbing the section or its collapsed state. Settings, menus, commands, and CLI keep their existing combined **Label (Colour)** names. An unlisted colour reads as **Custom (#RRGGBB)**.
- Pinned and unpinned tiers stay separate — the same colour can head a section in each, and both share one collapsed state.
- Collapsing survives relaunch, and selecting a workspace hidden inside a collapsed section expands it first, whether you got there by sidebar history, `⌘1…9`, the CLI, or session restore.
- Reordering works within a colour section and pin tier. Dragging into a real workspace group also works, matching what **Move to Group** does from the row's menu — the workspace joins the group and keeps its colour. Every other drop — another colour section, a standalone row, the other pin tier — is refused without changing colour, group, pin, or order.
- **Known limitation — the header ignores global font magnification.** Every other sidebar row scales; this one is pinned at 26pt.
- **Unverified:** Increase Contrast, Reduce Transparency, grayscale, keyboard focus, and VoiceOver. Light and Dark passed; Tom accepted releasing without the accessibility pass.

## 🟠⋯ Zoom once and have all of cmux scale
`⇧⌘=` and `⇧⌘-` resize everything together — terminals, the sidebar, tab bars, the command palette, Settings, browser panes, the markdown viewer, and text previews. `⇧⌘0` returns to normal.

- `⌘=` still sizes only the pane you are in, and the two compose: a pane you enlarged by hand stays proportionally larger when everything scales around it.
- Reachable from the View menu and the Command Palette, and rebindable in Settings or `~/.config/cmux/cmux.json`.
- **Everything: Actual Size** (`⇧⌘0`) resets the app-wide scale and every hand-sized pane, in every window. `⌘0` resets only the pane you are in.
- The View menu's **Zoom In**, **Zoom Out** and **Actual Size** act on whichever pane you are in — terminal, browser, markdown preview or text preview. They grey out on a pane that can't zoom, and **Actual Size** also greys out when the pane is already at its normal size.
- The scale runs 50%–200% with no on-screen indicator; at either limit the shortcut simply stops responding. The current percentage is in **Settings › App › Global Font Magnification**.
- PDF previews, image previews, and the canvas layout keep their own view zoom — fit-to-window is a different operation from scaling text.

## 🟠⋯ Know when your terminal theme cannot follow light and dark
With Appearance set to System, the Theme picker's System tile shows a split light/dark thumbnail — a picture of the app switching. If your Ghostty `theme` resolves to the *same* theme on both sides, the terminal cannot honour half of that, so the picker now says so and names the theme that is pinned.

- **The fix is a paired theme**, either `theme = light:<one>,dark:<other>` in your Ghostty config or `cmux themes set --light <one> --dark <other>`. Both have always worked; nothing told you they were needed.
- The whole pane stack — terminal cells, the pane fill and the window backdrop — takes its colour from the resolved theme, which is why a pinned theme reads as "dark mode is broken" rather than as one setting that stayed put.
- Shown only under Appearance = System. Under an explicit Light or Dark a pinned theme is exactly what you asked for, so the line stays out of the way.
- **It reports; it does not choose for you.** Guessing a counterpart theme from a name (dawn→moon, Latte→Mocha) would be right for some pairs and silently wrong for the rest, and would override a value you wrote deliberately.
- **It only speaks when *both* sides resolve to the same theme.** A one-sided `theme = light:X` leaves your dark appearance on ghostty's default, so the terminal does follow the appearance and no caveat is owed — even though the pair is probably unfinished. cmux cannot tell an unfinished pair from a chosen one, and v0.11.0 shipped the version that guessed: it reported `light:X` as pinned and named a theme the dark side never loads. Fixed in v0.11.1.
- Two things it cannot warn about: a paired theme whose two halves carry different `background-image-opacity` will change the window image's weight with the appearance, and colour-valued settings like `unfocused-split-fill` have no conditional form in Ghostty at all, so one tuned for a light background stays put in dark.

## 🟠⋯ Reach the workspaces you are working in by number
`⌘1…9` numbers only the workspaces that are in play — the ones carrying an Accent Strip — instead of counting every row in the sidebar. A workspace you have parked or finished drops out of the numbering, and the rows below it move **up** rather than leaving a gap, so `⌘3` lands on the third workspace that matters, not the third row. Hold `⌘` to see it: a badge appears only where a digit actually works.

- **The badge and the key renumber together, by construction.** They are computed from one set rather than kept in sync, so a badge cannot claim a digit that goes somewhere else. That is also why a parked workspace loses its number instead of just hiding the badge — a hidden badge whose key still fires is the worse lie.
- **`⌘9` keeps its jump-to-the-end idiom**, now landing on the last workspace in play. The View menu's nine "Workspace N" items follow the same numbering.
- **A workspace inside a group is numbered like any other row.** Only two rows carry no digit, and for different reasons: a **group header**, because that row names a group rather than a workspace (a later release gives groups their own `⌘⇧1…9`), and the members of a **collapsed** group, because they have no row on screen to press a digit for. Collapse a group and its members' digits pass to the rows below; expand it and they come back. *v0.14.0 excluded every grouped workspace, which left a sidebar made entirely of groups with no numbered workspaces at all; fixed in v0.15.1.*
- **A run of rows in the middle can carry no digit.** Because `⌘9` means "the last one", more than nine workspaces in play leaves the first eight and the last numbered and the rows between them bare.
- **A number can change under you.** The lane is inferred from live git and pull-request state, so `⌘3` can retarget without you doing anything. That is the accepted cost of renumbering over hiding.
- **The digit has no accessibility exposure.** It lives only in the visual hint pill, so VoiceOver has no way to say which digit selects a row.
- **With the workspace todo feature off, nothing changes.** No lane is read, every workspace stays numbered, and the numbering is exactly what it was. Turn it on at Settings → Beta Features → **Workspace Todo Controls**.
- **When nothing is in play, every workspace with a row of its own is numbered again** — a dead `⌘1` would read as a broken build, and Todo is the default lane. Collapse *every* group and there is nothing left with a row, so the digits do go dead.

## 🟠⋯ Recognize a workspace by its colour, selected or not
A workspace's colour stays visible as an identity strip down the leading edge of its row, over a quiet wash of the same colour — **while there is something going on in that workspace.** Selecting a workspace fills the row with a contrast-corrected version of that colour instead of a generic highlight, so the active one is obvious without rereading titles.

- **A workspace that is not in play gives up its strip.** Two lanes qualify — **Todo** and **Done**, the ends of the lifecycle. The three between them, **Working**, **Needs Attention** and **In Review**, mean work is in play and keep the strip. A parked row keeps only its wash, and the strip returns the moment the lane changes: an agent starts, the tree goes dirty, a PR opens, or you set a lane by hand. The idea is that attention is a budget — a workspace you have not started, or have finished, has no claim on it. This needs the workspace todo feature on (Settings → Beta Features → **Workspace Todo Controls**); with it off, every row keeps its strip.
- **Setting a workspace to "None (hide status)" does not park it.** That hides the status glyph; cmux keeps tracking the lane underneath, and the strip follows the lane. To park a workspace, set it to **Todo**.
- **The wash is deliberately faint, and among active workspaces the strip is what carries identity.** If a pair of *active* workspaces gets hard to tell apart, the strip is the thing to widen or brighten, not the wash to raise. There is no setting for any of it; the weights are chosen, not configurable.
- **A parked row still reads as coloured — in light appearance.** Checked against six colours: each stayed distinguishable from a workspace with no colour at all, and two colours ~33/255 apart stayed tellable apart even with the strip gone. **In dark appearance it mostly does not hold.** The wash is drawn at one weight for both appearances, and what you see is that weight times the gap between your colour and the sidebar's own background — a light sidebar is far from most workspace colours, a dark one is close to them, and measured the same wash gives about **3.5× less separation in dark**. Two workspace colours that are genuinely close have not been checked while both are parked, in either appearance.
- The active row's strip wears a pale tint of the workspace's own colour, so two similar colours stay distinguishable even while one is selected. That tint is its own value, not a reflection of the resting wash — quieting the rows around it cannot bleach it.
- The strip's trailing edge curves *into* the row rather than tapering, and follows the row's own corner — so it reads as part of the row's edge, not a bar sitting on top of it.
- Active row content is white over a fill darkened until it clears 4.5:1; the strip keeps at least 3:1 against that fill.
- There is no indicator-style setting. This is the only workspace colour treatment — Left Rail and Solid Fill are gone, and a leftover `workspaceColors.indicatorStyle` in `cmux.json` is ignored rather than reported.
- Increase Contrast, Reduce Transparency, and VoiceOver are unverified for this treatment.

## 🟠⋯ Read a pane at a glance, not as a one-item tab strip
A pane holding a single surface shows a centered caption instead of a lone tab, because one tab implies somewhere to switch to. Add a second surface and the familiar tab strip returns.

- The header keeps its icon, status marks, actions, and context menu — only the tab treatment goes.
- Drag and middle-click close stay on the caption itself; clicking the empty header focuses the pane.
- The empty header either side of the caption accepts a dropped tab — leading inserts before, trailing appends. Until v0.15.3 only the caption itself did, which left most of a wide header refusing drops.
- A focused pane draws a contrast-safe rule along its header, but only when more than one pane is on screen and only while the window is active.

## 🟠⋯ One background image across the whole window
A terminal `background-image` spans the window instead of being cropped separately into every pane, so splitting no longer breaks the picture at each divider.

- Requires `background-opacity` below `1`. At full opacity each pane still paints an opaque fill that hides the shared backdrop; removing that fill is tracked separately.
- Honors Ghostty's own `background-image-fit`, `-position`, `-opacity`, and `-repeat` settings.

## 🟠⋯ Put a new pane exactly where it belongs
Create a terminal pane to the left, right, above, or below the pane you are working in.

- Use the View menu, Command Palette, terminal context menu, configurable tab-bar actions, or customizable keyboard shortcuts.
- Existing Split Right and Split Down defaults stay unchanged.
- Split Left and Split Up are available to bind without adding new default shortcuts or tab-bar buttons.
- Actions invoked from a pane-specific surface target that pane, even when another pane or window owns global focus.
- Unsupported remote-tmux directions stop without substituting another direction or changing the local layout.

# 🔵⋯ Versions
- The flavour version lives in `rbf/VERSION`.
- Flavour release notes live in `rbf/CHANGELOG.md`.
- Upstream cmux version and release history remain in `cmux.xcodeproj/project.pbxproj` and the root `CHANGELOG.md`.
- Local flavour releases update the three `rbf/` release files without rewriting upstream release metadata.

# 🔵⋯ Build
Initialize the checkout once:

```sh
./scripts/setup.sh
```

Then build and run it:

```sh
make run      # build this branch, then launch it
make build    # build only; prints the App path
make test     # the unit tests (the only automated gate here)
make help     # everything else, including disk cleanup and install
```

You never pick a build-id — it comes from your branch (`tom-rigelblu/cm-19` → `cm-19`) and decides the DerivedData directory, the debug socket, the app name and the bundle id suffix, so two builds never collide. `make -C <path> run` builds a different checkout, which is how a worktree names its own build rather than someone else's.

`make install-rbf` installs the result as **cmux RBF** in `/Applications`; `make install-rbf-plan` prints that plan and writes nothing.

For a candidate alongside your regular app, use `make install-dogfood`.
It builds the current checkout as **cmux RBF (dogfood)**, with a persistent
dogfood identity, its own socket and saved state, and a separate Release build
directory. `make install-dogfood-plan` previews the destination and source
revision without building or writing. First install copies regular RBF's saved
windows and workspaces; updates preserve dogfood's own state. Regular RBF is
only read. The dogfood app shares `~/.config/cmux/cmux.json` with other cmux
apps and requires its own sign-in.

If a first install was interrupted, quit dogfood and run
`make migrate-dogfood-state` to fill missing stores; `migrate-dogfood-state-plan`
previews it. An explicit refresh of existing stores uses
`rbf/scripts/migrate-rbf-state.sh --dogfood --force`; it backs up dogfood's
existing stores before replacing them and refuses while dogfood is running.
This command does not cut a release or move a bookmark.
