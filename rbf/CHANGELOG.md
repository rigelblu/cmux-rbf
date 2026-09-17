---
title: "Cmux RBF Changelog"
---

Fork releases use the version in `rbf/VERSION`; upstream release history remains in the root `CHANGELOG.md`.

# 🔵⋯ [Unreleased]

## 🟠⋯ Changed for End Users
- 2026-09-17 - fix | **When a pane's saved agent won't come back, the pane now runs its approved restart command instead of coming back empty.** A record of an agent that cmux had already retired — or one whose agent wasn't running when you quit — still counted as "something will restore this pane", so the pane's own command never started and you got a bare shell. A pane whose agent really will resume is unchanged: its restart command still stays out of the way. (`#cm-96.3`)

## 🟠⋯ Changed for Developers
- `restartCommandPaneCandidates` moved out of `AppDelegate` into `RestartCommandPaneProjection` unchanged, so the snapshot → candidate projection is reachable from a test for the first time; the window/workspace/dock traversal above it stays private. `hasExistingResumeIntent` now asks whether a saved binding would resume the pane by itself rather than whether one exists. The saved `autoResume` flag decides for `agent-hook` and `process-detected` bindings, which is where restore reads it; a `cli` binding keeps counting as an intent, because its approval record re-derives that flag at restore and a stale `false` would start a restart command beside a resuming pane. An `agent-hook` binding also stops counting when the pane was captured with `wasAgentRunning: false`, matching the agent-hook-only gate restore applies, and the `agent` snapshot clause takes the same flag, matching the gate on the agent's own relaunch. `managedAgentResumeBinding` takes the same rule, since by construction it only ever holds an `agent-hook` binding. `mayResumePaneOnItsOwn` answers `true` conservatively for every other source, and the two pre-filters it depends on now carry comments naming it.

# 🔵⋯ v0.27.4 (2026-09-17) — #cm-96.2, #cm-95

*See which line and field broke your restart definitions, and match a pane's app on any environment variable. cmux RBF no longer shows upstream's "Update Available" pill.*

**`#cm-95`'s on-screen check had not run when this version was cut** — its code is in the build because it was committed first. Run its two checks before relying on it.

## 🟠⋯ Changed for End Users
- 2026-09-17 - feat | **cmux RBF no longer shows upstream's "Update Available" pill.** A new upstream cmux release doesn't mean you want to update the fork, so the sidebar footer stays clear. cmux RBF also stops checking upstream's release feed, and "Check for Updates" answers "No Updates Available" without checking anything. Upstream's own cmux app is unchanged. (`#cm-95`)
- 2026-09-17 - feat | **When your restart definitions file breaks a rule, Settings names the line and the field.** It used to say only that the file couldn't be used, so you had to find the mistake yourself. Now it reads like **Line 57 has an invalid “cwd” value.** — for an unknown field, a missing one, a wrong value, or a repeated id. A definition can also match a pane's app on any environment variable, up to 4 per definition, where only `JJUI_CONFIG_DIR` worked before. The schema file beside your definitions now carries the same rules, so your editor flags the same mistakes as you type. (`#cm-96.2`)
- 2026-09-17 - fix | **Three kinds of definitions file that used to slip through are now rejected, each with its line named:** one that repeats a key inside a definition (cmux kept one of the two silently, so the file you read wasn't the one it ran), one that uses `/` alone as an `executable` or `normalizedFinalComponent`, and one saved as UTF-16 or UTF-32 instead of UTF-8. A file with a UTF-8 byte-order mark, which some editors add, still works. (`#cm-96.2`)

## 🟠⋯ Changed for Developers
- `UpdateController.isDevLikeBundleIdentifier` now treats `com.cmuxterm.app.rbf` and `com.cmuxterm.app.rbf.*` like debug and staging builds. It makes no launch or background checks against upstream's appcast, clears any detected update, and answers manual checks with `.notFound`. The gate writes `SUEnableAutomaticChecks = false` into the app's user defaults, and a rollback doesn't undo that (`defaults delete com.cmuxterm.app.rbf SUEnableAutomaticChecks`). Outside `rbf/scripts/lib/rbf-channel.env`, `UpdateController.swift` is now the only code that names the channel's bundle id, and the env file's header lists it. `rbf/scripts/install-rbf.sh` no longer writes `SUEnableAutomaticChecks` or `SUAutomaticallyUpdate` into the installed plist; those lines never took effect, because Sparkle reads registered and user defaults first.
- The definitions file is read by cmux's own validator rather than `JSONDecoder`, so every failure carries the JSON path of what failed, and a strict scanner maps that path to a line and column. Settings shows the failure on the lowest line. The scanner refuses more than 64 nested containers: a legal catalog nests 6, and without the limit a ~50 KB file of open brackets overflowed the stack, which no `catch` can save. An explicit `null` is a wrong value at its key, never an absent one.

# 🔵⋯ v0.27.3 (2026-09-16) — #cm-96

## 🟠⋯ Changed for End Users
- 2026-09-16 - fix | **Restarted `jjui` and Hunk panes no longer come back as blank shells because one custom definitions file has an error or an unapproved change.** cmux keeps its shipped definitions running, identifies a known JSON error line in Settings, and never runs custom definitions until you approve the complete repaired list. Hunk's diff mode returns as `hunk diff`, including commands launched through an alias that expands to it. (`#cm-96`)

## 🟠⋯ Changed for Developers
- Restart-command identifiers are bounded generic slugs backed by a bundled JSON catalog rather than compiled cases. Enabled shipped authority remains available while user data is invalid, unreadable, missing after customization, or valid but unapproved; explicit Off still wins, and receipt plus second-read checks remain intact.

# 🔵⋯ v0.27.2 (2026-09-16) — #cm-74.1

*Label a passage in one click instead of typing the same note again. Use the Reply panel from the keyboard — step through replies, and leave when you are done. Read the agent's reply with the line breaks it actually wrote.*

## 🟠⋯ Changed for End Users
- 2026-09-16 - feat | **Keep one browser pane loaded so you find it where you left it.** A browser pane idle for five minutes reloads when you come back to it — a Figma canvas comes back blank, a doc back at the top. Turn on **Keep Page Loaded** for a pane and it's exempted from that timer: a toolbar button when the pane is wide, an item in the `⋯` overflow menu when it's compact. Off by default, so nothing changes until you turn it on; the setting survives a restart. It doesn't protect the pane if the system is actually low on memory. (`#cm-74.1`)

## 🟠⋯ Changed for Developers
- Exempting a pane from discard reevaluates its scheduling on the spot — turning the flag on cancels an already-armed timer instead of waiting for it to fire once more, and turning it off re-arms one if the pane still qualifies. The exemption is read once, in `scheduleIfNeeded`, and never inside `blockers(for:)`, so it can't also suppress the emergency memory-pressure discard.

## 🟠⋯ Changed for End Users
- 2026-09-15 - fix | **Switching between workspaces no longer leaves Reply on “Waiting for the first message” when the selected Claude has already replied.** Reply now changes its active session as one unit: while the next workspace is loading, the previous reply can remain visible but cannot receive a paste or a draft, and a late result from the workspace you left cannot replace the one you returned to. (`#cm-69.1c`)
- 2026-09-14 - fix | **Typing in the middle of the paste preview keeps the caret where you put it.** Click anywhere before the end of the expanded preview and type: the first character landed there, but every one after it jumped to the very end. Now each keystroke, `⌫` and paste stays where you are — and `Paste` and `Paste & Send` send the text you edited, not the preview it started from. Once edited, `Paste & Send` no longer needs a written note. Clear the box and both buttons turn off; `Discard edits` brings the generated text back. (`#cm-93`)
- 2026-09-14 - fix | **Click anywhere on a highlight's purple band to open its note.** In the Reply panel's list of highlights, a click just above, below or beside a note's text used to do nothing, even where the band was purple. Now each row answers across its whole band, out to halfway to the next row, so a click between two rows acts on the nearer one. Moving the pointer down the list also lights each highlight in turn, instead of flashing back to the open note in the gaps between rows. (`#cm-85`)
- 2026-09-14 - feat | **Sending from Reply closes the right sidebar, unless you pin it open.** After `Paste` or `Paste & Send` delivers, the sidebar hides and the keyboard goes to the agent pane your reply went to, even if another pane in a split had focus — ready to edit after `Paste`, or to watch the answer after `Paste & Send`. To keep the panel open instead, click the pin at the right of the Reply header, beside `‹ n/N ›`; it turns solid while it holds the panel open. The pin is per window and starts off in every new window and every launch. A send that doesn't go through leaves the sidebar where it is. (`#cm-91`)
- 2026-09-13 - fix | **What you write in Reply stays until you send it, even when you switch the sidebar away.** Switching the right sidebar to Files, Find or another mode and back used to throw away your unsent highlights and notes on the spot. Now they are all still there, on the reply you left, with the panel on that same reply. Text you type into the paste preview is kept too: switch away, or step `‹` to an older reply and back, and the preview reopens with your edits. `Discard edits` drops them, and `Paste` sends what you typed into the preview once you have edited it (`#cm-93`). Closing the window or quitting cmux still loses unsent writing. Because the panel now keeps your place, a `⌘⇧`-drag started from another sidebar mode follows the same rules as one from a hidden sidebar: if you are on an older reply, or the newest reply already has highlights, Reply opens and nothing new is highlighted. (`#cm-90`)
- 2026-09-13 - feat | **Start a reply from the terminal: `⌘⇧`-drag across the agent's words.** In a pane running Claude or Codex, hold `⌘` and `⇧` and drag across a phrase on one line of what the agent wrote. The right sidebar opens on Reply with that phrase highlighted in the agent's message and its note field open, so you can type your reply straight away — the same highlight a drag inside the panel makes. It works from a pane that doesn't have the keyboard yet, from a hidden sidebar, and from the Files sidebar. Letters you type before the note field is ready are dropped rather than sent to the agent. When it can't highlight, the panel still opens and the header says why, in place of the agent's name, until you act: **red** `Couldn't highlight selection, select below instead` when the phrase isn't in the agent's newest message (drag it in the panel instead), **orange** `Select within one line` when the selection spans more than one row, and grey `Still writing` while the agent is mid-turn, which clears by itself when the turn ends. Nothing happens if the Reply panel is already showing, if the pane's agent has exited, or with any other modifiers — `⌘`-click, `⇧`-click and `⌥`-drag work as before. (`#cm-89`)
- **Known limitation — a phrase that appears more than once highlights its first occurrence**, which may not be the one you dragged. Remove it with `✕` and drag the one you meant inside the panel.
- **Known limitation — the gesture never adds to a reply you've already started.** If the agent's newest message already has highlights, or the panel is stepped back to an older reply, the panel opens where you left it and adds nothing. Add further highlights by dragging inside the panel.
- **Known limitation — the not-found line is cut off at the sidebar's usual width**, and hovering it does not yet show it whole (`#cm-92`).
- 2026-09-11 - feat | **Reach your highlights from the keyboard: press Tab in the Reply panel.** With the panel focused and no note open, `Tab` opens the first highlight's note with the caret ready at the end of whatever is already there, and `⇧Tab` opens the last. The note's row and its mark scroll into view if they were off screen. With one highlight, Tab opens it — stepping between notes still needs two. With none, Tab does what it always did. `Escape` hands the keyboard back to the reply, and again to the terminal. If you clicked into the reply while a note was open, Tab returns you to *that* note rather than jumping to the first. (`#cm-83.1`)
- 2026-09-12 - feat | **Open the label menu without the mouse, and find every label in it.** The `⌄` beside the chips now holds **every** label rather than only the ones that did not fit, with each of the first nine showing its key beside it, and a dimmed line at the top telling you which key opens it — it follows your binding, so rebinding the label shortcut changes what it says. Press the same modifier with `0` while your caret is in a note to open it — the digit straight after the nine label slots — so the labels the digits cannot reach are still reachable from the keyboard. `Escape` closes it. **Known limitation — the `0` that opens the menu is not separately rebindable.** It follows whatever modifier `Insert Reply Label 1…9` is set to and has no Settings row of its own, so binding something else to that chord will not warn you of a clash. (`#cm-83.3`)
- 2026-09-11 - feat | **Stamp a label with a key: `⌥1` through `⌥9`.** While your caret is in a note, the Option keys insert the 1st through 9th label at the caret and close the note — the same thing clicking the chip does, spacing and all. Only while you are typing in a note: everywhere else those keys are untouched, and the characters `⌥1` normally types come straight back when the caret leaves. Rebind it in Settings → Keyboard under `Insert Reply Label 1…9`, or in `~/.config/cmux/cmux.json`. Labels past the ninth stay click-only — the digits run out. The keys are listed in the `⌄` menu beside their labels, so you do not have to remember them. (`#cm-83.2`)
- 2026-09-11 - feat | **Label a highlight in one click instead of typing the same note again.** With a note open in the Reply panel, a row of labels sits above the field — `lgtm`, `why?` and `redline` to start with. Click one and its text goes into the note **where your cursor was**, with a space added only where it would otherwise run into a word, and the note closes — a label is a finished note. It is just text: the agent receives exactly what the note says, and you can edit it like anything you typed. As many labels as fit the row show as chips, in your order; the `⌄` at the end holds **every** label — plus `Edit labels…`. A label never wipes a note — clicking one on a note you have opened but not clicked into adds to the end. (`#cm-69.3`)
- 2026-09-11 - feat | **Edit your labels in Settings → Reply.** Add, remove, rename and reorder them with the arrows; changes reach the panel as you type, with no restart. `Reset` brings back `lgtm` `why?` `redline`. Also settable as `reply.labels` in `~/.config/cmux/cmux.json` — a list of strings, in order; a non-text entry is skipped rather than rejecting the list, and `[]` means no labels. (`#cm-69.3`)
- 2026-09-11 - fix | **Taking a setting out of `cmux.json` no longer undoes a change you made in Settings since.** Before, removing a key put back whatever the setting held *before the file set it* — so a Settings change made in between was silently thrown away. Now the old value comes back only if you had not changed the setting since. **This applies to every setting `cmux.json` can manage**, not only labels. A file value you change still applies, as before.
- 2026-09-11 - feat | **Click a highlighted phrase in the reply to open its note**, the same as clicking its row in the list — and the list scrolls to it when it is out of view. Click the phrase again, or the open note's purple band, to close it; what you typed is kept, unlike Escape, which discards it. A double-click still selects a word, and a drag that ends on a highlight still makes a new one. (`#cm-84`)
- 2026-09-11 - feat | **Tab and ⇧Tab move between notes**, like ↓ and ↑ — from anywhere in the note, since Tab has nothing else to do in a one-line field. With only one note they move focus on as usual. (`#cm-82`)
- 2026-09-11 - fix | **A new highlight always puts your cursor in its note.** Every so often — seen on the highlight that made the list start scrolling — typing went nowhere because the note field never got the keyboard. The panel now checks that it did and asks again if not.
- 2026-09-11 - fix (ux) | **The label chips and the Paste buttons darken under the pointer**, so they read as clickable before you press them.
- 2026-09-11 - fix (ux) | **`Paste & Send` and `Paste` sit side by side, `Paste & Send` first**, and stack when the sidebar is too narrow for both full labels. **`Paste & Send` becomes the blue button once there is a written note or an edited preview (`#cm-93`) and the agent's turn has ended** — the moment it can be pressed; until then `Paste` is.
- 2026-09-11 - fix | **← and → no longer jump to another reply while you are typing a note.** At the start or end of the note's text the field ignored the key, it reached the panel's reply-stepping, and the note closed mid-sentence. They now just stop at the edge.
- **Known limitation — double-clicking a word inside an existing highlight opens that note first**, then selects the word; and clicking a link inside a highlight opens the note *and* follows the link.
- 2026-09-10 - fix (ux) | **The highlight you are working on is now pale iris instead of deep purple, so the agent's words stay the thing you read.** The marked phrase and its row in the list tint rather than block: dark text on a light wash, still well above the contrast bar (9.1:1). The unfocused highlights are unchanged.
- 2026-09-10 - feat | **Once a note is open in the Reply panel, ↑ and ↓ move to the previous and next note.** On a note's first line ↑ opens the one above; on its last line ↓ opens the one below. Inside a longer note they still move the caret between lines. A fresh press wraps from the last note to the first and back; holding the key stops at the end instead of spinning round. The list and the reply both scroll so the note and its highlighted words are on screen, and only when they aren't already. What you typed is kept when you move, and the caret lands after the text of the note you arrive at. Getting into the list took a click when this shipped; `#cm-83.1` since added `Tab`. No new user-facing text, so nothing to localize.
- 2026-09-10 - fix | **Your highlights list stops growing at a quarter of the Reply panel, not 40%, so the reply above it keeps more room.** On a 651pt panel the list now tops out around 163pt instead of 257pt, and the reply keeps about 398pt instead of 304pt. More than a few highlights scroll inside the list. A stopgap until `#cm-69.9` lets you drag the split yourself.
- 2026-09-10 - fix | **The Reply panel shows the line breaks the agent actually typed.** Ask for a numbered list and the terminal showed ten lines while the panel showed `1 2 3 4 5 6 7 8 9 10` on one — every single newline inside a paragraph was rendered as a space. The panel was borrowing the markdown *file* viewer's renderer, where collapsing is correct: a document author hard-wraps a paragraph at 80 columns and does not mean a break at each wrap. An agent's newline is never that. **This was the only agent-message surface in cmux still collapsing them** — the three other renderers that draw agent messages have always broken on a single newline. Code fences and tables are untouched. **A bullet is untouched in structure but not in content** — a two-line bullet now breaks where the agent wrapped it, which is the same promise applied one level in. Reasoning inside *Show thinking* gets its breaks back too, for the same reason. (`#cm-75.1`)
- **Known limitation — an agent that hard-wraps its prose now shows those wraps as breaks.** The panel cannot tell a wrap the agent meant from one it did not; nothing in the text marks the difference. **Measured before deciding, not assumed:** across 250 Claude transcripts and 250 Codex sessions, **zero** blocks of hard-wrapped prose — Codex's 279 flagged cases were all deliberate breaks in structured content (`description:`/`command:` pairs, `diff --stat` lines). So the trade costs nothing observed and buys back every deliberate newline. Your markdown **files** are unaffected either way; the file viewer still flows hard-wrapped paragraphs.
- 2026-09-09 - feat | **`←` and `→` step through replies once you click into the panel, instead of going to the terminal behind it.** The arrows were wired to the panel from the start and never reached it: clicking the reply body did make it the keyboard's owner, and cmux took that back about a second later because the focus registry had no entry for Reply. So every arrow you pressed landed in the agent's terminal. The panel now keeps the keyboard until you give it up, and the buttons and the keys do the same thing. (`#cm-69.1b`)
- 2026-09-09 - feat | **Escape hands the keyboard back to the agent's terminal, one level per press.** With a note field open the first Escape closes the field and leaves you in the panel; the next one returns you to the terminal. **This is not a convenience — without it the change above would be a trap**, because the route that used to hand focus back is exactly what keeping the keyboard in the panel switches off. Reaching for the mouse would have been the only way out. (`#cm-76`)
- 2026-09-09 - fix | **Typing keeps working after you close a note.** Closing a note field parked the keyboard on a one-pixel view that silently drops every character key, so `←` and everything else did nothing until you clicked the reply body again. **This one has been happening since the panel shipped**, and is not caused by the changes above. (`#cm-77`)
- **Known limitation — Command+F does nothing while the reply body has the keyboard.** Find has never been wired for this panel, and the panel is now somewhere you deliberately leave the keyboard, so the key is reachable and dead rather than unreachable and dead. Measured: 30 of 30 presses in the reply body did nothing, against 2 of 2 working in the terminal in the same session. **This is a deliberate call, not an oversight** — the honest answer is that Command+F should search *within* the reply, and a stopgap that jumps focus elsewhere would ship forever. The shortcut list says so beside the ⌘F row.
- **Known limitation — opening Reply from the command palette still leaves the keyboard nowhere.** The palette's own focus guard blocks the reply body from taking the keyboard while the palette is on screen, and the fallback lands on the same one-pixel view described above. Click the reply body once and everything works. Filed, measured, and untouched by this release.
- **Known limitation — the palette's "Open Reply as Pane" opens an empty pane.** Reply has never had a pane form; only the sidebar renders it. This predates this release.

## 🟠⋯ Changed for Developers
- 2026-09-13 - feat (technical) | **`#cm-89` localization audited: 3 new keys × 20 locales** in `Localizable.xcstrings` — `reply.terminalStart.notFound`, `.multiRow`, `.writing`. No web catalogs, schema or Settings text change. Machine-translated; a native pass is owed. Also fills `reply.labels.openThisMenu` (`#cm-83.3`) from 3 locales to 20.
- 2026-09-13 - feat (technical) | The gesture's decisions are pure and tested: `TerminalReplyStart` (release → ignore or open) and `TerminalReplyConsume` (held reply / highlights → silent, writing → notice, multi-row → notice, else find) in `ReplyAnnotationManifest.swift`; the page search is `window.__cmuxReplyFind` in `selectionObserverScript`, which now publishes through the ordinary `publish()` path and is `internal` so `ReplyTerminalFindTests` installs the shipped script. `MarkdownWebRenderer` gains a `seq`-gated `findRequest`/`onFindResult`, deferred until the page has loaded. A request is taken only once the Reply view's model belongs to the session the store just bound, and expires after 5 s if nothing takes it (cold code review). **Not covered by any test:** the view code that sets the drag flag (`mouseDragged`), the Reply view's consume triggers, and the expiry — the first two failed in dogfood and are covered only by the manual suite.
- 2026-09-11 - feat (technical) | **Localization audited: 16 new keys × 20 locales** in `Localizable.xcstrings` (Settings → Reply, `Edit labels…`, the `⌄`'s accessibility label), and `schemaDescriptions.reply.labels` in all 20 `web/messages` catalogs plus `web/data/cmux.schema.json`. Label *values* are never translated — the agent receives them verbatim. Two keys added and later deleted in the same slice (`chipGroup`, `menuGroup`) are gone from all 20. Machine-translated; a native pass is owed, Khmer especially.
- 2026-09-11 - feat (technical) | The insertion rule is pure and UTF-16: `ReplyLabelInsertion` in `CmuxAgentChat`, shared by both paths — through the field editor's `insertText(_:replacementRange:)` when the note field has the keyboard (so ⌘Z undoes it), else applied to the note at `lastNoteCaret`. **Why a recorded caret:** a chip click moves SwiftUI focus to the panel's focusable root on mouse-down, before the button's action runs (measured: `fr=KeyViewProxy`), so the caret is recorded on every `NSTextView.didChangeSelectionNotification` from the focused note's field editor.
- 2026-09-11 - fix (technical) | `KeyboardShortcutSettingsFileStore`'s removal loop restores a key's pre-file backup only when `settingStillHoldsImportedValue` — the setting still equals the previous import, with *absent* equal to a file `null` (as the apply path already treats it). Tests: `SettingsFileKeyRemovalTests` — a list edited since (kept), untouched (restored), a `null` colour (restored).
- 2026-09-11 - fix (technical) | **Tests that build a `KeyboardShortcutSettingsFileStore` must isolate `cmux.settingsFile.backups.v1` and `cmux.settingsFile.importedManagedDefaults.v1`.** The test host shares the dev app's bundle id and so its defaults; a real `cmux.json` leaves backups there that a fixture then "restores". `ReplyLabelsFileParserTests` failed deterministically this way until it cleared both, as `WindowTitleTemplateTests` already did.
- 2026-09-11 - fix (technical) | **Pre-existing, not fixed here:** 11 Swift Testing `settingsFileStore…` cases and a handful of XCTest store and shortcut cases fail identically on the last commit's store; and `everyCuratedSettingEntryIsReachable` flags `setting:terminal:restart-allowlisted-commands`, whose row anchors as `settings.terminal.…`.
- 2026-09-10 - fix (technical) | **Localization audited, none owed** — the change adds no user-facing string, no menu item, no settings row and no help text. It alters how existing agent-authored text is line-broken, and that text is never a catalog value.
- 2026-09-10 - fix (technical) | `MarkdownWebRenderer` gains `rendersLineBreaks`, a defaulted `var` that installs a `WKUserScript` re-running `marked.use({breaks: true})` on that renderer's page only. **Not an edit to `shell.html`** — that file is shared with every markdown viewer and touching it re-opens `#cm-15`'s two human checks; `onSelectionChanged` is the precedent for earning page behaviour this way. Safe per-instance because each `MarkdownRendererSession` owns one coordinator owns one `WKWebView` owns one JS context, so a page global cannot leak between renderers. **Defaulted, not required**, so the file panel's call site needs no edit.
- 2026-09-10 - fix (technical) | The script is `internal`, where its neighbour `selectionObserverScript` is `private`, and that difference is the test lane. `MarkdownReplyLineBreakTests` installs *that constant* into its own configuration; made `private` it could not name it and would have to hand-copy the JS, proving a duplicate works while the shipped script drifted. `@testable` lifts `internal` and never `private`, so the modifier is the whole of the test's reach. The bare-`WKWebView` shape that makes it possible comes from `MarkdownLinkBoundaryRegressionTests`, `MarkdownCodespanRenderingTests` and `MarkdownYMDShellTests` — none of which reference this script. Verification design decided an access modifier.
- 2026-09-10 - fix (technical) | **A `<br>` moves the rendered-text coordinate space, and an earlier draft of this claimed it did not.** `textNodes()` sums `nodeValue.length`, so a paragraph that was one node of length 5 becomes three nodes totalling 3 — every `#cm-69` mark offset after a break shifts. Nothing breaks today only because `ReplyAnnotation`, `ReplyAnnotationSet` and `ReplyDrafts` are not `Codable`, so no range survives the relaunch this change requires. Recorded as an Open migration item on `#cm-69.2b`: the day a mark persists across launches, this becomes a migration.
- 2026-09-10 - fix (technical) | A second `marked.use` **merges** rather than replaces — it overrides `breaks` and leaves the shell's `processAllTokens` hook and custom `codespan`/`code` renderers registered. Verified against the bundled `marked.min.js` before the design was fixed, with fence, table and list output byte-identical either way.
- 2026-09-09 - feat (technical) | `MainWindowFocusController` learns a fifth focus host, `replyHost`, and it is not shaped like the other four. They are containers that *find* the focused view; this **is** the view that takes the keyboard — the page's own `MarkdownWebView`, handed over by `MarkdownWebRenderer` while it is mounted. That distinction is load-bearing: `focusRightSidebarEndpoint` has to *make* its owner first responder, and an earlier attempt at a zero-size anchor could only ever *recognise* focus. The measured view chain killed it — the anchor's ancestors were its own 0×0 wrapper or the whole window, nothing in between.
- 2026-09-09 - feat (technical) | The hand-off fires on attach **and** detach, because `makeNSView` re-parents a cached web view rather than building one. A registration made once outlives its mount and answers from a detached view; the staleness guard is a same-window check in `replyOwns`, which settles the two-window case in the same line.
- 2026-09-09 - feat (technical) | Escape is an **opt-in** closure on `MarkdownWebView`, set only by the Reply mount. That class is shared with the markdown panel, so an unconditional `keyCode == 53` arm would have changed Escape in both. It is deliberately not gated on the editable-focus flag the viewer-navigation path uses — that flag turns true only after the injected script posts its first message, which would leave Escape dead on a page still loading.
- 2026-09-09 - fix (technical) | `focusRightSidebarEndpoint`'s `case .reply` returned `false` — a placeholder from `cm-69.1` waiting for a responder that did not exist yet. It was doing active harm, not waiting quietly: the `false` is what made `focusRightSidebar` fall through to the fallback host. The same abandoned step left a second placeholder in `RightSidebarToolPanel`, which is the empty pane noted above.
- 2026-09-09 - fix (technical) | Both arrow handlers now check modifiers. They matched on the key alone, so Command, Option and Shift arrows all stepped the reply — and Shift+arrow is the extend-selection stroke in a panel built for selecting spans. **Nothing shipped with this defect**: the handlers had never fired in a released build, so making them reachable is what made it reachable.

---

# 🔵⋯ v0.27.1 (2026-09-08) — #cm-69.6
*`◄` stops after the last five replies instead of walking a history you were never going to read.*

## 🟠⋯ Changed for End Users
- 2026-09-08 - feat | **`◄` stops after the last five replies instead of walking a history you were never going to read.** The Reply panel is for the messages you would actually correct, and a real session's loaded window holds roughly eleven to twenty-five replies — nobody reviews the twenty-fifth. When the walk stops, the header says **`Showing last`** beside the counter, so a greyed `◄` reads as "this is the limit" rather than as "the conversation started here", which would be false. **A reply carrying unsent notes never counts against the limit and always stays reachable**, so the cap can never strand something you wrote.
- 2026-09-08 - feat | **The position counter is re-based on the replies you can actually reach: the newest reads `5 of 5`, and the oldest you can step back to reads `1 of 5`.** It used to count up from the oldest message *loaded*, which meant something only while that was the start of the conversation — a place you could point at. With a limit it becomes "wherever five back happens to be". **`N` is now what `◄` will really reach:** the number you configured when nothing is marked, and larger than it only when one of your own marks is holding an older reply alive — so the number growing is itself the signal that something is marked back there. The counter also reads `3 of 5` rather than `3/5`.
- 2026-09-08 - feat | **Set how far `◄` walks with `reply.maxMessagesBack` in `~/.config/cmux/cmux.json`.** Defaults to 5; there is no Settings row, because the default is right unless you go looking. An absent, zero, negative or non-numeric value falls back to 5 rather than being quietly corrected to something you did not ask for.
- **Known limitation — the `Showing last` caption is unverified in every language but English.** cmux's string catalog has no translated "showing" verb to derive from, so the nineteen translations carry only the "newest/last" adjective. In German, Polish, Japanese, Korean and Chinese that can read as naming the single newest reply rather than the recent set. The English is settled; the translations need a native pass.

## 🟠⋯ Changed for Developers
- 2026-09-08 - feat (technical) | `ReplyPanelModel` owns how far `◄` reaches, as one predicate with three clauses. The middle one — *an annotated reply exists older than the next step* — is what keeps the reachable set **contiguous**: without it a mark seven back stays reachable while the un-annotated sixth does not, so the arrow would have to skip a reply or the anti-strand guarantee fails silently.
- 2026-09-08 - feat (technical) | `ReplyDrafts` moved from `ReplyPanelView`'s `@State` into `ReplyPanelStore`, which pushes the annotated message `seq`s into the model. It stays out of `ReplyPanelModel` because `load()` resets that type on every session change, and unsent writing must not die with a rebind.
- 2026-09-08 - fix (technical) | `ReplyPanelStore.stepBack()` asks `canStepBack` before acting. It had read *any* refusal from the model as licence to page older history, so a press at the limit would still have read 300 lines off disk — the model being right was not enough.
- 2026-09-08 - fix (technical) | `atOldestLoadedReply` is stated against the replies themselves rather than against the rendered counter. It read `position.index == 1`, and re-basing the counter on the *reachable* set makes that the oldest reply the cap lets you step to — not the oldest one loaded. The "the conversation did not start here" note would have fired **at the cap**, stacked under `Showing last`, on a transcript with plenty of replies still behind it.
- 2026-09-08 - feat (technical) | `reply.*` is a top-level section in `cmux.json`, not nested under `rightSidebar`, which the settings validator skips structurally — a typo beneath it is never reported. Verified with a control: `reply.maxMessagesBack` validates and `reply.maxMessagesBackk` is flagged.

---

# 🔵⋯ v0.27.0 (2026-09-07) — #cm-69.2a, #cm-69.2b
*Mark up passages in your agent's reply and send your notes back as one prompt.*
*`#cm-69.2a` (one span per reply) was built 2026-09-03 and never released on its own — its wire format was superseded the day after it was built, so it ships here in the format `#cm-69.2b` settled.*

## 🟠⋯ Changed for End Users
- 2026-09-06 - feat | **Mark up several passages in one reply and send your notes back as a single prompt.** Select a span in a rendered reply and it becomes a tinted phrase with its own number; the note you write on it joins a numbered list in the footer, in the order you marked them. `✕` on a hovered row removes it and renumbers the rest at once. `⤢` opens a preview of exactly what will be sent. **Paste** types the composed instruction into the agent's composer without submitting, at any point in the turn; **Paste & Send** also submits, and waits until the turn has ended.
- 2026-09-07 - fix | **The highlight you are working on is a solid colour, not a pale wash.** It had been an accent colour built to carry white text, made translucent to sit behind body text — which is why every candidate arrived looking washed out. The footer also lists your notes in the order you *selected* them rather than reordering them by position in the message.
- 2026-09-07 - fix | **Paging `◄` back far enough to pull in older history no longer erases unsent notes.** They had been pinned to an identifier that older messages arriving could rename, which took them out of the footer with no way back.
- 2026-09-07 - fix | **Opening a note keeps its highlight lit in the message, not only while the pointer is over the row.** The row and the span had disagreed about which highlight counted as in focus.
- 2026-09-07 - fix | **Notes no longer appear on a different session's reply, or on a reply that replaced theirs after a compaction.** They had been keyed by a transcript line number, and every session — and every rewritten transcript — has its own line 40.
- 2026-09-07 - fix | **The preview shows the reply you are on.** Stepping to another reply while it was open left the box showing one reply's notes while **Paste** sent another's.
- **Known limitation — a note is not checked against the message it was written on.** If the session rebinds or the transcript is rewritten between writing a note and sending it, the note is still pasteable and still says what you meant; nothing verifies it is being sent to the reply it was about. This is a deliberate call — a note you wrote is what you wanted to say, and refusing it would lose writing — but it means the panel cannot promise a delivery lands on its original target.
- **Known limitation — stepping away from a reply and back leaves its highlights unpainted.** The notes are still listed in the footer; the tinted spans in the message are not redrawn, because re-finding a span in a re-rendered message needs a way to tell two identical quotes apart that does not exist yet.

## 🟠⋯ Changed for Developers
- 2026-09-07 - feat (technical) | Multi-span annotation lives on `ReplyAnnotationSet`, numbered in selection order and serialized as one anchored list. Unsent drafts live in `ReplyDrafts`, keyed by `(session, transcript generation, message seq)` — a `seq` is a transcript line index and is unique inside neither a session nor a rewrite, so both coordinates are load-bearing.
- 2026-09-07 - feat (technical) | `ReplyDeliveryGate` holds the paste/send rule in one place. It had been written out at the button and again in the store, and the copies disagreed.

---

# 🔵⋯ v0.26.0 (2026-09-02) — #cm-69.1
*Read your agent's replies in the sidebar, and step back through them.*
*Also carries entries that had been sitting unreleased since v0.22.0 — `#cm-47`'s Antigravity auto-naming and two `#cm-60` corrections — which were pending before this release and ship with it.*

## 🟠⋯ Changed for End Users
- 2026-09-02 - feat | A new **Reply** mode in the right sidebar shows the newest thing your agent said, rendered as markdown, with `◄ n/N ►` to step back through earlier replies. It binds to the last agent pane you focused, follows along as new replies arrive, and holds your place when you have stepped back. Reasoning sits behind a "Show thinking" disclosure (#cm-69.1)
- 2026-09-02 - feat | **A reply is one turn, not one API response.** A prompt whose answer runs a tool part-way through shows as a single reply, matching what the terminal shows. It used to split into two, because the API ends a response wherever the agent stops to call a tool — a break you never asked for and cannot see (#cm-69.1)
- 2026-09-02 - fix | Clicking a link in a rendered reply no longer freezes the app. The link routing ran before the web view was told what to do with the click, so the window waited on it (#cm-69.1)
- 2026-09-02 - fix | Starting a fresh agent with Reply open no longer says "Lost track of this agent". It says it is waiting, then shows the reply when the turn ends. The panel had treated "this agent has not written anything yet" as a fault (#cm-69.1)
- **Known limitation — the panel is mouse-driven for now.** Arrow keys do not reach it: the sidebar's focus host swallows them before any mode sees them. Use `◄ ►`. Keyboard navigation is `#cm-69.1b` (#cm-69.1)
- **Known limitation — links open in your system browser, and `.md` links do nothing.** The panel has no pane of its own to route a link through, so it misses cmux's in-app browser. `#cm-69.1a` (#cm-69.1)
- 2026-08-23 - feat | Antigravity CLI sessions can now automatically name their cmux workspace and tab through a supported Naming Agent you explicitly select. Run `cmux hooks agy install --yes`, enable Workspace Auto-Naming, and choose an installed supported Naming Agent; manual names still always win (#cm-47)
- **Known limitation — Naming Agent → Automatic does not run Antigravity itself yet.** cmux reads Antigravity's bounded current-conversation transcript, but it will not invoke `agy` as a summarizer until that can be proven isolated from the real Antigravity home and useful tools. Select Claude Code, Codex, Grok, OpenCode, Pi, or OMP for now (#cm-47)

## 🟠⋯ Changed for Developers
- 2026-09-02 - feat (technical) | The shared `CmuxAgentChat` transcript parser now surfaces `apiMessageID` (Claude `message.id`, Codex `payload.id`) and `phase` (Codex `final_answer`/`commentary`). Both are additive optional fields the iPhone Agent Chat ignores (#cm-69.1)
- 2026-09-02 - fix (technical) | `ReplyPanelModel` pins its reading position by message `seq` rather than by reply id. A reply is delimited by the prompt in front of it, so the oldest loaded one is often partial and gets renamed when older history pages in — which threw the reader to the newest reply for pressing `◄` (#cm-69.1)
- 2026-09-02 - chore | Removed the `writing` state word and the muted body. Measured in dogfood: the transcript is written a whole content block at a time and Stop follows within a few hundred milliseconds, so the state only ever surfaced for a slow tool call mid-answer and cost a flicker on every ordinary turn. `isWriting` remains in the model for `#cm-69.2`'s annotation gate (#cm-69.1)
- 2026-08-29 - fix (docs) | **v0.22.0's release notes and README said the SwiftUI sidebar was unreachable in a shipped build because the Feature Flags window is DEBUG-only. That was wrong.** `cmux __internal_flags` ships in Release (`CLI/cmux.swift:3892`) and opens the same window through `TerminalController.swift:2058`, outside any `#if DEBUG` — only the Help-menu entry is fenced. What actually keeps the renderer flag from flipping is `Sources/FeatureFlags.swift:576`: a local override is discarded while a remote value is cached, and upstream's control plane pins this one on. The practical effect is unchanged — you will not see the SwiftUI list — but *effectively* unreachable is not unreachable, so the group colour menu there remains unwatched by anyone rather than retired as dead code (#cm-60)
- 2026-08-29 - fix (technical) | a `#cm-60` test named `theGroupsOwnColorIsTheOnlyTickedRow` asserted `count <= 1` on the ticked rows, which zero satisfies — so a build that ticked nothing passed it. Found by a cold scope review, not by the six-mutation campaign, which missed it because the neighbouring negative test caught the mutation that would have exposed it. Now resolves the expected row from the shared candidate model and asserts equality (#cm-60)
- 2026-08-23 - feat (technical) | the `antigravity` hook adapter now accepts only explicit `fullyIdle: true` completion boundaries, validates the current conversation's fixed transcript path with descriptor-relative no-follow opens, reads at most the final 512 KiB from the verified regular-file descriptor, and feeds only completed human user/model text into the existing locked auto-naming and `workspace.set_auto_title` path (#cm-47)

---

# 🔵⋯ v0.25.2 (2026-09-01) — #cm-67.2
*A label fix on `#cm-67.1`, found in its own dogfood.*

## 🟠⋯ Changed for End Users
- 2026-09-01 - fix (ux) | **tell at a glance which Arrange Splits patterns are yours.** A pattern you defined now reads **Editor (3:1) (Custom)** in both the menu and the command palette; the four built-ins are unchanged. This matters most in the palette, where your patterns and the built-ins interleave — a built-in can sit between two of yours — so position tells you nothing and the label is the only signal. With no custom patterns, both surfaces look exactly as they did in v0.25.1 (#cm-67.2)

## 🟠⋯ Changed for Developers
- 2026-09-01 - fix (technical) | one new localized key, `command.arrangeSplits.customPattern.label`, translated in all 19 locales with positional arguments so a locale can reorder the name and the ratios. **A palette contribution carries no rank, order, or group field** (`commandId · title · subtitle · shortcutHint · keywords · dismissOnRun · when · enablement`), so the fuzzy matcher owns row order outright and grouping is not available there — the label is the only channel, which is why it says what a pattern *is* rather than where it lives. Pinned by `testCustomArrangementPatternsJoinTheBuiltInsAndBadOnesDropAlone`, extended to assert the exact custom label **and** that no built-in carries the marker — observed failing against the unmarked label with `("Reading (2:1)") == ("Reading (2:1) (Custom)")` (#cm-67.2)

---

# 🔵⋯ v0.25.1 (2026-09-01) — #cm-67.1
*A slice of `#cm-67`, so a patch rather than a new minor. `#cm-47` and `#cm-60` stay unreleased above.*

## 🟠⋯ Changed for End Users
- 2026-09-01 - feat | **define your own Arrange Splits pattern once and reach it like a built-in.** Write `"panes": {"arrangePatterns": {"Triptych": "1:1:0.5"}}` in `cmux.json` and **Triptych (1:1:0.5)** appears in **View → Arrange Splits** and the command palette, below the four built-ins, live and with no restart. The notation is the one the menu already prints as its hints, so what you read is what you type. A pattern adapts to however many splits you have by the same rule the built-ins use — `1:1:0.5` lands 40/40/20 in three columns and `1:1:1:0.5` in four (#cm-67.1)
- 2026-09-01 - feat | **a pattern you got wrong drops on its own instead of taking the menu with it.** Weights are validated when the file is read: fewer than two, or any that is non-numeric, zero, negative, or infinite, drops that one pattern with a debug log and leaves every other pattern and all four built-ins working (#cm-67.1)

## 🟠⋯ Known Limitations
- **No Settings row and no shortcut for a custom pattern.** They are reachable from the menu and the palette only. Binding one to a key needs a dynamic action-id scheme, because cmux's two `ShortcutAction` enums are compile-time and must stay in sync — deliberately left to its own slice (#cm-67.1)
- **The 0.1–0.9 divider clamp still applies**, and custom ratios make it easier to hit on purpose: a share that would compute below 0.1 lands at the clamp. Validation rejects weights that cannot work at all; it cannot widen Bonsplit's range (#cm-67, #cm-67.1)

## 🟠⋯ Changed for Developers
- 2026-09-01 - refactor (technical) | the four built-in patterns are now `SplitRatioSpec`s rather than a `switch` of their own — `mainFirst` is literally `"2:1"`, `minorLast` is `"1:1:0.5"` — so one span-adaptation rule serves built-in and user-defined patterns alike and a future fix cannot be applied to one and forgotten on the other. Two tests hold this together: `SplitRatioSpecTests.builtInPatternsMatchTheirPreUnificationVectors` proves the *rule* reproduces the removed switch across 2…12 spans, and `testArrangementPresetWeightRulesAdaptToSpanCount` pins the *shipped vectors* — each at a span count above its written length, because below it the rule drops `weights[1]` and a wrong middle weight would not show. Cold review found exactly that gap: `mainLast` could be shipped as `1:5:2` with the whole suite green. Closed and re-proved by re-running the same mutation, now failing with `[1,5,5,2] == [1,1,1,2]`. Span rule: `s ≥ n` → `[w₀] + [w₁]×(s−n+1) + w[2…]` (identity at `s == n`, and it preserves every written weight); `s < n` → `[w₀] + w[(n−s+1)…]`. CmuxPanes 45/45, focused app suite 104/104 (#cm-67.1)

---

# 🔵⋯ v0.25.0 (2026-09-01) — #cm-66, #cm-67
*Cuts v0.25.0 for local dogfooding. Releases `#cm-66` and `#cm-67` together — they share one menu, one action path, and one commit, so splitting them across two versions would number the same change twice. `#cm-47` stays unreleased in the section above.*

## 🟠⋯ Changed for End Users
- 2026-09-01 - feat | **make your split widths or heights equal in one action, instead of dragging each divider.** **Equalize Split Widths** evens only the side-by-side columns and leaves stacked heights where you put them; **Equalize Split Heights** does the inverse. Both are in the View menu and the command palette. Neither claims a key by default — the chord space around ⌃⇧⌘= is taken — so bind them yourself in Settings → Keyboard Shortcuts or in `cmux.json`. The existing **Equalize Splits** (⌃⇧⌘=) still evens everything in one press (#cm-66)
- 2026-09-01 - feat | **arrange your splits into a common layout pattern in one action.** **View → Arrange Splits** offers four patterns — **Main First (2:1:…)**, **Main Last (…:1:2)**, **Minor First (0.5:1:…)**, **Minor Last (…:1:0.5)** — which adapt to however many splits you have rather than fitting a fixed count: Minor Last lands three columns at 40/40/20 and Main First lands two at 67/33. Only dividers move; no pane ever changes position. A split running the other way counts as one span and keeps its own internal proportions (#cm-67)

## 🟠⋯ Known Limitations
- **A pattern can degrade quietly at high span counts.** Bonsplit clamps every divider position to 0.1–0.9 and still reports success, so from six spans a Minor span's 0.5/5.5 share lands at 0.1 rather than its true ratio. You get a valid layout, just not the one the ratio names (#cm-67)
- **In canvas mode the menu and palette do not do what the shortcut does.** The shortcut path routes through the canvas executor while the menu and palette move the hidden split tree, visible only after you leave canvas. Inherited from upstream's Equalize Splits, not introduced here; tracked as `#cm-70` (#cm-66, #cm-67)
- **If you bind these in `cmux.json` by hand, use one shape, not two.** A flat `shortcuts.<action>: "cmd+ctrl+j"` silently outranks a `shortcuts.bindings.<action>` entry for the same action, and the Settings row keeps displaying the chord that no longer fires. Generic across every action and pre-existing; tracked as `#cm-71` (#cm-66)

## 🟠⋯ Changed for Developers
- 2026-09-01 - feat (technical) | `ExternalTreeNode.ratioDividerPlan(ratios:orientation:)` turns an arbitrary weight vector into per-split divider positions, appending children before parents and rejecting non-finite, zero, empty, or count-mismatched input; `spanCount(along:)` counts spans in one orientation, treating a cross-orientation subtree as a single span. The four patterns are named generators over that vector, so the geometry layer has no notion of a preset. Verified 36/36 in `CmuxPanes` plus focused app suites, with mutations M1–M4 each observed failing the intended assertion before the fix landed — M4 (dispatch-table orientation strings swapped) failing exactly the two bound-shortcut tests while the other 101 stayed green (#cm-66, #cm-67)

---

# 🔵⋯ v0.24.0 (2026-08-30) — #cm-65
*Cuts v0.24.0 for local dogfooding. Releases `#cm-65` only — `#cm-47` stays unreleased in the section above.*

## 🟠⋯ Changed for End Users
- 2026-08-30 - fix (ux) | **read a labeled sidebar color section by its meaning alone.** When a workspace color has a semantic label, its generated sidebar section now shows that label as the complete title instead of `Label (Color)`; the adjacent swatch keeps color identity visible. Clearing the label restores the custom display name or raw palette name. Settings, menus, commands, and CLI keep their existing combined `Label (Color)` names (#cm-65)

## 🟠⋯ Known Limitations
- VoiceOver and the installed-app behavior rerun were explicitly skipped and accepted unverified. Every visible tagged-build title scenario passed (#cm-65)

## 🟠⋯ Changed for Developers
- 2026-08-30 - fix (technical) | one sidebar-local title projection uses semantic label, then custom display name, then raw palette name, while both sidebar renderers and accessibility consume one shared header title. Focused coverage passes 9/9 and test wiring passes across 669 files. The repository-wide release run became definitively non-green in unrelated agent-resume, remote-command, and AppKit geometry tests: 95 cases started, 88 passed, 6 failed, and the run was stopped with one case active after a green verdict was no longer possible. Independent code and build-scope reviews both approved with zero findings (#cm-65)

---

# 🔵⋯ v0.23.0 (2026-08-29) — #cm-61
*Cuts v0.23.0 for local dogfooding. Releases `#cm-61` only — `#cm-47` stays unreleased in the section above.*

## 🟠⋯ Changed for End Users
- 2026-08-29 - feat (ux) | **rename a custom palette colour and edit its exact hex after creating it.** The custom name, semantic label, swatch, and `#RRGGBB` value are now independently understandable and editable in **Settings → Workspace Colors**. Clearing a custom name restores its stable `Custom N` fallback; the raw identity used by existing configuration and commands does not change (#cm-61)
- 2026-08-29 - feat (ux) | **keep a custom colour's existing assignments when its value changes.** If the old hex belongs to one palette entry, direct entry and the native colour picker automatically carry matching explicit workspace and group assignments to the final value without a dialog. The picker previews while open and saves its final value once when it closes (#cm-61)
- 2026-08-29 - fix (ux) | invalid names and hex drafts stay beside the error that explains how to repair them, while the last saved palette value remains authoritative. New duplicate palette hexes are rejected because assignments store only the value and cannot preserve which of two same-valued names was chosen (#cm-61)

## 🟠⋯ Known Limitations
- An imported palette that already contains the same old hex under multiple entries is ambiguous. Editing one of those entries changes that palette entry only; cmux does not guess which existing workspace or group assignments belonged to it (#cm-61)
- Effective colours resolved from `cmux.json` remain user-owned configuration. A palette edit does not rewrite configured literal hexes or other config text; built-in palette entries also remain non-editable (#cm-61)

## 🟠⋯ Changed for Developers
- 2026-08-29 - feat (technical) | `workspaceColors.displayNames` adds optional custom display names keyed by stable raw palette identity. One fail-closed resolver validates raw names, display names, and semantic labels; one revisioned host mutation owns palette changes and explicit workspace/group propagation. Focused Settings, coordinator, resolver-mutation, picker-lifecycle, test-wiring, localization, tagged-build, and 5/5 human dogfood evidence cover the shipped path (#cm-61)

---

# 🔵⋯ v0.22.0 (2026-08-28) — #cm-60
*Cuts v0.22.0 for local dogfooding. Releases `#cm-60` only — `#cm-47` stays unreleased, still held for one combined CM-47 delivery, and `#cm-54`/`#cm-55` remain in Review.*

## 🟠⋯ Added for End Users
- 2026-08-28 - feat (ux) | **you can give a workspace group a colour from inside the app.** Right-click a group header → **Group Color**, and pick from the same palette, with the same names, the workspace colour menu already offers. The colour itself is not new — `#cm-49` shipped the field and drew it as the header band — but until now the only way to set one was the `workspace.group.set_color` socket command. The checkmark marks the colour **you picked**, never one resolved on the group's behalf (#cm-60)

## 🟠⋯ Known Limitations
- **No Color does not always leave you with a neutral band.** It clears the group's own colour, which is exactly what it says. But if that group's anchor workspace has a cwd entry in `~/.config/cmux/cmux.json` carrying a colour, the configured colour then shows through — so **No Color** reads as ticked beside a band that is still coloured. The menu is telling the truth about the override and the band is telling the truth about what renders; they are answering different questions. Clear the colour on that cwd entry in `cmux.json` to get a neutral band (#cm-60)
- **A group's icon is still not reachable from the app.** `iconSymbol` has no UI; this release adds colour only (#cm-60)

## 🟠⋯ Changed for Developers
- 2026-08-28 - feat (technical) | the workspace colour submenu is now built once per renderer and shared by both menus — `SidebarColorSubmenu.make` for AppKit's `NSMenu`, `WorkspaceColorMenuRows` for SwiftUI — with both reading the same `WorkspaceTabColorSettings.colorMenuCandidates`. A palette or label change now reaches the workspace menu and the group menu together instead of one of them silently. The invalid-hex alert collapsed the same way, from three identical copies to one `presentInvalidWorkspaceColorAlert`. The group menu reads `customColorHex` and never the resolved `tintHex`, so a colour arriving from a `cmux.json` cwd config cannot tick a row the user never chose (#cm-60)

---

# 🔵⋯ v0.21.1 (2026-08-28) — #cm-56
*Two fixes from dogfooding v0.21.0, cut the same day. One of them retires a Known limitation v0.21.0 shipped: that release recorded the refused drag as intended behaviour, and it was not.*

## 🟠⋯ Changed for End Users
- 2026-08-28 - fix (ux) | **a colour section now reads as a container.** Workspaces inside one are indented like the members of a real workspace group, instead of sitting flush against the sidebar edge (#cm-56)
- 2026-08-28 - fix (ux) | **you can drag a coloured workspace into a real group again.** v0.21.0 refused that drop and its release notes recorded the refusal as intended; it was not. The row's own **Move to Group** menu already performed the same move, so the drag was disagreeing with the menu about one behaviour. Every other rejected drop still rejects — another colour section, a standalone row, the other pin tier — and this retires v0.21.0's Known limitation (#cm-56)

## 🟠⋯ Changed for Developers
- 2026-08-28 - fix (technical) | colour-section membership is resolved once from the shared projection and threaded to both sidebar renderers, which now delegate the indent to one rule (`SidebarWorkspaceColorSectionDropPolicy.indentsUnderHeader`) rather than each testing `groupId != nil`. `isGrouped` stays truthful about real `WorkspaceGroup` membership. The drop rule that refused a colour member every non-same-section target moved out of an untestable view wrapper into `allowsDropOutOfSection`, with tests for both — the previous version of that logic was unreachable from any test, which is how a too-broad refusal shipped unseen (#cm-56)

---

# 🔵⋯ v0.21.0 (2026-08-28) — #cm-56
*Cuts v0.21.0 for local dogfooding. Releases `#cm-56` only — `#cm-47` stays unreleased, held for one combined CM-47 delivery, and `#cm-54`/`#cm-55` remain in Review. Versions track release order, so those take later numbers than this one despite lower ids.*

## 🟠⋯ Changed for End Users
- 2026-08-26 - feat (ux) | **scan standalone workspaces by the meaning of their color.** Ungrouped colored workspaces now appear under compact collapsible color headers named from the effective palette label and name, styled with the same rounded, inset, appearance-aware band as a real group's header; real groups and uncolored workspaces keep their existing shape, and selecting a hidden member expands its color first (#cm-56)
- **Known limitation — Increase Contrast, Reduce Transparency, grayscale, keyboard focus, and VoiceOver were accepted unverified.** Light and Dark passed, along with same-color-section reorder and every rejected cross-color, cross-group, standalone-row, and cross-tier drop; the accessibility-state pass was explicitly skipped (#cm-56)
- **Known limitation — a colored ungrouped workspace can no longer be dragged into a real group.** Any workspace with a color now rejects that drop, the same way a drop into a different color section is rejected; drag a colorless workspace in, or use the group's own **Move to Group** action to move a colored one (#cm-56)
- **Known limitation — the color-section header ignores the global font-magnification setting.** Every other sidebar row scales with it; this header is pinned at 26pt. Recorded as a dated decision, to fix before any further sidebar row work (#cm-56)

## 🟠⋯ Changed for Developers
- 2026-08-26 - feat (technical) | one immutable color-section projection and one mutation path now drive SwiftUI/AppKit headers, shared-hex collapse persistence, active-member reveal, and same-color/same-pin-tier slot-preserving reorder without creating real workspace groups; the header band reuses `SidebarGroupHeaderBandPalette` from #cm-49 for renderer parity. The focused CM-56 suite passed 10/10 including 2/2 renderer-parity checks, adjacent real-group/numbering/drop suites passed 78/78, and test wiring passed across 666 files (#cm-56)
- 2026-08-27 - fix (technical) | an independent scope-review sweep found that switching `visibleWorkspaceRowIds` to `.workspace`-only filtering silently dropped every real group's header from the set of valid SwiftUI reorder-drop targets too, not just the intended color-section duplicate — restored via a dedicated `interactiveRowIds` helper that keeps real-group anchors. Also closed a coverage gap: the `Custom (#RRGGBB)` fallback label had no test asserting its actual title (#cm-56)
- 2026-08-27 - fix (technical) | a second, independent code review of the full slice found and closed: the AppKit renderer's own `reorderDropTargets()` still supplied a phantom target for a collapsed color section's hidden first member (SwiftUI already excluded it); `rowWorkspaceId` trapped on an empty `memberWorkspaceIds` array reachable through the public initializer, now returns `nil` instead; and the live-label-update `UserDefaults` observer could mutate `@State` off the main thread (#cm-56)
- 2026-08-28 - test (technical) | the `interactiveRowIds` regression guard is mutation-verified: reverting it to the buggy body makes its test fail on the missing group anchor while every other test stays green, so the guard genuinely discriminates rather than passing by construction (#cm-56)

---

# 🔵⋯ v0.20.0 (2026-08-25) — #cm-48
## 🟠⋯ Fixed for End Users
- 2026-08-25 - fix (ux) | **have every Codex session I rename update its cmux tab.** Ordinary `codex` launches from cmux-integrated zsh, bash, and fish keep using cmux's per-terminal wrapper even after shell startup or later tooling reorders `PATH`, so concurrent sessions no longer depend on which command happens to resolve first (#cm-48.1)
- 2026-08-25 - fix (ux) | **rename one Codex session without it claiming my workspace name.** An agent-sourced tab title now stays with its own tab when sibling agents share the workspace; a workspace name set directly in cmux keeps its existing behavior and still wins (#cm-48.2)
- 2026-08-25 - fix (diagnostics) | a typed `/rename` submission that cmux cannot prove now leaves one DEBUG explanation at submit time, without weakening the fail-closed input rule or adding work to later keystrokes (#cm-48.3)
- **Relaunch boundary:** a Codex process that was already running without cmux hooks must exit and relaunch; cmux itself does not need to restart (#cm-48.1)
- **Known limitation — fish dispatch is unproven at runtime on this machine.** zsh and bash passed the executable dispatch matrix; fish is implemented and inspected but the cases skipped because fish is not installed (#cm-48.1)
- **Known limitation — arrow-edited and pasted `/rename` submissions may fail closed.** Press Escape and type the command again without arrow keys. The DEBUG receipt for that live failure was accepted unverified (#cm-48.3)
- **Verification ceiling:** focused shell, hook-lifecycle, title-provenance, session-registry, and input-buffer checks pass. The repository-wide suite attempt was characterized but did not produce a green verdict (#cm-48)

---

# 🔵⋯ v0.17.1 (2026-08-25) — #cm-53
## 🟠⋯ Fixed for End Users
- 2026-08-25 - fix (ux) | **read my group workspace names in dark mode.** Workspace-group names now follow the appearance of their bands, so the group structure remains scannable without switching to Light appearance. The primary Light/Dark scenario passed; Reduce Transparency and Increase Contrast remain accepted unverified (#cm-53)

---

# 🔵⋯ v0.17.0 (2026-08-25) — #cm-49
## 🟠⋯ Changed for End Users
- 2026-08-25 - feat (ux) | **group headers now read as containers instead of looking like one more workspace row.** A full-width band carries the group's colour across the header; a group with no colour gets a neutral band, and the active group's band deepens. Member workspaces keep their narrow identity strip, so the container and its contents speak through different shapes (#cm-49)
- **Known limitation — a group name can render black on its dark band after an appearance change.** The separate `#cm-53` fix is not included in this release; Tom explicitly approved releasing `#cm-49` alone with that dependency unresolved (#cm-49)
- **Known limitation — Reduce Transparency and Increase Contrast were accepted unverified.** The normal Light and Dark appearances passed, including Dark → Light → Dark while the group was resting and active, but neither accessibility setting was exercised (#cm-49)

## 🟠⋯ Changed for Developers
- 2026-08-25 - feat (ux) (#cm-49) | SwiftUI and AppKit consume one `SidebarGroupHeaderBandPalette` for coloured, neutral, active and multi-selected group states. The final focused group-header suite passed 13/13 and project test wiring passed across 665 files; five author-run mutations were applied and caught. No independent verification verdict exists after two attempts returned none (#cm-49)

---

# 🔵⋯ v0.16.0 (2026-08-24) — #cm-46
## 🟠⋯ Changed for End Users
- 2026-08-24 - feat | open a web link in your default browser without changing where the next one opens. Right-click a recognized terminal web link and choose **Open in Default Browser**; after a page is already open in a cmux browser tab, use the external-link button beside the address bar—or the same command first in **More Actions** when the pane is narrow. The cmux tab stays open and terminal-link routing settings stay unchanged (#cm-46)
- **Known limitation — on a remote workspace whose proxy endpoint has not resolved yet, the action can open a page that was requested but never loaded.** `BrowserPanel.navigate` assigns `currentURL` optimistically on that path, and the action reads `currentURL`, so a URL you submitted but that never finished loading is what reaches your default browser. Local workspaces are unaffected: there `currentURL` follows the committed document. Found by reading the navigation path, not reported by anyone (#cm-46)

## 🟠⋯ Changed for Developers
- 2026-08-24 - feat (technical) (#cm-46) | one shared `DefaultBrowserOpenAction` backs both entry points. The terminal right-click path and the browser toolbar path keep their own eligibility rules and their own failure recovery — the terminal closes its menu silently, the browser keeps its existing alert and Copy Link — but they hand macOS the URL through the same injected action, so a test can substitute it and neither path can drift into opening links a different way (#cm-46)
- 2026-08-24 - fix (test) (#cm-46) | **the committed-vs-draft rule has no automated test, and that is now proven rather than assumed.** A test was written for it and removed after mutation showed it could not fail. `openCurrentPageInDefaultBrowser()` takes no URL; the omnibar's draft lives in view-local `OmnibarState.buffer` and never reaches `BrowserPanel`, so the guarantee is structural — enforced by the method signature. The mutation was complete, not a token one: a stored draft on the panel *plus* the view feeding it `omnibarState.buffer`, which is the whole regression and sits one line from being real (`omnibarState` at `BrowserPanelView.swift:265`, the handler at `:599`). The suite stayed green. **The behavior now rests entirely on a human check** — Scenario 8's draft step — recorded as such in the brief. A first mutation attempt went red on `extensions must not contain stored properties` and was discarded; a red from a build break is not a result, and it is the flattering direction to be wrong in (#cm-46)

---

# 🔵⋯ v0.15.3 (2026-08-12) — #cm-44
## 🟠⋯ Changed for End Users
- 2026-08-12 - fix | **a tab lands where you drop it.** Dragging a tab onto another tab in the same pane used to accept the drag and then ignore where it ended — the tab went to the end of the bar, every time, so reordering was impossible. The tab bar's full-width click surface was also registering itself as a drop target across the whole bar, and it answered every drop with "put it at the end", shadowing the per-tab targets that knew better (#cm-44)
- 2026-08-12 - fix | **a pane showing a single tab accepts drops on its header again.** When a pane has one tab, cmux draws it as a centred caption rather than a tab strip — and that is every freshly split pane. Removing the full-width drop target above took that layout's *only* coverage with it, leaving roughly 90% of a wide header dead: a tab dropped beside the label sprang back, and a folder dropped there no longer opened as a tab. Both sides of the caption now take drops, and dropping onto the label still works (#cm-44)
- **Known limitation — a narrow band of the tab bar still refuses drops.** With the full-width target gone, an 84pt strip just past the tabs takes no drop in the normal multi-tab layout. Measured, not reported by anyone, and it did not exist before this release. Not yet fixed because nobody has hit it in use (#cm-44)

## 🟠⋯ Changed for Developers
- 2026-08-12 - fix (test) (#cm-44) | **the drop suite could not detect its own defect returning.** Restoring the removed `.onDrop` left the filtered set 6/6 green, so the "6/6" recorded as this fix's evidence proved nothing. Upstream's discriminating assertion was sitting commented out in the file — disabled because the fork's own code violated it — with its `chromeDragZones` helper dead alongside. Restored live, probing the tab's **midpoint** rather than the last owned x: the tail of the owned run is `horizontalSlop`, where the registry claims pixels the SwiftUI layer treats as chrome, so the tail cannot satisfy both this assertion and the hit-capture one. New `testCaptionEmptyChromeAcceptsTabDrops` covers the caption layout nothing had ever constructed, and carries a setup guard that fails loudly when `presentation` does not reach the view — a stored default of `.tabs` had silently defeated two earlier measurements of the same defect (#cm-44)
- 2026-08-12 - fix (technical) (#cm-44) | one rule, two owners, still. The AppKit hit region and the SwiftUI drop layer each derive "where empty chrome begins" independently, and they disagree by 9.5pt — the click-forgiveness slop. Benign today, and the same shape that produced this release's drop bug. Both would collapse if the drop bounds were derived from `TabBarEmptyChromeHitRegion`, which is the route not taken here (#cm-44)

---

# 🔵⋯ v0.15.2 (2026-08-12) — #cm-45
## 🟠⋯ Changed for End Users
- 2026-08-12 - fix | **dragging a tab to tidy the order no longer starts an agent you were not running.** Reordering a tab selects it, which is intended and matches every browser. What came with it was not: selecting a tab resumes a hibernated agent in it, and a hibernated tab is one whose agent has already exited — so a drag meant to rearrange your tabs was silently launching a session and billing a fresh context from cold. Selection still happens; the resume no longer does. Only affects you if you have turned Agent Hibernation on, which is off by default (#cm-45)
- 2026-08-12 - feat (technical) | the tab context menu now refreshes fork-conversation availability while it is open, so a menu no longer remains stuck on the answer it had when it was first opened (#cm-45)
- **Known limitation — the live refresh race remains difficult to reproduce deliberately.** The wiring is covered and the implementation is always on, but the open-menu re-evaluation was not observed in dogfood; the feature ships on traced source behavior rather than that observation (#cm-45)
- **Known limitation — the drag-reorder resume fix ships unverified by hand.** The mechanism was traced link by link in the source and the change compiles clean, but no one has watched it work, and the scenario first designed to check it turned out to be unreachable: a *running* agent is never a hibernation candidate. If the suppression misses, the behaviour is exactly what it was before the fix, so the downside is bounded (#cm-45)

## 🟠⋯ Changed for Developers
- 2026-08-12 - feat (technical) | Bonsplit was caught up from `10563e2f` to `529913b7` across the fork's subtree rather than by moving the upstream gitlink. The port preserves the fork's tab-bar behavior and adds the upstream context-menu presenter and fallback coverage; the Bonsplit package checks passed 6/6 for the focused tab-context and drop-delegate cases, with the full app build clean apart from six environmental diagnostics (#cm-45)
- 2026-08-12 - fix (technical) (#cm-45) | `#cm-44` is a **hard dependency of this port, not optional follow-up.** The port deletes `TabBarManualReorderTrackingView` (269 lines) — the AppKit mouse monitor that computed a drop index from the pointer's real x, and the only thing compensating for the fork's shadowing overlay. At that revision alone, tab reordering does not work at all. Do not cherry-pick or bisect to it without `#cm-44` (#cm-45)
- 2026-08-12 - fix (test) (#cm-45) | `BonsplitTests` has no `pbxproj` entry, so `make test` never reaches any of it. Every guard above runs only under `swift test --package-path Packages/macOS/Bonsplit`, by hand. Second bonsplit change in a row in that state (#cm-45)

---

# 🔵⋯ v0.15.1 (2026-08-05) — #cm-37
## 🟠⋯ Changed for End Users
- 2026-08-05 - fix (ux) | the workspaces **inside a group** carry their `⌘1…9` numbers again. v0.14.0 took every grouped workspace out of the numbering, and if your sidebar is mostly or entirely groups that left you with **no numbered workspaces at all** — no badges when you hold `⌘`, and `⌘1…9` doing nothing, silently. Members of an expanded group are now numbered like any other row. Two rows still carry no digit, both on purpose: a **group header**, because that row names a group rather than a workspace (`#cm-29` gives groups their own `⌘⇧1…9`), and the members of a **collapsed** group, because they have no row on screen to press a digit for — collapse a group and its members' digits are released to the rows below, expand it and they come back (#cm-37)
- **Retires v0.14.0's "a grouped workspace has no number until the next slice" limitation.** That was not a limitation; it was a defect. The reasoning behind it — a collapsed group hides its members, so their digits would fire at rows you cannot see — is sound for *collapsed* groups and was generalized to all groups without checking the expanded case (#cm-37)
- **Known limitation — a run of rows in the middle can still show no digit.** `⌘9` keeps its jump-to-the-end idiom, so with more than nine workspaces in play the digits land on the first eight and the last, and the rows between carry none. Unchanged since v0.14.0, but far more visible now that group members count — slice `cm-37.2` tracks it (#cm-37)
- **Known limitation — collapse every group and the digits go dead again.** With nothing left that has a row of its own, there is nothing to number. Correct by the rule, and narrow enough to accept — but it is the same shape as the case v0.14.0 accepted and got wrong, so it is written down rather than assumed harmless (#cm-37)

## 🟠⋯ Changed for Developers
- 2026-08-05 - fix (technical) (#cm-37) | the `⌘1…9` eligibility rule now names what it means instead of approximating it. `#cm-28` spelled the rule *"in play and **ungrouped**"*, where `ungrouped` was a proxy for the governing constraint *a digit is visible if and only if it works*. `WorkspaceShortcutEligibility.Candidate` swaps `isGrouped` for `isGroupAnchor` + `isInCollapsedGroup` — the two rows `SidebarWorkspaceRenderItem.renderItems` actually suppresses — and both are derived through the same `groupsById` lookup that function uses, so a workspace with a dangling `groupId` (which `renderItems` draws as an ordinary row) stays numbered rather than becoming a visible row with no digit. The live bridge takes `groups:` because neither fact lives on `Workspace`: `anchorWorkspaceId` and `isCollapsed` are `WorkspaceGroup` fields, and reaching for `groupId != nil` because it was the only fact in scope is how the proxy got chosen in the first place. `TabManager.workspaceShortcutEligibility` remains the single live construction site, so all six call sites are untouched and badge and key still cannot answer to different rules (#cm-37)
- 2026-08-05 - fix (test) (#cm-37) | five tests asserted the superseded rule and one of them called it *"an accepted limitation … not a defect"* in its own doc comment, so the suite certified a feature that did nothing for its only user and passed every run. All five migrated. **Also found: `#cm-28`'s recorded green cited three `-only-testing:` filters, and one of them — `cmuxTests/WorkspaceShortcutMapperTests` — names a class that does not exist**, so it contributed zero tests and reported success anyway. The mapper's tests live inside the two eligibility classes. A filter that matches nothing is indistinguishable from a filter that passes (#cm-37)


---

# 🔵⋯ v0.15.0 (2026-08-04) — #cm-30
## 🟠⋯ Changed for End Users
- 2026-08-04 - fix | a restored Claude session comes back on the model and reasoning effort you were last using, instead of the ones the pane was originally launched with — because Claude Code restores them itself, and cmux no longer overrides it. Switching model or effort mid-session used to be silently undone by any cmux restart, and because the restored session then ran on a *different* model, the whole conversation was re-sent as fresh input rather than reused from cache: you paid to rebuild context you already had, on a model you did not pick. Nothing to turn on. Sessions launched with explicit `--model`/`--effort` still start on those; only the replay on resume is gone (#cm-30)
- **Known limitation — Claude only.** codex, gemini, cursor, amp, opencode, kimi and grok are deliberately unchanged: whether each restores its own model on resume is an empirical fact about that tool, and only Claude has been tested. `#cm-33` tracks codex (#cm-30)
- **Known limitation — the Sessions panel still names a model.** Resuming from the sidebar's Sessions list builds its command a different way, reading the last-known model from the session transcript rather than letting Claude restore it. That path does not have the bug this fixes — it reads the *current* model, not the launch-time one — but it means cmux has two answers to "how do we resume Claude". `#cm-33` reconciles them (#cm-30)

## 🟠⋯ Changed for Developers
- 2026-08-04 - fix (technical) (#cm-36) | `CMUX_DISABLE_AUTOMATIC_PACKAGE_RESOLUTION=0` no longer crashes `make test`. `rbf/scripts/dev.sh:197` built an array and expanded it as `"${resolve_args[@]}"`; under `set -u` on macOS's stock bash 3.2 an **empty** array expansion is an unbound-variable error, so the documented toggle had exactly one working position — its default. Turning it off died with `dev.sh: line 200: resolve_args[@]: unbound variable` before `xcodebuild` ever ran. Now `${resolve_args[@]+"${resolve_args[@]}"}`. Found the hard way during `#cm-30`: a fresh worktree had cached an SPM resolution with no GhosttyKit artifact, turning the flag off was the obvious recovery, and it crashed instead — sending the investigation after the wrong cause (#cm-36)
- 2026-08-04 - fix (#cm-30) | `--model` and `--effort` are dropped from **all four** places cmux authors a Claude resume command: `AgentResumeArgv.claudeResumeArgv`, `AgentForkArgv.builtInKind`, and both `claudeTeams` launcher resolutions — the last two resolve *before* `builtInKind`, so fixing only the built-in path would have left every `cmux claude-teams` pane broken with nothing reporting it. The shared `claudePolicy` is deliberately untouched: `AgentLaunchSanitizer.sanitizedLaunchArguments` has **six** production callers and at least one starts a *fresh* session (`TerminalForegroundCommandCapture` save-layout replay), where dropping `--model` would discard a model the user explicitly asked for. Seven pre-existing tests across four files carried `--model opus` as fixture data and were updated; two were **strengthened** rather than trimmed, gaining a trailing `--add-dir /tmp` so they still prove options after a one-word prompt survive. Mutation testing removed a dead guard from the new helper — a trailing-option ternary no test could discriminate, because both step sizes exit the loop identically (#cm-30)


---

# 🔵⋯ v0.14.0 (2026-08-04) — #cm-28
## 🟠⋯ Changed for End Users
- 2026-08-04 - feat (ux) | `⌘1…9` now numbers only the workspaces you are actually working in. The digits used to count every row in the sidebar, so a workspace you had parked or finished sat between the ones in play and took a number with it. They now range over the workspaces carrying an **Accent Strip** — in play and ungrouped — and the rows below a parked one move **up** rather than leaving a gap. Press `⌘3` and you land on the third workspace in play, not the third row. Hold `⌘` to see it: a badge appears only where a digit actually works. `⌘9` keeps its jump-to-the-end idiom, now landing on the last workspace in play, and the View menu's nine "Workspace N" items follow the same numbering. The badge and the key renumber together by construction rather than by being kept in sync, so a badge cannot claim a digit that goes somewhere else (#cm-28)
- **Known limitation — a grouped workspace has no number until the next slice.** Grouped workspaces leave the numbering entirely, which **removes keyboard reach you have today**. It is deliberate: a collapsed group hides its members, so those digits were already firing at rows you could not see. `#cm-29` gives groups their own namespace (`⌘⇧1…9`) and hands the reach back (#cm-28)
- **Known limitation — a number can change under you.** The lane is inferred from live git and pull-request state, so `⌘3` can retarget without you doing anything. That is the accepted cost of renumbering; the alternative was a badge that hides while its key still fires, which is the worse lie (#cm-28)
- **Known limitation — VoiceOver cannot reach the digit.** The number lives only in the visual hint pill. Before this change it happened to coincide with the row's "workspace N of M" announcement for the first eight rows; now it does not, and there is no accessible way to learn which digit selects a row (#cm-28)
- **Known limitation — with the workspace todo feature off, this does nothing, silently.** No lane is read, so every workspace stays eligible and the numbering is exactly what it was. Turn it on at Settings → Beta Features → **Workspace Todo Controls** (#cm-28)

## 🟠⋯ Changed for Developers
- 2026-08-04 - refactor (#cm-28) | the "is this workspace in play" lane now has exactly one definition, `Workspace.attentionTaskStatus(todoControlsEnabled:)`, read by both the Accent Strip and the `⌘1…9` numbering — so "striped" and "numbered" cannot drift apart. It took three homes to get there: an inline copy inside the shortcut eligibility (which a cold review found could drift from the sidebar factory with every test still green), then the row *palette* — a type that resolves colours from an immutable snapshot and never called it — and finally beside the `effectiveTaskStatus` it wraps. Guarded from both sides: breaking the one definition now reddens the numbering tests **and** `#cm-22`'s factory test. The digit arithmetic that used to be public as `workspaceIndex(forDigit:workspaceCount:)` is `private` and renamed to say it speaks eligible positions — the old name accepted `tabs.count` happily and would have silently reinstated the pre-`#cm-28` numbering, which is the shape an upstream merge would have brought back. `taskStatusSignals(orderedPanelIds:)` takes the panel order once instead of rebuilding the bonsplit tree snapshot twice per sample (#cm-28)
- 2026-08-04 - refactor | the installer's swap helper reads cleanly for the next person, and the one part v0.13.0 shipped untested now has tests — a post-release engineering-discernment pass (no behaviour change). The parent's detached-launch block moved out of `install-rbf.sh` into `rbf_swap_launch_detached`, which is both testable and where the fork's "a guard inside one entrypoint cannot be inherited by a second" rule wants it; it now covers immediate/late/never claims plus a real daemon asserted to outlive its spawner **and run in its own process group**. That last assertion is load-bearing: without it, removing the double-fork entirely left the suite green. Suite 23 → 28 tests. **Supersedes v0.13.0's known limitation** that the launch block had no unit test (#cm-27)


---

# 🔵⋯ v0.13.0 (2026-08-04) — #cm-27
## 🟠⋯ Changed for End Users
- 2026-08-04 - feat | install a new build of cmux RBF from inside cmux RBF — `make install-rbf` no longer refuses when the terminal it runs in is hosted by the app it is replacing. The old refusal was right about the 2-second swap and wrong about the ~10-minute build it also blocked; the installer now builds where you are, then hands the quit→swap→relaunch tail to a small detached helper that outlives the app's death. It prints what will happen before your terminal goes away, quits cmux RBF — **ending every shell and agent the app hosts, not just the install shell** — swaps the bundle with the same parked-rollback safety as before, relaunches the new build, and confirms by macOS notification. The full transcript lands in `~/Library/Logs/cmux-rbf/install.log`. Run from Terminal.app or upstream cmux, nothing changes: same live output, same messages, plus one plan line naming which route the swap will take (#cm-27)
- 2026-08-04 - feat | an install that cannot quit the app never costs you your workspaces — if cmux RBF is holding a dialog when the detached helper tries to quit it, a notification at ~10 seconds asks you to dismiss it; if the app still has not quit after 60 seconds, the install aborts cleanly — existing install untouched, staging removed, failure logged and notified. It never force-quits, in either mode, because killing a cmux that is asking about unsaved state discards exactly the workspaces this installer exists to preserve (#cm-27)

## 🟠⋯ Changed for Developers
- 2026-08-04 - refactor | the install tail (quit → swap → migrate → report) moved from `install-rbf.sh` into `rbf/scripts/lib/rbf-swap.sh`, seam-structured like `rbf-install-target.sh`, with a 23-test suite (`rbf-swap.test.sh`) covering routing, the argument contract, stuck-quit in both modes, rollback and double-failure, and cleanup ownership — paths unreachable from the real entry point, which takes no target flag by design. Staging cleanup ownership is an **atomic `mkdir` election** (`.rbf-swap-claimed`): the helper claims, a timed-out parent reclaims, exactly one side ever wins, and the parent's EXIT trap defers to an existing claim — closing a two-owner window a cold review found in the first marker-file design. Verified by mutation testing: 8/8 deliberate breaks caught (#cm-27)

## 🟠⋯ Known Limitations
- **The log cannot tell you which quit path fired.** The first real self-hosted install quit gracefully in seconds — so `osascript … to quit` does work from a detached, terminal-less helper on this machine — but the transcript records only that the app quit, not whether the polite request or the SIGTERM fallback did it. The discriminator today is elapsed time: a fallback run waits the full 60 seconds first. On a machine that declines the Automation grant the install still completes; the app simply skips its save path (#cm-27)
- **Notifications are best-effort.** The helper posts via `osascript`, whose banners Notification Center can suppress by settings. Delivery is confirmed on this machine — both by probe and on the first real install — but it is not guaranteed on another; the durable outcome record is the log, and the handoff notice names it before the terminal dies (#cm-27)
- **The parent's launch block — the daemonizer, the claim wait, the reclaim branch — has no unit test.** Everything behind the handoff boundary is suite-covered; the handoff itself is proven by probes (parent-exit and SIGHUP survival) and by the real self-hosted install, not by `rbf-swap.test.sh` (#cm-27)
- **The routing signal is the hosting bundle id, not the installed app.** A copy of the bundle run from anywhere sets it — including a hand-recovered `previous.app`, in which narrow case a detached run could execute first-install migration. And a tmux session begun inside cmux RBF keeps the id when attached from Terminal.app, so such a run routes detached even though that terminal would have survived: safe, but output goes to the log and the app still quits (#cm-27)
- **`install.log` grows by append forever.** Each run opens with a delimited header (timestamp, version, commit), so it stays greppable; nothing rotates it (#cm-27)

---

# 🔵⋯ v0.12.0 (2026-08-03) — #cm-22
## 🟠⋯ Changed for End Users
- 2026-08-03 - feat (ux) | let the workspaces that are not in play stop competing for your attention — a workspace row that carries a colour no longer draws its leading identity strip while its status lane is **Todo** or **Done**. Those are the two ends of the lifecycle: not started, and finished. The three lanes between them — **Working**, **Needs Attention**, **In Review** — mean work is in play, and those rows keep their strip. A parked row keeps its faint same-colour wash, so it still reads as belonging to a colour; it just stops using the sidebar's loudest element to say so. **Your colour assignment is never touched**, so nothing has to be restored (#cm-22)
- 2026-08-03 - feat (ux) | see a strip come back the moment work starts, without doing anything — the lane is tracked live, so the strip returns when an agent starts, the git tree goes dirty, a PR opens, or you set a lane by hand. Verified end to end: editing a file on disk in a workspace's directory makes its strip appear on its own, with cmux never touched (#cm-22)
- 2026-08-03 - feat (ux) | a workspace you have explicitly parked stays quiet — setting a workspace's status to **Todo** by hand suppresses its strip even while an agent runs in it. An explicit *"this is parked"* outranks what cmux can infer, which is the whole point of setting it (#cm-22)

## 🟠⋯ Changed for Developers
- 2026-08-03 - refactor | the `.done` row's content dimming is named once as `doneRowContentAlpha` instead of sitting as a bare `0.6` in both the AppKit and SwiftUI row renderers — the same duplication v0.10.0 closed for the accent strip's opacity and left open here. No behaviour change (#cm-22)

## 🟠⋯ Known Limitations
- **This is off unless the workspace todo feature is on**, and that defaults to off: Settings → Beta Features → **Workspace Todo Controls**. With it off, every row draws exactly as before and this change does nothing (#cm-22)
- **In dark appearance a parked coloured row is hard to tell from an uncoloured one.** The wash that survives suppression is drawn at a single weight for both appearances, and its visible difference is that weight times the gap between your workspace colour and the sidebar's own background. A light sidebar is far from most workspace colours; a dark one is close to them — measured, the same 5% wash yields about **3.5× less separation in dark**. So the identity that survives parking in light mostly does not survive it in dark. **This slice did not change that weight** — it made the wash the *only* carrier on a parked row, which is what exposed it. Tracked as its own fix (#cm-22)
- **An absent strip has three causes you cannot tell apart by looking** — the workspace is parked or finished, its status is hidden, or it has no colour assigned. If most of your workspaces are parked, the sidebar shows almost no strips at all, which looks the same as the feature being broken (#cm-22)
- **Colour stops being a navigation aid for work that is not in play.** A parked row still reads as coloured — checked against six colours, and each stayed distinguishable from an uncoloured row in light appearance — but two workspace colours that are genuinely close have not been checked while both are parked, and the strip was what separated them before. That is the feature working rather than failing, since a parked workspace is not asking to be identified at a glance (#cm-22)
- **Renaming a parked workspace briefly brings its strip back** for the duration of the inline edit. The editing state is resolved before the parked state, and you are interacting with that row anyway (#cm-22)
- **The sibling `.done` dimming is gated differently from the suppression.** Both now respond to a Done workspace, but suppression ignores whether you asked to *see* a status badge and the dimming does not — and that gate defaults to hiding status. So a Done workspace reliably loses its strip while its title usually will not dim (#cm-22)
- **Not checked before shipping, stated rather than omitted:** whether the sidebar stays usable for navigation over a working session; whether an absent strip causes real hesitation in practice; and how any of this behaves under Increase Contrast, Reduce Transparency or VoiceOver (#cm-22)

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
