import Testing
@testable import CmuxTerminalCore

struct TerminalAgentInputStateTests {
    @Test func inspectionIsLimitedToWaitsRunningEscapeAndPendingVimSequence() {
        var state = TerminalAgentInputState()
        #expect(!state.requiresKeyInspection(isEscape: false))
        #expect(!state.requiresKeyInspection(isEscape: true))
        state.isRunning = true
        #expect(!state.requiresKeyInspection(isEscape: false))
        #expect(state.requiresKeyInspection(isEscape: true))
        state.needsInput = true
        #expect(state.requiresKeyInspection(isEscape: false))
    }

    @Test func waitingKeyResolvesAndBindingNeverDoesWithoutClearingProjectedFlag() {
        var state = TerminalAgentInputState(needsInput: true)
        #expect(state.acceptKey(isEscape: false, isBinding: true) == nil)
        #expect(state.acceptKey(isEscape: false, isBinding: false) == false)
        #expect(state.needsInput)
        #expect(state.acceptKey(isEscape: true, isBinding: false) == true)
        // A committed ESC is passed as ordinary text, so it never declares unknown.
        #expect(state.acceptKey(isEscape: false, isBinding: false) == false)
    }

    @Test func escapeUnderGhosttysPerformableEndSearchResolvesAWait() {
        // Ghostty binds Escape to a performable `end_search`; with no search it reaches the program (Scenario 45).
        let isBinding = TerminalAgentInputState.countsAsBinding(isBinding: true, isPerformable: true, isEscape: true)
        var state = TerminalAgentInputState(needsInput: true, isRunning: true, usesVimEditor: true)
        #expect(state.acceptKey(isEscape: true, isBinding: isBinding) == true)
    }

    @Test func otherBindingsStillCountAsBindings() {
        #expect(TerminalAgentInputState.countsAsBinding(isBinding: true, isPerformable: true, isEscape: false))
        #expect(TerminalAgentInputState.countsAsBinding(isBinding: true, isPerformable: false, isEscape: true))
        #expect(!TerminalAgentInputState.countsAsBinding(isBinding: false, isPerformable: false, isEscape: true))
    }

    @Test func vimEscapeRequiresTwoAndAnyOtherKeyOrBindingResetsIt() {
        var state = TerminalAgentInputState(isRunning: true, usesVimEditor: true)
        #expect(state.acceptKey(isEscape: true, isBinding: false) == nil)
        #expect(state.requiresKeyInspection(isEscape: false))
        #expect(state.acceptKey(isEscape: true, isBinding: false) == true)
        #expect(state.acceptKey(isEscape: true, isBinding: false) == nil)
        #expect(state.acceptKey(isEscape: false, isBinding: false) == nil)
        #expect(state.acceptKey(isEscape: true, isBinding: false) == nil)
        #expect(state.acceptKey(isEscape: false, isBinding: true) == nil)
        #expect(state.acceptKey(isEscape: true, isBinding: false) == nil)
        #expect(state.acceptKey(isEscape: true, isBinding: false) == true)
    }

    @Test func phoneTypingOnlyResolvesWaitAndResetsVimEscapeSequence() {
        var waiting = TerminalAgentInputState(needsInput: true)
        #expect(waiting.acceptPhoneText() == false)
        var running = TerminalAgentInputState(isRunning: true, usesVimEditor: true)
        #expect(running.acceptKey(isEscape: true, isBinding: false) == nil)
        #expect(running.acceptPhoneText() == nil)
        #expect(running.acceptKey(isEscape: true, isBinding: false) == nil)
        #expect(running.acceptKey(isEscape: true, isBinding: false) == true)
        var idle = TerminalAgentInputState()
        #expect(idle.acceptKey(isEscape: true, isBinding: false) == nil)
    }
}
