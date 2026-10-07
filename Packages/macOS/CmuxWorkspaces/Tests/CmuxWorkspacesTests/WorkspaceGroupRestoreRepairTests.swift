import Foundation
import Testing
@testable import CmuxWorkspaces

// Nested workspace groups (#cm-106): the restore reads a legal tree, and what a window that is not a resting
// state draws before and after its first repair.
@MainActor
struct WorkspaceGroupRestoreRepairTests {
    private func group(_ lab: inout Labels, _ name: String, parent: String? = nil, ghost: UUID? = nil) -> WorkspaceGroup {
        WorkspaceGroup(
            id: lab.id(name),
            name: name,
            isCollapsed: false,
            isPinned: false,
            anchor: .empty(lab.id(name)),
            customColor: nil,
            iconSymbol: nil,
            parentGroupId: ghost ?? parent.map { lab.id($0) }
        )
    }

    @Test
    func aFileWithALoopOfGroupsIsRepairedAndEachRepairIsLoggedOnce() {
        var lab = Labels()
        let groups = [group(&lab, "A", parent: "B"), group(&lab, "B", parent: "A")]
        let result = WorkspaceGroupTree.repairingParents(of: groups)
        #expect(result.repairs == [.loop(group: lab.id("A"))])
        #expect(result.groups.map(\.parentGroupId) == [nil, lab.id("A")])
        #expect(result.repairs.map { WorkspaceGroupTree.message(for: $0) }
            == ["Repaired loop for group \(lab.id("A").uuidString) by clearing parent"])
    }

    @Test
    func aParentThatNamesNoGroupIsRepairedToTheTopLevel() {
        var lab = Labels()
        let ghost = UUID()
        let groups = [group(&lab, "A", ghost: ghost), group(&lab, "B", parent: "A")]
        let result = WorkspaceGroupTree.repairingParents(of: groups)
        #expect(result.repairs == [.unknownParent(group: lab.id("A"), parent: ghost)])
        #expect(result.groups.map(\.parentGroupId) == [nil, lab.id("A")])
        #expect(WorkspaceGroupTree.message(for: result.repairs[0])
            == "Repaired unknown parent for group \(lab.id("A").uuidString): parent \(ghost.uuidString) not found")
    }

    @Test
    func aLegalTreeIsLeftAsItIsWithNoRepair() {
        var lab = Labels()
        let groups = [group(&lab, "A"), group(&lab, "B", parent: "A")]
        let result = WorkspaceGroupTree.repairingParents(of: groups)
        #expect(result.repairs.isEmpty)
        #expect(result.groups == groups)
    }

    // The restore draws a window without repairing it. This shows what such a window draws before and
    // after the first bare repair, for the smallest window the design named.
    @Test
    func whatARestoredWindowThatIsNotARestingStateDrawsBeforeAndAfterItsFirstRepair() {
        var lab = Labels()
        let window = NestWindow(
            tabs: [lab.ws("w4", in: "G2", pinned: true), lab.ws("w2", in: "G1"), lab.ws("w1"), lab.ws("w0", pinned: true), lab.ws("w3", in: "G1")],
            groups: [lab.group("G0"), lab.group("G1", own: "w2"), lab.group("G2", pinned: true, own: "w4")]
        )
        let drawnBefore = compact(window, lab)
        var repaired = window
        repaired.bareRepair()
        let drawnAfter = compact(repaired, lab)
        print("restored window draws \(drawnBefore); after its first repair it draws \(drawnAfter)")
        #expect(drawnBefore == drawnAfter, "before \(drawnBefore) after \(drawnAfter)")
    }

    // The smallest window found that draws differently (Trouble, reported): the list of groups has G0 before G1 and
    // G2, but G2's run starts before G1's. The restore draws G0 above G1; the first repair lists G0 first and
    // draws it above G2. Characterised, not decided.
    @Test
    func theSmallestWindowFoundThatDrawsADifferentPlaceForAGroupWithNoWorkspaceAfterItsFirstRepair() {
        var lab = Labels()
        let window = NestWindow(
            tabs: [lab.ws("a", in: "G2"), lab.ws("b", in: "G1")],
            groups: [lab.group("G0"), lab.group("G1", own: "b"), lab.group("G2", own: "a")]
        )
        var repaired = window
        repaired.bareRepair()
        #expect(compact(window, lab) == "G2[a] | G0[-] | G1[b]")
        #expect(compact(repaired, lab) == "G0[-] | G2[a] | G1[b]")
    }

    // The same question over scrambled random windows, reported and not asserted: the design asks to decide nothing.
    @Test
    func whatScrambledRandomWindowsDrawBeforeAndAfterTheirFirstRepairIsCounted() {
        var differing = 0
        var first: String?
        var total = 0
        for index in 0..<300 {
            let seed = UInt64(97_000 + index)
            var rng = SplitMix64(seed: seed)
            var lab = Labels()
            let window = randomNestedWindow(&rng, &lab)
            var repaired = window
            repaired.bareRepair()
            total += 1
            let before = compact(window, lab), after = compact(repaired, lab)
            if before != after {
                differing += 1
                if first == nil { first = "seed \(seed): \(stored(window, lab)) draws \(before); after repair \(after)" }
            }
        }
        print("scrambled random windows: \(differing) of \(total) draw differently after the first repair; first: \(first ?? "none")")
        // Known: some windows do draw differently. If this ever reads 0 the
        // difference is gone and this test and the one above should be revisited.
        #expect(total == 300)
        #expect(differing > 0)
    }
}
