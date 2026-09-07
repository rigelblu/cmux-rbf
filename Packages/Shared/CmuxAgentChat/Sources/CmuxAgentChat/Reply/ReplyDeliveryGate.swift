import Foundation

/// When a marked-up reply may be pasted, and when it may also be submitted.
///
/// **One rule, in one place, because stating it twice is how it broke.** This
/// gate has two entrypoints — the footer's buttons decide what to *offer*, and
/// `ReplyPanelStore.deliver` decides what to *do* — and the repo's
/// shared-behaviour policy asks for one path serving both.
///
/// It was written twice instead, and the two copies disagreed: `Paste` was
/// gated on a note existing at the button *and* in the store, three lines under
/// a comment saying a paste is never refused. An **enabled** `Paste` typed
/// nothing and left the clipboard untouched, which is worse than a disabled
/// one. The fix realigned the values and deleted the shared predicate they had
/// once had — so the shape survived the fix for it, and a cold review found the
/// rule stated twice again a day later. Hence a type: disagreement is now
/// unreachable rather than currently-absent, and it is unit-testable, which
/// neither call site is.
///
/// **The rule itself, and why each half is what it is:**
/// - **A paste is refused only when there is nothing to paste.** Not on a
///   missing note: a mark with no note is a complete thought — *this span, and
///   I will tell you what about it* — and `Paste` lands in the composer where
///   the sentence gets finished (Tom, 2026-09-06: *"I don't see a reason to
///   disable paste any time"*).
/// - **A submit additionally waits for the turn to end and wants a real
///   instruction.** Typing into a running agent risks answering a permission
///   prompt with your notes, and an unwritten note submitted is a prompt that
///   says nothing.
public enum ReplyDeliveryGate {
    /// Whether `Paste` may type the composed instruction into the composer.
    public static func canPaste(_ set: ReplyAnnotationSet) -> Bool {
        !set.isEmpty
    }

    /// Whether `Paste & Send` may also submit it.
    ///
    /// - Parameter turnEnded: Whether the newest turn has settled. The store
    ///   owns that reading; the rule owns what to do with it.
    public static func canSend(_ set: ReplyAnnotationSet, turnEnded: Bool) -> Bool {
        canPaste(set) && turnEnded && set.isDeliverable
    }

    /// Whether a delivery may proceed at all, for a caller that knows only
    /// whether it intends to submit.
    ///
    /// The store's own guard, expressed once: a paste needs `canPaste`, and a
    /// submit needs `canSend` on top of it.
    public static func canDeliver(
        _ set: ReplyAnnotationSet,
        submit: Bool,
        turnEnded: Bool
    ) -> Bool {
        submit ? canSend(set, turnEnded: turnEnded) : canPaste(set)
    }
}
