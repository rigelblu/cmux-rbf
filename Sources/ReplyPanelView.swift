import AppKit
import Bonsplit
import CmuxAgentChat
import CmuxAppKitSupportUI
import CmuxSettings
import Combine
import SwiftUI

/// The right sidebar's Reply mode: the bound agent's newest reply, rendered.
///
/// Header pinned, body scrolling under it. The counter is the only thing
/// that says which of N replies is on screen, so a header that scrolled
/// away would take it exactly when a long reply makes it most needed.
struct ReplyPanelView: View {
    let workspace: Workspace?
    let windowAppearance: WindowAppearanceSnapshot
    /// `#cm-89` — a reply started by `⌘⇧`-dragging in this window's terminal.
    var terminalReplyRequest: TerminalReplyRequest? = nil
    /// Called with the request's `seq` once it is taken, so its owner clears it.
    var onTerminalReplyConsumed: (Int) -> Void = { _ in }

    /// The window's store, handed in — `#cm-90`. This view is rebuilt on every
    /// sidebar mode switch, so a store it owned took the unsent marks, notes
    /// and typed preview text with it.
    let store: ReplyPanelStore
    @State private var rendererSession = MarkdownRendererSession()

    /// The row whose note is open for writing, if any.
    ///
    /// Writing and editing are one surface: the list stays the list and one
    /// row becomes a field, so nothing opens and nothing moves and the other
    /// notes stay readable.
    @State private var editingID: UUID?

    /// Text in the open field, written through to the annotation as it is
    /// typed.
    ///
    /// Live rather than committed on Enter or blur. A deferred commit has to
    /// answer "which row does this text belong to" at the moment the field
    /// goes away, and the answer is wrong exactly when the user clicks
    /// straight from one row to another — the outgoing text lands on the
    /// incoming note. Writing through leaves no such moment.
    @State private var editingText: String = ""

    /// What the note said when the field opened, for Escape to restore.
    ///
    /// Escape is the only path that discards text, so it is the only thing
    /// that needs the old value.
    @State private var editingOriginal: String = ""

    /// Drives the caret into the field the moment a row opens.
    ///
    /// Without it a mark appears, its field appears, and typing goes
    /// nowhere: the sidebar's focus host swallows every key carrying
    /// characters (`RightSidebarPanelView.swift:527`) unless something
    /// inside it is first responder. Found in dogfood — every note stayed
    /// empty, so nothing was deliverable and both buttons stayed off.
    ///
    /// **On its own it is not enough, which is the second half of that same
    /// defect.** `@FocusState` moves focus *within* SwiftUI's focus system;
    /// it cannot take first responder from an AppKit terminal surface. Set
    /// alone it changed nothing visible and the caret stayed in the agent.
    /// `focusNoteField` is the pair: move the window's first responder into
    /// the sidebar first, then place the caret.
    @FocusState private var noteFieldFocused: Bool

    /// The note an ↑/↓ step opened, until something else opens one — `#cm-82`.
    ///
    /// **Keyed on the row, not consumed once.** A step that changes the
    /// list's height across its ceiling flips `ReplyAnnotationManifest`'s
    /// `ScrollView` branch, which rebuilds every row — so the stepped-to field
    /// appears a *second* time, after a one-shot flag would already be spent.
    /// That second appearance would take the cold path: the AppKit hop, and
    /// the select-all a focused field applies (cold review, 2026-09-10).
    ///
    /// **It keys on what caused the change, not on who holds focus.** A step
    /// tears down one row's field and builds the next, and by the time the
    /// new field's `.onAppear` runs the old field editor is detached and
    /// AppKit has restored nothing. A "focus is already in the sidebar" check
    /// there reads false and runs the AppKit hop — which makes the reply's web
    /// view first responder for a runloop turn and drops a key typed straight
    /// after the step.
    @State private var stepArrivalID: UUID?

    /// The open note whose field has already appeared once — `cm-69.3`.
    ///
    /// A second `.onAppear` for the same note is a **rebuild**, not an open:
    /// a chip or plain typing wrapped the field past the list's ceiling, and
    /// `ReplyAnnotationManifest` swapped in its `ScrollView`, rebuilding every
    /// row. The cold path there — the AppKit hop, then the select-all a
    /// focused field applies — would make the next keystroke replace the
    /// note. A rebuild restores ``lastNoteCaret`` instead. Generalises what
    /// ``stepArrivalID`` does for steps; cleared wherever a note opens or
    /// closes, so every first appearance keeps its existing path.
    @State private var fieldAppearedForID: UUID?

    /// Where the open note's caret last was — recorded on every text **and**
    /// selection change, never at one moment, so it cannot go stale.
    ///
    /// A chip click takes the keyboard before its action runs: SwiftUI moves
    /// focus to the panel's focusable root on mouse-down (measured, Tom's
    /// dogfood 2026-09-11: `fr=KeyViewProxy` at the click). So a label is
    /// inserted here, not at wherever the caret is by then (`cm-69.3` 3.1).
    @State private var lastNoteCaret: NSRange?

    /// `reply.labels`, kept live: Settings and `cmux.json` both write
    /// `UserDefaults`, and the chips follow without a relaunch.
    @State private var quickLabels: [String] = ReplyCatalogSection.defaultLabels
    /// `#cm-83.3` — holds the zero-size AppKit view the label menu anchors to.
    @State private var labelMenuAnchorBox = ReplyMenuAnchorBox()

    /// The note a keyboard step last asked both surfaces to bring into view.
    @State private var revealRequest: ReplyRevealRequest?
    @State private var revealSeq = 0

    /// `#cm-89` — why a terminal request highlighted nothing. While set it
    /// stands in for the header title: the paste notice's slot beside the
    /// name truncates and times out, and a reason has to stay readable until
    /// the user acts.
    @State private var terminalNotice: TerminalReplyNotice?
    /// `#cm-89` — the page search for a terminal request, once per `seq`.
    @State private var terminalFind: MarkdownPageFind?
    @State private var terminalFindSeq = 0
    /// The last request taken. Clearing the request is a round trip through
    /// `FileExplorerState`, and two triggers can fire inside it — dogfood
    /// 2026-09-13 logged `consume seq=1` twice, 22 ms apart, two finds.
    @State private var consumedTerminalReplySeq: Int?

    /// The mark the pointer is over, from either half.
    ///
    /// Hovering the phrase or its footer row colours **both**, which is what
    /// says the two are one thing.
    @State private var hoveredID: UUID?

    /// The paste preview's editable text, or `nil` while it is collapsed.
    @State private var previewText: String?

    /// Whether the preview has been typed in.
    ///
    /// Once it has, `Collapse` becomes `Discard edits` — honest about what
    /// returning costs, since nothing ever parses the text back.
    @State private var previewIsEdited = false

    /// Whether the "copied" confirmation is showing.
    ///
    /// **The clipboard write is the one effect with no evidence.** `Paste`
    /// types into the terminal *and* copies, because Claude Code collapses a
    /// long paste to `[Pasted text #1 +4 lines]` and the composer stops being
    /// readable. The copy is what makes that recoverable — and it is
    /// completely invisible, so nobody knows to reach for it (Tom's
    /// suggestion, dogfood 2026-09-06).
    @State private var showCopiedNote = false

    /// Dismisses the confirmation, cancellable so a second `Paste` restarts
    /// the clock instead of inheriting the first one's remaining time.
    @State private var copiedNoteDismissal: Task<Void, Never>?

    /// The panel's own height, for the footer's ceiling.
    @State private var panelHeight: CGFloat = 0

    /// How tall the note rows actually are, so the list can size to its
    /// content and stop at the ceiling.
    @State private var noteListHeight: CGFloat = 0

    /// Width floor for the position counter, wide enough for `10/15` so the
    /// arrows stop moving once a session runs past nine messages.
    private static let counterMinimumWidth: CGFloat = 34

    /// The panel's inner gutter, shared by the header and the rendered page.
    private static let bodyGutter: Double = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let previewText {
                // The preview is a *mode*, not a footer state: the reply is
                // not on screen at all, so the footer's ceiling and the
                // reply's floor have nothing left to govern.
                header
                Divider()
                pastePreview(previewText)
            } else {
                header
                Divider()
                if atOldestLoadedReply, store.model.historyTruncatedAtHead {
                    truncatedHistoryNote
                }
                content
                if !draft.annotations.isEmpty {
                    footerRule
                    annotationFooter
                }
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear.onAppear { panelHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { panelHeight = $0 }
            }
        )
        // The preview's whole claim is "exactly what Paste will send", and it
        // is written once, from the reply that was on screen when it opened.
        // The nav arrows and the arrow keys both stay live in preview mode,
        // and `draft` resolves through `viewedGroup` — so a single step left
        // the box showing one reply's manifest while Paste sent another's.
        //
        // Closing on the *outcome* rather than guarding each way to step:
        // buttons, keys, and a newer reply arriving while following all move
        // the viewed reply, and enumerating them is how one gets missed.
        // `viewedGroup?.id`, not `viewedGroupID` — the latter is nil while
        // following the newest, so newest → older → newest would not fire.
        // `#cm-90`: closing is still right, but what was *typed* into the
        // box belongs to its reply, so arriving on a reply that holds some
        // reopens it rather than leaving the text stranded.
        .onChange(of: store.model.viewedGroup?.id) { _ in restoreTypedPreview() }
        // A sidebar mode switch rebuilds this view with `previewText` at nil,
        // and a one-argument `onChange` never fires on first appearance — so
        // the reopen has to run here too, or Files → Reply loses the box.
        // Only when the box is closed: `onAppear` can also fire on a view that
        // was not rebuilt, and an open, untyped preview holds nothing to restore.
        // Accepted: after Files → another workspace → Reply, this can reopen the
        // previous workspace's box for the moment before `.task(id:)` rebinds;
        // the rebind changes `viewedGroup` and the handler above closes it.
        .onAppear { if previewText == nil { restoreTypedPreview() } }
        // `#cm-89`: a step is acting in the panel, so the notice gives the
        // title back. `viewedGroupID`, not `viewedGroup?.id` — the latter also
        // moves when the newest reply grows while following it, which wiped
        // the not-found line ~100 ms after it appeared (Tom, dogfood
        // 2026-09-13). `viewedGroupID` stays `nil` while following.
        .onChange(of: store.model.viewedGroupID) { _ in
            clearTerminalNotice(reason: "step")
        }
        .task(id: bindingKey) {
            await store.refresh(workspace: workspace)
        }
        // `#cm-89`. Five triggers — appear, request, bind, session, newest — because
        // the request can arrive before the panel can answer it: the view may
        // be mounting cold, the store still binding, or the transcript still
        // loading.
        .onAppear { consumeTerminalReplyIfReady(trigger: "appear") }
        // The new value is passed in, never re-read: dogfood 2026-09-13
        // logged this path consuming seq 1 while the sidebar already held
        // seq 4, and seq 4 was never taken.
        .onChange(of: terminalReplyRequest) { request in
            consumeTerminalReplyIfReady(request, trigger: "request")
        }
        .onChange(of: store.model.newestGroup?.id) { _ in consumeTerminalReplyIfReady(trigger: "newest") }
        .onChange(of: store.model.sessionID) { _ in
            // A new agent in the *same* pane keeps `boundPanelID`, so the
            // pane-change clear below never fires for it — the old line and a
            // find still running would carry over to the new agent (brief
            // cold read 2026-09-13).
            clearTerminalNotice(reason: "session")
            terminalFind = nil
            consumeTerminalReplyIfReady(trigger: "session")
        }
        .onChange(of: store.boundPanelID) { _ in
            // Following another agent: whatever the notice said was about the
            // old one, and a find still running would answer for it too.
            clearTerminalNotice(reason: "bind")
            terminalFind = nil
            consumeTerminalReplyIfReady(trigger: "bind")
        }
        .onChange(of: store.model.isNewestTurnWriting) { writing in
            // `Still writing` would be false within seconds of the turn ending.
            if !writing, terminalNotice == .writing { clearTerminalNotice(reason: "turnEnded") }
        }
        .onAppear { refreshQuickLabels() }
        // `UserDefaults` posts this on whichever thread wrote, and for every
        // key; hop to main, and assign only on a real change so an unrelated
        // write never re-renders the panel.
        .onReceive(
            NotificationCenter.default
                .publisher(for: UserDefaults.didChangeNotification)
                .receive(on: DispatchQueue.main)
        ) { _ in refreshQuickLabels() }
        // Every caret move in the open note, so a label can land where the
        // caret was even after a click has taken the keyboard. The
        // notification fires for every text view in the app; only the
        // field editor serving this panel's focused note field counts.
        .onReceive(
            NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)
        ) { notification in
            guard noteFieldFocused, editingID != nil,
                  let editor = notification.object as? NSTextView, editor.isFieldEditor,
                  editor === NSApp.keyWindow?.firstResponder else { return }
            lastNoteCaret = editor.selectedRange()
        }
        .focusable()
        // Arrow keys drive the same two actions the buttons do. `cm-69.1` has
        // no text field to compete with; once notes exist, an editing field
        // takes the keys first.
        // Never while a note field has the keyboard, even with its caret at
        // an edge: a text field ignores ← at its start and → at its end, the
        // key bubbles up here, and stepping the reply then closes the note
        // mid-sentence (Tom, dogfood 2026-09-11).
        // `#cm-83.1`: Tab from the reply body opens a note, so the keyboard
        // can reach the list without a click. Measured before it was written —
        // Tab arrives here with the body focused (`fr=MarkdownWebView`), so
        // this handler is enough and `MarkdownWebView` needs no opt-in hook
        // the way Escape did (`#cm-76`).
        //
        // Never while a note field has the keyboard: there Tab is `cm-69.3`'s
        // step between notes, and this must not shadow it.
        .backport.onKeyPress(.tab) { modifiers in
            enterNoteList(backwards: modifiers.contains(.shift))
        }
        // ⇧Tab can arrive as backtab (U+0019) rather than shift + tab, the
        // same way it does inside the note field.
        .backport.onKeyPress(KeyEquivalent("\u{19}")) { _ in
            enterNoteList(backwards: true)
        }
        .backport.onKeyPress(.leftArrow) { modifiers in
            guard Self.isUnmodifiedStep(modifiers), canStepBack,
                  !ReplyNoteCaret.fieldEditorIsKey else { return .ignored }
            Task { await store.stepBack() }
            return .handled
        }
        .backport.onKeyPress(.rightArrow) { modifiers in
            guard Self.isUnmodifiedStep(modifiers), canStepForward,
                  !ReplyNoteCaret.fieldEditorIsKey else { return .ignored }
            store.stepForward()
            return .handled
        }
    }

    /// Opens a note from the reply body — `#cm-83.1`.
    ///
    /// Returns `.ignored` for every case it does not own, so the key falls
    /// through to AppKit's normal focus move rather than being swallowed: no
    /// annotations, or the keyboard already inside a note field.
    ///
    /// The caret is placed **explicitly**. `beginEditing` ends in
    /// `placeCaretInNoteField()` whose default is `.asFocused` — select-all
    /// (measured `{0, 71}` of 71, see that function's doc) — so an entrance
    /// that left it alone would hand the user a fully selected note and
    /// destroy it on the first keystroke.
    private func enterNoteList(backwards: Bool) -> BackportKeyPressResult {
        let entries = draft.numbered
        let openIndex = editingID.flatMap { id in entries.firstIndex(where: { $0.id == id }) }
        #if DEBUG
        // Every branch logs, so "nothing happened" says WHICH refusal it was.
        // A change like this ships with a probe on the branch it adds, or its
        // failure is indistinguishable from the key never arriving.
        dlog(
            "cm-83.1 tab.entrance back=\(backwards ? 1 : 0) fieldKey=\(ReplyNoteCaret.fieldEditorIsKey ? 1 : 0) "
                + "count=\(entries.count) openIndex=\(openIndex.map(String.init) ?? "nil") "
                + "fr=\(ReplyNoteCaret.firstResponderName)"
        )
        #endif
        guard !ReplyNoteCaret.fieldEditorIsKey else { return .ignored }
        guard let target = ReplyNoteEntrance.target(
            count: entries.count,
            editingIndex: openIndex,
            backwards: backwards
        ) else { return .ignored }
        let entry = entries[target]

        // Re-entering the note that is already open: the keyboard is in this
        // window's sidebar already, so no AppKit hop — and the caret goes back
        // where it was before the click away, when that was recorded.
        if openIndex == target {
            let caret = lastNoteCaret
            placeCaretInNoteField(hop: false, caret: caret.map { .at($0) } ?? .end)
            revealNote(entry.id)
            return .handled
        }

        #if DEBUG
        dlog("cm-83.1 tab.entrance.open target=\(target) id=\(entry.id.uuidString.prefix(5))")
        #endif
        beginEditing(entry)
        placeCaretInNoteField(hop: false, caret: .end)
        revealNote(entry.id)
        return .handled
    }

    /// Whether an arrow press is the bare stroke that steps the reply.
    ///
    /// The two handlers above matched the key and ignored every modifier, so
    /// `⌘←`, `⌥←` and `⇧←` all stepped. `⇧`+arrow is the worst of the three:
    /// it is the extend-selection stroke, in a panel whose whole job is
    /// selecting spans. Nobody saw this until `cm-69.1b` made the handlers
    /// reachable — before that the sidebar host swallowed the keys first.
    ///
    /// Caps lock and the function/numeric-pad bits ride along on stray
    /// hardware and are not somebody pressing a chord, so they are ignored.
    private static func isUnmodifiedStep(_ modifiers: EventModifiers) -> Bool {
        modifiers.subtracting([.capsLock, .numericPad, .function]).isEmpty
    }

    /// Whether the reply on screen is the oldest one that can be loaded.
    ///
    /// **Re-expressed by `cm-69.6`, and leaving it alone would have been a
    /// silent regression.** It read `position.index == 1`, which was the
    /// oldest loaded reply while the counter counted up from the oldest.
    /// Under the inverted counter `index == 1` is the *newest* reply — so the
    /// truncated-history note would have moved to the top of the
    /// conversation and told the user the transcript continues above the
    /// reply that was written five seconds ago.
    ///
    /// Stated against the replies themselves rather than against the number
    /// the header happens to render, so a future re-basing of the counter
    /// cannot move it again.
    /// *Moved into `ReplyPanelModel` on 2026-09-08 so it can be tested.* The
    /// only human check that ever covered it needs a transcript past 2000
    /// lines, which made it the least-run assertion guarding the change most
    /// able to break it.
    private var atOldestLoadedReply: Bool { store.model.isAtOldestLoadedReply }

    /// Says why `◄` stopped.
    ///
    /// A disabled arrow on its own reads as "this is where the conversation
    /// started", which is false: the tailer backfills a bounded window and
    /// the rest of the transcript is still on disk. Shown only at the oldest
    /// loaded reply, so it is never a standing caption.
    private var truncatedHistoryNote: some View {
        Text(
            String(
                localized: "reply.history.truncatedAtHead",
                defaultValue: "This is as far back as the panel reads."
            )
        )
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, Self.bodyGutter)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var canStepBack: Bool {
        guard case let .showing(reading) = store.model.state else { return false }
        return reading.canStepBack
    }

    private var canStepForward: Bool {
        guard case let .showing(reading) = store.model.state else { return false }
        return reading.canStepForward
    }

    /// Everything that can change which agent the panel follows.
    ///
    /// Focus is in here so the sticky binding re-resolves as the user moves
    /// between agent panes. What the header *says* is deliberately not — it
    /// is written by the very refresh this id would trigger, so including it
    /// would make each bind schedule a second, redundant one.
    private var bindingKey: String {
        [
            workspace?.id.uuidString ?? "none",
            workspace?.focusedPanelId?.uuidString ?? "none",
        ].joined(separator: "|")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            if let terminalNotice {
                // In the title's place, so it reads as an explanation rather
                // than a name. Severity is Tom's (dogfood 2026-09-13): a miss
                // is red with an error icon, a selection over two lines is an
                // orange warning, and `Still writing` stays grey — it clears
                // by itself within seconds, and an alarm for that would make
                // the real misses read as routine. The icon carries the
                // meaning too, so it never rests on colour alone. The
                // multi-row and writing lines fit the title's ~148pt with the
                // icon (measured at 11pt); the not-found line is Tom's wording
                // and truncates at the usual sidebar width, by his choice.
                HStack(spacing: 4) {
                    if let symbol = terminalNoticeSymbol(terminalNotice) {
                        Image(systemName: symbol)
                            .font(.system(size: 11))
                            .accessibilityHidden(true)
                    }
                    Text(terminalNoticeText(terminalNotice))
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(terminalNoticeStyle(terminalNotice))
                // The not-found line is longer than the title's room at the
                // sidebar's usual width and truncates (Tom's copy, 2026-09-13),
                // so hovering shows it whole. Set on every notice rather than
                // measured: a tooltip repeating a line that already fits costs
                // nothing, and measuring truncation adds a layout pass here.
                // Shows — Tom hovered it on 2026-09-14 (`#cm-92`, parked as not
                // reproduced after an earlier report that it never did).
                .help(terminalNoticeText(terminalNotice))
            } else {
                Text(store.identity ?? String(localized: "rightSidebar.mode.reply", defaultValue: "Reply"))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if let stateWord {
                Text(stateWord)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }

            copiedNote

            Spacer(minLength: 8)

            if case let .showing(reading) = store.model.state {
                // Hidden while a terminal notice holds the title: shown, it
                // leaves the title 66.3pt and the notice truncates.
                if terminalNotice == nil {
                    capCaption(reading)
                }
                navigation(reading)
                pinButton
            }
        }
        .padding(.horizontal, Self.bodyGutter)
        .frame(height: 26)
    }

    /// `#cm-91` — whether a send hides the right sidebar.
    ///
    /// Sized and styled like the step buttons beside it. One tooltip in both
    /// states, naming what the pin does when on (Tom, 2026-09-14); the icon
    /// shows the state. VoiceOver gets the same label, and the *selected*
    /// trait while pinned, so the state is still announced without a string.
    private var pinButton: some View {
        let label = String(localized: "reply.pin.help", defaultValue: "Keeps the sidebar open after sending")
        return Button { store.isPinned.toggle() } label: {
            Image(systemName: store.isPinned ? "pin.fill" : "pin")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 14, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(store.isPinned ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(store.isPinned ? [.isToggle, .isSelected] : .isToggle)
    }

    /// `◄ 4/6 ►` as one control: two hit targets with the counter as the dead
    /// space between them.
    ///
    /// These step between replies and must never double as paging controls
    /// for a long one — within a reply the user scrolls, between replies the
    /// user presses these. Two motions, two meanings.
    private func navigation(_ reading: ReplyPanelReading) -> some View {
        HStack(spacing: 4) {
            stepButton(
                systemName: "chevron.left",
                label: String(
                    localized: "reply.nav.older",
                    defaultValue: "Older message"
                ),
                enabled: reading.canStepBack
            ) {
                Task { await store.stepBack() }
            }

            positionLabel(reading)

            stepButton(
                systemName: "chevron.right",
                label: String(
                    localized: "reply.nav.newer",
                    defaultValue: "Newer message"
                ),
                enabled: reading.canStepForward
            ) {
                store.stepForward()
            }

            // A visible control, not a hidden one. A number does not read as
            // pressable, and dogfood settled that immediately — the person who
            // had just approved a counter-only design went looking for an icon
            // and could not find the control at all. `chevron.right.2` reads
            // as "further in the same direction" from the arrow beside it.
            //
            // It always occupies its slot at the right edge, and dims on the
            // newest message rather than going away. Three arrangements were
            // built and looked at, in this order:
            //
            //   removed  — reclaims the width for the tab name, but slides
            //              every other control sideways as you navigate, so a
            //              press has to be re-aimed mid-task. A control must
            //              not move under the mouse that is using it.
            //   reserved — invisible but holding its slot. Holds the row still
            //              and shows nothing; pays for it with an open gap at
            //              the right edge whenever you are on the newest.
            //              Built, looked at, rejected: an unexplained hole
            //              beside two live arrows reads as something broken,
            //              which is worse than a control that is plainly off.
            //   dimmed   — always there, tertiary when there is nowhere newer
            //              to go. The row never moves, and the gap never
            //              appears. This is what shipped.
            //
            // Dimming carries its own meaning here: it is the same disabled
            // treatment the two arrows already use at the ends of the range,
            // so all three controls say "off" the same way.
            stepButton(
                systemName: "chevron.right.2",
                label: returnToNewestLabel,
                enabled: reading.canStepForward
            ) {
                store.returnToNewest()
            }
        }
    }

    private func stepButton(
        systemName: String,
        label: String,
        enabled: Bool,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 14, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .foregroundStyle(enabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
        // Same string to the pointer and to VoiceOver. These are three bare
        // chevrons in a 26pt row with no text on them, so what each one does
        // is only ever said here.
        .help(label)
        .accessibilityLabel(label)
    }

    /// The counter — a label, and only a label.
    ///
    /// It was briefly a button too, a hidden second way to reach the newest
    /// message. Cut: a number does not read as pressable, so anyone who found
    /// it would have used the visible control anyway, and making it a button
    /// gave it a *disabled* look at `n/n`, which is nonsense for a label. Its
    /// job is to be read.
    ///
    /// The noun is deliberately *message*, not *reply*: this mode is called
    /// Reply because replying is what you do in it, so using the same word for
    /// the agent's output makes one word mean two things one row apart. The
    /// design settles it — "a message = one `message.id` group of assistant
    /// lines" — and the counter counts exactly those.
    private func positionLabel(_ reading: ReplyPanelReading) -> some View {
        Text(
            String(
                format: String(
                    localized: "reply.nav.positionShort",
                    defaultValue: "%1$d of %2$d"
                ),
                reading.position.index,
                reading.position.total
            )
        )
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
            // A floor, not a fixed size: `1/5` is three characters and `10/15`
            // is five, so without one the arrows slide apart the moment a
            // session passes nine messages. Monospaced digits do not help —
            // the character *count* changes, not the glyph widths.
            .frame(minWidth: Self.counterMinimumWidth)
            .accessibilityLabel(
                String(
                    format: String(
                        localized: "reply.nav.position",
                        defaultValue: "Message %1$d of %2$d"
                    ),
                    reading.position.index,
                    reading.position.total
                )
            )
    }

    /// Why `◄` has stopped, when the cap is the reason.
    ///
    /// **Not decoration, and not optional.** The code beside it already
    /// records that *"a disabled arrow on its own reads as 'this is where the
    /// conversation started', which is false"* — and the cap invents a second
    /// reason for the arrow to stop that looks identical to the first. This
    /// caption is the only thing separating them.
    ///
    /// Shown only at the cap rather than standing permanently: it costs
    /// 69.7pt of a 256pt header, which takes the title from ~148pt to 66.3pt,
    /// and the existing caption in this row follows the same rule.
    ///
    /// **Holds its width while `copiedNote` gives way.** It takes the
    /// `.fixedSize()` that one drops — the persistent element is the one that
    /// must survive the squeeze, and without this the row would truncate the
    /// explanation and keep the toast.
    ///
    /// No accessibility label of its own: the counter beside it carries
    /// `reply.nav.position` ("Message 3 of 5"), which replaces that view's
    /// label rather than appending to it, so VoiceOver reads two elements and
    /// never concatenates them into "showing the last 3 of 5".
    /// **Both clauses of the visibility test earn their place**, and the
    /// second is not redundant with the first:
    ///
    /// - `total < groups.count` catches the ordinary case — the cap stopped
    ///   the walk with reachable replies still loaded behind it.
    /// - `hasMoreHistory` catches the case where the budget and the loaded
    ///   window happen to end together: five loaded, a cap of five, more on
    ///   disk. Then `total == groups.count` and the first clause is false,
    ///   while `◄` is dead and the conversation demonstrably continues.
    ///
    /// Both false means the walk really did reach the start of what exists,
    /// and the arrow greying is then the truth rather than the lie this
    /// caption is here to prevent. The truncated-backfill note above handles
    /// its own case and cannot collide with this one: it is gated on
    /// `historyTruncatedAtHead`, which is only ever set inside
    /// `pageOlderHistory()` — a path the cap suppresses.
    @ViewBuilder
    private func capCaption(_ reading: ReplyPanelReading) -> some View {
        if !reading.canStepBack, store.model.hasMoreHistory || reading.position.total < store.model.groups.count {
            Text(String(
                localized: "reply.nav.showingLast",
                defaultValue: "Showing last"
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
        }
    }

    private var returnToNewestLabel: String {
        String(
            localized: "reply.nav.returnToNewest",
            defaultValue: "Return to newest message"
        )
    }

    /// The one-word state caption, or `nil` when the body already says it.
    ///
    /// A readable reply says "finished" by being readable, so captioning it
    /// would put internal state-machine vocabulary on screen. The four states
    /// that keep a word are the ones with no readable body to speak for them
    /// — which also means the *presence* of a word is itself the non-colour
    /// channel, and state stays legible without relying on tint.
    private var stateWord: String? {
        switch store.model.state {
        case .noAgent:
            return String(localized: "reply.state.noAgent", defaultValue: "no agent")
        case .waiting:
            return String(localized: "reply.state.waiting", defaultValue: "waiting")
        case .unavailable:
            return String(localized: "reply.state.unavailable", defaultValue: "unavailable")
        case .showing:
            // No word for a reply being written, and none for a settled one.
            // Measured in dogfood: Claude flushes a whole content block at a
            // time and its Stop follows within a few hundred milliseconds, so
            // the word only ever appeared for a slow tool call mid-answer —
            // rare enough that its cost was a flicker on every ordinary turn.
            // The `isWriting` fact stays in the model and still gates
            // `cm-69.2`'s annotation; nothing renders it.
            return nil
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        switch store.model.state {
        case .noAgent:
            emptyState(
                title: String(
                    localized: "reply.empty.noAgent.title",
                    defaultValue: "No agent in this workspace"
                ),
                message: String(
                    localized: "reply.empty.noAgent.message",
                    defaultValue: "Start Claude or Codex in a pane and it appears here."
                )
            )
        case .waiting:
            emptyState(
                title: String(
                    localized: "reply.empty.waiting.title",
                    defaultValue: "Waiting for the first reply"
                ),
                // Naming the agent is the whole content of this state: it
                // says the binding worked and the silence is the agent's,
                // not cmux's. The unbound screen deliberately names nothing.
                message: String(
                    format: String(
                        localized: "reply.empty.waiting.message",
                        defaultValue: "%@ is bound. Nothing has been written this session."
                    ),
                    store.agentName ?? String(
                        localized: "reply.agent.fallbackName",
                        defaultValue: "The agent"
                    )
                )
            )
        case .unavailable:
            emptyState(
                title: String(
                    localized: "reply.empty.unavailable.title",
                    defaultValue: "Lost track of this agent"
                ),
                // The recovery is checked, not plausible-sounding: submitting a
                // prompt rewrites `transcriptPath` into the session record, so
                // messaging the agent genuinely reconnects the panel.
                message: String(
                    localized: "reply.empty.unavailable.message",
                    defaultValue: "Its transcript moved — usually after a resume, a restart, or a compaction. Send the agent a message and the panel reconnects."
                ),
                action: String(localized: "reply.empty.unavailable.retry", defaultValue: "Try again")
            ) {
                Task { await store.retry(workspace: workspace) }
            }
        case let .showing(reading):
            replyBody(reading)
        }
    }

    /// The page's own theme, and the colour painted behind it.
    ///
    /// `.solid` rather than `.terminal`: a reply is a reading surface, and the
    /// terminal's backdrop — image, opacity, blur — is not a page ground. It
    /// still follows light/dark from the terminal, which is what
    /// `MarkdownWebTheme.resolve` documents.
    private var pageTheme: MarkdownWebTheme {
        MarkdownWebTheme.resolve(
            backgroundColor: windowAppearance.compositedTerminalBackgroundColor,
            style: .solid
        )
    }

    /// The footer's ground: one step off the page it sits under.
    ///
    /// Derived from Ghostty through the same theme the body uses, so both
    /// sides of that edge come from one source. Unpainted it showed the
    /// sidebar's own chrome, which put a Ghostty surface and a sidebar
    /// surface against each other.
    private var footerGround: Color {
        Color(nsColor: pageTheme.adjacentChromeColor ?? pageCanvas)
    }

    /// The rule between the reply and the footer.
    ///
    /// The page's own hairline, not `Divider()`. `Divider()` paints the
    /// system separator — a sidebar colour drawn against a page that follows
    /// Ghostty, and darker than anything the page draws for itself.
    ///
    /// The frames draw no rule here (`N10 138:1475` is an unfilled 1pt
    /// spacer); the boundary they intend is `footerGround`'s tone step. This
    /// is that boundary with a hairline on top, in the page's own palette.
    @ViewBuilder
    private var footerRule: some View {
        if let hairline = pageTheme.hairlineColor {
            Color(nsColor: hairline).frame(height: 1)
        } else {
            Divider()
        }
    }

    private var pageCanvas: NSColor {
        MarkdownBackgroundStyle.colourBehindPage(
            theme: pageTheme,
            panelContent: windowAppearance.compositedTerminalBackgroundColor
        )
    }

    private func replyBody(_ reading: ReplyPanelReading) -> some View {
        MarkdownWebRenderer(
            // The reply, with its reasoning behind a disclosure above it.
            // Not `group.markdown` — that is the reply's own text, which is
            // what a `cm-69.2` note quotes, and reasoning is deliberately
            // shown but not annotatable.
            markdown: reading.group.renderedMarkdown(
                thinkingLabel: String(
                    localized: "reply.thinking.disclosure",
                    defaultValue: "Show thinking"
                )
            ),
            theme: pageTheme,
            backgroundColor: pageCanvas,
            isVisibleInUI: true,
            // The renderer keys its WebKit identity off these, so they must
            // stay stable across SwiftUI churn or the page reloads on every
            // rebuild. The reply's own id would reload the page on each new
            // reply; the panel is the thing that persists.
            panelId: Self.rendererPanelID,
            workspaceId: workspace?.id ?? Self.rendererPanelID,
            filePath: "",
            fontSize: MarkdownFontSizeSettings.resolvedDefault(),
            fontFamily: MarkdownFontFamily.resolvedDefault(),
            maxContentWidth: MarkdownMaxWidthSettings.resolvedDefault(),
            // Match the header's gutter exactly, so the agent's words line up
            // with the tab name above them. The shell's own 28px is a reading
            // margin sized for a wide viewer; here it left the body visibly
            // stepped in from the chrome and cost 36pt of the 256pt this panel
            // has at its narrowest — the width where "code feels cramped" is
            // already the named risk.
            horizontalPagePadding: Self.bodyGutter,
            // Read the agent's reply with the line breaks it actually wrote.
            // The shell's `breaks: false` is the markdown *file* viewer's
            // setting — right for a hard-wrapped document, wrong here, where
            // every newline was typed deliberately. Every other
            // agent-message renderer in cmux already parses with breaks on.
            rendersLineBreaks: true,
            session: rendererSession,
            onRequestPanelFocus: {},
            onSelectionChanged: { selection in
                // Each selection *adds* a mark now rather than re-aiming the
                // one being written. That is the whole of multi-span: the
                // question "what happens to the note already open" stops
                // existing once a second mark is a thing the set can hold.
                guard let selection else { return }
                takeSelection(selection)
            },
            onMarkHoverChanged: { hoveredID = $0 },
            // Clicking the phrase opens its note, the same as clicking its
            // row below, and scrolls the list to it (`#cm-84`; Tom, dogfood
            // 2026-09-11) — with enough notes the row sits out of view.
            // Clicking the phrase of the note already open closes it again,
            // **keeping the text** like Return, not discarding it like
            // Escape (Tom, dogfood 2026-09-11).
            onMarkClicked: { id in
                guard let entry = draft.numbered.first(where: { $0.id == id }) else { return }
                if editingID == id {
                    closeNoteKeepingText()
                    return
                }
                beginEditing(entry)
                revealNote(id)
            },
            marks: pageMarks,
            // **Tone marks the one in focus, from either direction.**
            // Hover is the transient reading — pointer over the mark, or over
            // its row in the footer. The open field is the persistent one:
            // while you are typing, this is the only thing in the page saying
            // which span you are writing about, and it replaces the outline
            // that used to do that job.
            //
            // Hover wins while it lasts, so moving the pointer still answers
            // "which one is that?" without losing where you were.
            activeMarkID: ReplyMarkFocus.id(hovered: hoveredID, editing: editingID),
            // Keyboard steps only — hover never scrolls the page (`#cm-82`).
            revealRequest: revealRequest.map { MarkdownPageReveal(id: $0.id.uuidString, seq: $0.seq) },
            // `#cm-89`: a match publishes through `onSelectionChanged` above,
            // exactly like a hand drag; only a miss needs an answer here.
            findRequest: terminalFind,
            onFindResult: { seq, published in
                #if DEBUG
                dlog("reply.terminalStart find seq=\(seq) published=\(published ? 1 : 0)")
                #endif
                guard seq == terminalFind?.seq, !published else { return }
                terminalNotice = .notFound
                #if DEBUG
                dlog("reply.terminalStart notice set notFound seq=\(seq)")
                #endif
            },
            // Registers the page as the responder that owns the keyboard while
            // the panel is mounted, so cmux's terminal key-routing repair
            // leaves it alone. Registered against the web view's own window,
            // not "the active main window" — with two windows open those are
            // not the same, and a wrong registration is invisible: the keys
            // simply keep going to the terminal, which is today's bug.
            onWebViewAttachmentChanged: { webView in
                guard let webView, let window = webView.window else { return }
                AppDelegate.shared?
                    .keyboardFocusCoordinator(for: window)?
                    .registerReplyHost(webView)
            },
            // Escape gives the keyboard back, which is `#cm-76`. `cm-69.1b`
            // made this view the sidebar's focus owner, and that stopped
            // `repairFocusedTerminalKeyboardRoutingIfNeeded` firing for Reply
            // — the only route out of the panel today. Without this the panel
            // is a keyboard trap: click in and the mouse is the way out.
            //
            // Only the no-note-field case reaches here. With a field open the
            // field editor is first responder, so `.onExitCommand` below takes
            // the first Escape and focus then parks on the 1x1 sidebar host,
            // whose own `keyDown` already routes Escape to `focusTerminal()`
            // (`Sources/RightSidebarPanelView.swift:519-525`). That is what
            // makes "one level per press" work without a second arm here.
            //
            // Mirrors that host's two steps exactly, fallback included: with
            // no terminal to hand back to, dropping first responder still
            // opens the trap, and returning `false` there would leave Escape
            // doing nothing at all.
            onEscape: { window in
                if AppDelegate.shared?
                    .keyboardFocusCoordinator(for: window)?
                    .focusTerminal() == true {
                    return true
                }
                window.makeFirstResponder(nil)
                return true
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The canvas sits directly behind the web view, and it is not
        // decoration. Without it, any moment the page is not painting — a
        // relayout, a window losing key — shows whatever is behind the panel
        // straight through, and it does not necessarily come back. Observed in
        // dogfood as the body turning the sidebar's own lavender and staying
        // there. `MarkdownPanelView` paints the same layer for the same reason.
        .background(Color(nsColor: pageCanvas))
    }

    // MARK: - The draft, and the reply it belongs to

    /// The marks on the reply currently on screen.
    ///
    /// Addressed by the reply itself rather than by a key taken off it:
    /// ``ReplyDrafts`` anchors on a message `seq`, because both handles a
    /// ``ReplyMessageGroup`` offers are rewritten when paging completes a
    /// turn the window started mid-answer.
    private var draft: ReplyAnnotationSet {
        guard let group = store.model.viewedGroup else { return ReplyAnnotationSet() }
        return store.draft(for: group)
    }

    private func updateDraft(_ change: (inout ReplyAnnotationSet) -> Void) {
        guard let group = store.model.viewedGroup else { return }
        store.updateDraft(for: group, change)
    }

    /// What the page should be painting.
    ///
    /// Derived from the same `numbered` the footer rows use, so a marker and
    /// its row cannot show different numbers in one snapshot.
    private var pageMarks: [MarkdownPageMark] {
        draft.numbered.map { entry in
            MarkdownPageMark(
                id: entry.id.uuidString,
                start: entry.range.lowerBound,
                end: entry.range.upperBound,
                number: entry.number,
                // No state — see `MarkdownPageMark`. A mark carries its wash
                // and its numeral, and the only thing that varies is tone.
            )
        }
    }

    // MARK: - The footer: the notes, in paste order

    /// The manifest — what Paste will send, in the order it will send it.
    ///
    /// The body scrolls, so a note that lived only beside its span would be
    /// invisible at the moment you press Paste.
    @ViewBuilder
    private var annotationFooter: some View {
        VStack(alignment: .leading, spacing: 0) {
            ReplyAnnotationManifest(
                entries: draft.numbered,
                editingID: editingID,
                hoveredID: $hoveredID,
                placeholder: placeholderText,
                gutter: Self.bodyGutter,
                fieldFill: Color(nsColor: pageCanvas),
                // The mark's own hovered colour. `hoveredID` is one value
                // driving both surfaces — hover a row and its mark lights in
                // the page — so drawing them in two palettes made one object
                // look like two.
                hoverFill: Color(nsColor: pageTheme.activeMarkColor),
                hoverTextFill: Color(nsColor: pageTheme.onActiveMarkColor),
                ceiling: footerCeiling,
                revealRequest: revealRequest,
                measuredHeight: $noteListHeight,
                onBeginEditing: { entry in
                    #if DEBUG
                    dlog("reply.note.open n=\(entry.number) via=row")
                    #endif
                    beginEditing(entry)
                },
                onRemove: { id in
                    if editingID == id { closeEditing() }
                    updateDraft { $0.remove(id: id) }
                },
                onPreview: {
                    previewText = draft.serialized()
                    previewIsEdited = false
                },
                labels: quickLabels,
                onApplyLabel: { applyLabel($1, to: $0) },
                onOpenLabelMenu: { openLabelMenu(for: $0, via: "click") },
                labelMenuAnchorBox: labelMenuAnchorBox,
                onCloseEditing: {
                    #if DEBUG
                    dlog("reply.note.close via=band kept=1")
                    #endif
                    closeNoteKeepingText()
                },
                field: { noteField($0) }
            )

            // Outside the scroll region, pinned below the list, so they are
            // reachable at any note count. A footer that scrolled as one
            // block would hide its own primary action exactly when the user
            // has done the most work.
            deliveryButtons
        }
        .padding(.vertical, ReplyFooterMetrics.topInset)
        .background(footerGround)
        // `#cm-85`: the resolved hover, so a pass over the rows can be read
        // back as `1, 2, 3` with or without a `nil` between. A mark hovered
        // in the reply body sets the same value, so a line can come from
        // the page as well as the footer.
        .onChange(of: hoveredID) { id in logHover(id) }
    }

    private func logHover(_ id: UUID?) {
        #if DEBUG
        let number = id.flatMap { id in draft.numbered.first { $0.id == id }?.number }
        dlog("reply.hover n=\(number.map(String.init) ?? "nil")")
        #endif
    }

    /// How tall the note list may grow before it scrolls.
    ///
    /// Three terms, and which one binds depends on the panel: above ~525pt
    /// the 25% proportion is tightest, below ~514pt the 120pt minimum is, and
    /// `minimumHeightAboveList` only decides the ~11pt band between them.
    ///
    /// **25%, lowered from 40% on 2026-09-10 by Tom's dogfood** — at 40% the
    /// list took ~257pt of a 651pt panel and the reply read cramped above it.
    /// A stopgap constant: `cm-69.9` makes the split the user's to size.
    private var footerCeiling: CGFloat {
        guard panelHeight > 0 else { return Self.unmeasuredFooterCeiling }
        return max(120, min(panelHeight * 0.25, panelHeight - Self.minimumHeightAboveList))
    }

    /// The ceiling used for the one layout pass before the panel has measured
    /// itself.
    ///
    /// 25% of 702 — the reference panel the design's proportion was written
    /// against. It was 281, 40% of that same panel, until the proportion was
    /// lowered. Not shared with `ReplyAnnotationManifestRenderTests`, which
    /// needs a ceiling its fixtures stay under and picks its own for that
    /// reason.
    private static let unmeasuredFooterCeiling: CGFloat = 176

    /// How close to the top of the panel the note list may grow.
    ///
    /// **This bounds the list, not the footer.** The count header, the two
    /// delivery buttons and the footer's own vertical padding all sit outside
    /// the ceiling — about 90pt — so the reply body keeps roughly 90pt less
    /// than this number, not the number itself.
    ///
    /// It was `replyFloor = 394`, documented as *"the height the reply keeps
    /// whatever the footer does"*, and that was false three ways: the term is
    /// dead above the proportion's crossover, overridden below ~514pt, and
    /// short by the chrome in between. Since the proportion dropped to 25%
    /// the crossover is ~525pt, so this term binds only in an ~11pt band;
    /// above it the reply keeps roughly `0.75 × panel − 90pt` — ~398pt of a
    /// 651pt panel, where 40% left it ~304pt. The brief's
    /// 394 was typed into a design sentence and never measured against a
    /// render; `cm-69.9` — size the split between the reply and my highlights
    /// myself — is where the size becomes the user's rather than a constant's.
    private static let minimumHeightAboveList: CGFloat = 394

    private var placeholderText: String {
        String(localized: "reply.annotation.notePlaceholder", defaultValue: "What should change?")
    }

    private func noteField(_ entry: NumberedAnnotation) -> some View {
        TextField(placeholderText, text: $editingText, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            // Grows as you type rather than scrolling sideways; growth is
            // bounded by the footer's own ceiling above.
            .lineLimit(1...8)
            .focused($noteFieldFocused)
            .onAppear {
                // A rebuild of a note that is already open: the keyboard is
                // in the sidebar, and the caret goes back where it was
                // (`cm-69.3`).
                if fieldAppearedForID == entry.id {
                    placeCaretInNoteField(hop: false, caret: lastNoteCaret.map { .at($0) } ?? .end)
                    return
                }
                fieldAppearedForID = entry.id
                // A step already holds the keyboard in the sidebar; only a
                // cold open needs AppKit to move it there (`#cm-82`).
                let byStep = stepArrivalID == entry.id
                placeCaretInNoteField(hop: !byStep, caret: byStep ? .end : .asFocused)
            }
            // `#cm-82`: at the field's first or last visual line, ↑/↓ move to
            // the neighbouring note instead of doing nothing. Inside the note
            // they still move the caret — the handler returns `.ignored`.
            .backport.onKeyPress(.upArrow) { modifiers, isRepeat in
                guard Self.isUnmodifiedStep(modifiers),
                      ReplyNoteCaret.isOnEdgeLine(.first) else { return .ignored }
                return stepNote(.previous, isRepeat: isRepeat)
            }
            .backport.onKeyPress(.downArrow) { modifiers, isRepeat in
                guard Self.isUnmodifiedStep(modifiers),
                      ReplyNoteCaret.isOnEdgeLine(.last) else { return .ignored }
                return stepNote(.next, isRepeat: isRepeat)
            }
            // Tab / ⇧Tab step too (Tom, dogfood 2026-09-11), anywhere in the
            // note: unlike ↑/↓, Tab has no job inside a one-line field. With
            // nowhere to go they fall through to the normal focus move.
            // ⇧Tab can arrive as backtab (U+0019) rather than shift + tab.
            .backport.onKeyPress(.tab) { modifiers, isRepeat in
                let rest = modifiers.subtracting([.capsLock, .numericPad, .function])
                if rest.isEmpty { return stepNote(.next, isRepeat: isRepeat) }
                if rest == .shift { return stepNote(.previous, isRepeat: isRepeat) }
                return .ignored
            }
            .backport.onKeyPress(KeyEquivalent("\u{19}")) { _, isRepeat in
                stepNote(.previous, isRepeat: isRepeat)
            }
            // `#cm-83.2`: the configured label key inserts the Nth label.
            // Nine handlers rather than one, because `.backport.onKeyPress`
            // binds a single `KeyEquivalent` — which is also what tells us the
            // digit, since the closure is handed modifiers and nothing else.
            .backport.onKeyPress(KeyEquivalent("1")) { m in insertLabel(1, m, entry) }
            .backport.onKeyPress(KeyEquivalent("2")) { m in insertLabel(2, m, entry) }
            .backport.onKeyPress(KeyEquivalent("3")) { m in insertLabel(3, m, entry) }
            .backport.onKeyPress(KeyEquivalent("4")) { m in insertLabel(4, m, entry) }
            .backport.onKeyPress(KeyEquivalent("5")) { m in insertLabel(5, m, entry) }
            .backport.onKeyPress(KeyEquivalent("6")) { m in insertLabel(6, m, entry) }
            .backport.onKeyPress(KeyEquivalent("7")) { m in insertLabel(7, m, entry) }
            .backport.onKeyPress(KeyEquivalent("8")) { m in insertLabel(8, m, entry) }
            .backport.onKeyPress(KeyEquivalent("9")) { m in insertLabel(9, m, entry) }
            // `#cm-83.3`: the digit after the nine label slots opens the menu,
            // so the labels the digits cannot reach are still reachable.
            .backport.onKeyPress(KeyEquivalent("0")) { m in
                let configured = KeyboardShortcutSettings.shortcut(for: .insertReplyLabelByNumber)
                // `keyEquivalent != nil` matches `insertLabel` five lines
                // down. Without it, a binding that resolves by key code rather
                // than key equivalent leaves ⌥1–⌥9 dead while ⌥0 still opens
                // the menu — a menu you can reach whose rows you cannot.
                guard !configured.isUnbound, !configured.hasChord,
                      configured.keyEquivalent != nil,
                      m.subtracting([.capsLock, .numericPad, .function])
                          == configured.eventModifiers,
                      ReplyNoteCaret.fieldEditorIsKey else { return .ignored }
                // Hand the key back when nothing opened, rather than eating it.
                return openLabelMenu(for: entry, via: "key") ? .handled : .ignored
            }
            .onChange(of: editingText) { text in
                updateDraft { $0.updateNote(id: entry.id, note: text) }
                if let caret = ReplyNoteCaret.selection { lastNoteCaret = caret }
            }
            .onSubmit { closeEditing() }

            .frame(maxWidth: .infinity, alignment: .leading)
            .onExitCommand {
                // Escape is the only path that discards text.
                updateDraft { $0.updateNote(id: entry.id, note: editingOriginal) }
                closeEditing()
            }
    }

    private var deliveryButtons: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Side by side when both full labels fit, stacked when they do
            // not (Tom, dogfood 2026-09-11). Never squeezed: at 256pt a row
            // forced the label "P&Send", which reads as a typo — so the row
            // is offered only at a width where neither label truncates.
            ViewThatFits(in: .horizontal) {
                // `Paste & Send` first, `Paste` after it (Tom, dogfood
                // 2026-09-11) — the same order stacked as side by side.
                HStack(spacing: 6) {
                    pasteAndSendButton
                    pasteButton
                }
                VStack(alignment: .leading, spacing: 6) {
                    pasteAndSendButton
                    pasteButton
                }
            }

            // One refusal, one sentence, and only for the button that is off.
            if ReplyDeliveryGate.canSend(draft, editedText: editedPreview, turnEnded: true), !store.canSubmit {
                footerNote(String(
                    localized: "reply.annotation.turnInFlight",
                    defaultValue: "Paste & Send returns when this turn ends"
                ))
            }
        }
        .padding(.horizontal, Self.bodyGutter)
        .padding(.top, 6)
    }

    /// Whether `Paste & Send` is the primary button — exactly when it can be
    /// pressed (Tom, dogfood 2026-09-11): a written note, or an edited paste
    /// preview (`#cm-93`), and the turn has ended. Until then `Paste` is
    /// primary: a prominent button that is greyed out would point at the one
    /// action that is not available.
    private var sendIsPrimary: Bool {
        ReplyDeliveryGate.canSend(draft, editedText: editedPreview, turnEnded: store.canSubmit)
    }

    /// The paste preview's text once it has been edited, else `nil` — `#cm-93`.
    ///
    /// An edited box is what gets sent (`#cm-69`, 2026-09-04: *"exactly what
    /// Paste will send"*), so the buttons and ``send(submit:)`` read the same
    /// value. An unedited box is only the marks' serialization, which
    /// `deliver` rebuilds itself.
    private var editedPreview: String? {
        previewIsEdited ? previewText : nil
    }

    private var pasteButton: some View {
        Button {
            send(submit: false)
        } label: {
            Text(String(localized: "reply.annotation.paste", defaultValue: "Paste"))
                .lineLimit(1)
                .fixedSize()
                .frame(maxWidth: .infinity)
        }
        .controlSize(.small)
        .modifier(ReplyDeliveryButtonStyle(prominent: !sendIsPrimary))
        .replyHoverHighlight(cornerRadius: 5)
        // **Paste is never gated** — it types into a composer the user is
        // looking at and submits nothing, so what goes in there is their
        // call. An unwritten note is not an unfinished action, it is an
        // action the user intends to finish in the terminal.
        //
        // Off only when there is genuinely nothing to put anywhere.
        .disabled(!ReplyDeliveryGate.canPaste(draft, editedText: editedPreview))
    }

    private var pasteAndSendButton: some View {
        Button {
            send(submit: true)
        } label: {
            Text(String(localized: "reply.annotation.pasteAndSend", defaultValue: "Paste & Send"))
                .lineLimit(1)
                .fixedSize()
                .frame(maxWidth: .infinity)
        }
        .controlSize(.small)
        .modifier(ReplyDeliveryButtonStyle(prominent: sendIsPrimary))
        .replyHoverHighlight(cornerRadius: 5)
        .disabled(!ReplyDeliveryGate.canSend(draft, editedText: editedPreview, turnEnded: store.canSubmit))
    }

    // MARK: - The paste preview

    /// Shows the box with what was typed into it on the reply now on screen,
    /// or closes it when nothing was — `#cm-90`.
    ///
    /// An unedited preview is not kept: it is only the marks' serialization,
    /// which `⤢` rebuilds exactly, so reopening it would open a mode nobody
    /// asked for.
    private func restoreTypedPreview() {
        let typed = store.model.viewedGroup.flatMap { store.typedPreview(for: $0) }
        previewText = typed
        previewIsEdited = typed != nil
    }

    /// Exactly what Paste will send, editable, at the panel's own width.
    private func pastePreview(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                // One-way: nothing parses the edited text back, so returning
                // discards it. Annotations flow out and never return, which
                // is why a mangled preview costs the agent's input and
                // nothing else.
                if let group = store.model.viewedGroup {
                    store.setTypedPreview(nil, for: group)
                }
                previewText = nil
                previewIsEdited = false
            } label: {
                Label(
                    previewIsEdited
                        ? String(localized: "reply.preview.discard", defaultValue: "Discard edits")
                        : String(localized: "reply.preview.collapse", defaultValue: "Collapse"),
                    systemImage: "arrow.down.right.and.arrow.up.left"
                )
                .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            // **Top-right, where the `⤢` that opened this lives.** You leave
            // a mode by reaching for the corner you entered it from; a toggle
            // whose halves sit in opposite corners makes you hunt for the
            // second one. It is also the platform's answer — dismissal is
            // top-right on macOS sheets and popovers, while top-left is
            // *back* in a navigation stack, and this is not a stack: the
            // header stays and only the body swaps.
            //
            // The label stays. The expand side gets away with a bare glyph
            // because its header line gives it context; the preview has no
            // other chrome, so the word removes a guess for one line's cost.
            .frame(maxWidth: .infinity, alignment: .trailing)

            ReplyPreviewEditor(text: text) { typed in
                previewText = typed
                previewIsEdited = true
                // Written through as typed, like the note fields, so a
                // step or a mode switch has no moment to lose it — `#cm-90`.
                if let group = store.model.viewedGroup {
                    store.setTypedPreview(typed, for: group)
                }
            }
            // Monospace is not decoration: a wire format shown in the body
            // face is indistinguishable from badly-wrapped prose, which is
            // the whole thing the fence exists to signal.
            .font(.system(size: 11, design: .monospaced))
            // `TextEditor` paints its own opaque ground, which came out stark
            // white over the panel. The reading surface follows Ghostty
            // through `pageTheme`, and this box has to sit on the same one.
            .scrollContentBackground(.hidden)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: pageCanvas))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.primary.opacity(0.12))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            deliveryButtons
        }
        .padding(.horizontal, Self.bodyGutter)
        .padding(.vertical, 8)
        .background(footerGround)
    }

    private func footerNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Editing and delivery

    private func beginEditing(_ entry: NumberedAnnotation) {
        stepArrivalID = nil
        fieldAppearedForID = nil
        lastNoteCaret = nil
        editingID = entry.id
        editingText = entry.note
        editingOriginal = entry.note
        placeCaretInNoteField()
    }

    /// Puts the caret in the open note field — from a cold start, or, with
    /// `hop: false`, after a `#cm-82` step.
    ///
    /// Two steps, because they answer different questions. AppKit decides
    /// which *view* has the keyboard, and until the sidebar wins that the
    /// terminal keeps every keystroke. SwiftUI then decides which *field*
    /// inside it holds the caret. Doing only the second left the focus in
    /// the agent, which is what dogfood found.
    ///
    /// The caret is placed a runloop turn later: the field may not be in the
    /// hierarchy yet on the pass that creates its row, and `@FocusState` set
    /// against a field that does not exist is dropped silently.
    ///
    /// - Parameters:
    ///   - hop: Whether to move AppKit's first responder into the sidebar
    ///     first. `false` only for a `#cm-82` step, where the keyboard is
    ///     already there and the hop would park it on the reply's web view.
    ///   - caret: Where the caret goes once the field has the keyboard.
    ///     Focusing a field selects all of it — measured, `{0, 71}` of 71 —
    ///     so anything but `.asFocused` replaces that selection, or the next
    ///     keystroke would replace a written note.
    private func placeCaretInNoteField(hop: Bool = true, caret: NoteCaretPlacement = .asFocused) {
        confirmNoteFieldFocus(for: editingID, caret: caret, retriesLeft: 2)
        if hop {
            _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                mode: .reply,
                focusFirstItem: false
            )
        }
        DispatchQueue.main.async {
            noteFieldFocused = true
            if case .asFocused = caret { return }
            // The field editor takes first responder on this pass; the
            // selection it applies on focus lands after, so move it a turn on.
            DispatchQueue.main.async {
                switch caret {
                case .asFocused: break
                case .end: ReplyNoteCaret.moveToEnd()
                case .at(let range): ReplyNoteCaret.select(range)
                }
                #if DEBUG
                // `#cm-82`'s one open question: after a step, the keyboard
                // must be in the new note, never on the reply's web view.
                dlog("reply.step landed fr=\(ReplyNoteCaret.firstResponderName)")
                #endif
            }
        }
    }

    /// Checks, after the fact, that the open note's field really took the
    /// keyboard, and asks again if it did not.
    ///
    /// Focus set on a field SwiftUI is in the middle of replacing is dropped
    /// without a word. A highlight that pushes the list past its ceiling
    /// rebuilds the field inside a scroll view, and three placements land
    /// within 30 ms of each other — the keyboard stayed on the reply (Tom,
    /// dogfood 2026-09-11, the fourth highlight made by double-click). No one
    /// ordering fixes that race, so the outcome is measured instead: 50 ms
    /// on, if a note is still open and no text field has the keyboard, drop
    /// focus and set it again. Bounded, so a field that can never take focus
    /// cannot loop.
    private func confirmNoteFieldFocus(for id: UUID?, caret: NoteCaretPlacement, retriesLeft: Int) {
        guard let id else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard editingID == id else { return }
            let held = ReplyNoteCaret.fieldEditorIsKey
            #if DEBUG
            dlog("reply.focus confirm held=\(held ? 1 : 0) retriesLeft=\(retriesLeft) fr=\(ReplyNoteCaret.firstResponderName)")
            #endif
            guard !held, retriesLeft > 0 else { return }
            noteFieldFocused = false
            DispatchQueue.main.async {
                guard editingID == id else { return }
                noteFieldFocused = true
                if case .asFocused = caret {} else {
                    DispatchQueue.main.async {
                        switch caret {
                        case .asFocused: break
                        case .end: ReplyNoteCaret.moveToEnd()
                        case .at(let range): ReplyNoteCaret.select(range)
                        }
                    }
                }
                confirmNoteFieldFocus(for: id, caret: caret, retriesLeft: retriesLeft - 1)
            }
        }
    }

    /// Moves the one open note field to the neighbouring note — `#cm-82`.
    ///
    /// Not `beginEditing`: that places the caret through the AppKit hop, and
    /// not `closeEditing`, which hands the keyboard to the reply body between
    /// two notes. Returns `.ignored` when there is nowhere to go, so the key
    /// falls through to the text field's own caret move.
    private func stepNote(_ direction: ReplyNoteStep.Direction, isRepeat: Bool) -> BackportKeyPressResult {
        let entries = draft.numbered
        guard let current = editingID,
              let index = entries.firstIndex(where: { $0.id == current }),
              let target = ReplyNoteStep.target(
                  from: index, count: entries.count, direction, isRepeat: isRepeat
              ) else { return .ignored }
        let next = entries[target]
        // Saved here, not left to `.onChange(of: editingText)`: that runs on
        // the next update, and the field it belongs to is gone by then.
        updateDraft { $0.updateNote(id: current, note: editingText) }
        // A key press means the keyboard is in charge of what is lit; hover
        // returns when the pointer next enters a mark or a row.
        hoveredID = nil
        stepArrivalID = next.id
        fieldAppearedForID = nil
        lastNoteCaret = nil
        editingID = next.id
        editingText = next.note
        editingOriginal = next.note
        revealNote(next.id)
        return .handled
    }

    /// Scrolls the list — and the reply — to a note, only as far as needed
    /// and not at all when it is already in view. Shared by a keyboard step
    /// (`#cm-82`) and a click on the note's phrase (`#cm-84`), so both reach
    /// a note that sits below the list's ceiling.
    private func revealNote(_ id: UUID) {
        revealSeq += 1
        revealRequest = ReplyRevealRequest(id: id, seq: revealSeq)
    }

    /// Pops the `⌄` label menu — `#cm-83.3`.
    ///
    /// One menu for both entrances: the chevron's click and `⌥0`. It anchors
    /// to the zero-size view the chip row hands back, so it opens where the
    /// chevron is rather than at the pointer.
    /// Returns whether a menu actually opened, so the caller can hand the key
    /// back when it did not. Every bail-out below is silent, and a key press
    /// that is swallowed by a control which then does nothing is the least
    /// debuggable failure this panel can produce.
    /// `via` is `"click"` or `"key"`. The two entrances differ by construction
    /// — a chevron click moves SwiftUI focus on mouse-down, `⌥0` never touches
    /// it — so one `route=menu` in the log cannot tell you which you are
    /// reading. They must be separable or the measurement is worthless.
    @discardableResult
    private func openLabelMenu(for entry: NumberedAnnotation, via: String) -> Bool {
        // Probe BEFORE the guard: with it after, "no log line" could mean the
        // click never fired OR the guard refused, and those need different
        // fixes. Same mistake this file already made once tonight.
        #if DEBUG
        dlog(
            "cm-83.3 labelMenu.request via=\(via) anchor=\(labelMenuAnchorBox.view != nil ? 1 : 0) "
                + "inWindow=\(labelMenuAnchorBox.view?.window != nil ? 1 : 0) labels=\(quickLabels.count)"
        )
        #endif
        guard let anchor = labelMenuAnchorBox.view, anchor.window != nil else { return false }
        let menu = ReplyLabelMenu.make(
            labels: quickLabels,
            shortcut: KeyboardShortcutSettings.shortcut(for: .insertReplyLabelByNumber),
            apply: { applyLabel($0, to: entry, route: "menu.\(via)") },
            edit: { AppDelegate.presentPreferencesWindow(navigationTarget: .reply) }
        )
        #if DEBUG
        dlog("cm-83.3 labelMenu.open items=\(menu.items.count) entry=\(entry.id.uuidString.prefix(5))")
        #endif
        // The anchor is forced to zero size, so `bounds.height` is 0 and the
        // old `bounds.height + 4` was dead arithmetic reading as "below the
        // control". `Anchor` is flipped (see its definition), so +y is down.
        // `.background` centres the anchor on the chevron chip, which is the
        // 8pt glyph plus 3pt padding each side — so half of it, plus a 4pt
        // gap, clears the chip's bottom edge.
        menu.popUp(
            positioning: nil as NSMenuItem?,
            at: NSPoint(x: 0, y: ReplyLabelMenu.dropBelowChevron),
            in: anchor
        )
        return true
    }

    /// Inserts the Nth quick label from the keyboard — `#cm-83.2`.
    ///
    /// Matches the **configured** binding rather than a hardcoded chord, so
    /// the Settings row and `cmux.json` mean something. It cannot use
    /// `StoredShortcut.matches(event:)` — that takes an `NSEvent` and this
    /// closure is handed `EventModifiers` and nothing else
    /// (`Sources/Backport.swift:45-58`) — so it compares the two halves it can
    /// see: the modifiers, and the digit this handler is bound to.
    ///
    /// A **chord** binding cannot be expressed here (`keyEquivalent` is nil
    /// when `hasChord`), so it falls back to click-only rather than firing on
    /// the chord's first stroke. Stated, not silent.
    private func insertLabel(
        _ n: Int,
        _ modifiers: EventModifiers,
        _ entry: NumberedAnnotation
    ) -> BackportKeyPressResult {
        let configured = KeyboardShortcutSettings.shortcut(for: .insertReplyLabelByNumber)
        guard !configured.isUnbound, !configured.hasChord,
              configured.keyEquivalent != nil,
              modifiers.subtracting([.capsLock, .numericPad, .function])
                  == configured.eventModifiers,
              ReplyNoteCaret.fieldEditorIsKey,
              n <= quickLabels.count else { return .ignored }
        #if DEBUG
        dlog("cm-83.2 label.key n=\(n) label=\(quickLabels[n - 1]) fieldKey=1")
        #endif
        applyLabel(quickLabels[n - 1], to: entry, route: "key")
        return .handled
    }

    /// Puts a quick label's text into the open note — `cm-69.3`.
    ///
    /// Inserted at the caret by `ReplyLabelInsertion`, then the note closes,
    /// keeping its text. The note's text is edited directly rather than
    /// through the field editor: with the field closing there is no undo to
    /// preserve. `noteFieldFocused` gates reading the live selection, because
    /// the window's field editor serves every text field in it.
    /// `route` is why this exists as a parameter rather than a literal: the
    /// probe below logged `click` for every insert, keyed ones included, and
    /// a cold review found `#cm-83.2`'s closing evidence leaning on that word
    /// to tell the two paths apart. An instrument that cannot distinguish the
    /// thing it is cited for is worse than none.
    private func applyLabel(
        _ label: String,
        to entry: NumberedAnnotation,
        route: String = "click"
    ) {
        guard editingID == entry.id else { return }
        #if DEBUG
        // Logged before anything moves focus, so it says where the keyboard
        // was at the click — the question 3.1 asks.
        dlog("reply.label \(route) focused=\(noteFieldFocused ? 1 : 0) fr=\(ReplyNoteCaret.firstResponderName) lastCaret=\(lastNoteCaret.map { NSStringFromRange($0) } ?? "nil")")
        #endif
        // A label finishes the note: it goes in where the caret was and the
        // note closes, keeping its text (Tom, dogfood 2026-09-11 — *"clicking
        // on the canned response should collapse"*). The caret is the live
        // one if the field still has the keyboard, else the one recorded
        // before the click took it, else the end.
        let end = NSRange(location: (editingText as NSString).length, length: 0)
        let selection = (noteFieldFocused ? ReplyNoteCaret.selection : nil) ?? lastNoteCaret ?? end
        let insertion = ReplyLabelInsertion.apply(label: label, to: editingText, selection: selection)
        editingText = insertion.applied(to: editingText)
        #if DEBUG
        dlog("reply.label inserted at=\(NSStringFromRange(insertion.range)) closing=1")
        #endif
        closeNoteKeepingText()
    }

    /// Reads `reply.labels`, assigning only when it changed.
    private func refreshQuickLabels() {
        let labels = UserDefaultsSettingsClient(defaults: .standard)
            .value(for: SettingCatalog().reply.labels)
        if labels != quickLabels { quickLabels = labels }
    }

    /// Closes the note field and hands the keyboard back to the reply body.
    ///
    /// **`#cm-77`.** The field editor takes first responder *after*
    /// ``placeCaretInNoteField()`` sets it, and AppKit does not restore the
    /// previous responder when a view is removed — so without this the keys
    /// after a note go nowhere. Returning the keyboard to the body is the
    /// intended behaviour and must not depend on responder-chain fallback.
    ///
    /// Deferred a runloop turn for the same reason ``placeCaretInNoteField()``
    /// defers the opposite move: the field editor is still first responder
    /// while this runs, and SwiftUI tears it down after the state change.
    ///
    /// It also makes Escape's two presses read the same way. Escape closes the
    /// field and lands here; the next Escape reaches the body's own arm
    /// (`#cm-76`) and hands off to the terminal. Before this, the in-between
    /// state was the 1x1 host, which swallowed anything typed there.
    /// Closes the open note by a click — on its phrase or its band — keeping
    /// what was typed, like Return and unlike Escape (Tom, dogfood
    /// 2026-09-11). Saved here first: the field's own onChange is deferred,
    /// and a click can land before the last keystroke's update runs.
    private func closeNoteKeepingText() {
        guard let id = editingID else { return }
        updateDraft { $0.updateNote(id: id, note: editingText) }
        closeEditing()
    }

    private func closeEditing() {
        clearEditingState()
        DispatchQueue.main.async {
            _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                mode: .reply,
                focusFirstItem: false
            )
        }
    }

    /// Drops the note-editing state without touching focus.
    ///
    /// Split out for ``send(submit:)``, which is not a user closing a note:
    /// it pastes into the terminal and deliberately moves no focus. Folding
    /// the hand-back into it would put the keyboard in the reply body right
    /// after the user sent something to the terminal — a behaviour change
    /// outside `#cm-77`, and one no scenario asks for.
    private func clearEditingState() {
        stepArrivalID = nil
        fieldAppearedForID = nil
        lastNoteCaret = nil
        editingID = nil
        editingText = ""
        editingOriginal = ""
    }

    /// `#cm-89` — takes a terminal request once the panel can answer it.
    ///
    /// Waits until the store follows the pane the drag came from **and** a
    /// reply has loaded: the store binds before its transcript arrives, and
    /// judging an empty model would call every cold open "not found". A
    /// request that never meets both is left alone rather than guessed at.
    ///
    /// Nothing here moves the reader — ``TerminalReplyConsume`` checks an
    /// older reply first, and the find only ever runs on the newest.
    private func consumeTerminalReplyIfReady(_ incoming: TerminalReplyRequest?? = nil, trigger: String) {
        let request = incoming ?? terminalReplyRequest
        guard let request, request.seq != consumedTerminalReplySeq else { return }
        guard store.boundPanelID == request.sourcePanelID else {
            #if DEBUG
            dlog("reply.terminalStart wait seq=\(request.seq) trigger=\(trigger) reason=notBound bound=\(store.boundPanelID?.uuidString.prefix(5) ?? "nil") source=\(request.sourcePanelID.uuidString.prefix(5))")
            #endif
            return
        }
        // The store sets `boundPanelID` before its new tail loads, and keeps
        // drawing the *previous* agent's model until the replacement is ready
        // (`ReplyPanelStore.startTail`). Judging that model would answer for
        // the wrong agent — cold code review 2026-09-13, Required 2.
        guard store.boundSessionID != nil, store.model.sessionID == store.boundSessionID else {
            #if DEBUG
            dlog("reply.terminalStart wait seq=\(request.seq) trigger=\(trigger) reason=staleModel")
            #endif
            return
        }
        guard let newest = store.model.newestGroup else {
            #if DEBUG
            dlog("reply.terminalStart wait seq=\(request.seq) trigger=\(trigger) reason=noReply")
            #endif
            return
        }
        consumedTerminalReplySeq = request.seq
        onTerminalReplyConsumed(request.seq)
        let decision = TerminalReplyConsume.decide(
            viewingOlderReply: store.model.viewedGroupID != nil,
            newestHasHighlights: !store.draft(for: newest).annotations.isEmpty,
            newestTurnWriting: store.model.isNewestTurnWriting,
            isMultiRow: request.isMultiRow,
            text: request.text
        )
        #if DEBUG
        dlog("reply.terminalStart consume seq=\(request.seq) trigger=\(trigger) decision=\(decision) writing=\(store.model.isNewestTurnWriting ? 1 : 0) newest=\(newest.id.prefix(8)) groups=\(store.model.groups.count) following=\(store.model.viewedGroupID == nil ? 1 : 0)")
        #endif
        switch decision {
        case .silent:
            terminalNotice = nil
        case .notice(let notice):
            terminalNotice = notice
        case .find(let text):
            terminalNotice = nil
            terminalFindSeq += 1
            terminalFind = MarkdownPageFind(text: text, seq: terminalFindSeq)
        }
    }

    private func clearTerminalNotice(reason: String) {
        guard terminalNotice != nil else { return }
        #if DEBUG
        dlog("reply.terminalStart notice cleared reason=\(reason) was=\(String(describing: terminalNotice!))")
        #endif
        terminalNotice = nil
    }

    private func terminalNoticeSymbol(_ notice: TerminalReplyNotice) -> String? {
        switch notice {
        case .notFound: return "exclamationmark.circle.fill"
        case .multiRow: return "exclamationmark.triangle.fill"
        case .writing: return nil
        }
    }

    private func terminalNoticeStyle(_ notice: TerminalReplyNotice) -> AnyShapeStyle {
        switch notice {
        case .notFound: return AnyShapeStyle(Color(nsColor: .systemRed))
        case .multiRow: return AnyShapeStyle(Color(nsColor: .systemOrange))
        case .writing: return AnyShapeStyle(.secondary)
        }
    }

    private func terminalNoticeText(_ notice: TerminalReplyNotice) -> String {
        switch notice {
        case .notFound:
            return String(localized: "reply.terminalStart.notFound", defaultValue: "Couldn't highlight selection, select below instead")
        case .multiRow:
            return String(localized: "reply.terminalStart.multiRow", defaultValue: "Select within one line")
        case .writing:
            return String(localized: "reply.terminalStart.writing", defaultValue: "Still writing")
        }
    }

    /// Takes a new selection as a mark, refusing one that overlaps another.
    private func takeSelection(_ selection: MarkdownPageSelection) {
        let annotation = ReplyAnnotation(quote: selection.quote, note: "", range: selection.range)
        var accepted = false
        updateDraft { accepted = $0.insert(annotation) }
        // A refused overlap leaves the standing mark alone: an ambiguous
        // quote is fixed by selecting more, never by cmux widening one.
        guard accepted else { return }
        clearTerminalNotice(reason: "highlight")
        stepArrivalID = nil
        fieldAppearedForID = nil
        lastNoteCaret = nil
        editingID = annotation.id
        editingText = ""
        editingOriginal = ""
        placeCaretInNoteField()
    }

    /// Says the clipboard now holds what was pasted, then goes away.
    ///
    /// **In the header, immediately after the agent's name** — the exact slot
    /// the state word used to occupy, which is where this panel already says
    /// transient things about itself (Tom's placement, dogfood 2026-09-06).
    /// It reads left-to-right with the thing it is about; parked on the right
    /// it sat against the `‹ 4/4 ›` arrows, which are navigation and have
    /// nothing to do with a paste. A floating capsule over the body was the
    /// first attempt and was worse still: it covered the reply to report
    /// something that had already finished.
    ///
    /// The header is also the only place it *can* live. A successful `Paste`
    /// clears the draft, which takes the whole footer off screen — a note
    /// hosted there would be removed in the same frame it appeared.
    ///
    /// Transient and non-blocking on purpose: it reports something that has
    /// already happened and needs no answer, so it takes no click to dismiss
    /// and moves nothing.
    @ViewBuilder
    private var copiedNote: some View {
        if showCopiedNote {
            Text(String(
                localized: "reply.annotation.copied",
                defaultValue: "Copied to clipboard"
            ))
            .font(.system(size: 10))
            // `.tertiary`, not `.secondary`, since `cm-69.6` put a second
            // caption in this row. `Showing last` is the only thing on screen
            // explaining why a control is dead; this vanishes after two
            // seconds. Identical grey made a permanent explanation and a toast
            // read the same, and every other way to separate them — weight, a
            // background chip — costs width a 28.6pt-over-budget row does not
            // have, paid for by the title. Demoting the transient one is free.
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            // Truncates rather than holding its width (Tom, 2026-09-07: "if
            // they fight, just truncate"). This carried `.fixedSize()` with
            // the note "on screen for two seconds and half of it says
            // nothing" — right while the header held one caption, wrong once
            // a second one made nineteen characters expensive.
            .truncationMode(.tail)
            .transition(.opacity)
        }
    }

    private func send(submit: Bool) {
        clearEditingState()
        // `#cm-93`: an edited preview is what gets sent — the box is the
        // composer moved one step earlier (`#cm-69`, 2026-09-04). It stays
        // one-way: nothing parses the edited text back into the marks.
        let delivered = store.deliver(draft, editedText: editedPreview, workspace: workspace, submit: submit)
        // `#cm-91`: on every exit, with the real result, so the store's rule
        // (a refused send never closes) holds wherever this line ends up.
        defer { closeSidebarAfterSendIfUnpinned(delivered: delivered) }
        guard delivered else { return }
        // Cleared only on a dispatch that actually happened. A refused send
        // that wiped the notes would lose writing the user cannot get back.
        if let group = store.model.viewedGroup {
            store.clearDraft(for: group)
        }
        previewText = nil
        previewIsEdited = false

        // Only on a dispatch that happened — `deliver` returning false means
        // nothing reached the terminal and nothing reached the clipboard, so
        // saying otherwise would be the one thing worse than saying nothing.
        copiedNoteDismissal?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { showCopiedNote = true }
        copiedNoteDismissal = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.25)) { showCopiedNote = false }
        }
    }

    /// `#cm-91` — hides this window's right sidebar after a delivered send,
    /// unless the pin holds it open, with the keyboard in the agent pane the
    /// reply went to.
    ///
    /// Runs from `send`'s `defer` with `deliver`'s real result, so a refused
    /// send reaches the store's rule as `false` and closes nothing.
    ///
    /// **Focus first, then hide.** If focus lands on the bound pane, the hide's
    /// own restore finds the keyboard already out of the sidebar and declines,
    /// so it moves once; if it does not land, that restore still runs. The window comes from the bound pane, not "the
    /// active main window", which is another window when two are open.
    private func closeSidebarAfterSendIfUnpinned(delivered: Bool) {
        let close = store.closesSidebarAfterSend(delivered: delivered)
        let window = store.boundPanelID
            .flatMap { AppDelegate.shared?.locateSurface(surfaceId: $0) }
            .flatMap { AppDelegate.shared?.windowForMainWindowId($0.windowId) }
        #if DEBUG
        dlog("reply.send delivered=\(delivered ? 1 : 0) pinned=\(store.isPinned ? 1 : 0) close=\(close ? 1 : 0) window=\(window != nil ? 1 : 0)")
        #endif
        guard close, let window else { return }
        var focused = false
        if let panelID = store.boundPanelID {
            focused = AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.focusTerminal(panelID: panelID) ?? false
        }
        _ = AppDelegate.shared?.closeRightSidebarInActiveMainWindow(preferredWindow: window)
        #if DEBUG
        dlog("reply.send closed focused=\(focused ? 1 : 0) fr=\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
        #endif
    }

    /// A stable id for the renderer's WebKit session, distinct from any real
    /// panel's. The Reply panel has no `Panel` of its own to borrow one from.
    private static let rendererPanelID = UUID()

    private func emptyState(
        title: String,
        message: String,
        action: String? = nil,
        perform: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let action, let perform {
                Button(action, action: perform)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Where ``ReplyPanelView``'s note field puts the caret once it has the
/// keyboard.
enum NoteCaretPlacement {
    /// Leave whatever focusing applied — select-all on a written note.
    case asFocused
    /// After the note's text.
    case end
    /// A recorded position — a rebuild, or an inserted label (`cm-69.3`).
    case at(NSRange)
}

/// The open note field's caret, read from AppKit — `#cm-82`.
///
/// SwiftUI exposes neither the caret nor line layout, so this reads the
/// field editor directly. It measures through `NSTextInputClient`'s
/// `firstRect(forCharacterRange:actualRange:)` and **never touches
/// `layoutManager`**: reading that on a TextKit 2 view switches it to
/// TextKit 1 for good, which the `#cm-82` spike very likely did to itself.
@MainActor
enum ReplyNoteCaret {
    enum Edge { case first, last }

    /// The note field's editor, when a note field is what has the keyboard.
    private static var editor: NSTextView? {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
              editor.isFieldEditor else { return nil }
        return editor
    }

    /// Whether the caret sits on the field's first or last **visual** line.
    ///
    /// Visual, so a note that wraps without a newline still has lines the
    /// arrows move between before they leave it. `false` — let the text field
    /// have the key — while an input method is composing, or while text is
    /// selected: the first arrow then collapses the selection as it always
    /// has, and the next one steps.
    static func isOnEdgeLine(_ edge: Edge) -> Bool {
        guard let editor, !editor.hasMarkedText() else { return false }
        let selection = editor.selectedRange()
        guard selection.length == 0 else { return false }
        let length = (editor.string as NSString).length
        // At a soft wrap the caret index is where the next line starts, but
        // with upstream affinity it is *drawn* at the end of the line above.
        // Measure the character before it, or ↓ there would step instead of
        // moving down to the line the caret is really on.
        let measured = editor.selectionAffinity == .upstream && selection.location > 0
            ? selection.location - 1
            : selection.location
        guard let caret = lineRect(editor, at: measured),
              let boundary = lineRect(editor, at: edge == .first ? 0 : length)
        else { return false }
        // Same line when the two rects share a vertical centre; half a line
        // of slack absorbs sub-point rounding without admitting a neighbour.
        return abs(caret.midY - boundary.midY) < max(caret.height, 1) / 2
    }

    /// The open note's selection, when a note field has the keyboard.
    static var selection: NSRange? { editor?.selectedRange() }

    /// Whether a text field actually holds AppKit's keyboard — what SwiftUI's
    /// `@FocusState` claims can be stale after a click in a web view.
    static var fieldEditorIsKey: Bool { editor != nil }

    /// Puts the caret (or a selection) at `range`, clamped to the note.
    static func select(_ range: NSRange) {
        guard let editor else { return }
        let length = (editor.string as NSString).length
        let start = min(max(range.location, 0), length)
        editor.setSelectedRange(NSRange(location: start, length: min(range.length, length - start)))
    }

    /// Puts the caret after the note's text, replacing the select-all that
    /// focusing a field applies.
    static func moveToEnd() {
        guard let editor else { return }
        let end = (editor.string as NSString).length
        editor.setSelectedRange(NSRange(location: end, length: 0))
    }

    #if DEBUG
    static var firstResponderName: String {
        NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
    }
    #endif

    private static func lineRect(_ editor: NSTextView, at location: Int) -> NSRect? {
        let rect = editor.firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
        return rect.isEmpty && rect.origin == .zero ? nil : rect
    }
}

/// The paste preview's editor, on its own so a test can host it — `#cm-93`.
///
/// It binds `TextEditor` to text it owns. Bound to `Binding(get: { text },
/// set:)` instead, every re-render of the panel — the keystroke's own, or the
/// newest reply growing — rewrote the editor's string and threw the caret to
/// the end, so the second character typed mid-text landed last.
struct ReplyPreviewEditor: View {
    let text: String
    let onEdit: (String) -> Void
    @State private var editorText: String
    /// The last text this editor and the panel agreed on — reported up, or
    /// taken in. Compared against instead of `text`, which lags a keystroke:
    /// type then `⌫` before a re-render and the `⌫` matches `text`, goes
    /// unreported, and the next render puts the character back.
    @State private var syncedText: String

    init(text: String, onEdit: @escaping (String) -> Void) {
        self.text = text
        self.onEdit = onEdit
        _editorText = State(initialValue: text)
        _syncedText = State(initialValue: text)
    }

    var body: some View {
        // The getter reads the editor's own text, so a re-render never
        // rewrites the box. The setter reports the edit on the keystroke
        // itself: from an `onChange` it would land a run-loop pass later, and a
        // click on `Paste` in that gap would send the text from before it.
        TextEditor(text: Binding(
            get: { editorText },
            set: { typed in
                editorText = typed
                guard typed != syncedText else { return }
                syncedText = typed
                onEdit(typed)
            }
        ))
            // Only text the panel has not already agreed on replaces the box:
            // a step to a reply holding other typed text (`#cm-90`). Never an
            // `.id` reset — `viewedGroup?.id` also moves while the newest reply
            // grows, and that would rebuild the editor mid-typing.
            .onChange(of: text) { incoming in
                guard incoming != syncedText else { return }
                syncedText = incoming
                editorText = incoming
            }
    }
}

/// The primary / secondary look for the two delivery buttons, switched by
/// which one is the next thing to press.
private struct ReplyDeliveryButtonStyle: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}
