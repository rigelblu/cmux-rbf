import CoreGraphics
import Foundation
import Testing
@testable import CmuxFoundation
@testable import CmuxWorkspaces

// The drop planner keeps its own copy of the group tree, because its package cannot see the model (#cm-106). These
// tests give that copy the broken inputs `WorkspaceGroupTreeTests` gives the model's tree (a self-parent, a loop of
// two, a chain that leads into a loop, a parent that names no group), and then give both trees the same random
// input and compare what each says holds what.
struct SidebarNestedGroupDropTreeRepairTests {
    private typealias Link = (id: UUID, parent: UUID?)

    /// The planner's tree, read through the context the planner builds from a request.
    private func plannerTree(_ links: [Link]) -> SidebarNestedGroupTree {
        let request = SidebarWorkspaceReorderDropRequest(
            point: .zero,
            draggedWorkspaceId: UUID(),
            workspaces: [],
            groups: links.map {
                SidebarWorkspaceReorderGroupSnapshot(
                    id: $0.id,
                    anchorWorkspaceId: UUID(),
                    isPinned: false,
                    isEmpty: true,
                    parentGroupId: $0.parent
                )
            },
            targets: []
        )
        return SidebarNestedGroupDropContext(request: request, sortedTargets: []).tree
    }

    private func modelTree(_ links: [Link]) -> WorkspaceGroupTree {
        WorkspaceGroupTree(items: links.map { (id: $0.id, parentGroupId: $0.parent) })
    }

    @Test
    func aGroupNamedAsItsOwnParentIsReadAsTopLevel() {
        let a = UUID()
        let tree = plannerTree([(a, a)])
        #expect(tree.parent(of: a) == nil)
        #expect(tree.children(of: nil) == [a])
    }

    @Test
    func aLoopOfTwoIsOpenedAtTheFirstGroupInListOrder() {
        let a = UUID()
        let b = UUID()
        let forward = plannerTree([(a, b), (b, a)])
        #expect(forward.parent(of: a) == nil)
        #expect(forward.parent(of: b) == a)
        #expect(forward.children(of: a) == [b])
        let reversed = plannerTree([(b, a), (a, b)])
        #expect(reversed.parent(of: b) == nil)
        #expect(reversed.parent(of: a) == b)
    }

    @Test
    func aChainThatLeadsIntoALoopStaysUnderItsParent() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let tree = plannerTree([(c, a), (a, b), (b, a)])
        #expect(tree.parent(of: c) == a)
        #expect(tree.parent(of: a) == nil)
        #expect(tree.parent(of: b) == a)
        #expect(tree.children(of: a) == [c, b])
    }

    @Test
    func aParentThatNamesNoGroupIsReadAsTopLevel() {
        let a = UUID()
        let tree = plannerTree([(a, UUID())])
        #expect(tree.parent(of: a) == nil)
        #expect(tree.children(of: nil) == [a])
    }

    @Test
    func theModelsTreeAndThePlannersTreeSayTheSameThingOnRandomBrokenInput() {
        var compared = 0
        var broken = 0
        for seed in 0..<400 {
            var rng = SplitMix64(seed: UInt64(70_000 + seed))
            let count = Int.random(in: 1...8, using: &rng)
            let ids = (0..<count).map { _ in UUID() }
            let links: [Link] = ids.map { id in
                switch Int.random(in: 0..<4, using: &rng) {
                case 0: (id, nil)
                case 1: (id, UUID())
                default: (id, ids.randomElement(using: &rng))
                }
            }
            let model = modelTree(links)
            let planner = plannerTree(links)
            if !model.repairs.isEmpty { broken += 1 }
            for id in ids {
                #expect(planner.parent(of: id) == model.parent(of: id), "seed \(seed): parent of group \(ids.firstIndex(of: id) ?? -1)")
                #expect(planner.chain(from: id) == [id] + model.ancestors(of: id), "seed \(seed): groups above group \(ids.firstIndex(of: id) ?? -1)")
                #expect(planner.children(of: id) == model.children(of: id), "seed \(seed): groups inside group \(ids.firstIndex(of: id) ?? -1)")
                compared += 1
            }
            #expect(planner.children(of: nil) == model.children(of: nil), "seed \(seed): top level")
        }
        // The random input must actually contain loops and dangling parents, or the comparison proves nothing.
        #expect(broken > 100, "windows with something to repair: \(broken) of 400")
        #expect(compared > 1_000)
    }
}
