import Foundation

/// Unsent marks, held per reply and surviving the transcript moving under
/// them.
///
/// **Keyed by a session and a message `seq`, never by anything on the group.**
/// A reply is delimited by the prompt in front of it, and the loaded window is
/// bounded with nothing aligning it to turn boundaries — so the oldest loaded
/// reply routinely starts mid-answer, and paging its prompt in completes it.
/// That rewrites both handles the group offers: ``ReplyMessageGroup/id`` is its
/// current first message's id, and ``ReplyMessageGroup/seq`` is that same
/// message's position. `ReplyMessageGroupTests` pins the observation — a group
/// read `seq` 3 before paging and 1 after, with its `id` renamed.
///
/// Keyed by either of those, a draft is orphaned exactly when its reply is
/// still on screen: the user's notes vanish from the footer, unsent. The code
/// that holds them calls that the worst outcome it can produce, so the key is
/// the thing that has to be right.
///
/// A message's own `seq` is fixed for the life of the transcript, and paging
/// only ever prepends — a message never leaves the reply it arrived in. So an
/// anchor taken from inside a reply still resolves to it afterwards, which is
/// the same rule ``ReplyPanelModel`` navigates by.
///
/// **The session is the other half of the key, and leaving it out was a real
/// defect.** A `seq` is a transcript *line index*, so every session has a
/// message at 40. `ReplyPanelView` holds one `ReplyDrafts` in `@State` that
/// nothing resets — `ReplyPanelStore.refresh` returns early when the session
/// is unchanged, and otherwise re-binds the *store*, leaving view state alone.
/// So a bare `seq` showed one session's notes on another session's reply.
/// Introduced 2026-09-07 by the change that moved this key off
/// ``ReplyMessageGroup/id``, which had been globally unique by way of
/// `apiMessageID`; found by a cold review the same day.
///
/// **A transcript rewrite retires an anchor without deleting the draft.**
/// `--resume` and compaction replace the file: `ReplyPanelStore.receive(batch:)`
/// clears `messages` and calls `ReplyPanelModel.reset()`, which drops that
/// model's own anchors and records why — *"Keeping the pin … would point them
/// at whatever reply happens to land in the same position."* The session id is
/// unchanged and `seq` starts over, so a draft keyed on the session alone
/// followed a **line number** into a conversation that no longer exists.
/// Bumping ``Scope/generation`` makes the old anchor stop matching. The draft
/// is still held — it is orphaned and invisible, not destroyed, which is the
/// side of the trade Tom's rule below points to.
///
/// **Drafts deliberately outlive a session change.** Scoping the key is not
/// dropping the draft: a note written before a compaction is still what the
/// user wanted to say (Tom, 2026-09-07, closing the target guard — *"Even if
/// it's not there, it's what the user wanted to write."*). Holding these in
/// ``ReplyPanelModel`` instead would have destroyed them, because `load()`
/// resets that model on every session change — and `retry()`, behind the error
/// state's *Try again*, forces exactly that path.
public struct ReplyDrafts: Sendable, Equatable {
    /// A reply, addressed so that neither paging nor a session change can
    /// point it at someone else's marks.
    /// Which transcript a draft belongs to.
    ///
    /// Two coordinates, because a `seq` is unique inside neither. The session
    /// separates two agents whose transcripts both have a line 40; the
    /// generation separates the same session before and after its file is
    /// rewritten, which `--resume` and compaction both do.
    public struct Scope: Hashable, Sendable {
        public let session: String
        public let generation: Int
        public init(session: String, generation: Int) {
            self.session = session
            self.generation = generation
        }
    }

    private struct Anchor: Hashable, Sendable {
        let scope: Scope
        /// A message `seq` from inside the reply — never the group's own.
        let seq: Int
    }

    private var byAnchor: [Anchor: ReplyAnnotationSet] = [:]

    public init() {}

    /// The marks written on `group` in `sessionID`, or an empty set.
    public func draft(for group: ReplyMessageGroup, in scope: Scope) -> ReplyAnnotationSet {
        guard let anchor = anchor(held: group, in: scope) else { return ReplyAnnotationSet() }
        return byAnchor[anchor] ?? ReplyAnnotationSet()
    }

    /// Edits the marks on `group`, anchoring the draft on a first edit.
    ///
    /// The anchor is taken once and then kept: re-deriving it per edit would
    /// reintroduce the bug in slow motion, since the message it names would
    /// drift with the window.
    public mutating func update(
        for group: ReplyMessageGroup,
        in scope: Scope,
        _ change: (inout ReplyAnnotationSet) -> Void
    ) {
        let anchor = anchor(held: group, in: scope)
            ?? Anchor(scope: scope, seq: Self.newAnchorSeq(for: group))
        var set = byAnchor[anchor] ?? ReplyAnnotationSet()
        change(&set)
        byAnchor[anchor] = set
    }

    /// Drops the marks on `group`.
    ///
    /// Called only after a delivery that actually happened — a refused send
    /// that wiped the notes would lose writing the user cannot get back.
    public mutating func clear(for group: ReplyMessageGroup, in scope: Scope) {
        guard let anchor = anchor(held: group, in: scope) else { return }
        byAnchor[anchor] = nil
    }

    /// The stored anchor `group` currently holds in `sessionID`, if any.
    ///
    /// Deterministic rather than "whichever the dictionary yields first". Two
    /// anchors landing in one group would need a prompt between two loaded
    /// replies to disappear, which paging cannot do — it only prepends — so
    /// the `min` is unreachable in practice and is here to keep the reading of
    /// a draft from depending on hash order if that ever stops being true.
    private func anchor(held group: ReplyMessageGroup, in scope: Scope) -> Anchor? {
        let seqs = Set(group.messages.map(\.seq))
        return byAnchor.keys
            .filter { $0.scope == scope && seqs.contains($0.seq) }
            .min { $0.seq < $1.seq }
    }

    /// The `seq` a first edit pins a draft to.
    ///
    /// The **last** loaded message rather than the first, because trimming
    /// takes the oldest messages: a reply straddling that boundary loses its
    /// front while the rest of it is still readable, and an anchor on the
    /// front would die with a reply the user can still see. Falls back to the
    /// group's own position, which a group with no messages cannot reach —
    /// ``ReplyMessageGroup/groups(from:)`` only emits a group that has prose.
    private static func newAnchorSeq(for group: ReplyMessageGroup) -> Int {
        group.messages.last?.seq ?? group.seq
    }
}
