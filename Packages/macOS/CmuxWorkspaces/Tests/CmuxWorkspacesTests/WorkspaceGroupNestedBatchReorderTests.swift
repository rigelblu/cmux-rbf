import Foundation
import Testing
@testable import CmuxWorkspaces

// Nested workspace groups (#cm-106): `reorderWorkspaces` (socket `reorder_many`) in a window that holds a nested group. The rebuild
// from the requested order is repaired into group runs, which can place whole groups the request did not list; the
// notice names every workspace whose place changed.
@MainActor
struct WorkspaceGroupNestedBatchReorderTests {
    private typealias Spec = (tabs: [(String, String?)], groups: [(String, String?, String?)])

    /// `P[-: Q[q: q2]] | R[r]`: `P` has no workspace of its own.
    private let parentWithoutOwn: Spec = (
        [("q", "Q"), ("q2", "Q"), ("r", "R")],
        [("P", nil, nil), ("Q", "P", "q"), ("R", nil, "r")]
    )
    /// `R[r] | P[p: Q[q: q2]]`.
    private let parentWithOwn: Spec = (
        [("r", "R"), ("p", "P"), ("q", "Q"), ("q2", "Q")],
        [("R", nil, "r"), ("P", nil, "p"), ("Q", "P", "q")]
    )
    /// `R[r] | P[p: Q[q: S[s: s2]]]`: three levels.
    private let threeLevels: Spec = (
        [("r", "R"), ("p", "P"), ("q", "Q"), ("s", "S"), ("s2", "S")],
        [("R", nil, "r"), ("P", nil, "p"), ("Q", "P", "q"), ("S", "Q", "s")]
    )

    private struct Outcome {
        var before: [String]
        var after: [String]
        var notices: [Set<String>]
        var firstIds: [String?]
        var lists: [[String]]
        var plannedMoved: [String]
        var shape: String
    }

    private func run(_ spec: Spec, plan: [String]) -> Outcome {
        var lab = Labels()
        let tabs = spec.tabs.map { lab.ws($0.0, in: $0.1) }
        let groups = spec.groups.map { lab.group($0.0, parent: $0.1, own: $0.2) }
        let w = NestedWorld(NestWindow(tabs: tabs, groups: groups))
        let before = w.model.tabs.map { lab.name($0.id) }
        let noticesBefore = w.host.orderChanges.count
        // v0.31.0 lists the planned workspaces whose index the plan changes, in plan order.
        var plannedMoved: [String] = []
        if case .success(let items) = w.reorder.workspaceBatchReorderPlan(orderedWorkspaceIds: plan.map { lab.id($0) }) {
            plannedMoved = items.filter { $0.fromIndex != $0.toIndex }.map { lab.name($0.workspaceId) }
        }
        _ = w.reorder.reorderWorkspaces(orderedWorkspaceIds: plan.map { lab.id($0) })
        return Outcome(
            before: before,
            after: w.model.tabs.map { lab.name($0.id) },
            notices: w.host.orderChanges.dropFirst(noticesBefore).map { Set($0.map { lab.name($0) }) },
            firstIds: w.host.orderChanges.dropFirst(noticesBefore).map { $0.first.map { lab.name($0) } },
            lists: w.host.orderChanges.dropFirst(noticesBefore).map { $0.map { lab.name($0) } },
            plannedMoved: plannedMoved,
            shape: w.compact(lab)
        )
    }

    private func positionsChanged(_ outcome: Outcome) -> Set<String> {
        Set(outcome.after.enumerated().compactMap { index, name in outcome.before.firstIndex(of: name) == index ? nil : name })
    }

    @Test
    func aPlanThatMovesAGroupsRunNamesEveryWorkspaceWhosePlaceChanged() {
        let cases: [(String, Spec, [String])] = [
            ("a workspace behind a group's name, parent with no workspace of its own", parentWithoutOwn, ["r"]),
            ("the workspace behind a group's name", parentWithOwn, ["p"]),
            ("the workspace behind a child group's name", parentWithOwn, ["q"]),
            ("a plain workspace inside, which the repair does not honour", parentWithOwn, ["q2"]),
            ("a plain workspace and another group's workspace", parentWithOwn, ["q2", "r"]),
            ("three levels, the top parent's workspace", threeLevels, ["p"]),
            ("three levels, the deepest workspace", threeLevels, ["s2"])
        ]
        for (name, spec, plan) in cases {
            let outcome = run(spec, plan: plan)
            let changed = positionsChanged(outcome)
            print("BATCH \(name): plan \(plan): \(outcome.before) -> \(outcome.after); named \(outcome.notices)")
            #expect(!changed.isEmpty, "\(name): the order changed")
            #expect(outcome.notices.count == 1, "\(name): one notice, got \(outcome.notices)")
            #expect(changed.isSubset(of: outcome.notices.first ?? []), "\(name): names \(outcome.notices.first ?? []), but \(changed) changed place")
            #expect(Set(plan).isSubset(of: outcome.notices.first ?? []), "\(name): names the planned workspaces")
            // The planned workspaces come first, in the plan's order, as v0.31.0 lists them.
            #expect(Array((outcome.lists.first ?? []).prefix(outcome.plannedMoved.count)) == outcome.plannedMoved, "\(name): the notice starts with the plan's moved workspaces \(outcome.plannedMoved), got \(outcome.lists.first ?? [])")
        }
    }

    @Test
    func aPlanThatLeavesTheOrderAsItWasStillNamesWhatThePlanSaidMoved() {
        // As in a window with no nested group: the plan's own indexes decide the notice. Pinned here, not fixed.
        let outcome = run(parentWithoutOwn, plan: ["q2"])
        #expect(outcome.before == outcome.after)
        #expect(outcome.notices == [["q2"]])
    }

    @Test
    func aPlannedWorkspaceThatStaysPutStillPrecedesOneThatMoved() {
        // `P[p: Q[q: q2]] | R[r] | S[s: s2]`, plan `[q, s]`: `q` stays at its place, `s` moves up. The plan's order holds.
        let spec: Spec = (
            [("p", "P"), ("q", "Q"), ("q2", "Q"), ("r", "R"), ("s", "S"), ("s2", "S")],
            [("P", nil, "p"), ("Q", "P", "q"), ("R", nil, "r"), ("S", nil, "s")]
        )
        let outcome = run(spec, plan: ["q", "s"])
        #expect(outcome.before != outcome.after)
        #expect(outcome.lists == [["q", "s", "s2", "r"]], "\(outcome.lists)")
    }

    @Test
    func aPlanWhoseWorkspacesAllStayPutStillNamesThemFirstWhenTheRepairMovesAGroup() {
        // A seeded random window (`randomNestedWindow`, seed 7_000_011) and the plan `[w0, w3]`: the plan moves `w0`,
        // the repair puts it back and moves `w3` and `w2`. The plan's workspace comes first.
        var rng = SplitMix64(seed: 7_000_011)
        var lab = Labels()
        var start = randomNestedWindow(&rng, &lab)
        start.bareRepair()
        let w = NestedWorld(start)
        let before = w.model.tabs.map { lab.name($0.id) }
        let notices = w.host.orderChanges.count
        _ = w.reorder.reorderWorkspaces(orderedWorkspaceIds: [lab.id("w0"), lab.id("w3")])
        let after = w.model.tabs.map { lab.name($0.id) }
        #expect(before.firstIndex(of: "w0") == after.firstIndex(of: "w0"), "w0 stands where it did: \(before) -> \(after)")
        #expect(before != after)
        #expect(w.host.orderChanges.dropFirst(notices).map { $0.map { lab.name($0) } } == [["w0", "w3", "w2"]])
    }
}
