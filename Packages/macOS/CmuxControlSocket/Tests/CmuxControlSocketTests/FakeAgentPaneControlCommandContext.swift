import Foundation
@testable import CmuxControlSocket

// cmux-rbf #cm-126.3: records witness calls without app, defaults, or filesystem state.
@MainActor
final class FakeAgentPaneControlCommandContext: ControlCommandContext {
    var checkResult: ControlAgentPaneCheck = .refused(.browserOff)
    var applied: ControlAgentPaneApplied?
    var summaries: [ControlAgentPaneSummary]? = []
    var checkCalls: [(UUID, URL)] = []
    var applyCalls: [ControlAgentPanePlan] = []
    var listCalls: [UUID?] = []

    func controlAgentPaneCheck(surfaceID: UUID, url: URL) -> ControlAgentPaneCheck {
        checkCalls.append((surfaceID, url))
        return checkResult
    }

    func controlAgentPaneApply(_ plan: ControlAgentPanePlan) -> ControlAgentPaneApplied? {
        applyCalls.append(plan)
        return applied
    }

    func controlAgentPaneList(workspaceID: UUID?) -> [ControlAgentPaneSummary]? {
        listCalls.append(workspaceID)
        return summaries
    }

    // A valid relay provenance must still be rejected by this local-only domain.
    func controlRemoteRelayDispatchError(method: String, params: [String: JSONValue]) -> ControlCallResult? { nil }
}
