import Foundation
import Testing
@testable import CmuxFoundation
@testable import CmuxWorkspaces

// Nested workspace groups (#cm-106): a group's header cannot be dragged to another window, nested or not. The sidebar
// asks `SidebarWorkspaceDragActivationPolicy` with `isSourceGroupAnchor`, which it reads from the source window's groups
// as "some group, at any level, has this workspace as its own workspace" (`ContentView.swift`, the two
// `shouldRejectMirroring` calls). These tests read that fact from nested `WorkspaceGroup` values the same way and give
// it to the policy. The policy's own tests live in `CmuxFoundation`, whose test target does not build on this toolchain.
struct SidebarNestedHeaderDragPolicyTests {
    private let policy = SidebarWorkspaceDragActivationPolicy()

    /// `P` (top level, with a workspace) holds `C` (with a workspace) and `E` (no workspace of its own).
    private func groups() -> (groups: [WorkspaceGroup], p: UUID, c: UUID, member: UUID) {
        let p = UUID(), c = UUID(), member = UUID()
        let all = [
            NestGroup(id: UUID(), parentId: nil, isPinned: false, anchorWorkspaceId: p),
            NestGroup(id: UUID(), parentId: nil, isPinned: false, anchorWorkspaceId: c),
            NestGroup(id: UUID(), parentId: nil, isPinned: false, anchorWorkspaceId: nil)
        ]
        var groups = all.map { $0.toWorkspaceGroup() }
        groups[1].parentGroupId = groups[0].id
        groups[2].parentGroupId = groups[0].id
        return (groups, p, c, member)
    }

    /// What the sidebar computes for the dragged id in the source window.
    private func isSourceGroupAnchor(_ dragged: UUID, in groups: [WorkspaceGroup]) -> Bool {
        groups.contains { $0.liveAnchorWorkspaceId == dragged }
    }

    @Test func aNestedHeaderThatHasAWorkspaceIsRejectedForAnotherWindow() {
        let w = groups()
        let anchor = isSourceGroupAnchor(w.c, in: w.groups)
        #expect(anchor, "the nested group's own workspace is read as a group anchor")
        #expect(policy.shouldRejectMirroring(isLocalWorkspace: false, isSourceGroupAnchor: anchor))
        #expect(!policy.shouldRejectMirroring(isLocalWorkspace: true, isSourceGroupAnchor: anchor), "the same window may still re-arm it")
    }

    @Test func aTopLevelHeaderIsRejectedForAnotherWindowToo() {
        let w = groups()
        let anchor = isSourceGroupAnchor(w.p, in: w.groups)
        #expect(anchor)
        #expect(policy.shouldRejectMirroring(isLocalWorkspace: false, isSourceGroupAnchor: anchor))
    }

    @Test func aNestedHeaderWithNoWorkspaceIsNeverMistakenForAWorkspaceSoOnlyItsGroupIdCouldBeDragged() {
        // A header with none is dragged by its group id. The sidebar's source lookup for another window is by workspace
        // id (`tabManagerFor(tabId:)`) and finds nothing for a group id, so it never gets to the policy. What this checks
        // is the other half: the group has no live workspace, so no workspace id reads as its anchor.
        let w = groups()
        let empty = w.groups[2]
        #expect(empty.liveAnchorWorkspaceId == nil)
        #expect(!isSourceGroupAnchor(UUID(), in: w.groups))
        #expect(!isSourceGroupAnchor(empty.id, in: w.groups), "its group id is not read as a workspace anchor either")
    }

    @Test func anOrdinaryWorkspaceInANestedWindowStillMovesToAnotherWindow() {
        let w = groups()
        let anchor = isSourceGroupAnchor(w.member, in: w.groups)
        #expect(!anchor)
        #expect(!policy.shouldRejectMirroring(isLocalWorkspace: false, isSourceGroupAnchor: anchor))
    }
}
