import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite("WorkspaceGroupTreeTests")
struct WorkspaceGroupTreeTests {
    @Test
    func unknownParentIsRepairedToTopLevel() {
        let ghost = UUID()
        let groupA = UUID()
        let tree = WorkspaceGroupTree(items: [(id: groupA, parentGroupId: ghost)])
        #expect(tree.parent(of: groupA) == nil)
        #expect(tree.repairs == [.unknownParent(group: groupA, parent: ghost)])
        #expect(tree.depth(of: groupA) == 0)
        #expect(tree.children(of: nil) == [groupA])
    }

    @Test
    func oneLoopIsOpenedAtFirstInListOrder() {
        let a = UUID()
        let b = UUID()
        // A -> B, B -> A, with [A, B] order: A opened to top level
        let treeAB = WorkspaceGroupTree(items: [
            (id: a, parentGroupId: b),
            (id: b, parentGroupId: a)
        ])
        #expect(treeAB.parent(of: a) == nil)
        #expect(treeAB.parent(of: b) == a)
        #expect(treeAB.repairs == [.loop(group: a)])
        #expect(treeAB.depth(of: a) == 0)
        #expect(treeAB.depth(of: b) == 1)
        #expect(treeAB.children(of: a) == [b])

        // Reversed list order [B, A]: B opened to top level
        let treeBA = WorkspaceGroupTree(items: [
            (id: b, parentGroupId: a),
            (id: a, parentGroupId: b)
        ])
        #expect(treeBA.parent(of: b) == nil)
        #expect(treeBA.parent(of: a) == b)
        #expect(treeBA.repairs == [.loop(group: b)])
    }

    @Test
    func selfLoopIsRepaired() {
        let a = UUID()
        let tree = WorkspaceGroupTree(items: [(id: a, parentGroupId: a)])
        #expect(tree.parent(of: a) == nil)
        #expect(tree.repairs == [.loop(group: a)])
        #expect(tree.depth(of: a) == 0)
    }

    @Test
    func twoLoopsAreBothRepaired() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let d = UUID()
        let tree = WorkspaceGroupTree(items: [
            (id: a, parentGroupId: b),
            (id: b, parentGroupId: a),
            (id: c, parentGroupId: d),
            (id: d, parentGroupId: c)
        ])
        #expect(tree.repairs == [.loop(group: a), .loop(group: c)])
        #expect(tree.parent(of: a) == nil)
        #expect(tree.parent(of: b) == a)
        #expect(tree.parent(of: c) == nil)
        #expect(tree.parent(of: d) == c)
        #expect(tree.descendants(of: a) == [b])
        #expect(tree.descendants(of: c) == [d])
    }

    @Test
    func chainLeadingIntoLoopLeavesLeadingNodeUnderParent() {
        // C -> A, A -> B, B -> A, listed [C, A, B]
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let tree = WorkspaceGroupTree(items: [
            (id: c, parentGroupId: a),
            (id: a, parentGroupId: b),
            (id: b, parentGroupId: a)
        ])
        #expect(tree.repairs == [.loop(group: a)])
        #expect(tree.parent(of: c) == a)
        #expect(tree.parent(of: a) == nil)
        #expect(tree.parent(of: b) == a)
        #expect(tree.depth(of: a) == 0)
        #expect(tree.depth(of: b) == 1)
        #expect(tree.depth(of: c) == 1)
        #expect(tree.children(of: a) == [c, b])
    }

    @Test
    func readsAcrossAChainOfThreeGroups() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let tree = WorkspaceGroupTree(items: [
            (id: a, parentGroupId: nil),
            (id: b, parentGroupId: a),
            (id: c, parentGroupId: b)
        ])
        #expect(tree.isInside(c, a))
        #expect(!tree.isInside(a, c))
        #expect(tree.descendants(of: a) == [b, c])
        #expect(tree.contains(b))
        #expect(!tree.contains(UUID()))
        #expect(tree.order == [a, b, c])
    }
}
