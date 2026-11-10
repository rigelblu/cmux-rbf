import Foundation
import Testing

@testable import CmuxAgentChat

/// `cm-136.1` Scenario 1: inline Reply and the Reply panel share one quote
/// function (`quoteBlock`), and differ in one thing only: inline Reply turns
/// the 36-character width limit off (Q10, Tom 2026-11-05).
///
/// Each case below is a rule in the brief. The panel's own output is pinned by
/// `#cm-69`'s suites (`ReplyAnnotationTests`, `ReplyAnnotationSet*Tests`),
/// which run unchanged; the cases here that touch the panel exist so a
/// regression in the shared seam fails in this file too, by name.
@Suite("ReplyPassageQuote")
struct ReplyPassageQuoteTests {
    private func annotation(_ quote: String, _ note: String) -> ReplyAnnotation {
        ReplyAnnotation(quote: quote, note: note, range: 0..<quote.count)
    }

    @Test("A 23-character passage with no line break is one > \"…\" line")
    func shortPassageIsOneLine() {
        #expect(ReplyPassageQuote.quote("origin-checked open tab") == "> \"origin-checked open tab\"")
    }

    @Test("A 37-character passage with no line break is still one line (the panel fences it)")
    func justOverThePanelBudgetIsOneLine() {
        let line = String(repeating: "x", count: ReplyAnnotationSet.inlineQuoteCharacterBudget + 1)
        #expect(line.count == 37)
        #expect(ReplyPassageQuote.quote(line) == "> \"\(line)\"")
    }

    @Test("An 800-character passage with no line break is one line, whole")
    func longPassageIsOneLine() {
        let line = String(repeating: "word ", count: 160).trimmingCharacters(in: .whitespaces)
        let quoted = ReplyPassageQuote.quote(line)
        #expect(quoted == "> \"\(line)\"")
        #expect(!quoted.contains("\n"))
        #expect(quoted.count >= 800)
    }

    @Test("A backtick fence on one line stays a one-line quote")
    func fenceOnOneLineStaysInline() {
        let passage = "use ``` to open a fence"
        #expect(ReplyPassageQuote.quote(passage) == "> \"\(passage)\"")
    }

    @Test("A passage with a line break is a fence")
    func lineBreakTakesAFence() {
        #expect(ReplyPassageQuote.quote("first\n\nsecond") == "```\nfirst\n\nsecond\n```")
    }

    @Test("A fence opens one backtick longer than the longest run inside")
    func fenceNestsByBacktickCount() {
        let passage = "before\n```swift\nlet x = 1\n```\nafter"
        #expect(ReplyPassageQuote.quote(passage) == "````\n\(passage)\n````")
    }

    @Test("Surrounding whitespace is trimmed before the line-break test")
    func trailingNewlineIsNotALineBreak() {
        #expect(ReplyPassageQuote.quote("  two words \n") == "> \"two words\"")
    }

    @Test("The Reply panel still fences the same 37-character line")
    func panelKeepsItsLimit() {
        let line = String(repeating: "x", count: 37)
        let serialized = ReplyAnnotationSet(annotations: [annotation(line, "n")]).serialized()
        #expect(serialized == "1.\n```\n\(line)\n```\nn")
    }

    @Test("The Reply panel still fences an 800-character line")
    func panelStillFencesALongLine() {
        let line = String(repeating: "y", count: 800)
        let serialized = ReplyAnnotationSet(annotations: [annotation(line, "n")]).serialized()
        #expect(serialized == "1.\n```\n\(line)\n```\nn")
    }

    @Test("The shared function's default is the panel's budget, and nil is no limit")
    func seamDefaultsToTheBudget() {
        let line = String(repeating: "z", count: 37)
        #expect(ReplyAnnotationSet.quoteBlock(line) == "```\n\(line)\n```")
        #expect(ReplyAnnotationSet.quoteBlock(line, inlineBudget: 36) == "```\n\(line)\n```")
        #expect(ReplyAnnotationSet.quoteBlock(line, inlineBudget: nil) == "> \"\(line)\"")
        #expect(ReplyAnnotationSet.quoteBlock(String(repeating: "z", count: 36)) == "> \"\(String(repeating: "z", count: 36))\"")
    }
}
