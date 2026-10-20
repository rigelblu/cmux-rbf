import CmuxSettings
import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
private final class GroupColorContext: ControlCommandContext {
    var calls = 0
    var stored: String? = "#765432"
    func controlSetWorkspaceGroupColor(routing: ControlRoutingSelectors, groupID: UUID, hex: String?) -> (found: Bool, storedHex: String?)? {
        calls += 1
        stored = hex.flatMap(WorkspaceColorHex.normalized)
        return (true, stored)
    }
}

@MainActor
@Suite("Workspace group color socket responses")
struct ControlCommandCoordinatorWorkspaceGroupColorTests {
    @Test func invalidHexIsRejectedWithoutCallingTheApp() throws {
        let context = GroupColorContext(), coordinator = ControlCommandCoordinator(context: context)
        let result = try #require(coordinator.handle(.init(id: .int(1), method: "workspace.group.set_color",
            params: ["group_id": .string(UUID().uuidString), "hex": .string("#GG1122")])))
        guard case .err(let code, _, _) = result else { Issue.record("Expected invalid_params, got \(result)"); return }
        #expect(code == "invalid_params")
        #expect(context.calls == 0 && context.stored == "#765432")
    }

    @Test func successReturnsTheNormalizedStoredColor() throws {
        let context = GroupColorContext(), coordinator = ControlCommandCoordinator(context: context)
        let result = try #require(coordinator.handle(.init(id: .int(1), method: "workspace.group.set_color",
            params: ["group_id": .string(UUID().uuidString), "hex": .string(" abcdef ")])))
        guard case .ok(.object(let payload)) = result else { Issue.record("Expected color response"); return }
        #expect(context.stored == "#ABCDEF")
        #expect(payload["custom_color"] == .string("#ABCDEF"))
    }
}
