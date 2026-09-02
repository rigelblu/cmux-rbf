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

    /// How muted an unfinished reply's body is.
    ///
    /// Measured, not chosen: 45% renders at 3.97:1 against the panel fill,
    /// under WCAG AA for body text, and most replies are read *while* they
    /// are being written. 55% measures 5.59:1 and still sits far below a
    /// finished reply's contrast, so it stays legibly unfinished. Do not
    /// lower it without re-measuring.
    private static let writingBodyOpacity: Double = 0.55

    /// Width floor for the position counter, wide enough for `10/15` so the
    /// arrows stop moving once a session runs past nine messages.
    private static let counterMinimumWidth: CGFloat = 34

    /// The panel's inner gutter, shared by the header and the rendered page.
    private static let bodyGutter: Double = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if atOldestLoadedReply, store.model.historyTruncatedAtHead {
                truncatedHistoryNote
            }
            content
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
        case let .showing(reading):
            return reading.isWriting
                ? String(localized: "reply.state.writing", defaultValue: "writing")
                : nil
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
            onRequestPanelFocus: {}
        )
        .opacity(reading.isWriting ? Self.writingBodyOpacity : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The canvas sits directly behind the web view, and it is not
        // decoration. Without it, any moment the page is not painting — a
        // relayout, a window losing key — shows whatever is behind the panel
        // straight through, and it does not necessarily come back. Observed in
        // dogfood as the body turning the sidebar's own lavender and staying
        // there. `MarkdownPanelView` paints the same layer for the same reason.
        .background(Color(nsColor: pageCanvas))
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
