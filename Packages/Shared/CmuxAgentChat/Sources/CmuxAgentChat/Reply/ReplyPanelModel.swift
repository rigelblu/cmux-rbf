import Foundation

/// Whether the Reply panel has an agent to read, and whether it can read it.
public enum ReplyPanelBinding: Sendable, Equatable {
    /// No agent surface in the selected workspace.
    case noAgent

    /// A session resolved and its transcript is being tailed.
    case bound

    /// A session resolved but its transcript could not be opened.
    case unreadable
}

/// The Reply panel's whole state, as a value.
///
/// Every rule the design settled about *what shows* lives here rather than
/// in the view, so each one can be tested by calling a function instead of
/// by driving a window. The view's job is to render ``state`` and to report
/// events back in.
public struct ReplyPanelModel: Sendable, Equatable {
    /// Whether an agent is bound, and readable.
    public private(set) var binding: ReplyPanelBinding

    /// The session's replies, oldest first.
    public private(set) var groups: [ReplyMessageGroup]

    /// Transcript position of a message inside the reply the user stepped to,
    /// or `nil` while following the newest.
    ///
    /// **A `seq`, not a group id, and that is load-bearing.** A turn is
    /// delimited by the prompt in front of it, and the window is bounded
    /// (600 / 300 / 4000) with nothing aligning it to turn boundaries — so
    /// the oldest loaded turn routinely starts mid-answer and is named after
    /// whichever response was visible. Paging the prompt in completes the
    /// turn and renames it. Pinning by id then failed to resolve and fell
    /// back to the newest, so pressing `◄` at the oldest reply threw the
    /// reader to the front of the conversation. A message's `seq` is fixed
    /// for the life of the transcript, and prepending, appending and
    /// trimming all leave the anchor inside the same turn.
    private var viewedAnchorSeq: Int?

    /// Transcript position of a message inside the newest reply known to be
    /// finished. Same anchoring rule, and for the same reason: pinned by id,
    /// a settled reply flipped back to `writing` when older history arrived.
    private var finishedAnchorSeq: Int?

    /// Which reply the user stepped to, or `nil` while following the newest.
    ///
    /// `nil` is not "none selected" — it is the *following* state, and it is
    /// what makes a newly arrived reply appear without asking. Stepping back
    /// pins a reply and stops the following; stepping forward to the newest
    /// clears it and resumes.
    public var viewedGroupID: String? { groupID(holding: viewedAnchorSeq) }

    /// Id of the newest reply known to be finished.
    ///
    /// One field rather than two, because the two ways a reply can be known
    /// finished answer the same question. At bind time the agent's lifecycle
    /// answers it (nothing running means nothing left to write); afterwards
    /// the session's Stop event does. Either way the answer is "this reply is
    /// done", and a newer reply arriving makes it stale — which is exactly
    /// the behaviour wanted, since a new reply is by definition unfinished.
    public var finishedGroupID: String? { groupID(holding: finishedAnchorSeq) }

    /// Resolves an anchor to whichever loaded reply currently holds it.
    ///
    /// `nil` when nothing is anchored, and also when the anchored message has
    /// been evicted — a pin that no longer names a loaded reply is exactly a
    /// pin that should stop holding.
    private func groupID(holding seq: Int?) -> String? {
        group(holding: seq)?.id
    }

    /// Resolves an anchor to the loaded reply that currently holds it.
    ///
    /// Searched from the newest end. A `seq` belongs to exactly one reply, so
    /// direction cannot change the answer — but the anchors in play are the
    /// reply being read and the newest settled one, both near the end of a
    /// window holding up to 4000 messages.
    private func group(holding seq: Int?) -> ReplyMessageGroup? {
        guard let seq else { return nil }
        return groups.last { $0.messages.contains { $0.seq == seq } }
    }

    /// The anchor to remember a reply by.
    ///
    /// Its *last* message: the window trims from the front, so the last
    /// message is the last of a reply to be evicted.
    private static func anchor(of group: ReplyMessageGroup?) -> Int? {
        group?.messages.last?.seq
    }

    /// Whether a cold-open settle is still owed to the first replies to load.
    ///
    /// Binding and loading race: the panel binds before it has read a line,
    /// so the lifecycle answer arrives with nothing to apply it to. This
    /// holds that answer until there is. It is consumed once and never
    /// refilled, because the lifecycle describes the reply that existed at
    /// bind — a reply written afterwards has its own Stop event coming, and
    /// re-applying the bind answer to it would settle a reply mid-write.
    private var owesBindSettle: Bool

    /// Whether a Stop has been seen whose own reply may not have landed yet.
    ///
    /// The Stop hook is a process spawn and a socket round trip; the
    /// transcript's watcher throttles at 200ms. So a turn's last prose can
    /// arrive *after* the Stop that ended it, and settling "whatever is
    /// newest right now" marks the previous reply while the real one is
    /// still in flight — leaving the panel permanently one turn behind, a
    /// finished reply muted and captioned as writing.
    ///
    /// So the Stop answer stays owed and keeps moving forward onto each
    /// newer reply, until a new turn starts and closes the window. Unlike
    /// `owesBindSettle` this is not consumed on first use: one turn can land
    /// several replies late.
    private var owesStopSettle: Bool = false

    /// How many **un-annotated** replies `◄` may walk back through.
    ///
    /// Read from `reply.maxMessagesBack` in `cmux.json`, defaulting to
    /// ``defaultMaxMessagesBack``. The panel is for the replies you would
    /// actually correct, and the newest 600 transcript lines group into
    /// roughly 11–25 of them — nobody reviews the 25th.
    ///
    /// **A setting, not session state**, which is why ``load(groups:hasMoreHistory:sessionID:agentIsRunning:)``
    /// carries it across the reset it performs. Letting it fall back to the
    /// default there would silently revert a configured cap on every session
    /// change, and nothing on screen would say so.
    public private(set) var maxMessagesBack: Int = ReplyPanelModel.defaultMaxMessagesBack

    /// The cap applied when `cmux.json` names none, or names an unusable one.
    public static let defaultMaxMessagesBack = 5

    /// Transcript positions of messages inside replies carrying unsent marks.
    ///
    /// Pushed in by the store, because the drafts themselves deliberately live
    /// outside this type: ``load(groups:hasMoreHistory:sessionID:agentIsRunning:)``
    /// resets the model on every session change, and holding a user's unsent
    /// writing behind that would destroy it.
    ///
    /// Message `seq`s rather than group ids, for the reason every other anchor
    /// here is: a group's id and `seq` are both its *first message's*, and
    /// paging a prompt in renames the group without moving any message.
    private var annotatedSeqs: Set<Int> = []

    /// Whether older replies exist on disk beyond the ones loaded.
    ///
    /// Answered by the transcript's own paging, which is honest about a
    /// backfill that skipped a long head — so reaching the first loaded reply
    /// is not the same as reaching the start of the conversation.
    public private(set) var hasMoreHistory: Bool = false

    /// Whether the conversation continues past the oldest reply that can ever
    /// be loaded.
    ///
    /// Distinct from `hasMoreHistory`, which answers "is there more to page
    /// in". The tailer backfills a bounded window and then keeps answering
    /// `hasMore: true` for as long as older transcript exists on disk — true,
    /// and useless as a paging signal, because it will never serve it. Kept
    /// apart so `◄` can stop while the panel can still say the rest is on
    /// disk rather than pretending the conversation starts here.
    public private(set) var historyTruncatedAtHead: Bool = false

    /// The session this panel is bound to, when it is bound to one.
    ///
    /// Held here rather than only in the app layer so the rule that a turn
    /// ending elsewhere must not settle *this* panel is enforced where it can
    /// be tested by calling a function.
    public private(set) var sessionID: String?

    /// Creates an unbound model.
    public init() {
        self.binding = .noAgent
        self.groups = []
        self.viewedAnchorSeq = nil
        self.finishedAnchorSeq = nil
        self.owesBindSettle = false
        self.sessionID = nil
    }

    // MARK: - Derived state

    /// The newest reply, or `nil` when none has been loaded.
    public var newestGroup: ReplyMessageGroup? { groups.last }

    /// The reply the panel is showing.
    ///
    /// The pinned one when the user has stepped back and it is still
    /// loaded, otherwise the newest. A pin that no longer resolves falls
    /// back rather than showing nothing: the reply it named is gone, and an
    /// empty panel would be a worse answer than the newest reply.
    public var viewedGroup: ReplyMessageGroup? {
        guard viewedAnchorSeq != nil else { return newestGroup }
        return group(holding: viewedAnchorSeq) ?? newestGroup
    }

    // MARK: - How far `◄` reaches

    /// Whether the reply `k` back from the newest carries unsent marks.
    ///
    /// An index outside the loaded window answers `false`: an unloaded reply
    /// cannot hold a draft, so it spends budget like any other.
    private func isAnnotated(reverseIndex k: Int) -> Bool {
        guard k >= 0, k < groups.count else { return false }
        return groups[groups.count - 1 - k].messages.contains { annotatedSeqs.contains($0.seq) }
    }

    /// How far back the oldest loaded annotated reply sits, or `nil`.
    private var oldestAnnotatedReverseIndex: Int? {
        guard !groups.isEmpty else { return nil }
        for k in stride(from: groups.count - 1, through: 0, by: -1) where isAnnotated(reverseIndex: k) {
            return k
        }
        return nil
    }

    /// Un-annotated replies among the newest `k + 1`, counting unloaded ones.
    private func unannotatedCount(through k: Int) -> Int {
        guard k >= 0 else { return 0 }
        return (0...k).reduce(0) { $0 + (isAnnotated(reverseIndex: $1) ? 0 : 1) }
    }

    /// Whether the walk may step from `k` back from the newest to `k + 1`.
    ///
    /// Three clauses, and the middle one is the one that is easy to leave out:
    ///
    /// 1. the next reply is annotated — an annotated reply is always reachable;
    /// 2. an annotated reply sits **older** than the next one;
    /// 3. the un-annotated replies through the next one fit the budget.
    ///
    /// **Clause 2 is what makes the guarantee true by walking rather than by
    /// teleporting.** Without it the reachable set is non-contiguous: a mark
    /// seven back stays "reachable" while the un-annotated sixth is not, so
    /// `◄` would have to skip a reply to get there — or the anti-strand
    /// promise silently fails and a note ages out of reach, which this feature
    /// ranks as the worst outcome it can produce.
    ///
    /// Nothing here consults ``hasMoreHistory``: the budget outranks it, which
    /// is the whole point of the cap. `cm-69.1` offered `◄` whenever an older
    /// reply was loaded *or* still on disk, and that rule would otherwise win
    /// by default and page history in at the cap.
    private func mayStepBack(from k: Int) -> Bool {
        let next = k + 1
        if isAnnotated(reverseIndex: next) { return true }
        if let oldest = oldestAnnotatedReverseIndex, oldest > next { return true }
        return unannotatedCount(through: next) <= maxMessagesBack
    }

    /// How many replies `◄` can reach, counting the one on screen.
    ///
    /// The `N` of `n of N`, and it is the **reachable** count rather than the
    /// loaded one — so the exemption lets it exceed ``maxMessagesBack``, and
    /// the configured number is only what shows when nothing is marked.
    ///
    /// Counts loaded replies only. A reply still on disk is reachable in the
    /// sense that `◄` will page it in, but it cannot be numbered before it
    /// arrives.
    public var reachableCount: Int {
        guard !groups.isEmpty else { return 0 }
        var k = 0
        while k + 1 < groups.count, mayStepBack(from: k) { k += 1 }
        return k + 1
    }

    /// Whether `◄` is offered at all.
    ///
    /// The same answer ``state`` publishes, reachable without unwrapping the
    /// enum — because a caller that has to destructure `.showing` to ask will
    /// eventually just not ask. `ReplyPanelStore.stepBack` is that caller: it
    /// pages older history whenever a step is refused, and at the cap that is
    /// precisely the behaviour the cap exists to prevent.
    public var canStepBack: Bool {
        guard case let .showing(reading) = state else { return false }
        return reading.canStepBack
    }

    /// Records which replies currently carry unsent marks.
    ///
    /// - Parameter seqs: Message `seq`s from inside every annotated reply.
    public mutating func noteAnnotated(seqs: Set<Int>) {
        annotatedSeqs = seqs
    }

    /// Sets how many un-annotated replies `◄` may walk back through.
    ///
    /// Clamped at 1 rather than trusted: `0` would leave the newest reply as
    /// the only reachable one and `◄` permanently dead, which reads as a
    /// broken panel rather than as a configured one. A caller with a bad value
    /// should fall back to ``defaultMaxMessagesBack`` before reaching here;
    /// this clamp is the second line, not the first.
    ///
    /// - Parameter limit: The configured cap.
    public mutating func setMaxMessagesBack(_ limit: Int) {
        maxMessagesBack = max(1, limit)
    }

    /// What the panel should render.
    ///
    /// Order matters. Nothing bound outranks everything, because there is
    /// no session to say anything else about. A read fault outranks silence,
    /// because "waiting for the first reply" would be a lie about a
    /// transcript that cannot be opened.
    public var state: ReplyPanelState {
        switch binding {
        case .noAgent:
            return .noAgent
        case .unreadable:
            return .unavailable
        case .bound:
            break
        }
        guard let group = viewedGroup,
              let index = groups.firstIndex(where: { $0.id == group.id }) else {
            return .waiting
        }
        // Counted back from the newest, so the newest reply reads `1 of N`.
        // `cm-69.1` counted from the oldest *loaded*, which was meaningful
        // only while the oldest loaded reply was the conversation's start —
        // a place the user can point at. The cap replaces that anchor with
        // "wherever five back happens to be", which nobody can point at, so
        // the number is re-based onto the question the panel actually raises.
        let reverseIndex = groups.count - 1 - index
        return .showing(
            ReplyPanelReading(
                group: group,
                isWriting: isWriting(group),
                // `n > N` is a real state, not a bug to renormalise: a reply
                // ages past the cap while you stand on it, and moving the
                // reader would destroy the note being written on it.
                position: ReplyPanelPosition(index: reverseIndex + 1, total: reachableCount),
                canStepBack: (index > 0 || hasMoreHistory) && mayStepBack(from: reverseIndex),
                canStepForward: index + 1 < groups.count
            )
        )
    }

    /// Whether the **newest** turn is still being written — the turn gate.
    ///
    /// This is what `Paste & Send` reads, and it is deliberately about the
    /// newest turn rather than the one on screen: an older reply is a
    /// deliberate target, and annotating it says nothing about whether the
    /// agent is free to receive a submit right now.
    ///
    /// **Never the lifecycle map.** `needsInput` is both Claude's resting
    /// state and its blocking state, pushed through the same key with the
    /// same value (`CLI/cmux.swift:25252` and `:25524`), so no lifecycle read
    /// can separate "finished" from "waiting on a permission prompt". A gate
    /// that refused `needsInput` would refuse the agent's resting state —
    /// the feature would be dead exactly when it is usable.
    ///
    /// It gates **only** the button that submits. `Paste` types at any point
    /// in a turn, because it submits nothing; a wrong *target* is a
    /// different rule and refuses both.
    public var isNewestTurnWriting: Bool {
        guard let newest = newestGroup else { return false }
        return isWriting(newest)
    }

    /// Whether the agent is still adding to a reply.
    ///
    /// Only the newest reply can be unfinished. A reply the user stepped
    /// back to is finished by construction — a completed reply cannot grow —
    /// and without that rule, reading reply 4 while the agent writes reply 7
    /// would mute a finished reply and, later, block the note being written
    /// on it.
    private func isWriting(_ group: ReplyMessageGroup) -> Bool {
        guard group.id == newestGroup?.id else { return false }
        return finishedGroupID != group.id
    }

    // MARK: - Transitions

    /// Binds the panel to a session whose transcript is being tailed.
    ///
    /// - Parameters:
    ///   - sessionID: The session being followed. Turn-end signals are
    ///     matched against it.
    ///   - agentIsRunning: Whether the agent's live lifecycle says it is
    ///     mid-turn. On a cold open there is no Stop event to wait for — it
    ///     fired before the panel existed — so the lifecycle is the only
    ///     thing that can say whether the newest reply is still growing.
    public mutating func bind(sessionID: String, agentIsRunning: Bool) {
        binding = .bound
        self.sessionID = sessionID
        owesBindSettle = !agentIsRunning
        settleFromBindIfOwed()
    }

    /// Applies the cold-open lifecycle answer to the newest reply, once.
    private mutating func settleFromBindIfOwed() {
        guard owesBindSettle, let newest = newestGroup else { return }
        finishedAnchorSeq = Self.anchor(of: newest)
        owesBindSettle = false
    }

    /// Replaces everything the panel holds with one freshly-read session.
    ///
    /// One mutation, and that is the entire point of the method. The store
    /// used to clear the model, `await` the tailer three times, then refill
    /// it — and every `await` yields the main actor, so SwiftUI rendered the
    /// emptied model in between. Switching between two agent panes flashed
    /// the no-agent empty state, and tore down the body's web view with it.
    /// `@MainActor` buys mutual exclusion, not atomicity.
    ///
    /// Do not split this back into a reset-then-fill pair, and do not call it
    /// with a half-read page: whatever it is handed is what the panel shows
    /// the instant it returns.
    ///
    /// - Parameters:
    ///   - groups: The session's replies, in ascending transcript order.
    ///   - hasMoreHistory: Whether older replies remain unread behind these.
    ///   - sessionID: The session now being followed.
    ///   - agentIsRunning: Whether the agent's lifecycle says it is mid-turn.
    public mutating func load(
        groups: [ReplyMessageGroup],
        hasMoreHistory: Bool,
        sessionID: String,
        agentIsRunning: Bool
    ) {
        // The cap is configuration, not session state. `self = ReplyPanelModel()`
        // would silently revert a user's `reply.maxMessagesBack` to the default
        // on every session change, with nothing on screen saying so.
        let configuredCap = maxMessagesBack
        self = ReplyPanelModel()
        maxMessagesBack = configuredCap
        apply(groups: groups)
        noteHistory(hasMore: hasMoreHistory)
        bind(sessionID: sessionID, agentIsRunning: agentIsRunning)
    }

    /// Records that no agent runs in the selected workspace.
    public mutating func unbind() {
        binding = .noAgent
        groups = []
        viewedAnchorSeq = nil
        finishedAnchorSeq = nil
        // A `seq` is a line index, so every transcript has one at 40. Left
        // behind, these would mark whichever replies land on the same lines.
        annotatedSeqs = []
        owesBindSettle = false
        owesStopSettle = false
        sessionID = nil
        hasMoreHistory = false
        historyTruncatedAtHead = false
    }

    /// Records that the bound session's transcript could not be read.
    ///
    /// Replies already loaded are kept: the last thing the agent said stays
    /// readable, and re-binding after a successful retry does not flash an
    /// empty panel on the way back.
    public mutating func markUnreadable() {
        binding = .unreadable
    }

    /// Replaces the loaded replies.
    ///
    /// - Parameter groups: Replies in ascending transcript order.
    public mutating func apply(groups: [ReplyMessageGroup]) {
        self.groups = groups
        settleFromBindIfOwed()
        settleFromStopIfOwed()
    }

    /// Moves the Stop's answer onto the newest reply while the window is open.
    private mutating func settleFromStopIfOwed() {
        guard owesStopSettle, let newest = newestGroup else { return }
        finishedAnchorSeq = Self.anchor(of: newest)
    }

    /// Pins the panel to one reply, or resumes following the newest.
    ///
    /// - Parameter groupID: The reply to hold on, or `nil` to follow the
    ///   newest again. Passing the newest reply's own id also resumes
    ///   following: being on the newest *is* the following state, so
    ///   arriving there by stepping forward must behave exactly like never
    ///   having left.
    public mutating func view(groupID: String?) {
        guard let groupID, groupID != newestGroup?.id else {
            viewedAnchorSeq = nil
            return
        }
        viewedAnchorSeq = Self.anchor(of: groups.first { $0.id == groupID })
    }

    /// Steps to the next older reply.
    ///
    /// Reports whether it moved, so the caller can tell "there was one loaded"
    /// from "there may be one on disk" without reading state back out and
    /// re-deriving the rule. A caller that gets `false` and has history left
    /// pages it in and asks again.
    ///
    /// - Returns: `true` when the view moved.
    @discardableResult
    public mutating func stepBack() -> Bool {
        guard let current = viewedGroup,
              let index = groups.firstIndex(where: { $0.id == current.id }),
              index > 0 else { return false }
        // The same predicate `state` derives `canStepBack` from, deliberately
        // not a parameter. `canStepBack` is read off `state`, a parameterless
        // computed property, so a `skipping:` argument here could never reach
        // it: the arrow would stay lit, the press would return false, and the
        // store would page older history in — the one thing the cap forbids.
        guard mayStepBack(from: groups.count - 1 - index) else { return false }
        viewedAnchorSeq = Self.anchor(of: groups[index - 1])
        return true
    }

    /// Steps to the next newer reply, resuming following at the newest.
    ///
    /// - Returns: `true` when the view moved.
    @discardableResult
    public mutating func stepForward() -> Bool {
        guard let current = viewedGroup,
              let index = groups.firstIndex(where: { $0.id == current.id }),
              index + 1 < groups.count else { return false }
        view(groupID: groups[index + 1].id)
        return true
    }

    /// Returns to the newest reply and resumes following it.
    ///
    /// Stepping forward one at a time is fine two replies back and a chore
    /// eleven back, which is the state a long session leaves you in. Offered
    /// exactly when ``ReplyPanelReading/canStepForward`` is true — a newer
    /// reply existing is the same condition as having somewhere to return to.
    ///
    /// - Returns: `true` when the view moved.
    @discardableResult
    public mutating func returnToNewest() -> Bool {
        guard viewedAnchorSeq != nil else { return false }
        viewedAnchorSeq = nil
        return true
    }

    /// Records what the transcript said about older history.
    ///
    /// - Parameter hasMore: Whether replies older than the loaded window
    ///   remain on disk.
    /// Records that paging reached the head of a bounded backfill.
    ///
    /// Stops `◄` — there is nothing further this tailer can serve — while
    /// remembering that the conversation did not start here.
    public mutating func noteHistoryTruncatedAtHead() {
        historyTruncatedAtHead = true
        hasMoreHistory = false
    }

    public mutating func noteHistory(hasMore: Bool) {
        hasMoreHistory = hasMore
    }

    /// Records that a session finished its turn.
    ///
    /// Ignores every session but the bound one. A machine runs many agents at
    /// once and their turns end constantly, so a panel that settled on any
    /// Stop would mark a reply finished while this agent was mid-sentence —
    /// and later unlock annotation on a moving target. The check lives here
    /// rather than at the call site because there is no compiler forcing a
    /// caller to make it.
    ///
    /// - Parameter sessionID: The session whose turn ended.
    public mutating func markTurnFinished(sessionID: String) {
        guard sessionID == self.sessionID else { return }
        finishedAnchorSeq = Self.anchor(of: newestGroup)
        owesBindSettle = false
        owesStopSettle = true
    }

    /// Records that a new turn began — closing the finished turn's window,
    /// **and settling the turn it followed.**
    ///
    /// The signal is a user message arriving in the transcript: nothing else
    /// separates a finished turn's late tail from the next turn's opening
    /// line, and without it a Stop would settle the *next* reply mid-write.
    ///
    /// **This is the third settle path, and it is the only one that cannot
    /// fail to arrive.** `.stop` is a hook: a crash, an uninstalled hook or
    /// a killed process means it never fires, and there is no timeout
    /// anywhere in `Reply/` to fall back on — so the turn gate would hold
    /// `Paste & Send` shut for the life of that session, while the panel
    /// captioned it "returns when this turn ends". A user message is
    /// self-evidently the end of whatever came before it, and the parser
    /// already closes a run on one, so this reads a signal that was present
    /// and merely unused.
    ///
    /// Called before the batch is applied, so `newestGroup` is still the
    /// turn that just ended rather than the one beginning.
    ///
    /// - Parameter sessionID: The session that started a turn. A different
    ///   session's turn says nothing about this panel's.
    public mutating func markTurnStarted(sessionID: String) {
        guard sessionID == self.sessionID else { return }
        owesStopSettle = false
        owesBindSettle = false
        finishedAnchorSeq = Self.anchor(of: newestGroup)
    }

    /// Drops everything derived from a transcript that has been rewritten.
    ///
    /// A resume, a restart, or a compaction replaces the file, so the reply
    /// ids in hand address a conversation that no longer exists. Keeping the
    /// pin or the finished marker across that would point them at whatever
    /// reply happens to land in the same position.
    public mutating func reset() {
        groups = []
        viewedAnchorSeq = nil
        finishedAnchorSeq = nil
        // Same reason as `unbind`: the rewritten file restarts `seq` at zero,
        // so these would exempt replies nobody has marked. The store re-pushes
        // whatever still resolves against the new generation.
        annotatedSeqs = []
        owesBindSettle = false
        owesStopSettle = false
        // The old file's history is gone with the file. Paging back stays
        // unavailable until the panel rebinds and reads the new one.
        hasMoreHistory = false
        historyTruncatedAtHead = false
    }
}
