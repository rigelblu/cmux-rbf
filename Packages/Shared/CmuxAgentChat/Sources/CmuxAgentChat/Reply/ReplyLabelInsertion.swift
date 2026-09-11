import Foundation

/// Where a quick label goes in a note, and exactly what text goes there —
/// `cm-69.3`.
///
/// **One rule for both insertion paths.** With the note field's editor holding
/// the keyboard, the panel hands `range` and `text` to
/// `insertText(_:replacementRange:)`, so undo and the field's binding follow.
/// Without it, the panel applies the same result to the note's text itself.
/// Keeping both on this value is what makes a test of it a test of what
/// production does.
///
/// Ranges are UTF-16 (`NSRange`) because that is what the field editor's
/// `selectedRange()` reports; a `String.Index` walk would drift on any note
/// holding an emoji or a combining mark.
public struct ReplyLabelInsertion: Equatable, Sendable {
    /// The UTF-16 range of the note to replace — the selection, or an empty
    /// range at the caret.
    public let range: NSRange
    /// The label, padded with one space on each side that needs one.
    public let text: String

    /// Where the caret belongs afterwards: just past the inserted text.
    public var caretLocation: Int { range.location + (text as NSString).length }

    /// The insertion of `label` into `note` over `selection`.
    ///
    /// Pads with one space on a side whose neighbouring character is neither
    /// whitespace nor the edge of the note, so a label never fuses with a word
    /// and never doubles a space that is already there. A selection is
    /// replaced — **except one covering the whole note**, which is treated as
    /// a caret at the end. Focusing a note field selects all of it, so that is
    /// what a chip click finds on a note that was opened but not clicked
    /// into, and a label must never wipe a written note (cold code review,
    /// 2026-09-11). A selection reaching past the note's end is clamped to it.
    public static func apply(label: String, to note: String, selection: NSRange) -> ReplyLabelInsertion {
        let length = (note as NSString).length
        let start = min(max(selection.location, 0), length)
        var range = NSRange(location: start, length: min(max(selection.length, 0), length - start))
        if length > 0, range.location == 0, range.length == length {
            range = NSRange(location: length, length: 0)
        }
        let utf16 = note as NSString
        func needsSpace(at index: Int) -> Bool {
            guard index >= 0, index < length else { return false }
            let unit = utf16.character(at: index)
            guard let scalar = Unicode.Scalar(unit) else { return true } // half a surrogate pair: an emoji, not a space
            return !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        let before = needsSpace(at: range.location - 1) ? " " : ""
        let after = needsSpace(at: range.location + range.length) ? " " : ""
        return ReplyLabelInsertion(range: range, text: before + label + after)
    }

    /// The note with this insertion applied — the no-editor path.
    public func applied(to note: String) -> String {
        (note as NSString).replacingCharacters(in: range, with: text)
    }
}
