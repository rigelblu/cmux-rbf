import Foundation
import Testing
import CmuxSettings
@testable import CmuxWorkspaces

// The nested order repair does the same amount of set-building work however many loose workspaces the window holds
// (#cm-106). It counts the work, not the time: a time budget passes on an idle machine and fails on a loaded one.
@MainActor
struct WorkspaceGroupNestedOrderRepairCostTests {
    private func window(looseCount: Int) -> (NestedWorld, Labels) {
        var lab = Labels()
        var tabs = [lab.ws("p", in: "P"), lab.ws("c", in: "C"), lab.ws("c2", in: "C")]
        for index in 0..<looseCount { tabs.append(lab.ws("l\(index)")) }
        let groups = [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c")]
        return (NestedWorld(NestWindow(tabs: tabs, groups: groups), selected: nil), lab)
    }

    #if DEBUG
    @Test
    func theRepairBuildsTheSetOfTopLevelRowsOnceHoweverManyLooseWorkspacesThereAre() {
        var builds: [Int] = []
        for looseCount in [4, 40, 400] {
            let (w, lab) = window(looseCount: looseCount)
            #expect(w.model.hasNestedWorkspaceGroup)
            let before = w.model.nestedTopLevelRowSetBuilds
            w.model.nestedNormalizeWorkspaceGroupRunsPreservingOrder(w.model.tabs.map(\.id).reversed())
            builds.append(w.model.nestedTopLevelRowSetBuilds - before)
            #expect(w.violations(lab).isEmpty)
        }
        #expect(builds == [1, 1, 1], "set builds per repair at 4, 40 and 400 loose workspaces")
    }
    #endif

    @Test
    func theRepairPutsTheLooseWorkspacesAndTheGroupInTheOrderAsked() {
        let (w, lab) = window(looseCount: 3)
        let desired = [lab.idByName["l2"]!, lab.idByName["l0"]!, lab.idByName["p"]!, lab.idByName["l1"]!]
        w.model.nestedNormalizeWorkspaceGroupRunsPreservingOrder(desired)
        #expect(w.compact(lab) == "l2 | l0 | P[p: C[c: c2]] | l1")
        #expect(w.violations(lab).isEmpty)
    }
}
