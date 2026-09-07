import Foundation

/// Unsent marks, held per reply and surviving the transcript moving under
/// them.
///
/// **Keyed by a message `seq`, never by anything on the group.** A reply is
/// delimited by the prompt in front of it, and the loaded window is bounded
/// with nothing aligning it to turn boundaries — so the oldest loaded reply
/// routinely starts mid-answer, and paging its prompt in completes it. That
/// rewrites both handles the group offers: ``ReplyMessageGroup/id`` is its
/// current first message's id, and ``ReplyMessageGroup/seq`` is that same
/// message's position. `ReplyMessageGroupTests` pins the observation — a
/// group read `seq` 3 before paging and 1 after, with its `id` renamed.
///
/// Keyed by either of those, a draft is orphaned exactly when its reply is
/// still on screen: the user's notes vanish from the footer, unsent. The
/// code that holds them calls that the worst outcome it can produce, so the
/// key is the thing that has to be right.
///
/// A message's own `seq` is fixed for the life of the transcript, and paging
/// only ever prepends — a message never leaves the reply it arrived in. So
/// an anchor taken from inside a reply still resolves to it afterwards, which
/// is the same rule ``ReplyPanelModel`` navigates by.
public struct ReplyDrafts: Sendable, Equatable {
    /// Marks, keyed by a message `seq` that sits inside the reply they are
    /// written on.
    private var byAnchorSeq: [Int: ReplyAnnotationSet] = [:]

    public init() {}

    /// The marks written on `group`, or an empty set when it has none.
    public func draft(for group: ReplyMessageGroup) -> ReplyAnnotationSet {
        guard let anchor = anchor(held: group) else { return ReplyAnnotationSet() }
        return byAnchorSeq[anchor] ?? ReplyAnnotationSet()
    }

    /// Edits the marks on `group`, anchoring the draft on a first edit.
    ///
    /// The anchor is taken once and then kept: re-deriving it per edit would
    /// reintroduce the bug in slow motion, since the message it names would
    /// drift with the window.
    public mutating func update(
        for group: ReplyMessageGroup,
        _ change: (inout ReplyAnnotationSet) -> Void
    ) {
        let anchor = anchor(held: group) ?? Self.newAnchor(for: group)
        var set = byAnchorSeq[anchor] ?? ReplyAnnotationSet()
        change(&set)
        byAnchorSeq[anchor] = set
    }

    /// Drops the marks on `group`.
    ///
    /// Called only after a delivery that actually happened — a refused send
    /// that wiped the notes would lose writing the user cannot get back.
    public mutating func clear(for group: ReplyMessageGroup) {
        guard let anchor = anchor(held: group) else { return }
        byAnchorSeq[anchor] = nil
    }

    /// The stored anchor `group` currently holds, if it has one.
    ///
    /// Deterministic rather than "whichever the dictionary yields first". Two
    /// anchors landing in one group would need a prompt between two loaded
    /// replies to disappear, which paging cannot do — it only prepends — so
    /// the `min` is unreachable in practice and is here to keep the reading
    /// of a draft from depending on hash order if that ever stops being true.
    private func anchor(held group: ReplyMessageGroup) -> Int? {
        let seqs = Set(group.messages.map(\.seq))
        return byAnchorSeq.keys.filter(seqs.contains).min()
    }

    /// The anchor a first edit pins a draft to.
    ///
    /// The **last** loaded message rather than the first, because trimming
    /// takes the oldest messages: a reply straddling that boundary loses its
    /// front while the rest of it is still readable, and an anchor on the
    /// front would die with a reply the user can still see. Falls back to the
    /// group's own position, which a group with no messages cannot reach —
    /// ``ReplyMessageGroup/groups(from:)`` only emits a group that has prose.
    private static func newAnchor(for group: ReplyMessageGroup) -> Int {
        group.messages.last?.seq ?? group.seq
    }
}
