import CmuxSettings
import Foundation
@testable import CmuxControlSocket

@MainActor
final class FakeWorkspaceGroupSafetyContext: ControlCommandContext {
    var createdChildWorkspaceIDs: [UUID]?
    var createdExternalID: String?
    var createResolution: ControlWorkspaceGroupCreateResolution = .notCreated
    var ungroupedGroupIDs: [UUID] = []
    var removeGeneratedAnchor = false
    var deletedGroupIDs: [UUID] = []
    var deleteResult = 2
    var listResolution: ControlWorkspaceGroupListResolution = .tabManagerUnavailable // (#cm-106)
    var moveResolution: ControlWorkspaceGroupMoveResolution = .moved // (#cm-106)

    func controlCreateWorkspaceGroup(
        routing: ControlRoutingSelectors,
        name: String,
        cwd: String?,
        childWorkspaceIDs: [UUID],
        externalID: String?
    ) -> ControlWorkspaceGroupCreateResolution {
        createdChildWorkspaceIDs = childWorkspaceIDs
        createdExternalID = externalID
        return createResolution
    }

    func controlUngroupWorkspaceGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        removeGeneratedAnchor: Bool
    ) -> ControlWorkspaceGroupUngroupResolution {
        ungroupedGroupIDs.append(groupID)
        self.removeGeneratedAnchor = removeGeneratedAnchor
        return .dissolved(keptWorkspaceCount: 2)
    }

    func controlDeleteWorkspaceGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID
    ) -> Int? {
        deletedGroupIDs.append(groupID)
        return deleteResult
    }

    func controlWorkspaceGroupList(routing: ControlRoutingSelectors) -> ControlWorkspaceGroupListResolution {
        listResolution
    }

    func controlMoveWorkspaceGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        toIndex: Int?,
        beforeGroupID: UUID?,
        afterGroupID: UUID?
    ) -> ControlWorkspaceGroupMoveResolution {
        moveResolution
    }
}
