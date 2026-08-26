import Foundation
import Testing
@testable import CmuxWorkspaces

@MainActor
@Suite struct WorkspaceColorSectionReorder {
    @Test func permutesOnlyMemberSlots() {
        let first = CoordinatorStubTab()
        let nonmember = CoordinatorStubTab()
        let second = CoordinatorStubTab()
        let third = CoordinatorStubTab()
        let model = WorkspacesModel<CoordinatorStubTab>()
        model.tabs = [first, nonmember, second, third]
        let host = StubGroupHost(model: model)
        let coordinator = WorkspaceReorderCoordinator(model: model)
        coordinator.attach(host: host)

        #expect(coordinator.reorderWorkspaceWithinColorSection(
            tabId: third.id,
            targetWorkspaceId: first.id,
            insertBefore: true,
            memberWorkspaceIds: [first.id, second.id, third.id]
        ))
        #expect(model.tabs.map(\.id) == [third.id, nonmember.id, first.id, second.id])
        #expect(host.orderChanges == [[third.id]])
    }

    @Test func rejectsStaleGroupedAndCrossTierMembers() {
        let first = CoordinatorStubTab()
        let pinned = CoordinatorStubTab(isPinned: true)
        let grouped = CoordinatorStubTab(groupId: UUID())
        let model = WorkspacesModel<CoordinatorStubTab>()
        model.tabs = [first, pinned, grouped]
        let coordinator = WorkspaceReorderCoordinator(model: model)

        #expect(!coordinator.reorderWorkspaceWithinColorSection(
            tabId: first.id,
            targetWorkspaceId: pinned.id,
            insertBefore: true,
            memberWorkspaceIds: [first.id, pinned.id]
        ))
        #expect(!coordinator.reorderWorkspaceWithinColorSection(
            tabId: first.id,
            targetWorkspaceId: grouped.id,
            insertBefore: true,
            memberWorkspaceIds: [first.id, grouped.id]
        ))
        #expect(!coordinator.reorderWorkspaceWithinColorSection(
            tabId: first.id,
            targetWorkspaceId: UUID(),
            insertBefore: true,
            memberWorkspaceIds: [first.id]
        ))
    }
}
