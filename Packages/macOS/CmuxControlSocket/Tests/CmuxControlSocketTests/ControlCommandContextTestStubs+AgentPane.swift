import Foundation
@testable import CmuxControlSocket

// cmux-rbf #cm-126.3: inert defaults for test fakes exercising other domains.
extension ControlAgentPaneContext {
    func controlAgentPaneCheck(surfaceID: UUID, url: URL) -> ControlAgentPaneCheck { .refused(.browserOff) }
    func controlAgentPaneApply(_ plan: ControlAgentPanePlan) -> ControlAgentPaneApplied? { nil }
    func controlAgentPaneList(workspaceID: UUID?) -> [ControlAgentPaneSummary]? { [] }
}
