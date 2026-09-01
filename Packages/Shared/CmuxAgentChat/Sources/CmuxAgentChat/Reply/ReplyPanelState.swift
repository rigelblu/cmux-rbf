import Foundation

/// Which of the session's replies is on screen, and whether either end of
/// the walk has been reached.
///
/// `index` is 1-based because it is read by a person: the panel renders it
/// as `4/6`.
public struct ReplyPanelPosition: Sendable, Equatable {
    /// Position of the reply on screen, counting from the oldest loaded.
    public let index: Int

    /// How many replies are loaded.
    public let total: Int

    /// Creates a position.
    ///
    /// - Parameters:
    ///   - index: 1-based position of the reply on screen.
    ///   - total: Count of loaded replies.
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

    /// Where this reply sits among the loaded ones — the `4/6` the header
    /// shows, and nothing more.
    public let position: ReplyPanelPosition

    /// Whether an older reply can be reached.
    ///
    /// Not the same as being past the first *loaded* reply: older ones may
    /// still be on disk, unread. Folded in here so the control and the action
    /// answer one question, instead of the view composing two facts and the
    /// store composing them differently.
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
