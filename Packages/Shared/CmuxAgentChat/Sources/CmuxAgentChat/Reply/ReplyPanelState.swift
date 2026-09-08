import Foundation

/// Which of the session's replies is on screen, and whether either end of
/// the walk has been reached.
///
/// `index` is 1-based because it is read by a person: the panel renders it
/// as `3 of 5`.
///
/// **Both fields changed meaning in `cm-69.6`, and neither reads like it.**
/// `cm-69.1` shipped `index` counting up from the oldest *loaded* reply and
/// `total` as the loaded count — so the newest reply read `34/34` and `◄`
/// walked it down. Under the cap the oldest loaded reply is no longer a place
/// anyone can point at, so the count is re-based onto the question the panel
/// actually raises: how far back am I.
public struct ReplyPanelPosition: Sendable, Equatable {
    /// Position of the reply on screen, counting **back from the newest**.
    ///
    /// `1` is the newest reply. Can exceed ``total``: a reply ages past the
    /// cap while you stand on it, and the reader is deliberately not moved.
    public let index: Int

    /// How many replies `◄` can reach, **not** how many are loaded.
    ///
    /// Exceeds `reply.maxMessagesBack` whenever a reply carries unsent marks,
    /// since those stay reachable without spending budget. The configured
    /// number is what shows when nothing is marked.
    public let total: Int

    /// Creates a position.
    ///
    /// - Parameters:
    ///   - index: 1-based position of the reply on screen, newest first.
    ///   - total: Count of reachable replies.
    public init(index: Int, total: Int) {
        self.index = index
        self.total = total
    }
}

/// The reply on screen and how finished it is.
public struct ReplyPanelReading: Sendable, Equatable {
    /// The reply being read.
    public let group: ReplyMessageGroup

    /// Whether the agent is still adding to this reply.
    ///
    /// Drives the muted body treatment, and later gates whether the reply
    /// can be annotated at all — an unfinished reply is a moving target.
    public let isWriting: Bool

    /// Where this reply sits in the reachable set — the `3 of 5` the header
    /// shows, and nothing more.
    public let position: ReplyPanelPosition

    /// Whether an older reply can be reached.
    ///
    /// Not the same as being past the first *loaded* reply: older ones may
    /// still be on disk, unread. Folded in here so the control and the action
    /// answer one question, instead of the view composing two facts and the
    /// store composing them differently.
    ///
    /// **Since `cm-69.6` this is also false at the cap**, with replies both
    /// loaded and on disk behind it. The header's `Showing last` caption is
    /// the only thing separating that from "the conversation starts here",
    /// which is why the caption is not decoration.
    public let canStepBack: Bool

    /// Whether a newer reply can be reached.
    ///
    /// Only loaded replies count — there is nothing newer to fetch, since the
    /// tail is already live.
    public let canStepForward: Bool

    /// Creates a reading.
    ///
    /// - Parameters:
    ///   - group: The reply on screen.
    ///   - isWriting: Whether the agent is still adding to it.
    ///   - position: Where it sits among the loaded replies.
    ///   - canStepBack: Whether an older reply is loaded or fetchable.
    ///   - canStepForward: Whether a newer loaded reply exists.
    public init(
        group: ReplyMessageGroup,
        isWriting: Bool,
        position: ReplyPanelPosition,
        canStepBack: Bool,
        canStepForward: Bool
    ) {
        self.group = group
        self.isWriting = isWriting
        self.position = position
        self.canStepBack = canStepBack
        self.canStepForward = canStepForward
    }
}

/// What the Reply panel has to show.
///
/// Four outcomes, and the three that show no message are deliberately
/// distinct rather than one "empty" case: they differ in what the user
/// should do next. Nothing bound is an invitation, bound-and-silent is
/// reassurance that the binding worked, and a read failure is a fault with
/// a way out.
public enum ReplyPanelState: Sendable, Equatable {
    /// No agent runs in the selected workspace, so there is nothing to bind.
    case noAgent

    /// An agent is bound and its transcript is readable, but it has not
    /// written a reply yet.
    case waiting

    /// A session resolved, but its transcript could not be read.
    case unavailable

    /// A reply is on screen.
    case showing(ReplyPanelReading)
}
