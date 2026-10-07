import Foundation
import Testing
import CmuxSettings
@testable import CmuxWorkspaces

// Scenario 40 (#cm-106), over the nested order and coordinator functions: after every step of a long random sequence of operations
// on a window with nested groups, the six rules hold.
@MainActor
struct WorkspaceGroupNestedSequenceTests {
    private static let operations = [
        "close", "move to another window", "pin group", "pin workspace", "ungroup", "delete group", "fold",
        "add workspace", "remove workspace", "new workspace in group", "move group by index", "move child group by index",
        "move to top", "notification move", "step", "socket index", "refused drag", "repair",
        "single drag", "block drag", "reorder workspaces", "reorder before", "set anchor", "set pinned several",
        "move group to", "new group in place", "move group beside"
    ]

    /// Puts the window back into a nested state: creates groups (a flat window runs upstream's code) until there
    /// are three, then nests one in another, so a group with a group beside it exists. Test setup only; nothing in the app nests a group yet.
    private func makeNested(_ w: NestedWorld, _ rng: inout SplitMix64, _ lab: inout Labels) {
        var guardCount = 0
        while w.window.groups.count < 4 && guardCount < 6 {
            guardCount += 1
            let loose = w.window.tabs.filter { $0.groupId == nil && !w.window.isAnchor($0.id) }.prefix(2).map(\.id)
            _ = w.groups.createWorkspaceGroup(name: "R\(w.window.groups.count)", childWorkspaceIds: Array(loose), collapseSidebarSelection: false)
        }
        // Two groups go inside the same parent, so a group with a group beside it exists inside a parent too.
        let top = w.window.groups.filter { $0.parentId == nil }
        if let parent = top.randomElement(using: &rng) {
            for child in top.filter({ $0.id != parent.id }).shuffled(using: &rng).prefix(2) {
                if let index = w.model.workspaceGroups.firstIndex(where: { $0.id == child.id }) {
                    w.model.workspaceGroups[index].parentGroupId = parent.id
                }
            }
            w.model.normalizeWorkspaceGroupContiguity()
        } else {
            _ = nest(w, &rng, &lab)
        }
    }

    private func nest(_ w: NestedWorld, _ rng: inout SplitMix64, _ lab: inout Labels) -> String? {
        let window = w.window
        let tree = WorkspaceGroupTree(items: window.groups.map { ($0.id, $0.parentId) })
        let pairs = window.groups.flatMap { g in
            window.groups.compactMap { d -> (UUID, UUID)? in
                guard d.id != g.id, !tree.isInside(d.id, g.id), tree.parent(of: g.id) != d.id else { return nil }
                return (g.id, d.id)
            }
        }
        guard let (child, parent) = pairs.randomElement(using: &rng),
              let index = w.model.workspaceGroups.firstIndex(where: { $0.id == child }) else { return nil }
        w.model.workspaceGroups[index].parentGroupId = parent
        w.model.normalizeWorkspaceGroupContiguity()
        return "nest: \(lab.name(child)) into \(lab.name(parent))"
    }

    @Test
    func theSixRulesHoldAfterEveryStepOfLongRandomSequencesOfStep2sOperations() {
        let seeds = Int(ProcessInfo.processInfo.environment["CM106_SEEDS"] ?? "") ?? 60
        var tried = [String: Int]()
        var changed = [String: Int]()
        var startedNested = 0
        var steps = 0
        var rebuilt = 0
        var deepStates = 0
        var noWorkspaceGroupStates = 0
        var failures = 0
        for index in 0..<seeds {
            let seed = UInt64(98_000 + index)
            var rng = SplitMix64(seed: seed)
            var lab = Labels()
            var start = randomNestedWindow(&rng, &lab)
            start.bareRepair()
            let w = NestedWorld(start, selected: start.tabs.randomElement(using: &rng)?.id)
            var history: [String] = []
            for step in 0..<120 {
                steps += 1
                let nestedBefore = w.model.hasNestedWorkspaceGroup
                if !nestedBefore { makeNested(w, &rng, &lab); rebuilt += 1 }
                let before = w.window
                let foldsBefore = w.model.workspaceGroups.map(\.isCollapsed)
                let isNested = before.groups.contains { $0.parentId != nil }
                let operation = Self.operations.randomElement(using: &rng)!
                if ProcessInfo.processInfo.environment["CM106_TRACE"] != nil {
                    FileHandle.standardError.write(Data("TRACE seed \(seed) step \(step) \(operation) | \(stored(before, lab))\n".utf8))
                }
                guard let text = apply(operation, to: w, &rng, &lab) else { continue }
                history.append(text)
                let after = w.window
                if isNested {
                    startedNested += 1
                    tried[operation, default: 0] += 1
                    if after != before || w.model.workspaceGroups.map(\.isCollapsed) != foldsBefore { changed[operation, default: 0] += 1 }
                }
                // A window that was flat before the step ran upstream's code, with upstream's own quirks (Ungroup
                // leaves rows where they are), so only a step that started in a nested window is held to the rules.
                let problems = isNested ? nestViolations(after, lab) : []
                let facts = WindowFacts(after)
                if after.groups.contains(where: { facts.depth($0.id) >= 2 }) { deepStates += 1 }
                if !facts.noRunGroups.isEmpty { noWorkspaceGroupStates += 1 }
                if !problems.isEmpty {
                    failures += 1
                    Issue.record("Seed \(seed) step \(step): \(text) -> \(problems) | before \(stored(before, lab)) | after \(stored(after, lab)) | last \(history.suffix(4))")
                    break
                }
            }
        }
        for name in Self.operations.sorted() {
            print("sequences: \(name): \(tried[name] ?? 0) tried in a nested window, \(changed[name] ?? 0) changed it")
            #expect((tried[name] ?? 0) > 0, "never tried in a nested window: \(name)")
            if name != "repair" { #expect((changed[name] ?? 0) > 0, "never changed a nested window: \(name)") }
            if name == "move group by index" { #expect((changed[name] ?? 0) >= 40, "a move among the top-level groups changed a nested window only \(changed[name] ?? 0) times") }
            if name == "move group to" || name == "new group in place" {
                #expect((changed[name] ?? 0) >= 40, "\(name) changed a nested window only \(changed[name] ?? 0) times")
            }
            if name == "move group beside" { #expect((changed[name] ?? 0) >= 40, "a move beside a group changed a nested window only \(changed[name] ?? 0) times") }
            if name == "move child group by index" { #expect((changed[name] ?? 0) >= 40, "a move among the groups inside a parent changed a nested window only \(changed[name] ?? 0) times") }
        }
        print("sequences: \(steps) steps, \(startedNested) started in a nested window (\(rebuilt) windows rebuilt as nested), \(deepStates) states two or more levels deep, \(noWorkspaceGroupStates) states with a group holding no workspace")
        #expect(failures == 0)
        #expect(startedNested >= 2000, "steps that started nested: \(startedNested)")
        #expect(deepStates > 0)
        #expect(noWorkspaceGroupStates > 0)
    }

    /// The first nest of a window comes from an entrance, not from test setup: starting flat, `Move Group to` and a
    /// new group made in place each make the first nested group, and the six rules hold after it.
    @Test
    func theFirstNestFromAFlatWindowThroughTheEntrancesKeepsTheSixRules() {
        var firstNests = ["move group to": 0, "new group in place": 0]
        var tries = ["move group to": 0, "new group in place": 0]
        var failures = 0
        for index in 0..<400 {
            let seed = UInt64(96_000 + index)
            var rng = SplitMix64(seed: seed)
            var lab = Labels()
            let start = upstreamNormalized(randomFlatWindow(&rng))
            let w = NestedWorld(start, selected: start.tabs.randomElement(using: &rng)?.id)
            guard !w.model.hasNestedWorkspaceGroup else { continue }
            let operation = index % 2 == 0 ? "move group to" : "new group in place"
            if operation == "move group to" {
                guard start.groups.count >= 2,
                      let g = start.groups.randomElement(using: &rng),
                      let destination = start.groups.filter({ $0.id != g.id }).randomElement(using: &rng) else { continue }
                tries[operation, default: 0] += 1
                _ = w.groups.moveWorkspaceGroup(groupId: g.id, intoParent: destination.id)
            } else {
                let grouped = start.tabs.filter { $0.groupId != nil && !start.isAnchor($0.id) }
                guard let first = grouped.randomElement(using: &rng) else { continue }
                tries[operation, default: 0] += 1
                let more = start.tabs.filter { $0.id != first.id && !start.isAnchor($0.id) && Bool.random(using: &rng) }
                _ = w.groups.createWorkspaceGroup(name: "Made", childWorkspaceIds: [first.id] + more.map(\.id), collapseSidebarSelection: false)
            }
            if w.model.hasNestedWorkspaceGroup { firstNests[operation, default: 0] += 1 }
            let problems = nestViolations(w.window, lab)
            if !problems.isEmpty {
                failures += 1
                Issue.record("Seed \(seed) \(operation): \(problems)")
            }
        }
        for name in firstNests.keys.sorted() {
            print("first nests: \(name): \(tries[name] ?? 0) tried from a flat window, \(firstNests[name] ?? 0) made the first nested group")
            #expect((firstNests[name] ?? 0) >= 30, "\(name) made the first nested group only \(firstNests[name] ?? 0) times")
        }
        #expect(failures == 0)
    }

    /// Runs one operation on a random subject. Returns what it did, or nil when nothing could be drawn.
    private func apply(_ operation: String, to w: NestedWorld, _ rng: inout SplitMix64, _ lab: inout Labels) -> String? {
        let window = w.window
        func name(_ id: UUID) -> String { lab.name(id) }
        switch operation {
        case "close":
            guard window.tabs.count > 1, let tab = window.tabs.randomElement(using: &rng) else { return nil }
            w.model.tabs.removeAll { $0.id == tab.id }
            w.model.promoteAnchorOrRemoveGroupsAnchoredBy(closedWorkspaceId: tab.id)
            return "close: \(name(tab.id))"
        case "move to another window":
            guard window.tabs.count > 1, let tab = window.tabs.randomElement(using: &rng) else { return nil }
            w.model.tabs.removeAll { $0.id == tab.id }
            w.model.dissolveGroupsAnchoredBy(closedWorkspaceId: tab.id)
            return "move to another window: \(name(tab.id))"
        case "pin group":
            guard let g = window.groups.randomElement(using: &rng) else { return nil }
            w.groups.setWorkspaceGroupPinned(groupId: g.id, isPinned: !g.isPinned)
            return "pin group: \(name(g.id))"
        case "pin workspace":
            guard let t = window.tabs.randomElement(using: &rng) else { return nil }
            w.reorder.togglePin(tabId: t.id)
            return "pin workspace: \(name(t.id))"
        case "ungroup":
            guard let g = window.groups.randomElement(using: &rng) else { return nil }
            _ = w.groups.ungroupWorkspaceGroup(groupId: g.id)
            return "ungroup: \(name(g.id))"
        case "delete group":
            guard let g = window.groups.randomElement(using: &rng) else { return nil }
            _ = w.groups.deleteWorkspaceGroup(groupId: g.id)
            return "delete group: \(name(g.id))"
        case "fold":
            guard let g = window.groups.randomElement(using: &rng) else { return nil }
            w.groups.toggleWorkspaceGroupCollapsed(groupId: g.id)
            return "fold: \(name(g.id))"
        case "add workspace":
            guard let t = window.tabs.randomElement(using: &rng), let g = window.groups.randomElement(using: &rng) else { return nil }
            let placement: WorkspaceGroupNewPlacement? = [nil, .top, .end, .afterCurrent].randomElement(using: &rng)!
            w.groups.addWorkspaceToGroup(workspaceId: t.id, groupId: g.id, placement: placement, referenceWorkspaceId: window.tabs.randomElement(using: &rng)?.id)
            return "add workspace: \(name(t.id)) into \(name(g.id))"
        case "remove workspace":
            guard let t = window.tabs.filter({ $0.groupId != nil }).randomElement(using: &rng) else { return nil }
            w.groups.removeWorkspaceFromGroup(workspaceId: t.id)
            return "remove workspace: \(name(t.id))"
        case "new workspace in group":
            guard let g = window.groups.randomElement(using: &rng) else { return nil }
            let placement: WorkspaceGroupNewPlacement = [.top, .end, .afterCurrent].randomElement(using: &rng)!
            _ = w.groups.createWorkspaceInGroup(groupId: g.id, placement: placement, referenceWorkspaceId: window.tabs.randomElement(using: &rng)?.id)
            return "new workspace in group: \(name(g.id))"
        case "move group to":
            // Any group into any group or the top level, the group itself and the ones inside it included: the
            // refusals change nothing and must leave the rules holding.
            guard let g = window.groups.randomElement(using: &rng) else { return nil }
            let destination: UUID? = Int.random(in: 0..<4, using: &rng) == 0 ? nil : window.groups.randomElement(using: &rng)?.id
            _ = w.groups.moveWorkspaceGroup(groupId: g.id, intoParent: destination)
            return "move group to: \(name(g.id)) into \(destination.map(name) ?? "top")"
        case "new group in place":
            // A few workspaces, most of them in a group, made into a new group: it lands inside the first one's group.
            let candidates = window.tabs.filter { !window.isAnchor($0.id) }
            let grouped = candidates.filter { $0.groupId != nil }
            let pool = Int.random(in: 0..<4, using: &rng) == 0 ? candidates : (grouped.isEmpty ? candidates : grouped)
            guard !pool.isEmpty else { return nil }
            let chosen = pool.filter { _ in Bool.random(using: &rng) }
            let children = chosen.isEmpty ? [pool[0]] : chosen
            _ = w.groups.createWorkspaceGroup(name: "Made", childWorkspaceIds: children.map(\.id), collapseSidebarSelection: false)
            return "new group in place: \(children.map { name($0.id) })"
        case "move group beside":
            // Before or after any other group, the ones in another parent included: those are refused and change nothing.
            guard let g = window.groups.randomElement(using: &rng) else { return nil }
            let besides = window.groups.filter { $0.parentId == g.parentId && $0.id != g.id }
            let target: UUID? = Int.random(in: 0..<10, using: &rng) < 8 ? (besides.randomElement(using: &rng)?.id ?? g.id) : window.groups.randomElement(using: &rng)?.id
            guard let target else { return nil }
            let after = Bool.random(using: &rng)
            _ = w.groups.moveWorkspaceGroup(groupId: g.id, beside: target, after: after)
            return "move group beside: \(name(g.id)) \(after ? "after" : "before") \(name(target))"
        case "move child group by index":
            // Among the groups inside a parent: the group is one with a group beside it under the same parent.
            let children = window.groups.filter { g in g.parentId != nil && window.groups.contains { $0.parentId == g.parentId && $0.id != g.id } }
            guard let g = children.randomElement(using: &rng) else { return nil }
            let besides = window.groups.indices.filter { window.groups[$0].parentId == g.parentId && window.groups[$0].id != g.id }
            let index = Int.random(in: 0..<10, using: &rng) < 8
                ? besides.randomElement(using: &rng)!
                : Int.random(in: -1...(window.groups.count + 1), using: &rng)
            w.groups.moveWorkspaceGroup(groupId: g.id, toIndex: index)
            return "move child group by index: \(name(g.id))"
        case "move group by index":
            // Among the top-level groups only; `move child group by index` is the one inside a parent.
            guard let g = window.groups.filter({ $0.parentId == nil }).randomElement(using: &rng) else { return nil }
            // Mostly the list index of a group beside it, since a target in another parent changes nothing;
            // otherwise any index, ends included.
            let besides = window.groups.indices.filter { window.groups[$0].parentId == g.parentId && window.groups[$0].id != g.id }
            let index = Int.random(in: 0..<10, using: &rng) < 8 && !besides.isEmpty
                ? besides.randomElement(using: &rng)!
                : Int.random(in: -1...(window.groups.count + 1), using: &rng)
            w.groups.moveWorkspaceGroup(groupId: g.id, toIndex: index)
            return "move group by index: \(name(g.id))"
        case "move to top":
            let chosen = window.tabs.filter { _ in Bool.random(using: &rng) }.map(\.id)
            guard !chosen.isEmpty else { return nil }
            w.reorder.moveTabsToTop(Set(chosen))
            return "move to top: \(chosen.map(name))"
        case "notification move":
            guard let t = window.tabs.randomElement(using: &rng) else { return nil }
            w.reorder.moveTabToTopForNotification(t.id)
            return "notification move: \(name(t.id))"
        case "step":
            guard let t = window.tabs.randomElement(using: &rng), let i = window.tabs.firstIndex(where: { $0.id == t.id }) else { return nil }
            // Only in a nested window: a flat one runs upstream's code, which traps on an unpinned workspace
            // behind the name of a pinned group (upstream's behaviour, kept).
            guard window.groups.contains(where: { $0.parentId != nil }) else { return nil }
            _ = w.reorder.reorderWorkspace(tabId: t.id, toIndex: i + [-1, 1].randomElement(using: &rng)!)
            return "step: \(name(t.id))"
        case "socket index":
            guard let t = window.tabs.randomElement(using: &rng) else { return nil }
            guard window.groups.contains(where: { $0.parentId != nil }) else { return nil }
            _ = w.reorder.reorderWorkspace(tabId: t.id, toIndex: Int.random(in: -1...(window.tabs.count + 1), using: &rng))
            return "socket index: \(name(t.id))"
        case "refused drag":
            guard let t = window.tabs.randomElement(using: &rng) else { return nil }
            let refused = !w.reorder.reorderSidebarWorkspace(tabId: t.id, toIndex: Int.random(in: 0...window.tabs.count, using: &rng), isDragOperation: true, usesTopLevelRows: true)
            return "refused drag: \(name(t.id)) \(refused)"
        case "single drag":
            guard let t = window.tabs.randomElement(using: &rng) else { return nil }
            let explicit: UUID? = Bool.random(using: &rng) ? window.groups.randomElement(using: &rng)?.id : nil
            _ = w.reorder.reorderSidebarWorkspace(tabId: t.id, toIndex: Int.random(in: 0...window.tabs.count, using: &rng), isDragOperation: true, usesTopLevelRows: Bool.random(using: &rng), explicitGroupId: explicit)
            return "single drag: \(name(t.id))"
        case "block drag":
            let chosen = window.tabs.filter { _ in Bool.random(using: &rng) }.map(\.id)
            guard chosen.count >= 2, let grabbed = chosen.randomElement(using: &rng) else { return nil }
            _ = w.reorder.reorderSidebarWorkspaces(tabIds: chosen, draggedTabId: grabbed, toIndex: Int.random(in: 0...window.tabs.count, using: &rng), isDragOperation: true, usesTopLevelRows: Bool.random(using: &rng))
            return "block drag: \(chosen.map(name))"
        case "reorder workspaces":
            _ = w.reorder.reorderWorkspaces(orderedWorkspaceIds: window.tabs.map(\.id).shuffled(using: &rng))
            return "reorder workspaces: all"
        case "reorder before":
            guard let t = window.tabs.randomElement(using: &rng), let r = window.tabs.randomElement(using: &rng), t.id != r.id else { return nil }
            if Bool.random(using: &rng) {
                _ = w.reorder.reorderWorkspace(tabId: t.id, before: r.id)
            } else {
                _ = w.reorder.reorderWorkspace(tabId: t.id, after: r.id)
            }
            return "reorder before: \(name(t.id)) near \(name(r.id))"
        case "set anchor":
            guard let t = window.tabs.filter({ $0.groupId != nil }).randomElement(using: &rng), let g = t.groupId else { return nil }
            w.groups.setWorkspaceGroupAnchor(groupId: g, workspaceId: t.id)
            return "set anchor: \(name(t.id)) of \(name(g))"
        case "set pinned several":
            let chosen = window.tabs.filter { _ in Bool.random(using: &rng) }.map(\.id)
            guard !chosen.isEmpty else { return nil }
            w.reorder.setPinned(workspaceIds: chosen, pinned: Bool.random(using: &rng))
            return "set pinned several: \(chosen.map(name))"
        default:
            w.model.normalizeWorkspaceGroupContiguity()
            return "repair: all"
        }
    }
}
