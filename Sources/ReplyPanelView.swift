import AppKit
import CmuxAgentChat
import CmuxAppKitSupportUI
import SwiftUI

/// The right sidebar's Reply mode: the bound agent's newest reply, rendered.
///
/// Header pinned, body scrolling under it. The counter is the only thing
/// that says which of N replies is on screen, so a header that scrolled
/// away would take it exactly when a long reply makes it most needed.
struct ReplyPanelView: View {
    let workspace: Workspace?
    let windowAppearance: WindowAppearanceSnapshot

    @State private var store = ReplyPanelStore()
    @State private var rendererSession = MarkdownRendererSession()

    /// Every reply's marks, keyed by `(session, generation, message seq)`.
    ///
    /// **Nothing here is ever cleared except by a delivery that happened.**
    /// Stepping to another reply takes the footer with it and brings it back
    /// on return; losing a written note is worse than a failed send, so no
    /// draft is discarded because the panel re-resolved its agent, changed
    /// session, or had its transcript replaced.
    ///
    /// What those events change is which drafts still *match*. A session
    /// change and a transcript rewrite each mint a new ``ReplyDrafts/Scope``,
    /// so earlier drafts stop resolving rather than reattaching to whichever
    /// reply now occupies their line — a `seq` is a transcript line index and
    /// is unique inside neither. Orphaned and invisible, not destroyed.
    ///
    /// *(This comment previously claimed a rewrite cleared the drafts and
    /// that they were keyed "by the message they are about". Neither was
    /// true: nothing cleared on a rewrite, and the key had moved twice. Found
    /// by a cold review 2026-09-07.)*
    @State private var drafts = ReplyDrafts()

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
        .onChange(of: store.model.viewedGroup?.id) { _ in
            previewText = nil
            previewIsEdited = false
        }
        .task(id: bindingKey) {
            await store.refresh(workspace: workspace)
        }
        .focusable()
        // Arrow keys drive the same two actions the buttons do. `cm-69.1` has
        // no text field to compete with; once notes exist, an editing field
        // takes the keys first.
        .backport.onKeyPress(.leftArrow) { _ in
            guard canStepBack else { return .ignored }
            Task { await store.stepBack() }
            return .handled
        }
        .backport.onKeyPress(.rightArrow) { _ in
            guard canStepForward else { return .ignored }
            store.stepForward()
            return .handled
        }
    }

    /// Whether the reply on screen is the oldest one that can be loaded.
    private var atOldestLoadedReply: Bool {
        guard case let .showing(reading) = store.model.state else { return false }
        return reading.position.index == 1
    }

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
            Text(store.identity ?? String(localized: "rightSidebar.mode.reply", defaultValue: "Reply"))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)

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
                navigation(reading)
            }
        }
        .padding(.horizontal, Self.bodyGutter)
        .frame(height: 26)
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
        Text("\(reading.position.index)/\(reading.position.total)")
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
            activeMarkID: ReplyMarkFocus.id(hovered: hoveredID, editing: editingID)
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
        guard let group = store.model.viewedGroup,
              let scope = store.draftScope else { return ReplyAnnotationSet() }
        return drafts.draft(for: group, in: scope)
    }

    private func updateDraft(_ change: (inout ReplyAnnotationSet) -> Void) {
        guard let group = store.model.viewedGroup,
              let scope = store.draftScope else { return }
        drafts.update(for: group, in: scope, change)
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
                measuredHeight: $noteListHeight,
                onBeginEditing: { beginEditing($0) },
                onRemove: { id in
                    if editingID == id { closeEditing() }
                    updateDraft { $0.remove(id: id) }
                },
                onPreview: {
                    previewText = draft.serialized()
                    previewIsEdited = false
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
    }

    /// How tall the note list may grow before it scrolls.
    private var footerCeiling: CGFloat {
        guard panelHeight > 0 else { return 281 }
        return max(120, min(panelHeight * 0.40, panelHeight - Self.replyFloor))
    }

    /// The height the reply keeps whatever the footer does.
    private static let replyFloor: CGFloat = 394

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
            .onAppear { placeCaretInNoteField() }
            .onChange(of: editingText) { text in
                updateDraft { $0.updateNote(id: entry.id, note: text) }
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

            // Stacked full-width, not side by side: at 256pt a row forced the
            // label "P&Send", which reads as a typo and makes the user decode
            // it. Stacking costs 26pt and buys both full labels.
            Button {
                send(submit: false)
            } label: {
                Text(String(localized: "reply.annotation.paste", defaultValue: "Paste"))
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            // **Paste is never gated** — and now the code says so too. It
            // typed into a composer the user is looking at and submitted
            // nothing, so what goes in there is their call; then it gated on
            // `isDeliverable` anyway, five lines under a comment promising it
            // did not. An unwritten note is not an unfinished action, it is
            // an action the user intends to finish in the terminal.
            //
            // Off only when there is genuinely nothing to put anywhere.
            .disabled(draft.isEmpty)

            Button {
                send(submit: true)
            } label: {
                Text(String(localized: "reply.annotation.pasteAndSend", defaultValue: "Paste & Send"))
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .disabled(!draft.isDeliverable || !store.canSubmit)

            // One refusal, one sentence, and only for the button that is off.
            if draft.isDeliverable, !store.canSubmit {
                footerNote(String(
                    localized: "reply.annotation.turnInFlight",
                    defaultValue: "Paste & Send returns when this turn ends"
                ))
            }
        }
        .padding(.horizontal, Self.bodyGutter)
        .padding(.top, 6)
    }

    // MARK: - The paste preview

    /// Exactly what Paste will send, editable, at the panel's own width.
    private func pastePreview(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                // One-way: nothing parses the edited text back, so returning
                // discards it. Annotations flow out and never return, which
                // is why a mangled preview costs the agent's input and
                // nothing else.
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

            TextEditor(text: Binding(
                get: { text },
                set: { previewText = $0; previewIsEdited = true }
            ))
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
        editingID = entry.id
        editingText = entry.note
        editingOriginal = entry.note
        placeCaretInNoteField()
    }

    /// Puts the caret in the open note field, from a cold start.
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
    private func placeCaretInNoteField() {
        _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
            mode: .reply,
            focusFirstItem: false
        )
        DispatchQueue.main.async { noteFieldFocused = true }
    }

    private func closeEditing() {
        editingID = nil
        editingText = ""
        editingOriginal = ""
    }

    /// Takes a new selection as a mark, refusing one that overlaps another.
    private func takeSelection(_ selection: MarkdownPageSelection) {
        let annotation = ReplyAnnotation(quote: selection.quote, note: "", range: selection.range)
        var accepted = false
        updateDraft { accepted = $0.insert(annotation) }
        // A refused overlap leaves the standing mark alone: an ambiguous
        // quote is fixed by selecting more, never by cmux widening one.
        guard accepted else { return }
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
            .foregroundStyle(.secondary)
            .lineLimit(1)
            // Never squeezed by the identity beside it: this is on screen for
            // two seconds and half of it says nothing.
            .fixedSize()
            .transition(.opacity)
        }
    }

    private func send(submit: Bool) {
        closeEditing()
        // Sends the annotations, never the preview's text: the preview is
        // one-way, and a paste that shipped what was typed into it would
        // make the box a parser after all.
        guard store.deliver(draft, workspace: workspace, submit: submit) else { return }
        // Cleared only on a dispatch that actually happened. A refused send
        // that wiped the notes would lose writing the user cannot get back.
        if let group = store.model.viewedGroup, let scope = store.draftScope {
            drafts.clear(for: group, in: scope)
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
