import Foundation
import Testing
@testable import CmuxWorkspaces

@MainActor
struct WorkspaceSeparatelyPinnedRevealTests {
    @Test(arguments: [false, true])
    func selectionAndMoveOpenOnlyGroupsThatStillHideTheWorkspace(_ nested: Bool) {
        var labels = Labels()
        let parent = labels.group("P", own: "p")
        let group = labels.group("G", parent: nested ? "P" : nil, own: "g")
        var tabs = [labels.ws("g", in: "G"), labels.ws("pin", in: "G", pinned: true), labels.ws("plain", in: "G")]
        if nested { tabs.insert(labels.ws("p", in: "P"), at: 0) }
        let pin = labels.id("pin")
        let world = NestedWorld(.init(tabs: tabs, groups: nested ? [parent, group] : [group]), selected: pin)
        for index in world.model.workspaceGroups.indices { world.model.workspaceGroups[index].isCollapsed = true }
        world.model.workspaceIdsShownInPinned = { [pin] }
        world.model.expandWorkspaceGroupForSelectionIfNeeded()
        #expect(world.model.workspaceGroups.allSatisfy { $0.isCollapsed })
        world.model.workspaceIdsShownInPinned = { [] }
        world.model.expandWorkspaceGroups(containing: [pin])
        #expect(world.model.workspaceGroups.allSatisfy { !$0.isCollapsed })
    }
}

extension WorkspaceSeparatelyPinnedRevealTests {
    enum CollapseCase: CaseIterable { case flat, nested, parent }

    @Test(arguments: CollapseCase.allCases, [false, true])
    func foldingKeepsEveryStillVisiblePinSelected(_ kind: CollapseCase, _ sections: Bool) {
        var labels = Labels()
        let nested = kind != .flat
        let parent = labels.group("P", own: "p")
        let group = labels.group("G", parent: nested ? "P" : nil, own: "g")
        var tabs = [labels.ws("g", in: "G"), labels.ws("pin", in: "G", pinned: true), labels.ws("plain", in: "G")]
        if nested { tabs.insert(labels.ws("p", in: "P"), at: 0) }
        let pin = labels.id("pin"), plain = labels.id("plain")
        let world = NestedWorld(.init(tabs: tabs, groups: nested ? [parent, group] : [group]), selected: pin)
        world.model.workspaceIdsShownInPinned = { sections ? [pin] : [] }
        world.host.sidebarSelectedWorkspaceIds = [pin, plain]
        let foldedGroup = kind == .parent ? parent.id : group.id
        world.groups.toggleWorkspaceGroupCollapsed(groupId: foldedGroup)
        #expect(world.model.workspaceGroups.first { $0.id == foldedGroup }?.isCollapsed == true)
        #expect(world.model.selectedTabId == (sections ? pin : (kind == .parent ? parent.anchorWorkspaceId : group.anchorWorkspaceId)))
        #expect(world.host.sidebarSelectedWorkspaceIds.contains(pin) == sections, "only a pin actually hidden by the fold leaves the multi-selection")
        #expect(!world.host.sidebarSelectedWorkspaceIds.contains(plain))
    }
}
