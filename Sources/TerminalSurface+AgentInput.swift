import CmuxTerminal
import Foundation

extension TerminalSurface {
    @MainActor
    func updateAgentInputPhase(_ states: [String: AgentHibernationLifecycleState]) {
        agentInputState.needsInput = states.values.contains(.needsInput)
        agentInputState.isRunning = states.contains { !AgentHibernationLifecycleStatusKeys.isManualKey($0.key) && $0.value == .running }
    }

    @MainActor
    func installAgentPaneInputHandler(workspaceId: UUID, journal: AgentJournalLifecycleCenter = .shared) {
        let surfaceId = id
        onAgentPaneInput = { isEscape in
            journal.resolvePaneInput(workspaceId: workspaceId, surfaceId: surfaceId, isEscape: isEscape)
        }
    }

    @MainActor
    func acceptAgentPhoneTyping(_ text: String) {
        guard !text.isEmpty, let isEscape = agentInputState.acceptPhoneText() else { return }
        onAgentPaneInput?(isEscape)
    }
}
