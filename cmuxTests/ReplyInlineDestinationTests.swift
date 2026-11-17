import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `cm-136.7`: where the toolbar's passage goes. `Add to reply` only when the
/// Reply panel shows this pane's agent on its newest reply; every other state
/// is today's `Reply`. One test per row of the design's destination table.
@Suite
struct ReplyInlineDestinationTests {
    private let source = UUID()

    @Test("The panel on this pane's agent, following the newest reply, takes the passage")
    func panelOnThisAgentNewestAddsToReply() {
        #expect(ReplyInlineDestination.resolve(
            sidebarShowingReply: true, boundPanelID: source, sourcePanelID: source, viewingOlderReply: false
        ) == .replyPanel)
    }

    @Test("A hidden sidebar is Reply")
    func sidebarHiddenIsPrompt() {
        #expect(ReplyInlineDestination.resolve(
            sidebarShowingReply: false, boundPanelID: source, sourcePanelID: source, viewingOlderReply: false
        ) == .prompt)
    }

    @Test("Another sidebar mode is Reply")
    func otherModeIsPrompt() {
        // The sidebar reports only whether it shows Reply, so Files and Notes
        // arrive here as `false`, the same as hidden.
        #expect(ReplyInlineDestination.resolve(
            sidebarShowingReply: false, boundPanelID: source, sourcePanelID: source, viewingOlderReply: false
        ) == .prompt)
    }

    @Test("A panel bound to another pane is Reply")
    func panelOnAnotherPaneIsPrompt() {
        #expect(ReplyInlineDestination.resolve(
            sidebarShowingReply: true, boundPanelID: UUID(), sourcePanelID: source, viewingOlderReply: false
        ) == .prompt)
    }

    @Test("A panel bound to no agent is Reply")
    func panelUnboundIsPrompt() {
        #expect(ReplyInlineDestination.resolve(
            sidebarShowingReply: true, boundPanelID: nil, sourcePanelID: source, viewingOlderReply: false
        ) == .prompt)
    }

    @Test("A panel held on an older reply is Reply")
    func olderReplyIsPrompt() {
        #expect(ReplyInlineDestination.resolve(
            sidebarShowingReply: true, boundPanelID: source, sourcePanelID: source, viewingOlderReply: true
        ) == .prompt)
    }
}
