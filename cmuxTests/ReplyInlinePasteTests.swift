import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `cm-136.1` Scenario 5: Reply pastes once, into the source pane, and never
/// submits. The production target's pane lookup is covered by human
/// Scenarios 10 and 12 and by `ReplyInlineShellTests`.
@Suite
struct ReplyInlinePasteTests {
    private final class RecordingTarget: ReplyInlinePasteTarget {
        var sent: [(events: [TextBoxSubmit.DispatchEvent], panel: UUID)] = []
        let resolves: Bool
        init(resolves: Bool = true) { self.resolves = resolves }
        func send(_ events: [TextBoxSubmit.DispatchEvent], toPanel id: UUID) -> Bool {
            guard resolves else { return false }
            sent.append((events, id))
            return true
        }
    }

    @Test("A one-line quote is one paste ending in one newline")
    func oneLineQuote() {
        #expect(ReplyInlinePaste.events(for: "> \"origin-checked open tab\"")
            == [.pasteText("> \"origin-checked open tab\"\n")])
    }

    @Test("A fenced quote is one paste ending in one newline, fence untouched")
    func fencedQuote() {
        let fence = "```\nfirst\n\nsecond\n```"
        #expect(ReplyInlinePaste.events(for: fence) == [.pasteText(fence + "\n")])
    }

    @Test("There is no key event: Reply never submits")
    func noKeyEvents() {
        for quote in ["> \"x\"", "```\na\nb\n```"] {
            for event in ReplyInlinePaste.events(for: quote) {
                switch event {
                case .pasteText: break
                default: Issue.record("unexpected event \(event) for \(quote)")
                }
            }
        }
    }

    @Test("Reply sends exactly one batch, to the source pane")
    func sendsOnceToTheSourcePane() {
        let target = RecordingTarget()
        let source = UUID()
        let sent = ReplyInlinePaste.reply(quote: "> \"x\"", sourcePanelID: source, target: target)
        #expect(sent)
        #expect(target.sent.count == 1)
        #expect(target.sent.first?.panel == source)
        #expect(target.sent.first?.events == [.pasteText("> \"x\"\n")])
    }

    @Test("A pane that can't be resolved gets nothing, and Reply says so")
    func unresolvedPaneSendsNothing() {
        let target = RecordingTarget(resolves: false)
        #expect(!ReplyInlinePaste.reply(quote: "> \"x\"", sourcePanelID: UUID(), target: target))
        #expect(target.sent.isEmpty)
    }
}
