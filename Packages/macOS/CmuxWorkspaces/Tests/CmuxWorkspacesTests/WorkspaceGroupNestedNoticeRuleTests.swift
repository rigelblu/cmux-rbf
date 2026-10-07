import CoreGraphics
import Foundation
import Testing
import CmuxFoundation
@testable import CmuxWorkspaces

// Nested workspace groups (#cm-106): the notice rule, over random nested windows. After every step that changes the order of `tabs`,
// a notice was sent; and for the entrances that move a workspace or a group, its first id is a workspace the step
// moved (a workspace whose place changed), because the event bus takes the first id as the event's workspace.
@MainActor
struct WorkspaceGroupNestedNoticeRuleTests {
    private static let seeds = 80
    private static let stepsPerSeed = 30

    /// Nests a group again after the window stopped holding one: groups are made from loose workspaces until there are two
    /// top-level groups, and one goes into the other through `Move Group to`. False when the window is too small.
    private func nestAgain(_ w: NestedWorld) -> Bool {
        var made = 0
        while w.window.groups.filter({ $0.parentId == nil }).count < 2, made < 4 {
            made += 1
            let loose = w.window.tabs.filter { $0.groupId == nil && !w.window.isAnchor($0.id) }.prefix(1).map(\.id)
            guard w.groups.createWorkspaceGroup(name: "Again\(made)", childWorkspaceIds: Array(loose), collapseSidebarSelection: false) != nil else { break }
        }
        let top = w.window.groups.filter { $0.parentId == nil }
        guard top.count >= 2 else { return false }
        _ = w.groups.moveWorkspaceGroup(groupId: top[0].id, intoParent: top[1].id)
        return w.model.hasNestedWorkspaceGroup
    }

    /// A drop planned by the real planner at a random position of the drawn sidebar: the plan, what is selected, and
    /// what is dragged. Nil when the window offers none of the kind or the pointer plans nothing.
    private func randomDropPlan(
        _ w: NestedWorld,
        kind: Int,
        _ rng: inout SplitMix64
    ) -> (plan: SidebarWorkspaceReorderDropPlan, selected: Set<UUID>, dragged: UUID)? {
        let groups = w.model.workspaceGroups
        let anchors = Set(groups.compactMap(\.liveAnchorWorkspaceId))
        var selected: Set<UUID> = []
        let dragged: UUID
        switch kind {
        case 0:
            guard let tab = w.model.tabs.filter({ !anchors.contains($0.id) }).randomElement(using: &rng) else { return nil }
            dragged = tab.id
        case 1:
            guard let group = groups.filter({ $0.parentGroupId != nil && $0.liveAnchorWorkspaceId != nil }).randomElement(using: &rng),
                  let anchor = group.liveAnchorWorkspaceId else { return nil }
            dragged = anchor
        default:
            guard let tab = w.model.tabs.filter({ !anchors.contains($0.id) }).randomElement(using: &rng) else { return nil }
            dragged = tab.id
            selected = Set(w.model.tabs.filter { !anchors.contains($0.id) && Bool.random(using: &rng) }.map(\.id)).union([dragged])
        }
        let block = Set(SidebarWorkspaceDragBlockResolver().movingWorkspaceIds(
            orderedWorkspaceIds: w.model.tabs.map(\.id), selectedIds: selected, draggedId: dragged, anchorIds: anchors
        ))
        let probe = WorkspaceGroupNestedDropRuleTests.request(w, point: .zero, dragged: dragged, block: block.count > 1 ? block : [])
        guard let point = WorkspaceGroupNestedDropRuleTests.pointerPositions(probe).randomElement(using: &rng),
              let plan = SidebarWorkspaceReorderDropResolver().plan(
                for: WorkspaceGroupNestedDropRuleTests.request(w, point: point, dragged: dragged, block: block.count > 1 ? block : [])
              ) else { return nil }
        return (plan, selected, dragged)
    }

    @Test
    func aStepThatChangesTheOrderSendsANoticeAndNamesAMovedWorkspaceFirst() {
        var tried = [String: Int](), orderChanged = [String: Int]()
        var stepsRun = 0, renested = 0, gaveUp = 0
        var failures = [String]()
        for index in 0..<Self.seeds {
            let seed = UInt64(5_000_000 + index)
            var rng = SplitMix64(seed: seed)
            var lab = Labels()
            var start = randomNestedWindow(&rng, &lab)
            start.bareRepair()
            let w = NestedWorld(start, selected: start.tabs.randomElement(using: &rng)?.id)
            for step in 0..<Self.stepsPerSeed {
                if !w.model.hasNestedWorkspaceGroup {
                    guard nestAgain(w) else { gaveUp += 1; break }
                    renested += 1
                }
                guard w.model.tabs.count >= 2 else { break }
                let window = w.window
                let orderBefore = window.tabs.map(\.id)
                let noticesBefore = w.host.orderChanges.count
                // Entrances whose first id must be a workspace the step moved are `mover`; the others only need a notice.
                var mover = true
                var chosen: Set<UUID>?
                let name: String
                switch Int.random(in: 0..<15, using: &rng) {
                case 0:
                    name = "move to top (one)"
                    let t = window.tabs.randomElement(using: &rng)!
                    chosen = [t.id]
                    w.reorder.moveTabToTop(t.id)
                case 1:
                    name = "move to top (several)"
                    let some = window.tabs.filter { _ in Bool.random(using: &rng) }.map(\.id)
                    guard !some.isEmpty else { continue }
                    chosen = Set(some)
                    mover = false
                    w.reorder.moveTabsToTop(Set(some))
                case 2:
                    name = "notification move"
                    let t = window.tabs.randomElement(using: &rng)!
                    chosen = [t.id]
                    w.reorder.moveTabToTopForNotification(t.id)
                case 3:
                    name = "step"
                    let t = window.tabs.randomElement(using: &rng)!
                    let at = window.tabs.firstIndex { $0.id == t.id }!
                    chosen = [t.id]
                    _ = w.reorder.reorderWorkspace(tabId: t.id, toIndex: at + [-1, 1].randomElement(using: &rng)!)
                case 4:
                    name = "socket index"
                    let t = window.tabs.randomElement(using: &rng)!
                    chosen = [t.id]
                    _ = w.reorder.reorderWorkspace(tabId: t.id, toIndex: Int.random(in: 0..<window.tabs.count, using: &rng))
                case 5:
                    name = "header drag"
                    guard let g = window.groups.filter({ $0.parentId == nil }).randomElement(using: &rng),
                          let anchor = g.anchorWorkspaceId else { continue }
                    chosen = [anchor]
                    _ = w.reorder.reorderSidebarWorkspace(tabId: anchor, toIndex: Int.random(in: 0..<window.tabs.count, using: &rng), isDragOperation: true, usesTopLevelRows: true)
                case 6:
                    name = "reorder_many"
                    let ids = window.tabs.shuffled(using: &rng).prefix(Int.random(in: 1...3, using: &rng)).map(\.id)
                    // v0.31.0 lists the planned workspaces first, whether or not they stand elsewhere after the repair.
                    chosen = Set(ids)
                    mover = false
                    _ = w.reorder.reorderWorkspaces(orderedWorkspaceIds: Array(ids))
                case 7:
                    name = "pin group"
                    guard let g = window.groups.randomElement(using: &rng) else { continue }
                    w.groups.setWorkspaceGroupPinned(groupId: g.id, isPinned: !g.isPinned)
                case 8:
                    name = "move group by index"
                    guard let g = window.groups.filter({ $0.parentId == nil }).randomElement(using: &rng) else { continue }
                    w.groups.moveWorkspaceGroup(groupId: g.id, toIndex: Int.random(in: 0..<window.groups.count, using: &rng))
                case 9:
                    name = "move group beside"
                    guard let g = window.groups.randomElement(using: &rng),
                          let other = window.groups.filter({ $0.parentId == g.parentId && $0.id != g.id }).randomElement(using: &rng) else { continue }
                    _ = w.groups.moveWorkspaceGroup(groupId: g.id, beside: other.id, after: Bool.random(using: &rng))
                case 10:
                    name = "move group to"
                    mover = false
                    guard let g = window.groups.randomElement(using: &rng) else { continue }
                    _ = w.groups.moveWorkspaceGroup(groupId: g.id, intoParent: Bool.random(using: &rng) ? nil : window.groups.randomElement(using: &rng)?.id)
                case 11:
                    name = "ungroup"
                    mover = false
                    guard let g = window.groups.randomElement(using: &rng) else { continue }
                    _ = w.groups.ungroupWorkspaceGroup(groupId: g.id)
                default:
                    // The drop entrances: a workspace, a nested group's header, and several workspaces,
                    // planned by the real planner and committed the way the sidebar commits.
                    let drop = Int.random(in: 0..<3, using: &rng)
                    name = ["drop one workspace", "drop a nested header", "drop several workspaces"][drop]
                    mover = drop != 2
                    guard let planned = randomDropPlan(w, kind: drop, &rng) else { continue }
                    chosen = drop == 1 ? Set(w.model.workspaceIdsInside(
                        w.model.workspaceGroups.first { $0.liveAnchorWorkspaceId == planned.dragged }?.id ?? UUID()
                    )) : (drop == 2 ? planned.selected : [planned.dragged])
                    _ = WorkspaceGroupNestedDropRuleTests.commit(planned.plan, w, selected: planned.selected)
                }
                tried[name, default: 0] += 1
                stepsRun += 1
                let orderAfter = w.model.tabs.map(\.id)
                guard orderAfter != orderBefore else { continue }
                orderChanged[name, default: 0] += 1
                let notices = Array(w.host.orderChanges.dropFirst(noticesBefore))
                let where_ = "seed \(seed) step \(step) \(name) | before \(orderBefore.map { lab.name($0) }) after \(orderAfter.map { lab.name($0) }) | notices \(notices.map { $0.map { lab.name($0) } })"
                guard let first = notices.first?.first else {
                    failures.append("no notice: \(where_)")
                    continue
                }
                if mover {
                    let placeChanged = orderBefore.firstIndex(of: first) != orderAfter.firstIndex(of: first)
                    if !placeChanged { failures.append("first id did not change place: \(where_)") }
                    if let chosen, chosen.count == 1, !chosen.contains(first), name != "reorder_many", !name.hasPrefix("pin"), !name.hasPrefix("move group") {
                        failures.append("first id is not the moved workspace: \(where_)")
                    }
                } else if let chosen, !chosen.contains(first) {
                    failures.append("first id is not one of the moved workspaces: \(where_)")
                }
            }
        }
        print("aStepThatChangesTheOrder: \(stepsRun) of \(Self.seeds * Self.stepsPerSeed) steps ran, window nested again \(renested) times, seeds given up \(gaveUp); tried \(tried.sorted { $0.key < $1.key }), order changed \(orderChanged.sorted { $0.key < $1.key })")
        #expect(failures.isEmpty, "\(failures.count) steps broke the rule; first: \(failures.prefix(3))")
        // Every entrance the test drives changed the order in at least 3 steps.
        for name in [
            "move to top (one)", "move to top (several)", "notification move", "step", "socket index", "header drag",
            "reorder_many", "pin group", "move group by index", "move group beside", "move group to", "ungroup",
            "drop one workspace", "drop a nested header", "drop several workspaces"
        ] {
            #expect((orderChanged[name] ?? 0) >= 3, "too few steps changed the order for \(name): \(orderChanged[name] ?? 0)")
        }
        #expect(stepsRun >= Self.seeds * Self.stepsPerSeed * 8 / 10, "only \(stepsRun) of \(Self.seeds * Self.stepsPerSeed) steps ran")
    }
}
