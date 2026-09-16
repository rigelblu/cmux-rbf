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
    private struct BindingTarget: Equatable {
        let workspaceID: UUID
        let panelID: UUID
        let sessionID: String
    }

    private struct BindingHeader {
        let identity: String
        let agentName: String
    }

    /// One source of truth for whether the panel may act on a session.
    ///
    /// A target becomes inactive as soon as a different bind starts. The
    /// outgoing presentation can stay on screen while the replacement is
    /// prepared, but delivery, drafts, paging, tail batches, and wakeups all
    /// key off this state rather than independently mutable ids.
    private enum BindingPhase {
        case unbound
        case binding(BindingTarget, revision: Int, retryPending: Bool)
        case waiting(BindingTarget)
        case unavailable(BindingTarget)
        case bound(BindingTarget, revision: Int)
    }

    private enum RefreshCause {
        case selection
        case sessionsChanged
        case titleChanged
        case turnFinished
        case retry

        var retriesBinding: Bool {
            switch self {
            case .sessionsChanged, .turnFinished, .retry:
                true
            case .selection, .titleChanged:
                false
            }
        }
    }

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
    var boundPanelID: UUID? {
        guard case let .bound(target, _) = bindingPhase else { return nil }
        return target.panelID
    }

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
    var boundSessionID: String? {
        guard case let .bound(target, _) = bindingPhase else { return nil }
        return target.sessionID
    }

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
    /// Written only through ``updateDraft(for:_:)``, ``clearDraft(for:)`` and
    /// ``setTypedPreview(_:for:)``, so that the model's exemption set cannot
    /// drift from the drafts it is derived from — the failure would be
    /// invisible, since both look right on their own. The third skips
    /// ``syncAnnotatedReplies()`` because typed preview text changes neither
    /// the marks nor which replies are annotated (`#cm-90`); it is sent in
    /// their place while the preview is edited (`#cm-93`).
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
    private var bindingPhase: BindingPhase = .unbound
    private var bindingRevision = 0
    private var pendingHeader: BindingHeader?

    private var messages: [ChatMessage] = []
    private let tailerStopper: @MainActor (AgentChatTranscriptTailer) async -> Void
    private let initialHistoryLoader:
        @MainActor (AgentChatTranscriptTailer, Int) async -> ChatHistoryPage

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

    init(
        tailerStopper: @escaping @MainActor (AgentChatTranscriptTailer) async -> Void = {
            await $0.stop()
        },
        initialHistoryLoader: @escaping @MainActor (
            AgentChatTranscriptTailer,
            Int
        ) async -> ChatHistoryPage = { tailer, limit in
            tailer.history(beforeSeq: nil, limit: limit)
        }
    ) {
        self.tailerStopper = tailerStopper
        self.initialHistoryLoader = initialHistoryLoader
    }

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
        await refresh(workspace: workspace, cause: .selection)
    }

    private func refresh(workspace: Workspace?, cause: RefreshCause) async {
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

        let target = BindingTarget(
            workspaceID: workspace.id,
            panelID: panelID,
            sessionID: record.sessionID
        )
        let header = BindingHeader(
            identity: headerIdentity(workspace: workspace, panelID: panelID, record: record),
            agentName: record.agentKind.displayName
        )

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

        switch bindingPhase {
        case let .bound(current, _):
            guard current != target else {
                commit(header: header)
                return
            }
        case let .binding(current, revision, retryPending):
            guard current != target else {
                pendingHeader = header
                if cause.retriesBinding, !retryPending {
                    bindingPhase = .binding(current, revision: revision, retryPending: true)
                }
                return
            }
        case let .waiting(current), let .unavailable(current):
            if current == target, case .titleChanged = cause {
                commit(header: header)
                return
            }
        case .unbound:
            break
        }

        await startTail(target: target, header: header, workspace: workspace)
    }

    private func commit(header: BindingHeader) {
        identity = header.identity
        agentName = header.agentName
    }

    private func currentRecord(for target: BindingTarget) -> AgentChatSessionRecord? {
        guard let registry = TerminalController.shared.agentChatTranscriptService?.registry,
              let record = registry.currentOrMostRecentSession(
                  surfaceID: target.panelID.uuidString
              ),
              record.sessionID == target.sessionID else {
            return nil
        }
        return record
    }

    private func isCurrentBinding(target: BindingTarget, revision: Int) -> Bool {
        guard case let .binding(current, currentRevision, _) = bindingPhase else {
            return false
        }
        return current == target && currentRevision == revision
    }

    private func takeRetryPending(target: BindingTarget, revision: Int) -> Bool {
        guard case let .binding(current, currentRevision, retryPending) = bindingPhase,
              current == target,
              currentRevision == revision,
              retryPending else {
            return false
        }
        bindingPhase = .binding(current, revision: currentRevision, retryPending: false)
        return true
    }

    private func isCurrentBound(target: BindingTarget, revision: Int) -> Bool {
        guard case let .bound(current, currentRevision) = bindingPhase else {
            return false
        }
        return current == target && currentRevision == revision
    }

    private func currentHeader(fallback: BindingHeader) -> BindingHeader {
        pendingHeader ?? fallback
    }

    private func retryCurrentResolution() async {
        guard let workspace = followedWorkspace else {
            await unbind()
            return
        }
        await refresh(workspace: workspace, cause: .sessionsChanged)
    }

    /// Re-opens the transcript after a read failure, for the error state's
    /// `Try again`.
    ///
    /// - Parameter workspace: The selected workspace.
    func retry(workspace: Workspace?) async {
        await refresh(workspace: workspace, cause: .retry)
    }

    /// Stops tailing and forgets the binding.
    func stop() async {
        if let turnFinishedObserver {
            NotificationCenter.default.removeObserver(turnFinishedObserver)
            self.turnFinishedObserver = nil
        }
        bindingRevision &+= 1
        bindingPhase = .unbound
        pendingHeader = nil
        let outgoingTailer = tailer
        tailer = nil
        messages = []
        if let outgoingTailer {
            await tailerStopper(outgoingTailer)
        }
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

    /// Whether the right sidebar stays open after a send — `#cm-91`.
    ///
    /// Per window and memory-only by Tom's call: this store is one per window
    /// and lives only as long as it, so every new window and launch starts
    /// unpinned.
    var isPinned = false

    /// Whether a send should hide the right sidebar — `#cm-91`.
    ///
    /// - Parameter delivered: Whether `deliver` actually dispatched. A refused
    ///   send leaves the user's marks in place, so it leaves the panel too.
    func closesSidebarAfterSend(delivered: Bool) -> Bool {
        delivered && !isPinned
    }

    /// Text typed into `group`'s paste preview, if any — `#cm-90`.
    ///
    /// `nil` unless the displayed model and the active binding agree. During
    /// a workspace switch the outgoing presentation may remain visible, but
    /// the binding is inactive until its replacement commits.
    func typedPreview(for group: ReplyMessageGroup) -> String? {
        guard let scope = draftScope, model.sessionID == boundSessionID else { return nil }
        return drafts.typedPreview(for: group, in: scope)
    }

    /// Keeps what was typed into `group`'s paste preview; `nil` drops it.
    ///
    /// No `syncAnnotatedReplies()`: typed text changes neither the marks nor
    /// which replies are exempt from the cap. It is what `Paste` sends while
    /// the preview is edited (`#cm-93`), but it is never parsed back.
    func setTypedPreview(_ text: String?, for group: ReplyMessageGroup) {
        // Same boundary as ``typedPreview(for:)``: never file outgoing text
        // under a replacement session while that replacement is binding.
        guard let scope = draftScope, model.sessionID == boundSessionID else { return }
        drafts.setTypedPreview(text, for: group, in: scope)
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
        applyConfiguredCap(to: &model)
    }

    private func applyConfiguredCap(to model: inout ReplyPanelModel) {
        model.setMaxMessagesBack(configuredCap())
    }

    private func configuredCap() -> Int {
        UserDefaultsSettingsClient(defaults: .standard)
            .value(for: SettingCatalog().reply.maxMessagesBack)
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
        guard case let .bound(target, revision) = bindingPhase,
              model.hasMoreHistory,
              let tailer,
              let oldestSeq = messages.first?.seq else { return false }
        let page = await tailer.history(beforeSeq: oldestSeq, limit: Self.historyPageLimit)
        guard isCurrentBound(target: target, revision: revision) else { return false }

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
                Task {
                    await self.refresh(
                        workspace: self.followedWorkspace,
                        cause: .sessionsChanged
                    )
                }
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
                Task {
                    await self.refresh(
                        workspace: self.followedWorkspace,
                        cause: .titleChanged
                    )
                }
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
                switch self.bindingPhase {
                case let .bound(target, _):
                    guard target.sessionID == sessionID else { return }
                    self.model.markTurnFinished(sessionID: sessionID)
                case let .binding(target, revision, retryPending):
                    guard target.sessionID == sessionID else { return }
                    if !retryPending {
                        self.bindingPhase = .binding(
                            target,
                            revision: revision,
                            retryPending: true
                        )
                    }
                case let .waiting(target), let .unavailable(target):
                    guard target.sessionID == sessionID else { return }
                    self.model.markTurnFinished(sessionID: sessionID)
                    Task {
                        await self.refresh(
                            workspace: self.followedWorkspace,
                            cause: .turnFinished
                        )
                    }
                case .unbound:
                    Task {
                        await self.refresh(
                            workspace: self.followedWorkspace,
                            cause: .turnFinished
                        )
                    }
                }
            }
        }
    }


    private func unbind() async {
        let revision = bindingRevision &+ 1
        await stop()
        guard case .unbound = bindingPhase, bindingRevision == revision else { return }
        identity = nil
        agentName = nil
        model.unbind()
    }

    private func startTail(
        target: BindingTarget,
        header: BindingHeader,
        workspace: Workspace
    ) async {
        bindingRevision &+= 1
        let revision = bindingRevision
        bindingPhase = .binding(target, revision: revision, retryPending: false)
        pendingHeader = header

        let outgoingTailer = tailer
        tailer = nil
        // `messages` is private and nothing renders it, so clearing it now is
        // invisible — and it must be cleared now, or a batch arriving from
        // the new tailer would append the new agent's lines to the previous
        // agent's. `model` is what the panel draws, so it is deliberately
        // left showing the outgoing agent until the replacement is ready.
        messages = []
        if let outgoingTailer {
            await tailerStopper(outgoingTailer)
        }
        guard isCurrentBinding(target: target, revision: revision) else { return }

        while isCurrentBinding(target: target, revision: revision) {
            // Re-read after stopping the old tailer. A session update can land
            // while that stop is suspended; using the record captured before
            // the await is the race that left workspace B waiting forever.
            guard let record = currentRecord(for: target) else {
                await retryCurrentResolution()
                return
            }

            // No path recorded yet is different from a path that will not
            // open. Both remain inactive so a matching wake can retry them.
            guard let path = record.transcriptPath,
                  FileManager.default.fileExists(atPath: path) else {
                if takeRetryPending(target: target, revision: revision) {
                    continue
                }
                var waiting = ReplyPanelModel()
                waiting.bind(
                    sessionID: target.sessionID,
                    agentIsRunning: agentIsRunning(
                        workspace: workspace,
                        panelID: target.panelID
                    )
                )
                commit(header: currentHeader(fallback: header))
                model = waiting
                pendingHeader = nil
                bindingPhase = .waiting(target)
                return
            }
            guard FileManager.default.isReadableFile(atPath: path) else {
                if takeRetryPending(target: target, revision: revision) {
                    continue
                }
                var unreadable = ReplyPanelModel()
                unreadable.markUnreadable()
                commit(header: currentHeader(fallback: header))
                model = unreadable
                pendingHeader = nil
                bindingPhase = .unavailable(target)
                return
            }

            let candidateTailer = AgentChatTranscriptTailer(
                sessionID: target.sessionID,
                agentKind: record.agentKind,
                path: path
            ) { [weak self] batch in
                await self?.receive(batch: batch, target: target, revision: revision)
            }

            await candidateTailer.start()
            let page = await initialHistoryLoader(candidateTailer, Self.initialHistoryLimit)
            guard isCurrentBinding(target: target, revision: revision) else {
                await tailerStopper(candidateTailer)
                return
            }
            guard currentRecord(for: target)?.transcriptPath == path else {
                await tailerStopper(candidateTailer)
                guard isCurrentBinding(target: target, revision: revision) else { return }
                continue
            }

            var replacement = ReplyPanelModel()
            replacement.load(
                groups: ReplyMessageGroup.groups(from: page.messages),
                hasMoreHistory: page.hasMore,
                sessionID: target.sessionID,
                agentIsRunning: agentIsRunning(
                    workspace: workspace,
                    panelID: target.panelID
                )
            )
            applyConfiguredCap(to: &replacement)

            // Header, body, resources, and active target cross the boundary
            // together, with no suspension point between them.
            commit(header: currentHeader(fallback: header))
            messages = page.messages
            model = replacement
            tailer = candidateTailer
            pendingHeader = nil
            bindingPhase = .bound(target, revision: revision)
            syncAnnotatedReplies()
            return
        }
    }

    private func receive(
        batch: AgentChatTranscriptTailer.Batch,
        target: BindingTarget,
        revision: Int
    ) async {
        guard isCurrentBound(target: target, revision: revision) else { return }

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
                guard isCurrentBound(target: target, revision: revision) else { return }
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
        if batch.appended.contains(where: { $0.role == .user }) {
            model.markTurnStarted(sessionID: target.sessionID)
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
    /// - Parameters:
    ///   - editedText: The paste preview's text once edited, else `nil`. When
    ///     set it is the payload, and the gate reads it instead of the marks
    ///     (`#cm-93`). No default on purpose: a second way to deliver that
    ///     forgot it would send the marks while the box shows other text.
    ///   - submit: `false` leaves it unsent so the user can read it where it
    ///     will run. `true` appends the agent's own submit key.
    /// - Returns: whether anything was dispatched. `false` means the gate
    ///   refused or the bound pane could not be resolved — the draft is kept
    ///   either way, since losing a written note is worse than a failed send.
    @discardableResult
    func deliver(
        _ annotations: ReplyAnnotationSet,
        editedText: String?,
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
                  annotations, editedText: editedText, submit: submit, turnEnded: canSubmit
              ),
              let workspace,
              let panelID = boundPanelID,
              let panel = workspace.panels[panelID] as? TerminalPanel else { return false }

        // `#cm-93`: an edited paste preview is sent as written; otherwise the
        // marks' serialization, which is what an unedited preview shows.
        let payload = editedText ?? annotations.serialized()

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
