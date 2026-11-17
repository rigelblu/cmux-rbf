import Foundation
import Testing

@testable import CmuxAgentChat

private func mark(_ quote: String, _ note: String, _ range: Range<Int>) -> ReplyAnnotation {
    ReplyAnnotation(quote: quote, note: note, range: range)
}

/// `cm-136.7`: what `Add to reply` does with a passage, given the marks the
/// reply already carries. Ranges are half-open, so overlap is shared
/// characters and a range starting where another ends is not an overlap.
@Suite("ReplyAnnotationSetAdd")
struct ReplyAnnotationSetAddTests {
    @Test("A passage that overlaps no mark is inserted")
    func noOverlapInserts() {
        let set = ReplyAnnotationSet(annotations: [mark("alpha", "one", 0..<10)])
        #expect(set.addPlan(for: 20..<25) == .insert)
    }

    @Test("A passage starting where a mark ends shares no characters with it, so it is inserted")
    func adjacentInserts() {
        let set = ReplyAnnotationSet(annotations: [mark("alpha", "one", 0..<10)])
        #expect(set.addPlan(for: 10..<15) == .insert)
    }

    @Test("A passage inside one mark opens that mark's note and changes nothing")
    func insideOneOpensItsNote() {
        let hit = mark("alpha bravo", "one", 0..<11)
        let set = ReplyAnnotationSet(annotations: [hit])
        #expect(set.addPlan(for: 2..<7) == .openNote(hit.id))
    }

    @Test("A passage starting before a mark and ending inside it grows that mark to the union")
    func partialLeftGrows() {
        let hit = mark("bravo charlie", "one", 10..<22)
        let set = ReplyAnnotationSet(annotations: [hit])
        #expect(set.addPlan(for: 5..<14) == .grow(hit.id, 5..<22))
    }

    @Test("A passage starting inside a mark and ending after it grows that mark to the union")
    func partialRightGrows() {
        let hit = mark("bravo charlie", "one", 10..<22)
        let set = ReplyAnnotationSet(annotations: [hit])
        #expect(set.addPlan(for: 18..<30) == .grow(hit.id, 10..<30))
    }

    @Test("A passage containing a mark grows that mark to the passage's range")
    func supersetGrows() {
        let hit = mark("bravo", "one", 10..<15)
        let set = ReplyAnnotationSet(annotations: [hit])
        #expect(set.addPlan(for: 5..<25) == .grow(hit.id, 5..<25))
    }

    @Test("A passage over two marks opens the one that starts first in the message, not the one marked first")
    func twoOverlapsOpenFirstInDocumentOrder() {
        // Selection order: the mark later in the message was made first.
        let later = mark("delta", "later", 20..<30)
        let earlier = mark("alpha", "earlier", 0..<10)
        let set = ReplyAnnotationSet(annotations: [later, earlier])
        #expect(set.addPlan(for: 5..<25) == .openNote(earlier.id))
    }

    @Test("Growing keeps the mark's id, its place in the list, and its note")
    func growKeepsIdIndexAndNote() {
        let before = mark("bravo", "keep this note", 10..<15)
        let other = mark("echo", "other", 40..<45)
        var set = ReplyAnnotationSet(annotations: [other, before])

        let grown = set.grow(before.id, quote: "bravo charlie", range: 10..<22)
        #expect(grown)
        #expect(set.annotations.map(\.id) == [other.id, before.id])
        #expect(set.annotations[1].note == "keep this note")
        #expect(set.annotations[1].quote == "bravo charlie")
        #expect(set.annotations[1].range == 10..<22)
    }

    @Test("Growing a mark leaves every number on the reply where it was")
    func growKeepsNumbering() {
        let a = mark("alpha", "a", 0..<5)
        let b = mark("bravo", "b", 10..<15)
        let c = mark("charlie", "c", 20..<27)
        var set = ReplyAnnotationSet(annotations: [a, b, c])

        let grown = set.grow(b.id, quote: "bravo chunk", range: 10..<18)
        #expect(grown)
        #expect(set.numbered.map(\.number) == [1, 2, 3])
        #expect(set.numbered.map(\.id) == [a.id, b.id, c.id])
        #expect(set.numbered.map(\.quote) == ["alpha", "bravo chunk", "charlie"])
    }

    @Test("Growing refuses an id that is not on the reply and changes nothing")
    func growRefusesUnknownID() {
        let a = mark("alpha", "a", 0..<5)
        var set = ReplyAnnotationSet(annotations: [a])

        let refused = set.grow(UUID(), quote: "alpha beta", range: 0..<10)
        #expect(!refused)
        #expect(set.annotations == [a])
    }

    @Test("Growing refuses a range that does not contain the mark's old range and changes nothing")
    func growRefusesRangeNotContainingOld() {
        let a = mark("bravo", "b", 10..<15)
        var set = ReplyAnnotationSet(annotations: [a])

        let refused = set.grow(a.id, quote: "ravo c", range: 11..<20)
        #expect(!refused)
        #expect(set.annotations == [a])
    }

    @Test("Growing refuses a range that overlaps another mark and changes nothing")
    func growRefusesOverlapWithAnother() {
        let a = mark("bravo", "b", 10..<15)
        let other = mark("echo", "e", 20..<25)
        var set = ReplyAnnotationSet(annotations: [a, other])

        let refused = set.grow(a.id, quote: "bravo charlie delta", range: 10..<22)
        #expect(!refused)
        #expect(set.annotations == [a, other])
    }
}
