import CmuxWorkspaces
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `cm-136.9` Scenario 40: the toolbar's agent-pane rule is `#cm-89`'s live
/// session plus a program running in the pane, never a shell idle at its prompt.
@Suite
struct ReplyInlineAgentPaneRuleTests {
    @Test func liveSessionOverShellIdleAtItsPromptDoesNotCount() {
        #expect(!ReplyInlineAgentPaneRule.counts(hasLiveSession: true, shellState: .promptIdle))
    }

    @Test func liveSessionWithACommandRunningCounts() {
        #expect(ReplyInlineAgentPaneRule.counts(hasLiveSession: true, shellState: .commandRunning))
    }

    @Test func liveSessionWithNoShellIntegrationCounts() {
        #expect(ReplyInlineAgentPaneRule.counts(hasLiveSession: true, shellState: .unknown))
    }

    @Test func noLiveSessionDoesNotCountWhateverTheShellDoes() {
        #expect(!ReplyInlineAgentPaneRule.counts(hasLiveSession: false, shellState: .commandRunning))
    }
}
