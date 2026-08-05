---
title: "Cmux RBF"
---

This directory holds this flavour's docs, scripts, changelog, and version metadata. The upstream cmux README and changelog remain at the repository root.

# 🔵⋯ Use
This is for my personal use and shared publicly for those curious. I'm not accepting issues or contributions here.

# 🔵⋯ Context
This is my ~~fork~~ flavour of [cmux](https://github.com/manaflow-ai/cmux): a terminal workspace adapted around how I organize and move through active work.

# 🔵⋯ Features
## 🟠⋯ Use the cmux you build as your everyday app

The flavour installs as **cmux RBF** in `/Applications`, with its own green `RBF` banner icon, its own bundle id and its own socket — so it is something you open from the Dock rather than something you launch out of a build directory. Upstream's `cmux.app` is never read, written or replaced; it stays as the fallback, and both can run at once. `make install-rbf-plan` prints the whole plan and writes nothing; `make install-rbf` does it.

- The first install copies your workspaces, window layout, session order and reopen history across, so it opens into the setup you already have. Re-installing never touches them again, including workspaces created since.
- `~/.config/cmux/cmux.json` resolves from `$HOME`, not the bundle id, so shortcuts and sidebar config are shared with upstream automatically and permanently — no migration, and no drift.
- **You will sign in once, by hand.** Auth lives in the keychain under a service name derived from the bundle id, so a separate app cannot see it by construction. No file copy reaches it.
- macOS permissions survive every reinstall, because the install signs with a stable identity rather than ad-hoc. An ad-hoc signature changes the designated requirement each time, which silently drops every grant.
- **Running `make install-rbf` from inside cmux RBF works.** The build runs where you are; the 2-second swap hands off to a detached helper that quits the app — ending every shell and agent it hosts — swaps, relaunches the new build, and confirms by notification, with the transcript in `~/Library/Logs/cmux-rbf/install.log`. From any other terminal the whole install runs inline with live output, exactly as before.
- **About still reports upstream's version** (`0.64.20 / 100`) — both version keys were inherited at the fork point. A fork-owned version key (`RBFVersion`) is already written into the installed bundle, but nothing reads it yet; until `#cm-17.3` lands that reader, `env | grep CMUX_BUNDLE_ID` answers "which cmux am I in?"; `com.cmuxterm.app.rbf` is the flavour.
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

Type `/rename` in a Codex session and the cmux tab hosting it takes the same name — and the workspace too, when that session is the only agent working there. One piece of work stops carrying two different names.

- Only a rename you type syncs. The names Codex generates for itself are ignored, a redraw of the confirmation will not retrigger one, and neither will a keystroke sent over the cmux socket rather than typed.
- A name you set in cmux yourself still wins, and stays until you clear it.
- **The session has to have said something first.** Codex registers a session with cmux at its first real prompt, so a `/rename` typed before you have sent it any message is declined and nothing happens. Send one message, then rename.
- Two smaller gaps, both documented in `docs/workspace-auto-naming.md`: dragging a Codex tab into another workspace stops its rename sync until the surface is recreated, and two Codex sessions sharing a workspace can each read as the only one there, so the second rename may claim the workspace title. Tab titles stay correct in both cases.

## 🟠⋯ Name a workspace colour by what it means to you
Give workspace colours your own meaning — such as **GOAL: Primary (Teal)** — and see which one is assigned whenever you open the chooser. Labels are optional and change nothing underneath: colour names, hex values, saved workspaces, and scripts keep working exactly as before.

- Meaning comes first and the colour's own name stays in parentheses, so a label never costs you the identity underneath it. With no label, you just see the colour name.
- The colour menu marks what is already assigned — checked for one workspace, mixed when several selected workspaces disagree — instead of making you assign one and look.
- **Edit Color Labels…** at the foot of the menu opens Settings on the Workspace Colors rows, rather than leaving you to find them.
- **No Color** is always offered and carries its own state. The command palette calls it **No Color** too, so one action has one name; `clear-color` remains its CLI spelling.
- A colour a workspace still wears after you removed it from the palette appears as a temporary **Custom (#RRGGBB)** row rather than vanishing.
- Edit labels in Settings or in `~/.config/cmux/cmux.json` under `workspaceColors.labels`. Clearing one restores the raw colour name.
- Automation reads the palette with `cmux workspace-color list [--json]` and can assign by label: `cmux workspace-action set-color "GOAL: Primary"`.
- **No Color** itself cannot be labelled, `workspace-group set-color` stays hex-only, and if two entries share a hex both show as assigned — cmux stores a colour, not which entry you picked.

## 🟠⋯ Zoom once and have all of cmux scale
`⇧⌘=` and `⇧⌘-` resize everything together — terminals, the sidebar, tab bars, the command palette, Settings, browser panes, the markdown viewer, and text previews. `⇧⌘0` returns to normal.

- `⌘=` still sizes only the pane you are in, and the two compose: a pane you enlarged by hand stays proportionally larger when everything scales around it.
- Reachable from the View menu and the Command Palette, and rebindable in Settings or `~/.config/cmux/cmux.json`.
- **Everything: Actual Size** resets the app-wide scale only; a hand-sized pane keeps its own zoom. Reset that pane with `⌘0` while it is focused.
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
- **A grouped workspace has no number.** Groups leave the numbering entirely — a collapsed group hides its members, so those digits were firing at rows you could not see. This *removes* keyboard reach that existed before; a later release gives groups their own `⌘⇧1…9`.
- **A number can change under you.** The lane is inferred from live git and pull-request state, so `⌘3` can retarget without you doing anything. That is the accepted cost of renumbering over hiding.
- **The digit has no accessibility exposure.** It lives only in the visual hint pill, so VoiceOver has no way to say which digit selects a row.
- **With the workspace todo feature off, nothing changes.** No lane is read, every workspace stays numbered, and the numbering is exactly what it was. Turn it on at Settings → Beta Features → **Workspace Todo Controls**.
- **When nothing is in play, every ungrouped workspace is numbered again** — a dead `⌘1` would read as a broken build, and Todo is the default lane.

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
