import AppKit
import CmuxAgentChat
import CmuxSettings
import Foundation
import Observation

/// Follows one agent in the selected workspace and keeps ``model`` describing
/// what the Reply panel should show.
///
/// Everything about *what shows* lives in ``ReplyPanelModel``, which is a
/// pure value tested in the shared package. What lives here is the wiring
/// the package cannot own: which agent to follow, opening its transcript,
/// and turning file growth into replies.
@MainActor
@Observable
final class ReplyPanelStore {
    /// What the panel should render.
    private(set) var model = ReplyPanelModel()

    /// The name shown at the left of the panel header.
    ///
    /// The bound pane's tab name when it has one, the agent's name
    /// otherwise. In a one-agent workspace "Claude" only repeats what the
    /// user already knows; the tab name says *which work*.
    private(set) var identity: String?

    /// The bound agent's own name, whatever the header ends up showing.
    ///
    /// The waiting state needs it even when the header is showing a tab
    /// name: naming the agent is what tells the user the binding worked and
    /// the silence is the agent's, not cmux's.
    private(set) var agentName: String?

    /// The surface the panel is following, when one is bound.
    ///
    /// Delivery needs it twice over: to find the `TerminalSurface` to type
    /// into, and to read that pane's own lifecycle. Both must be the *bound*
    /// pane rather than the focused one — the binding is sticky, so the user
    /// can be looking elsewhere while the reply they annotated belongs here.
    private(set) var boundPanelID: UUID?

    /// How many transcript lines the initial read takes in.
    ///
    /// Well under the tailer's own 2000-line backfill: replies are what this
    /// panel walks, and a few hundred lines is many more replies than anyone
    /// steps back through in a session.
    private static let initialHistoryLimit = 600

    /// Ceiling on the mirrored transcript window.
    ///
    /// Matches the tailer's own cache bound, so the panel never holds more
    /// than the thing it mirrors. Without it a long session grows this array
    /// for as long as the panel stays open, and every batch re-groups all of
    /// it.
    private static let maxMirroredMessages = 4000

    /// How many older transcript lines one `◄`-triggered page reads.
    private static let historyPageLimit = 300

    /// Readable so the view can scope per-session state to it — `ReplyDrafts`
    /// keys on it, because a `seq` alone is a transcript line index that every
    /// session has. Still store-written only.
    private(set) var boundSessionID: String?

    /// How many times the bound transcript has been replaced under us.
    ///
    /// `--resume` and compaction rewrite the file, and `seq` starts over while
    /// the session id does not — so this is the second half of what makes a
    /// draft anchor unambiguous. `ReplyPanelModel.reset()` drops its own
    /// anchors for the same reason; this lets view-side state do the same
    /// without deleting anything.
    private(set) var transcriptGeneration = 0

    /// Where per-reply state belongs right now, or `nil` when nothing is bound.
    var draftScope: ReplyDrafts.Scope? {
        boundSessionID.map { ReplyDrafts.Scope(session: $0, generation: transcriptGeneration) }
    }

    /// Every reply's unsent marks, keyed by `(session, generation, message seq)`.
    ///
    /// **Moved here from `ReplyPanelView`'s `@State` by `cm-69.6`**, because
    /// the cap has to know which replies carry marks and the view cannot tell
    /// the model anything the model reads while deriving `state`. Held by the
    /// store rather than by ``ReplyPanelModel`` for the reason that type's own
    /// documentation gives: `load()` resets it on every session change, and a
    /// user's unsent writing must not die with a rebind.
    ///
    /// Written only through ``updateDraft(for:_:)`` and ``clearDraft(for:)``,
    /// so that the model's exemption set cannot drift from the drafts it is
    /// derived from — the failure would be invisible, since both look right on
    /// their own.
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
    /// **`cm-69.6` gives that rule a second consequence worth naming:** an
    /// orphaned draft stops exempting its reply from the cap too, because the
    /// exemption is derived from the drafts that resolve in the *current*
    /// scope. That is the right answer — the reply it was written on is no
    /// longer reachable in this conversation — but it means a rewrite can
    /// shorten the walk, which nothing on screen explains.
    private(set) var drafts = ReplyDrafts()
    private var stickyPanelID: UUID?
    private var tailer: AgentChatTranscriptTailer?

    /// Invalidates batches from a tailer the panel has already moved off.
    ///
    /// Stopping a tailer does not unschedule a batch already in flight, so
    /// without this a workspace switch can land the previous agent's replies
    /// in the new agent's panel.
    private var generation = 0

    private var messages: [ChatMessage] = []

    /// Live subscription to agent turn endings.
    ///
    /// `nonisolated(unsafe)` only so `deinit` can release it: a deinit is
    /// nonisolated by language rule, and by the time it runs the last
    /// reference is gone, so nothing else can be touching these.
    nonisolated(unsafe) private var turnFinishedObserver: (any NSObjectProtocol)?

    /// Live subscription to agents appearing and disappearing.
    nonisolated(unsafe) private var sessionsChangedObserver: (any NSObjectProtocol)?

    /// Live subscription to panel renames.
    ///
    /// The header names the tab, so a rename changes what this panel says.
    /// It cannot come from observing the `Workspace`: that publisher fires on
    /// every pane, layout, and lifecycle change it owns, and subscribing to
    /// all of it to catch one string is the kind of over-observation that
    /// re-renders a panel hundreds of times a second.
    nonisolated(unsafe) private var titleChangedObserver: (any NSObjectProtocol)?

    /// The workspace the panel is following.
    ///
    /// Held so a session appearing can re-resolve the binding on its own. The
    /// view drives the ordinary path, but it only re-drives on a workspace or
    /// focus change — neither of which happens when an agent starts in a pane
    /// that is already on screen. Weak: the panel follows the workspace, it
    /// does not keep it alive.
    private weak var followedWorkspace: Workspace?

    // MARK: - Driving
    deinit {
        // The sessions observer deliberately outlives `stop()` — waiting for
        // an agent to appear is exactly the unbound state — so it is only
        // released here.
        if let sessionsChangedObserver {
            NotificationCenter.default.removeObserver(sessionsChangedObserver)
        }
        if let turnFinishedObserver {
            NotificationCenter.default.removeObserver(turnFinishedObserver)
        }
        if let titleChangedObserver {
            NotificationCenter.default.removeObserver(titleChangedObserver)
        }
    }


    /// Re-resolves which agent to follow and starts tailing it.
    ///
    /// Safe to call on every workspace change, focus change, and appearance:
    /// resolving to the same session is a no-op, so the tail is not torn down
    /// and rebuilt on unrelated churn.
    ///
    /// - Parameter workspace: The selected workspace, or `nil` when none is.
    func refresh(workspace: Workspace?) async {
        followedWorkspace = workspace
        observeSessionChanges()
        observeTitleChanges()
        guard let workspace,
              let registry = TerminalController.shared.agentChatTranscriptService?.registry,
              let panelID = resolveAgentPanelID(in: workspace, registry: registry),
              let record = registry.currentOrMostRecentSession(surfaceID: panelID.uuidString) else {
            await unbind()
            return
        }
        // After the guard: with no agent bound there is no turn whose ending
        // means anything here, and subscribing first would add and remove the
        // observer on every refresh of an agentless workspace.
        observeTurnEndings()

        identity = headerIdentity(workspace: workspace, panelID: panelID, record: record)
        agentName = record.agentKind.displayName
        boundPanelID = panelID

        // Before the early return, not after it. `applyConfiguredCap` used to
        // sit only in the bind path below, which made the setting reachable
        // ONLY by binding a *different* session — so editing
        // `reply.maxMessagesBack` and switching workspaces back and forth did
        // nothing, and an app relaunch was the only way to pick it up. The
        // comment on that call claimed the opposite. Found while staging a
        // dogfood scenario, not by any test: `ReplyMaxMessagesBackConfigTests`
        // exercises the parser, and a parser that works is not a panel that
        // reads it.
        applyConfiguredCap()

        guard record.sessionID != boundSessionID else {
            // Already following this session. Only the header can have moved
            // — a tab rename, or the pane picking up a title.
            return
        }

        await startTail(record: record, panelID: panelID, workspace: workspace)
    }

    /// Re-opens the transcript after a read failure, for the error state's
    /// `Try again`.
    ///
    /// - Parameter workspace: The selected workspace.
    func retry(workspace: Workspace?) async {
        boundSessionID = nil
        await refresh(workspace: workspace)
    }

    /// Stops tailing and forgets the binding.
    func stop() async {
        if let turnFinishedObserver {
            NotificationCenter.default.removeObserver(turnFinishedObserver)
            self.turnFinishedObserver = nil
        }
        generation &+= 1
        await tailer?.stop()
        tailer = nil
        boundSessionID = nil
        messages = []
    }

    // MARK: - Binding
    /// Steps to the next older reply, paging one in when none is loaded.
    ///
    /// The model reports whether it moved, so this asks first and only pays
    /// for a page read when the walk actually ran out.
    func stepBack() async {
        // Asked before anything else, and this guard is the slice's whole
        // point at this layer. `model.stepBack()` returns false for two
        // different reasons — nothing older is loaded, or the cap is spent —
        // and the line below reads the first as licence to page. Without this
        // guard a press at the cap reads a 300-line page off disk, which is
        // exactly the behaviour the cap exists to prevent.
        guard model.canStepBack else { return }
        if model.stepBack() { return }
        guard await pageOlderHistory() else { return }
        model.stepBack()
    }

    /// Edits the marks on `group`, then re-derives the model's exemption set.
    ///
    /// One path in and out, so *which replies are annotated* is answered by
    /// the drafts themselves rather than by a second copy that can fall behind.
    func updateDraft(
        for group: ReplyMessageGroup,
        _ change: (inout ReplyAnnotationSet) -> Void
    ) {
        guard let scope = draftScope else { return }
        drafts.update(for: group, in: scope, change)
        syncAnnotatedReplies()
    }

    /// Drops the marks on `group` after a delivery that actually happened.
    func clearDraft(for group: ReplyMessageGroup) {
        guard let scope = draftScope else { return }
        drafts.clear(for: group, in: scope)
        syncAnnotatedReplies()
    }

    /// The marks written on `group`, or an empty set.
    func draft(for group: ReplyMessageGroup) -> ReplyAnnotationSet {
        guard let scope = draftScope else { return ReplyAnnotationSet() }
        return drafts.draft(for: group, in: scope)
    }

    /// Pushes the annotated replies into the model.
    ///
    /// Called after every draft edit and after every path that resets the
    /// model — `load` and `reset` both clear the set deliberately, so a reply
    /// keeps its exemption only while a draft in the *current* scope still
    /// resolves to it.
    private func syncAnnotatedReplies() {
        model.noteAnnotated(seqs: draftScope.map { drafts.annotatedSeqs(in: $0) } ?? [])
    }

    /// Reads `reply.maxMessagesBack` into the model.
    ///
    /// **This is the surface that makes the setting exist.** The catalog
    /// entry, the schema, the template and twenty locales all describe a key;
    /// only a consumer makes it do anything, and `#cm-67`'s v0.25.1 shipped a
    /// setting that had every one of those and no consumer, under 149 passing
    /// assertions.
    ///
    /// Read on every **refresh** rather than once at construction, so editing
    /// `cmux.json` takes effect on the next workspace switch instead of
    /// needing a relaunch. *(It was on every bind until 2026-09-08, which is
    /// not the same thing: `refresh` returns early when the session is
    /// unchanged, so the only way to pick up an edited value was to bind a
    /// different session — an app relaunch, in practice. The doc comment said
    /// "workspace switch" the whole time.)* The file store publishes into
    /// `UserDefaults`, and
    /// `UserDefaultsSettingsClient` falls back to the catalog default for an
    /// absent or unusable value — which is where `0`, a negative and
    /// `"five"` all land, because the parser refuses to store them at all.
    private func applyConfiguredCap() {
        model.setMaxMessagesBack(
            UserDefaultsSettingsClient(defaults: .standard)
                .value(for: SettingCatalog().reply.maxMessagesBack)
        )
    }

    /// Steps to the next newer reply.
    func stepForward() {
        model.stepForward()
    }

    /// Returns to the newest reply and resumes following it.
    func returnToNewest() {
        model.returnToNewest()
    }

    /// Reads one page of replies older than the loaded window.
    ///
    /// - Returns: `true` when the window grew, so a step is now possible.
    private func pageOlderHistory() async -> Bool {
        guard model.hasMoreHistory,
              let tailer,
              let oldestSeq = messages.first?.seq else { return false }
        let generation = generation
        let page = await tailer.history(beforeSeq: oldestSeq, limit: Self.historyPageLimit)
        guard generation == self.generation else { return false }

        guard !page.messages.isEmpty else {
            // An empty page still carrying `hasMore` is the tailer saying
            // "older transcript exists, and I will never serve it" — its
            // backfill is bounded. Re-noting `hasMore` here left `◄` lit
            // forever, re-reading the same empty page on every press.
            if page.hasMore {
                model.noteHistoryTruncatedAtHead()
            } else {
                model.noteHistory(hasMore: false)
            }
            return false
        }
        model.noteHistory(hasMore: page.hasMore)

        // No trim here. Pages come out of the tailer's own cache, which is
        // bounded, so paging cannot grow this past the thing it mirrors —
        // and trimming the newest to make room would drop the real newest
        // reply, leaving an older one wearing its "still writing" treatment.
        messages.insert(contentsOf: page.messages, at: 0)
        model.apply(groups: ReplyMessageGroup.groups(from: messages))
        return true
    }

    /// Starts listening for agents appearing and disappearing, once.
    ///
    /// Subscribed even with nothing bound — that is the case it exists for.
    private func observeSessionChanges() {
        guard sessionsChangedObserver == nil else { return }
        sessionsChangedObserver = NotificationCenter.default.addObserver(
            forName: .agentChatSessionsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refresh(workspace: self.followedWorkspace) }
            }
        }
    }

    /// Starts listening for panel renames, once.
    ///
    /// Subscribed even with nothing bound, for the same reason the sessions
    /// observer is: the subscription outlives any one binding, and adding and
    /// removing it per rebind is more moving parts than leaving it up.
    ///
    /// It re-runs the whole refresh rather than recomputing the header alone.
    /// `refresh` already returns early when the bound session has not changed,
    /// so the extra cost is one dictionary lookup, and having one path that
    /// resolves the header means the two cannot drift.
    private func observeTitleChanges() {
        guard titleChangedObserver == nil else { return }
        titleChangedObserver = NotificationCenter.default.addObserver(
            forName: .panelCustomTitleDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refresh(workspace: self.followedWorkspace) }
            }
        }
    }

    /// Starts listening for agent turn endings, once.
    ///
    /// The panel subscribes to *every* session's turn ending and lets the
    /// model discard the ones that are not its own. Filtering here instead
    /// would mean re-subscribing on every rebind, and a rebind that raced a
    /// Stop could miss it — the model already knows which session it follows,
    /// and that check is tested.
    private func observeTurnEndings() {
        guard turnFinishedObserver == nil else { return }
        turnFinishedObserver = NotificationCenter.default.addObserver(
            forName: .agentChatSessionTurnDidFinish,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let sessionID = notification
                .userInfo?[AgentChatTurnFinishedKeys.sessionID] as? String else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.markTurnFinished(sessionID: sessionID)

                // Nothing bound means `startTail` found no transcript to open
                // — the agent had not written one yet. The only other retry is
                // `agentChatSessionsDidChange`, which fires on session start,
                // first prompt and session end, so it races the file's
                // creation and does not come back. Losing that race left the
                // panel on "Waiting for the first message" through a whole
                // completed turn.
                //
                // A turn ending is the one moment content is certain to exist,
                // so it is the honest retry point. Cheap, too: this only runs
                // while unbound, never on the ordinary per-turn path.
                guard self.boundSessionID == nil else { return }
                Task { await self.refresh(workspace: self.followedWorkspace) }
            }
        }
    }


    private func unbind() async {
        await stop()
        identity = nil
        agentName = nil
        boundPanelID = nil
        model.unbind()
    }

    private func startTail(
        record: AgentChatSessionRecord,
        panelID: UUID,
        workspace: Workspace
    ) async {
        generation &+= 1
        let generation = generation
        await tailer?.stop()
        tailer = nil
        // `messages` is private and nothing renders it, so clearing it now is
        // invisible — and it must be cleared now, or a batch arriving from
        // the new tailer would append the new agent's lines to the previous
        // agent's. `model` is what the panel draws, so it is deliberately
        // left showing the outgoing agent until the replacement is ready.
        messages = []

        // No path recorded yet is a different fact from a path that will not
        // open, and folding them together put a false sentence on the most
        // common path in the feature. The session-start hook carries no
        // transcript path — the record is created with `nil`
        // (`CLI/cmux.swift:667`) and the path arrives with the first prompt —
        // so every brand-new agent read as "Its transcript moved". Nothing had
        // moved, and `waiting` was left unreachable in practice despite being
        // written for exactly this.
        //
        // Both branches deliberately leave `boundSessionID` nil, so the next
        // refresh retries rather than short-circuiting on "already following
        // this session" (see the note above the claim below).
        guard let path = record.transcriptPath,
              FileManager.default.fileExists(atPath: path) else {
            // No file yet. Claude's session-start hook records a well-formed
            // path *before* creating anything at it — measured in
            // `~/.cmuxterm/claude-hook-sessions.json`, where a fresh session
            // reads `transcriptPath: <path>, exists: false` — so this is the
            // ordinary state of every new agent, not a fault.
            //
            // Built whole and assigned once, for the same reason as the
            // success path below.
            var waiting = ReplyPanelModel()
            waiting.bind(
                sessionID: record.sessionID,
                agentIsRunning: agentIsRunning(workspace: workspace, panelID: panelID)
            )
            model = waiting
            return
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            // The file is there and will not open — a permissions or media
            // fault, which is a real thing to report rather than silence to
            // wait through.
            var unreadable = ReplyPanelModel()
            unreadable.markUnreadable()
            model = unreadable
            return
        }

        // Claimed only once the transcript actually opened. Claiming it
        // above the guard wedged the panel: `refresh` returns early on
        // "already following this session", so a failed open was never
        // retried and the error screen's own instruction — send the agent a
        // message and the panel reconnects — could not work. A failed open
        // must leave nothing bound for the next refresh to short-circuit on.
        boundSessionID = record.sessionID

        let tailer = AgentChatTranscriptTailer(
            sessionID: record.sessionID,
            agentKind: record.agentKind,
            path: path
        ) { [weak self] batch in
            await self?.receive(batch: batch, generation: generation)
        }
        self.tailer = tailer

        await tailer.start()
        let page = await tailer.history(beforeSeq: nil, limit: Self.initialHistoryLimit)
        guard generation == self.generation else { return }

        // One mutation. Reset-then-fill here is what made the panel flash its
        // empty state on every pane switch: the three awaits above each yield
        // the main actor, and SwiftUI renders whatever the model holds at
        // that moment.
        messages = page.messages
        model.load(
            groups: ReplyMessageGroup.groups(from: page.messages),
            hasMoreHistory: page.hasMore,
            sessionID: record.sessionID,
            agentIsRunning: agentIsRunning(workspace: workspace, panelID: panelID)
        )
        // Also here, because `load` resets the model — `load` carries the cap
        // across its own reset, but this keeps the two paths from depending on
        // that subtlety to agree.
        applyConfiguredCap()
        // `load` clears the model's exemption set, and `boundSessionID` has
        // only just become this session — so the scope resolves here and not
        // a line earlier. Drafts written against a different session or an
        // earlier generation simply do not match, which is the intent.
        syncAnnotatedReplies()
    }

    private func receive(batch: AgentChatTranscriptTailer.Batch, generation: Int) async {
        guard generation == self.generation else { return }

        if batch.didReset {
            messages = []
            model.reset()
            // The file was replaced, so `seq` starts over. Anything keyed by
            // it has to stop matching or it follows a line number into a
            // different conversation — the same hazard `model.reset()` guards
            // for its own anchors. *(Said "one layer up in the view" until
            // `cm-69.6`; the drafts live in this type now.)*
            transcriptGeneration += 1
            // A no-op today, since the new generation resolves no drafts. Kept
            // so "the model's exemption set equals the drafts in the current
            // scope" holds by construction on every path, rather than holding
            // here by coincidence and breaking the first time it does not.
            syncAnnotatedReplies()
            // The reset batch is empty because nothing was *appended* — but
            // the tailer has already re-read the replacement file into its
            // cache before emitting it. Dropping the old messages and
            // stopping here left the panel claiming "Nothing has been
            // written this session" with the whole conversation sitting one
            // call away, after every `--resume` and every compaction.
            if let tailer {
                let page = await tailer.history(
                    beforeSeq: nil,
                    limit: Self.initialHistoryLimit
                )
                guard generation == self.generation else { return }
                messages = page.messages
                model.apply(groups: ReplyMessageGroup.groups(from: messages))
                model.noteHistory(hasMore: page.hasMore)
            }
        }

        if !batch.updated.isEmpty {
            let replacements = Dictionary(
                batch.updated.map { ($0.id, $0) },
                uniquingKeysWith: { _, newer in newer }
            )
            messages = messages.map { replacements[$0.id] ?? $0 }
        }
        messages.append(contentsOf: batch.appended)
        if messages.count > Self.maxMirroredMessages {
            messages.removeFirst(messages.count - Self.maxMirroredMessages)
        }

        // A user message is the only thing that separates a finished turn's
        // late tail from the next turn's opening line. Both arrive as "a new
        // group after a Stop", so without this the model has to guess, and
        // either guess strands a reply wearing the wrong state. Told before
        // the groups are applied, so a batch carrying the prompt and the
        // first reply together resolves in the right order.
        if let boundSessionID, batch.appended.contains(where: { $0.role == .user }) {
            model.markTurnStarted(sessionID: boundSessionID)
        }

        model.apply(groups: ReplyMessageGroup.groups(from: messages))
    }

    // MARK: - Which agent

    /// Picks the agent pane the panel follows.
    ///
    /// Sticky to the last agent pane that held focus: focusing a browser or
    /// an editor must not blank the panel, and later must not swap it out
    /// from under a note being written. Recency is deliberately not a tie
    /// break — `lastActivityAt` is bumped by every pre- and post-tool hook,
    /// so the busier agent would keep stealing the panel.
    ///
    /// Before any agent pane has held focus there is nothing sticky to
    /// honour, so a live session wins and ties fall to a stable id order.
    /// Arbitrary, but never moving; the explicit picker is a later slice.
    private func resolveAgentPanelID(
        in workspace: Workspace,
        registry: AgentChatSessionRegistry
    ) -> UUID? {
        let agentPanelIDs = workspace.panels.keys.filter { panelID in
            registry.currentOrMostRecentSession(surfaceID: panelID.uuidString) != nil
        }
        guard !agentPanelIDs.isEmpty else {
            stickyPanelID = nil
            return nil
        }

        if let focused = workspace.focusedPanelId, agentPanelIDs.contains(focused) {
            stickyPanelID = focused
        }
        if let sticky = stickyPanelID, agentPanelIDs.contains(sticky) {
            return sticky
        }

        let live = agentPanelIDs.filter { panelID in
            registry.liveSession(surfaceID: panelID.uuidString) != nil
        }
        let candidates = live.isEmpty ? agentPanelIDs : live
        let resolved = candidates.min { $0.uuidString < $1.uuidString }
        stickyPanelID = resolved
        return resolved
    }

    /// Whether `Paste & Send` may fire right now — **the turn gate**.
    ///
    /// It is the only gate in this feature. `Paste` has none: it types into
    /// a composer the user is looking at and submits nothing, so what goes
    /// in there is the user's call, not cmux's. That includes notes about a
    /// reply ten turns back, and notes written before the agent restarted —
    /// carrying feedback forward is a thing to want, not a mistake to
    /// prevent (Tom, 2026-09-05, superseding the "target guard refuses both
    /// buttons" rule).
    ///
    /// **Reads `isNewestTurnWriting`, never the lifecycle map.** `needsInput`
    /// is both Claude's resting state and its blocking state, arriving
    /// through the same key with the same value (`CLI/cmux.swift:25252` and
    /// `:25524`), so a lifecycle gate refuses the agent's resting state —
    /// exactly when pasting is the point.
    ///
    /// Asked of the **newest** turn, whatever reply is on screen: an older
    /// reply is a deliberate target, and annotating it says nothing about
    /// whether the agent is free to receive a submit.
    var canSubmit: Bool {
        !model.isNewestTurnWriting
    }

    /// Types the serialized feedback into the bound pane's composer.
    ///
    /// - Parameter submit: `false` leaves it unsent so the user can read it
    ///   where it will run. `true` appends the agent's own submit key.
    /// - Returns: whether anything was dispatched. `false` means the gate
    ///   refused or the bound pane could not be resolved — the draft is kept
    ///   either way, since losing a written note is worse than a failed send.
    @discardableResult
    func deliver(
        _ annotations: ReplyAnnotationSet,
        workspace: Workspace?,
        submit: Bool
    ) -> Bool {
        // **The second half of "Paste is never gated", and it was still
        // gating.** The button's `.disabled` was fixed 2026-09-06; this guard
        // sat three lines above a comment saying a paste is never refused and
        // refused it anyway, so pressing an enabled `Paste` with no note
        // typed nothing and left the clipboard untouched (Tom, dogfood).
        //
        // Two entrypoints, one rule — and it now lives in one place rather
        // than being restated here. The previous fix realigned the two copies
        // and deleted the predicate they shared, so the shape that caused the
        // defect outlived the fix for it and a cold review found the rule
        // written twice again a day later (2026-09-07).
        guard ReplyDeliveryGate.canDeliver(
                  annotations, submit: submit, turnEnded: canSubmit
              ),
              let workspace,
              let panelID = boundPanelID,
              let panel = workspace.panels[panelID] as? TerminalPanel else { return false }

        let payload = annotations.serialized()

        // **Also on the clipboard, every time.** Claude Code collapses a long
        // paste to `[Pasted text #1 +4 lines]`, so the composer stops being a
        // place you can read what is about to run — which is the entire
        // reason `Paste` does not submit. We cannot detect that: cmux types
        // into a PTY and how the TUI renders those bytes is invisible from
        // here. The clipboard is the one channel that does not depend on
        // knowing.
        //
        // **The cost, accepted:** this replaces whatever was on the
        // clipboard. Paste is a deliberate click on a list the user just
        // wrote, so the surprise is small and the recovery — seeing what was
        // actually sent — is the thing they came for.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)

        let events = TextBoxSubmit.dispatchEvents(
            for: [.text(payload)],
            terminalAgentContext: WorkspaceContentView.terminalAgentContext(
                panel: panel,
                workspace: workspace
            ),
            submit: submit
        )
        TextBoxSubmit.sendEvents(events, via: panel.surface)
        return true
    }

    private func agentIsRunning(workspace: Workspace, panelID: UUID) -> Bool {
        (workspace.agentLifecycleStatesByPanelId[panelID] ?? [:])
            .contains { key, state in
                !AgentHibernationLifecycleStatusKeys.isManualKey(key) && state == .running
            }
    }

    private func headerIdentity(
        workspace: Workspace,
        panelID: UUID,
        record: AgentChatSessionRecord
    ) -> String {
        let custom = workspace.panelCustomTitles[panelID]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let custom, !custom.isEmpty { return custom }
        return record.agentKind.displayName
    }
}
