import Foundation

/// What adding a passage from the agent's terminal does to a reply's marks.
///
/// Only the inline toolbar's `Add to reply` asks this. Selections made in the
/// Reply panel still go through ``ReplyAnnotationSet/insert(_:)``, which refuses
/// every overlap.
public enum ReplyAddPlan: Equatable {
    /// The passage overlaps no mark: it becomes the next mark.
    case insert
    /// The passage sits inside one mark, or overlaps two or more: nothing
    /// changes, and this mark's note opens with the caret.
    case openNote(UUID)
    /// The passage partly overlaps one mark, or contains it: that mark takes
    /// this union range in place, and its note opens with the caret.
    case grow(UUID, Range<Int>)
}

extension ReplyAnnotationSet {
    /// The plan for a passage at `range`.
    ///
    /// Overlap is shared characters, as ``ReplyAnnotation/range`` is half-open:
    /// a passage starting where a mark ends is an `insert`.
    public func addPlan(for range: Range<Int>) -> ReplyAddPlan {
        let hits = annotations.filter { $0.range.overlaps(range) }
        // Document order: the mark that starts first in the message.
        guard let first = hits.min(by: { $0.range.lowerBound < $1.range.lowerBound }) else {
            return .insert
        }
        guard hits.count == 1 else { return .openNote(first.id) }
        let inside = first.range.lowerBound <= range.lowerBound && range.upperBound <= first.range.upperBound
        if inside { return .openNote(first.id) }
        let union = min(first.range.lowerBound, range.lowerBound)..<max(first.range.upperBound, range.upperBound)
        return .grow(first.id, union)
    }
}
