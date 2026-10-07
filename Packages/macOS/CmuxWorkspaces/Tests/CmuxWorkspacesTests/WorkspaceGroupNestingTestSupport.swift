import Foundation
import Testing
@testable import CmuxWorkspaces

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct Labels {
    private(set) var idByName: [String: UUID] = [:]
    private(set) var nameById: [UUID: String] = [:]

    mutating func id(_ name: String) -> UUID {
        if let existing = idByName[name] { return existing }
        let new = UUID()
        idByName[name] = new
        nameById[new] = name
        return new
    }

    mutating func name(_ id: UUID, as name: String) {
        idByName[name] = id
        nameById[id] = name
    }

    func name(_ id: UUID) -> String {
        nameById[id] ?? String(id.uuidString.prefix(4))
    }

    mutating func ws(_ name: String, in group: String? = nil, pinned: Bool = false) -> NestWorkspace {
        let groupId = group.map { id($0) }
        return NestWorkspace(id: id(name), groupId: groupId, isPinned: pinned)
    }

    mutating func group(_ name: String, parent: String? = nil, pinned: Bool = false, own: String? = nil) -> NestGroup {
        let parentId = parent.map { id($0) }
        let ownId = own.map { id($0) }
        return NestGroup(id: id(name), parentId: parentId, isPinned: pinned, anchorWorkspaceId: ownId)
    }
}

struct NestGroup: Equatable, Sendable {
    var id: UUID
    var parentId: UUID?
    var isPinned: Bool
    var anchorWorkspaceId: UUID?

    func toWorkspaceGroup() -> WorkspaceGroup {
        WorkspaceGroup(
            id: id,
            name: "g",
            isCollapsed: false,
            isPinned: isPinned,
            anchor: anchorWorkspaceId.map { .workspace($0) } ?? .empty(id),
            customColor: nil,
            iconSymbol: nil,
            parentGroupId: parentId
        )
    }
}

struct NestWorkspace: Equatable, Sendable {
    var id: UUID
    var groupId: UUID?
    var isPinned: Bool
}

struct NestWindow: Equatable, Sendable {
    var tabs: [NestWorkspace]
    var groups: [NestGroup]

    var tree: WorkspaceGroupTree {
        WorkspaceGroupTree(items: groups.map { ($0.id, $0.parentId) })
    }

    func layout() -> WorkspaceGroupLayout {
        WorkspaceGroupLayout(
            tree: tree,
            groups: groups.map { $0.toWorkspaceGroup() },
            workspaces: tabs.map { WorkspaceGroupWorkspaceItem(id: $0.id, groupId: $0.groupId, isPinned: $0.isPinned) }
        )
    }

    /// Writes the layout back the way it chooses: after an edit the groups follow their rows,
    /// in the bare repair a group with no workspace inside keeps its index.
    mutating func apply(_ layout: WorkspaceGroupLayout) {
        let out = layout.output()
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let groupsById = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        tabs = out.tabOrder.compactMap { id in
            guard var tab = tabsById[id] else { return nil }
            tab.groupId = out.groupIdByWorkspace[id] ?? nil
            tab.isPinned = layout.workspacePinned[id] ?? tab.isPinned
            return tab
        }
        groups = out.groupOrder.compactMap { id in
            guard var group = groupsById[id] else { return nil }
            group.parentId = out.parentByGroup[id] ?? nil
            group.anchorWorkspaceId = out.anchorByGroup[id]
            group.isPinned = layout.groupPinned[id] ?? group.isPinned
            return group
        }
    }

    /// Read the stored window and write it back with no edit.
    mutating func bareRepair() {
        apply(layout())
    }

    func groupFacts(_ id: UUID) -> NestGroup? {
        groups.first { $0.id == id }
    }

    func holdsGroups(_ id: UUID) -> Bool {
        groups.contains { $0.parentId == id }
    }

    func isAnchor(_ workspace: UUID) -> Bool {
        groups.contains { $0.anchorWorkspaceId == workspace }
    }

    @discardableResult
    mutating func moveGroup(_ group: UUID, into destination: UUID?) -> WorkspaceGroupLayout.MoveResult {
        guard let facts = groupFacts(group) else { return .rowNotFound }
        let tree = self.tree
        var layout = self.layout()
        let place: WorkspaceGroupLayout.Place
        if destination == nil && !facts.isPinned {
            place = .directlyBelow(.group(tree.outermost(of: group)))
        } else {
            place = .lastOfTier
        }
        let result = layout.move(.group(group), to: destination, at: place)
        if result == .moved {
            apply(layout)
        }
        return result
    }

    mutating func moveWorkspace(_ workspace: UUID, into destination: UUID) {
        var layout = self.layout()
        if layout.move(.workspace(workspace), to: destination, at: .afterLastWorkspaceOfTier) == .moved {
            apply(layout)
        }
    }

    mutating func moveWorkspaceUpOneLevel(_ workspace: UUID) {
        guard let group = tabs.first(where: { $0.id == workspace })?.groupId else { return }
        var layout = self.layout()
        if layout.move(.workspace(workspace), to: tree.parent(of: group), at: .directlyBelow(.group(group))) == .moved {
            apply(layout)
        }
    }

    mutating func moveWorkspaceToTopLevel(_ workspace: UUID) {
        guard let group = tabs.first(where: { $0.id == workspace })?.groupId else { return }
        var layout = self.layout()
        if layout.move(.workspace(workspace), to: nil, at: .directlyBelow(.group(tree.outermost(of: group)))) == .moved {
            apply(layout)
        }
    }

    /// A pin is not a layout edit: store the flag, then run the bare repair.
    mutating func setWorkspacePinned(_ workspace: UUID, _ pinned: Bool) {
        guard let index = tabs.firstIndex(where: { $0.id == workspace }) else { return }
        tabs[index].isPinned = pinned
        bareRepair()
    }

    mutating func setGroupPinned(_ group: UUID, _ pinned: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == group }) else { return }
        groups[index].isPinned = pinned
        bareRepair()
    }

    mutating func close(_ workspace: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == workspace }) else { return }
        let closed = tabs.remove(at: index)
        if let g = closed.groupId, let gi = groups.firstIndex(where: { $0.id == g }),
           groups[gi].anchorWorkspaceId == workspace {
            if let next = tabs.first(where: { $0.groupId == g }) {
                groups[gi].anchorWorkspaceId = next.id
            } else if holdsGroups(g) || groups[gi].isPinned {
                groups[gi].anchorWorkspaceId = nil
            } else {
                groups.remove(at: gi)
            }
        }
        bareRepair()
    }

    @discardableResult
    mutating func reorderGroupInList(_ group: UUID, toSiblingIndex target: Int) -> Bool {
        var layout = self.layout()
        guard layout.moveGroupInList(group, toSiblingIndex: target) else { return false }
        apply(layout)
        return true
    }
}

func compact(_ window: NestWindow, _ lab: Labels, layout given: WorkspaceGroupLayout? = nil) -> String {
    let layout = given ?? window.layout()
    func level(_ lv: UUID?) -> [String] {
        layout.rows(of: lv).map { row in
            switch row {
            case .workspace(let id):
                return lab.name(id) + (layout.isPinned(row) ? "*" : "")
            case .group(let id):
                let own = layout.anchor[id].map { lab.name($0) } ?? "-"
                let inner = level(id)
                return lab.name(id) + (layout.isPinned(row) ? "*" : "") + "[" + own
                    + (inner.isEmpty ? "" : ": " + inner.joined(separator: ", ")) + "]"
            }
        }
    }
    return level(nil).joined(separator: " | ")
}

func stored(_ window: NestWindow, _ lab: Labels) -> String {
    let tabs = window.tabs.map { tab in
        lab.name(tab.id) + (tab.isPinned ? "*" : "") + (tab.groupId.map { "(" + lab.name($0) + ")" } ?? "")
    }.joined(separator: " ")
    let groups = window.groups.map { group in
        lab.name(group.id) + (group.isPinned ? "*" : "")
            + "(in " + (group.parentId.map { lab.name($0) } ?? "top")
            + ", own " + (group.anchorWorkspaceId.map { lab.name($0) } ?? "-") + ")"
    }.joined(separator: " ")
    return "tabs: [\(tabs)]  groups: [\(groups)]"
}

struct IndependentRow: Equatable {
    var isGroup: Bool
    var id: UUID
    var pinned: Bool
}

struct WindowFacts {
    let window: NestWindow
    let byId: [UUID: NestGroup]
    let chains: [[UUID]]
    var range: [UUID: ClosedRange<Int>] = [:]
    var broken: Set<UUID> = []

    init(_ window: NestWindow) {
        self.window = window
        let byId = Dictionary(uniqueKeysWithValues: window.groups.map { ($0.id, $0) })
        self.byId = byId
        chains = window.tabs.map { tab in
            var out: [UUID] = []
            var cursor = tab.groupId
            var steps = 0
            while let c = cursor, let group = byId[c], steps <= window.groups.count {
                out.append(c)
                cursor = group.parentId
                steps += 1
            }
            return out
        }
        for group in window.groups {
            let indices = window.tabs.indices.filter { chains[$0].contains(group.id) }
            if let first = indices.first, let last = indices.last {
                range[group.id] = first...last
                if last - first + 1 != indices.count {
                    broken.insert(group.id)
                }
            }
        }
    }

    func depth(_ id: UUID) -> Int {
        var depth = 0
        var cursor = byId[id]?.parentId
        while let c = cursor, depth <= window.groups.count {
            depth += 1
            cursor = byId[c]?.parentId
        }
        return depth
    }

    func rows(of level: UUID?) -> [IndependentRow] {
        var out: [IndependentRow] = []
        var seen = Set<UUID>()
        for (index, tab) in window.tabs.enumerated() {
            let chain = chains[index]
            if let level {
                guard let position = chain.firstIndex(of: level) else { continue }
                if position == 0 {
                    if byId[level]?.anchorWorkspaceId != tab.id {
                        out.append(IndependentRow(isGroup: false, id: tab.id, pinned: tab.isPinned))
                    }
                } else {
                    let child = chain[position - 1]
                    if seen.insert(child).inserted {
                        out.append(IndependentRow(isGroup: true, id: child, pinned: byId[child]?.isPinned ?? false))
                    }
                }
            } else if let top = chain.last {
                if seen.insert(top).inserted {
                    out.append(IndependentRow(isGroup: true, id: top, pinned: byId[top]?.isPinned ?? false))
                }
            } else {
                out.append(IndependentRow(isGroup: false, id: tab.id, pinned: tab.isPinned))
            }
        }
        return out
    }

    var noRunGroups: Set<UUID> {
        Set(window.groups.map(\.id).filter { range[$0] == nil })
    }
}

func nestViolations(_ window: NestWindow, _ lab: Labels) -> [String] {
    var out: [String] = []
    let ids = Set(window.groups.map(\.id))
    let byId = Dictionary(uniqueKeysWithValues: window.groups.map { ($0.id, $0) })
    for group in window.groups {
        if let parent = group.parentId, !ids.contains(parent) {
            out.append("R5 \(lab.name(group.id)) names a parent that does not exist")
        }
        var cursor = group.parentId
        var steps = 0
        while let c = cursor, steps <= window.groups.count {
            if c == group.id {
                out.append("R5 \(lab.name(group.id)) is in a loop")
                break
            }
            cursor = byId[c]?.parentId
            steps += 1
        }
    }
    for tab in window.tabs {
        if let g = tab.groupId, !ids.contains(g) {
            out.append("R6 \(lab.name(tab.id)) names a group that does not exist")
        }
    }
    guard out.isEmpty else { return out }

    let facts = WindowFacts(window)
    for group in window.groups {
        if facts.broken.contains(group.id) {
            out.append("R1 the run of \(lab.name(group.id)) is broken")
        }
        if let parent = group.parentId, let r = facts.range[group.id], let pr = facts.range[parent],
           !(pr.lowerBound <= r.lowerBound && r.upperBound <= pr.upperBound) {
            out.append("R1 the run of \(lab.name(group.id)) is not inside its parent's")
        }
    }
    for level in [UUID?.none] + window.groups.map({ Optional($0.id) }) {
        let rows = facts.rows(of: level)
        if let firstUnpinned = rows.firstIndex(where: { !$0.pinned }),
           rows[firstUnpinned...].contains(where: { $0.pinned }) {
            let name = level.map { lab.name($0) } ?? "top level"
            out.append("\(level == nil ? "R3" : "R2") a pinned row sits below an unpinned row in \(name)")
        }
    }
    for group in window.groups {
        if let own = group.anchorWorkspaceId {
            guard let index = window.tabs.firstIndex(where: { $0.id == own }) else {
                out.append("R2 the workspace behind \(lab.name(group.id)) is not in tabs")
                continue
            }
            if window.tabs[index].groupId != group.id {
                out.append("R2 the workspace behind \(lab.name(group.id)) is not its own")
            } else if facts.range[group.id]?.lowerBound != index {
                out.append("R2 the workspace behind \(lab.name(group.id)) is not first in its run")
            }
        } else if window.tabs.contains(where: { $0.groupId == group.id }) {
            out.append("R2 \(lab.name(group.id)) owns a workspace but none stands behind its name")
        }
    }
    let index = Dictionary(uniqueKeysWithValues: window.groups.enumerated().map { ($1.id, $0) })
    for group in window.groups {
        if let parent = group.parentId, let pi = index[parent], let gi = index[group.id], pi > gi {
            out.append("R4 \(lab.name(group.id)) is listed before its parent")
        }
    }
    let withRun = window.groups.filter { facts.range[$0.id] != nil }
    let sorted = withRun.sorted { lhs, rhs in
        let l = (facts.range[lhs.id]!.lowerBound, facts.depth(lhs.id))
        let r = (facts.range[rhs.id]!.lowerBound, facts.depth(rhs.id))
        return l < r
    }
    if sorted.map(\.id) != withRun.map(\.id) {
        out.append("R4 groups with a run are not listed in the order their runs start")
    }
    return out
}

/// Rules 1 to 3 (WorkspaceGroupLayout.swift, "The six rules") never reorder rows inside a tier: the rows of each level and tier, by first
/// encounter in tabs order, are the same before and after the first write.
func tierOrderProblems(before scrambled: NestWindow, after window: NestWindow, _ lab: Labels) -> [String] {
    let before = WindowFacts(scrambled)
    let after = WindowFacts(window)
    var out: [String] = []
    for level in [UUID?.none] + window.groups.map({ Optional($0.id) }) {
        for tier in [true, false] {
            let was = before.rows(of: level).filter { $0.pinned == tier }
            let now = after.rows(of: level).filter { $0.pinned == tier }
            if was != now {
                out.append("rows of a tier were reordered at \(level.map { lab.name($0) } ?? "top level")")
            }
        }
    }
    return out
}

/// Rule 4 (WorkspaceGroupLayout.swift, "The six rules"), "keeps its place": two groups with no workspace inside that the edit did not touch,
/// beside each other in one tier, keep their order.
func untouchedNoRunOrderProblems(before previous: NestWindow, after window: NestWindow, touched: Set<UUID>) -> [String] {
    let stay = WindowFacts(previous).noRunGroups
        .intersection(WindowFacts(window).noRunGroups)
        .subtracting(touched)
    func order(_ w: NestWindow) -> [String: [UUID]] {
        var out: [String: [UUID]] = [:]
        for group in w.groups where stay.contains(group.id) {
            let key = (group.parentId?.uuidString ?? "top") + (group.isPinned ? "/pinned" : "/unpinned")
            out[key, default: []].append(group.id)
        }
        return out
    }
    let was = order(previous)
    let now = order(window)
    var out: [String] = []
    for (key, list) in was {
        guard let other = now[key] else { continue }
        let common = Set(list).intersection(other)
        if list.filter({ common.contains($0) }) != other.filter({ common.contains($0) }) {
            out.append("R4 two untouched groups with no workspace inside, beside each other in one tier, swapped places")
        }
    }
    return out
}

/// What a run of random sequences reached, so a green run cannot hide a sequence that never got there.
struct SequenceCounts {
    var editsApplied = 0
    var reorders = 0
    var reordersInsideAParent = 0
    var statesTwoLevelsDeep = 0
    var statesWithGroupHoldingNoWorkspace = 0

    var summary: String {
        "edits applied=\(editsApplied), reorders=\(reorders), reorders inside a parent=\(reordersInsideAParent), "
            + "states two or more levels deep=\(statesTwoLevelsDeep), "
            + "states with a group that has no workspace inside=\(statesWithGroupHoldingNoWorkspace)"
    }

    var zeroCounts: [String] {
        [
            ("edits applied", editsApplied),
            ("reorders", reorders),
            ("reorders inside a parent", reordersInsideAParent),
            ("states two or more levels deep", statesTwoLevelsDeep),
            ("states with a group that has no workspace inside", statesWithGroupHoldingNoWorkspace)
        ].filter { $0.1 == 0 }.map(\.0)
    }

    mutating func record(_ edit: EditRecord, after window: NestWindow) {
        editsApplied += 1
        if edit.isListReorder {
            reorders += 1
            if edit.inParent { reordersInsideAParent += 1 }
        }
        let facts = WindowFacts(window)
        if window.groups.contains(where: { facts.depth($0.id) >= 2 }) { statesTwoLevelsDeep += 1 }
        if !facts.noRunGroups.isEmpty { statesWithGroupHoldingNoWorkspace += 1 }
    }
}

/// One layout edit described by ids, so the same edit can be applied to two layout values.
enum LayoutEdit {
    case moveGroup(UUID, UUID?, WorkspaceGroupLayout.Place)
    case moveWorkspace(UUID, UUID?, WorkspaceGroupLayout.Place)
    case reorder(UUID, Int)

    var isReorder: Bool {
        if case .reorder = self { return true }
        return false
    }

    func text(_ lab: Labels) -> String {
        switch self {
        case .moveGroup(let g, let d, let place):
            return "move group \(lab.name(g)) to \(d.map { lab.name($0) } ?? "top level") at \(place)"
        case .moveWorkspace(let w, let d, let place):
            return "move workspace \(lab.name(w)) to \(d.map { lab.name($0) } ?? "top level") at \(place)"
        case .reorder(let g, let index):
            return "reorder group \(lab.name(g)) to index \(index)"
        }
    }

    /// Returns whether the edit changed the layout.
    @discardableResult
    func apply(to layout: inout WorkspaceGroupLayout) -> Bool {
        switch self {
        case .moveGroup(let g, let d, let place):
            return layout.move(.group(g), to: d, at: place) == .moved
        case .moveWorkspace(let w, let d, let place):
            return layout.move(.workspace(w), to: d, at: place) == .moved
        case .reorder(let g, let index):
            return layout.moveGroupInList(g, toSiblingIndex: index)
        }
    }
}

func randomLayoutEdit(_ window: NestWindow, _ rng: inout SplitMix64, after previous: LayoutEdit? = nil) -> LayoutEdit? {
    let tree = window.tree
    func randomPlace(workspace: Bool) -> WorkspaceGroupLayout.Place {
        switch Int.random(in: 0..<(workspace ? 5 : 4), using: &rng) {
        case 0: return .firstOfTier
        case 1: return .lastOfTier
        case 2: return .index(Int.random(in: 0...4, using: &rng))
        case 3:
            let references: [WorkspaceGroupLayout.Row] = window.tabs.map { .workspace($0.id) } + window.groups.map { .group($0.id) }
            return references.randomElement(using: &rng).map { .directlyBelow($0) } ?? .lastOfTier
        default: return .afterLastWorkspaceOfTier
        }
    }
    // Half the draws are reorders: the reorder-then-reorder pairs are the ones that need many samples.
    switch Int.random(in: 0..<4, using: &rng) {
    case 0:
        guard let g = window.groups.randomElement(using: &rng) else { return nil }
        let destinations: [UUID?] = [nil] + window.groups
            .filter { $0.id != g.id && !tree.isInside($0.id, g.id) }
            .map { Optional($0.id) }
        guard let destination = destinations.randomElement(using: &rng) else { return nil }
        return .moveGroup(g.id, destination, randomPlace(workspace: false))
    case 1:
        guard let w = window.tabs.filter({ !window.isAnchor($0.id) }).randomElement(using: &rng) else { return nil }
        let destinations: [UUID?] = [nil] + window.groups.map { Optional($0.id) }
        guard let destination = destinations.randomElement(using: &rng) else { return nil }
        return .moveWorkspace(w.id, destination, randomPlace(workspace: true))
    default:
        // Prefer a level that holds a group with no workspace inside, when there is one.
        let noRun = WindowFacts(window).noRunGroups
        let atNoRunLevel = window.groups.filter { g in
            window.groups.contains { noRun.contains($0.id) && $0.id != g.id && tree.parent(of: $0.id) == tree.parent(of: g.id) }
        }
        var pool = !atNoRunLevel.isEmpty && Bool.random(using: &rng) ? atNoRunLevel : window.groups
        // After a reorder, often reorder again at the same level, and often a pinned group.
        if case .reorder(let before, _)? = previous, Int.random(in: 0..<10, using: &rng) < 6 {
            let level = tree.parent(of: before)
            let sameLevel = window.groups.filter { tree.parent(of: $0.id) == level }
            if sameLevel.count > 1 { pool = sameLevel }
        }
        if Int.random(in: 0..<3, using: &rng) == 0 {
            let pinned = pool.filter(\.isPinned)
            if !pinned.isEmpty { pool = pinned }
        }
        guard let g = pool.randomElement(using: &rng) else { return nil }
        let siblings = window.groups.filter { tree.parent(of: $0.id) == tree.parent(of: g.id) }
        guard siblings.count > 1 else { return nil }
        return .reorder(g.id, Int.random(in: -1...siblings.count, using: &rng))
    }
}

struct EditRecord {
    var text: String
    var touchedGroups: Set<UUID> = []
    var isListReorder = false
    var inParent = false
}

let editKinds = [
    "group into group", "group to top level", "group to a group higher up",
    "workspace into group", "workspace up one level", "workspace to top level",
    "pin/unpin workspace", "pin/unpin group",
    "close workspace", "reorder group beside its neighbours", "new workspace"
]

func randomNestedWindow(_ rng: inout SplitMix64, _ lab: inout Labels) -> NestWindow {
    let groupCount = Int.random(in: 2...6, using: &rng)
    let workspaceCount = Int.random(in: 4...14, using: &rng)
    var groups: [NestGroup] = []
    for i in 0..<groupCount {
        let parent: UUID? = (i > 0 && Int.random(in: 0..<10, using: &rng) < 6)
            ? groups[Int.random(in: 0..<i, using: &rng)].id : nil
        groups.append(NestGroup(
            id: lab.id("G\(i)"),
            parentId: parent,
            isPinned: Int.random(in: 0..<10, using: &rng) < 3,
            anchorWorkspaceId: nil
        ))
    }
    var tabs: [NestWorkspace] = []
    for i in 0..<workspaceCount {
        let group: UUID? = Int.random(in: 0..<10, using: &rng) < 7 ? groups.randomElement(using: &rng)?.id : nil
        tabs.append(NestWorkspace(id: lab.id("w\(i)"), groupId: group, isPinned: Int.random(in: 0..<4, using: &rng) == 0))
    }
    for gi in groups.indices {
        groups[gi].anchorWorkspaceId = tabs.filter { $0.groupId == groups[gi].id }.randomElement(using: &rng)?.id
    }
    tabs.shuffle(using: &rng)
    groups.shuffle(using: &rng)
    return NestWindow(tabs: tabs, groups: groups)
}

func randomEdit(
    _ window: inout NestWindow,
    _ rng: inout SplitMix64,
    _ lab: inout Labels,
    counter: inout Int,
    forceKind: Int? = nil
) -> EditRecord? {
    let kind = forceKind ?? Int.random(in: 0...editKinds.count, using: &rng)
    if kind == editKinds.count {
        window.bareRepair()
        return EditRecord(text: "bare repair (read, write with keep-index)")
    }
    let tree = window.tree
    switch kind {
    case 0:
        let pairs = window.groups.flatMap { g in
            window.groups.compactMap { d -> (UUID, UUID)? in
                guard d.id != g.id, !tree.isInside(d.id, g.id), tree.parent(of: g.id) != d.id else { return nil }
                return (g.id, d.id)
            }
        }
        guard let (g, d) = pairs.randomElement(using: &rng) else { return nil }
        window.moveGroup(g, into: d)
        return EditRecord(text: "move group \(lab.name(g)) into \(lab.name(d))", touchedGroups: [g])
    case 1:
        guard let g = window.groups.filter({ $0.parentId != nil }).randomElement(using: &rng)?.id else { return nil }
        window.moveGroup(g, into: nil)
        return EditRecord(text: "move group \(lab.name(g)) to the top level", touchedGroups: [g])
    case 2:
        let pairs = window.groups.flatMap { g in tree.ancestors(of: g.id).dropFirst().map { (g.id, $0) } }
        guard let (g, d) = pairs.randomElement(using: &rng) else { return nil }
        window.moveGroup(g, into: d)
        return EditRecord(text: "move group \(lab.name(g)) up into \(lab.name(d))", touchedGroups: [g])
    case 3:
        let movable = window.tabs.filter { !window.isAnchor($0.id) }
        guard let w = movable.randomElement(using: &rng),
              let d = window.groups.filter({ $0.id != w.groupId }).randomElement(using: &rng)?.id else { return nil }
        window.moveWorkspace(w.id, into: d)
        return EditRecord(text: "move workspace \(lab.name(w.id)) into \(lab.name(d))")
    case 4:
        guard let w = window.tabs.filter({ $0.groupId != nil && !window.isAnchor($0.id) }).randomElement(using: &rng) else { return nil }
        window.moveWorkspaceUpOneLevel(w.id)
        return EditRecord(text: "move workspace \(lab.name(w.id)) up one level")
    case 5:
        guard let w = window.tabs.filter({ $0.groupId != nil && !window.isAnchor($0.id) }).randomElement(using: &rng) else { return nil }
        window.moveWorkspaceToTopLevel(w.id)
        return EditRecord(text: "move workspace \(lab.name(w.id)) to the top level")
    case 6:
        guard let w = window.tabs.randomElement(using: &rng) else { return nil }
        window.setWorkspacePinned(w.id, !w.isPinned)
        return EditRecord(text: "\(w.isPinned ? "unpin" : "pin") workspace \(lab.name(w.id))")
    case 7:
        guard let g = window.groups.randomElement(using: &rng) else { return nil }
        window.setGroupPinned(g.id, !g.isPinned)
        return EditRecord(text: "\(g.isPinned ? "unpin" : "pin") group \(lab.name(g.id))", touchedGroups: [g.id])
    case 8:
        guard let w = window.tabs.randomElement(using: &rng) else { return nil }
        window.close(w.id)
        return EditRecord(
            text: "close workspace \(lab.name(w.id))"
        )
    case 9:
        guard let g = window.groups.randomElement(using: &rng) else { return nil }
        let siblings = window.groups.filter { tree.parent(of: $0.id) == tree.parent(of: g.id) }
        guard siblings.count > 1 else { return nil }
        let target = Int.random(in: -1...siblings.count, using: &rng)
        guard window.reorderGroupInList(g.id, toSiblingIndex: target) else { return nil }
        return EditRecord(
            text: "reorder group \(lab.name(g.id)) to index \(target) in the list of groups beside it",
            touchedGroups: Set(siblings.map(\.id)),
            isListReorder: true,
            inParent: tree.parent(of: g.id) != nil
        )
    default:
        counter += 1
        let new = NestWorkspace(id: lab.id("n\(counter)"), groupId: nil, isPinned: false)
        window.tabs.append(new)
        window.bareRepair()
        return EditRecord(text: "new ungrouped workspace \(lab.name(new.id))")
    }
}

// MARK: - Upstream model adapter

@MainActor
func snapshot<Tab: WorkspaceTabRepresenting>(_ model: WorkspacesModel<Tab>) -> NestWindow {
    NestWindow(
        tabs: model.tabs.map { NestWorkspace(id: $0.id, groupId: $0.groupId, isPinned: $0.isPinned) },
        groups: model.workspaceGroups.map {
            NestGroup(id: $0.id, parentId: $0.parentGroupId, isPinned: $0.isPinned, anchorWorkspaceId: $0.liveAnchorWorkspaceId)
        }
    )
}

@MainActor
final class NestingStubTab: WorkspaceTabRepresenting {
    let id: UUID
    var groupId: UUID?
    var isPinned: Bool
    var currentDirectory: String = "/tmp"

    init(id: UUID, groupId: UUID?, isPinned: Bool) {
        self.id = id
        self.groupId = groupId
        self.isPinned = isPinned
    }
}

@MainActor
func upstreamModel(_ window: NestWindow) -> WorkspacesModel<NestingStubTab> {
    let model = WorkspacesModel<NestingStubTab>()
    model.tabs = window.tabs.map { NestingStubTab(id: $0.id, groupId: $0.groupId, isPinned: $0.isPinned) }
    model.workspaceGroups = window.groups.map { group in
        WorkspaceGroup(
            id: group.id,
            name: "g",
            isCollapsed: false,
            isPinned: group.isPinned,
            anchor: group.anchorWorkspaceId.map { .workspace($0) } ?? .empty(group.id),
            customColor: nil,
            iconSymbol: nil,
            parentGroupId: group.parentId
        )
    }
    return model
}

@MainActor
func upstreamNormalized(_ window: NestWindow) -> NestWindow {
    let model = upstreamModel(window)
    model.normalizeWorkspaceGroupContiguity()
    return snapshot(model)
}

enum FlatOp {
    case moveToTop(UUID)
    case notify(UUID)
    case moveGroup(UUID, Int)
    case dragRow(UUID, Int)
    case dragMemberOut(UUID, Int)
    case dragBlock([UUID], dragged: UUID, Int)
    case preserveLiveOrder([UUID])
    case toggleGroupPin(UUID)
    case toggleWorkspacePin(UUID)
}

let flatOpKinds = [
    "1 moveTabsToTop([id])",
    "2 moveTabToTopForNotification(id)",
    "3 moveWorkspaceGroup(groupId:toIndex:) — nested: the layout edit moveGroupInList",
    "4a top-level drag, one row",
    "4b top-level drag, a member promoted out of its group",
    "4c top-level drag, several group rows",
    "5 preserveLiveOrder",
    "6a toggleWorkspaceGroupPinned",
    "6b togglePin (workspace)"
]

func rowIdentity(_ row: WorkspaceGroupLayout.Row, _ layout: WorkspaceGroupLayout) -> UUID {
    switch row {
    case .workspace(let id): id
    case .group(let id): layout.anchor[id] ?? id
    }
}

func topLevelRow(forIdentity id: UUID, in window: NestWindow) -> WorkspaceGroupLayout.Row? {
    if let group = window.groups.first(where: { $0.anchorWorkspaceId == id }) { return .group(group.id) }
    if let group = window.groups.first(where: { $0.id == id && $0.anchorWorkspaceId == nil }) { return .group(group.id) }
    if let tab = window.tabs.first(where: { $0.id == id }), tab.groupId == nil { return .workspace(id) }
    return nil
}

func pickFlatOp(_ kind: Int, _ window: NestWindow, _ rng: inout SplitMix64) -> FlatOp? {
    let layout = window.layout()
    let rows = layout.rows(of: nil)
    let identities = rows.map { rowIdentity($0, layout) }
    switch kind {
    case 0: return window.tabs.randomElement(using: &rng).map { .moveToTop($0.id) }
    case 1: return window.tabs.randomElement(using: &rng).map { .notify($0.id) }
    case 2:
        guard let group = window.groups.randomElement(using: &rng) else { return nil }
        let index = Int.random(in: -1...window.groups.count, using: &rng)
        return .moveGroup(group.id, index)
    case 3:
        guard let id = identities.randomElement(using: &rng) else { return nil }
        return .dragRow(id, Int.random(in: -1...(rows.count + 1), using: &rng))
    case 4:
        guard let tab = window.tabs.filter({ $0.groupId != nil && !window.isAnchor($0.id) }).randomElement(using: &rng) else { return nil }
        return .dragMemberOut(tab.id, Int.random(in: -1...(rows.count + 2), using: &rng))
    case 5:
        let anchors = window.groups.compactMap(\.anchorWorkspaceId).shuffled(using: &rng)
        guard anchors.count >= 2 else { return nil }
        let chosen = Array(anchors.prefix(Int.random(in: 2...anchors.count, using: &rng)))
        guard let dragged = chosen.randomElement(using: &rng) else { return nil }
        return .dragBlock(chosen, dragged: dragged, Int.random(in: -1...(rows.count + 1), using: &rng))
    case 6:
        let live = rows.filter { row in
            if case .group(let id) = row { return layout.hasRun(id) }
            return true
        }.shuffled(using: &rng)
        guard !live.isEmpty else { return nil }
        let sorted = live.filter { layout.isPinned($0) } + live.filter { !layout.isPinned($0) }
        return .preserveLiveOrder(sorted.map { rowIdentity($0, layout) })
    case 7: return window.groups.randomElement(using: &rng).map { .toggleGroupPin($0.id) }
    default: return window.tabs.randomElement(using: &rng).map { .toggleWorkspacePin($0.id) }
    }
}

@MainActor
func upstreamApply(_ op: FlatOp, _ window: NestWindow) -> NestWindow {
    let model = upstreamModel(window)
    let reorder = WorkspaceReorderCoordinator(model: model)
    let groups = WorkspaceGroupCoordinator(model: model)
    switch op {
    case .moveToTop(let id): reorder.moveTabsToTop([id])
    case .notify(let id): reorder.moveTabToTopForNotification(id)
    case .moveGroup(let id, let index):
        groups.moveWorkspaceGroup(groupId: id, toIndex: index)
    case .dragRow(let id, let index), .dragMemberOut(let id, let index):
        _ = reorder.reorderSidebarWorkspace(tabId: id, toIndex: index, isDragOperation: true, usesTopLevelRows: true)
    case .dragBlock(let ids, let dragged, let index):
        _ = reorder.reorderSidebarWorkspaces(tabIds: ids, draggedTabId: dragged, toIndex: index, isDragOperation: true, usesTopLevelRows: true)
    case .preserveLiveOrder(let ids):
        model.normalizeWorkspaceGroupContiguity(preservingTopLevelIds: ids)
    case .toggleGroupPin(let id): groups.toggleWorkspaceGroupPinned(groupId: id)
    case .toggleWorkspacePin(let id): reorder.togglePin(tabId: id)
    }
    return snapshot(model)
}

func clampedTopLevelIndex(_ target: Int, count: Int, pinnedCount: Int, isPinned: Bool) -> Int {
    let clamped = max(0, min(target, max(0, count - 1)))
    return isPinned ? min(clamped, max(0, pinnedCount - 1)) : max(clamped, pinnedCount)
}

func nestedApply(_ op: FlatOp, _ original: NestWindow) -> NestWindow {
    var window = original
    var layout = window.layout()
    switch op {
    case .moveToTop(let id):
        guard let tab = window.tabs.first(where: { $0.id == id }) else { return original }
        if let group = tab.groupId {
            if !window.isAnchor(id) { layout.move(.workspace(id), to: group, at: .firstOfTier) }
            layout.move(.group(group), to: nil, at: .firstOfTier)
        } else {
            layout.move(.workspace(id), to: nil, at: .firstOfTier)
        }
        window.apply(layout)
    case .notify(let id):
        guard let tab = window.tabs.first(where: { $0.id == id }) else { return original }
        let topRow: WorkspaceGroupLayout.Row = tab.groupId.map { .group($0) } ?? .workspace(id)
        if layout.isPinned(topRow) { return original }
        if let group = tab.groupId, !window.isAnchor(id) { layout.move(.workspace(id), to: group, at: .firstOfTier) }
        layout.move(topRow, to: nil, at: .firstOfTier)
        window.apply(layout)
    case .moveGroup(let id, let toIndex):
        guard layout.moveGroupInList(id, toSiblingIndex: toIndex) else { return original }
        window.apply(layout)
    case .dragRow(let id, let target):
        guard let row = topLevelRow(forIdentity: id, in: window) else { return original }
        let rows = layout.rows(of: nil)
        guard let from = rows.firstIndex(of: row) else { return original }
        let final = clampedTopLevelIndex(target, count: rows.count, pinnedCount: rows.filter { layout.isPinned($0) }.count, isPinned: layout.isPinned(row))
        if from == final { return original }
        layout.move(row, to: nil, at: .index(final))
        window.apply(layout)
    case .dragMemberOut(let id, let target):
        guard let tab = window.tabs.first(where: { $0.id == id }), tab.groupId != nil, !window.isAnchor(id) else { return original }
        let rows = layout.rows(of: nil)
        let pinnedCount = rows.filter { layout.isPinned($0) }.count
        let final = clampedTopLevelIndex(target, count: rows.count + 1, pinnedCount: pinnedCount + (tab.isPinned ? 1 : 0), isPinned: tab.isPinned)
        layout.move(.workspace(id), to: nil, at: .index(final))
        window.apply(layout)
    case .dragBlock(let ids, let dragged, let target):
        let rows = layout.rows(of: nil)
        let movingRows = window.tabs.filter { ids.contains($0.id) }.compactMap { topLevelRow(forIdentity: $0.id, in: window) }
        guard movingRows.count >= 2, let draggedRow = topLevelRow(forIdentity: dragged, in: window) else { return original }
        let space = rows.filter { $0 != draggedRow }
        let start = max(0, target)
        let reference: WorkspaceGroupLayout.Row? = start < space.count ? space[start...].first { !movingRows.contains($0) } : nil
        var desired = rows.filter { !movingRows.contains($0) }
        for tier in [true, false] {
            let tierRows = movingRows.filter { layout.isPinned($0) == tier }
            guard !tierRows.isEmpty else { continue }
            let referenceIndex = reference.flatMap { desired.firstIndex(of: $0) } ?? desired.count
            let pinnedCount = desired.filter { layout.isPinned($0) }.count
            let at = tier ? min(referenceIndex, pinnedCount) : max(referenceIndex, pinnedCount)
            desired.insert(contentsOf: tierRows, at: min(at, desired.count))
        }
        if desired == rows { return original }
        layout.setRows(of: nil, desired)
        window.apply(layout)
    case .preserveLiveOrder(let ids):
        let rows = layout.rows(of: nil)
        func isNoRun(_ row: WorkspaceGroupLayout.Row) -> Bool {
            if case .group(let g) = row { return !layout.hasRun(g) }
            return false
        }
        var attached: [WorkspaceGroupLayout.Row: [WorkspaceGroupLayout.Row]] = [:]
        var trailing: [WorkspaceGroupLayout.Row] = []
        for (index, row) in rows.enumerated() where isNoRun(row) {
            let next = rows[(index + 1)...].first { !isNoRun($0) }
            if let next, case .group = next, layout.isPinned(next) == layout.isPinned(row) {
                attached[next, default: []].append(row)
            } else {
                trailing.append(row)
            }
        }
        var desired: [WorkspaceGroupLayout.Row] = []
        for id in ids {
            guard let row = topLevelRow(forIdentity: id, in: window) else { continue }
            desired.append(contentsOf: attached[row] ?? [])
            desired.append(row)
        }
        desired.append(contentsOf: trailing)
        guard layout.setRows(of: nil, desired) else { return original }
        window.apply(layout)
    case .toggleGroupPin(let id):
        guard let index = window.groups.firstIndex(where: { $0.id == id }) else { return original }
        window.groups[index].isPinned.toggle()
        window.bareRepair()
    case .toggleWorkspacePin(let id):
        guard let index = window.tabs.firstIndex(where: { $0.id == id }) else { return original }
        window.tabs[index].isPinned.toggle()
        window.bareRepair()
    }
    return window
}

struct FlatDifference {
    var tabsDiffer: Bool
    var groupsDiffer: Bool
    /// Whether upstream's operation changed the window at all, so a comparison of two no-ops can be told apart.
    var upstreamChanged = false
    var any: Bool { tabsDiffer || groupsDiffer }
}

@MainActor
func opDifference(_ op: FlatOp, _ window: NestWindow) -> FlatDifference {
    let up = upstreamApply(op, window)
    let mine = nestedApply(op, window)
    return FlatDifference(
        tabsDiffer: up.tabs.map(\.id) != mine.tabs.map(\.id),
        groupsDiffer: up.groups.map(\.id) != mine.groups.map(\.id),
        upstreamChanged: up != window
    )
}

@MainActor
func flatDifference(_ window: NestWindow) -> FlatDifference {
    let up = upstreamNormalized(window)
    var mine = window
    mine.bareRepair()
    return FlatDifference(
        tabsDiffer: up.tabs.map(\.id) != mine.tabs.map(\.id),
        groupsDiffer: up.groups.map(\.id) != mine.groups.map(\.id)
    )
}

@MainActor
func isUpstreamResting(_ window: NestWindow) -> Bool {
    let again = upstreamNormalized(window)
    return again.tabs.map(\.id) == window.tabs.map(\.id) && again.groups.map(\.id) == window.groups.map(\.id)
}

func randomFlatWindow(_ rng: inout SplitMix64) -> NestWindow {
    let groupCount = Int.random(in: 0...4, using: &rng)
    let workspaceCount = Int.random(in: 0...8, using: &rng)
    var groups: [NestGroup] = (0..<groupCount).map { _ in
        NestGroup(id: UUID(), parentId: nil, isPinned: Int.random(in: 0..<10, using: &rng) < 4, anchorWorkspaceId: nil)
    }
    let drawable = groups.filter { _ in Int.random(in: 0..<10, using: &rng) < 7 }
    var tabs: [NestWorkspace] = (0..<workspaceCount).map { _ in
        let group: UUID? = Int.random(in: 0..<10, using: &rng) < 6 ? drawable.randomElement(using: &rng)?.id : nil
        return NestWorkspace(id: UUID(), groupId: group, isPinned: Int.random(in: 0..<10, using: &rng) < 3)
    }
    for gi in groups.indices {
        groups[gi].anchorWorkspaceId = tabs.filter { $0.groupId == groups[gi].id }.randomElement(using: &rng)?.id
    }
    tabs.shuffle(using: &rng)
    groups.shuffle(using: &rng)
    return NestWindow(tabs: tabs, groups: groups)
}

@MainActor
func upstreamFixtureStates() throws -> [(String, NestWindow)] {
    var out: [(String, NestWindow)] = []
    func note<T: WorkspaceTabRepresenting>(_ name: String, _ model: WorkspacesModel<T>) {
        out.append((name, snapshot(model)))
    }

    do {
        let f = try WorkspaceCoordinatorTopLevelGroupBlockFixture()
        note("TopLevelGroupBlockFixture", f.model)
        _ = f.reorder.reorderSidebarWorkspaces(tabIds: [f.anchor1Id, f.anchor2Id], draggedTabId: f.anchor1Id, toIndex: 2, isDragOperation: true, usesTopLevelRows: true)
        note("selectedGroupsMoveAsContiguousSectionsAfterLooseRow/after", f.model)
    }
    do {
        let f = try WorkspaceCoordinatorTopLevelGroupBlockFixture()
        _ = f.reorder.reorderSidebarWorkspaces(tabIds: [f.anchor1Id, f.anchor2Id], draggedTabId: f.anchor1Id, toIndex: 4, isDragOperation: true, usesTopLevelRows: true)
        note("pastEndTargetAppendsSelectedGroups/after", f.model)
    }
    do {
        let f = try WorkspaceCoordinatorTopLevelGroupBlockFixture()
        f.groups.setWorkspaceGroupPinned(groupId: f.group1Id, isPinned: true)
        note("mixedPinTiers/pinned", f.model)
        _ = f.reorder.reorderSidebarWorkspaces(tabIds: [f.anchor1Id, f.anchor2Id], draggedTabId: f.anchor1Id, toIndex: 4, isDragOperation: true, usesTopLevelRows: true)
        note("mixedPinTiers/after", f.model)
    }
    do {
        let f = try WorkspaceCoordinatorTopLevelGroupBlockFixture()
        f.model.normalizeWorkspaceGroupRunsPreservingOrder([f.anchor1Id, f.loose1.id, f.anchor2Id, f.loose2.id, f.loose3.id])
        note("movingReference/runsReordered-before-sync", f.model)
        f.model.syncWorkspaceGroupsOrderToAnchorOrder()
        note("movingReference/setup", f.model)
        _ = f.reorder.reorderSidebarWorkspaces(tabIds: [f.anchor1Id, f.anchor2Id], draggedTabId: f.anchor2Id, toIndex: 0, isDragOperation: true, usesTopLevelRows: true)
        note("movingReference/after", f.model)
    }
    do {
        let model = WorkspacesModel<CoordinatorStubTab>()
        let host = StubGroupHost(model: model)
        let reorder = WorkspaceReorderCoordinator(model: model)
        reorder.attach(host: host)
        let a = CoordinatorStubTab(isPinned: true), b = CoordinatorStubTab(isPinned: true), c = CoordinatorStubTab(), d = CoordinatorStubTab()
        model.tabs = [a, b, c, d]
        note("moveTabsToTop/setup", model)
        reorder.moveTabsToTop([d.id, b.id])
        note("moveTabsToTop/after", model)
    }
    do {
        let model = WorkspacesModel<CoordinatorStubTab>()
        let host = StubGroupHost(model: model)
        let groups = WorkspaceGroupCoordinator(model: model)
        groups.attach(host: host)
        let reorder = WorkspaceReorderCoordinator(model: model)
        reorder.attach(host: host)
        let dragged = CoordinatorStubTab(), child1 = CoordinatorStubTab(), child2 = CoordinatorStubTab(), outside = CoordinatorStubTab()
        model.tabs = [dragged, child1, child2, outside]
        note("explicitGroupDrop/tabs-only", model)
        let g = try #require(groups.createWorkspaceGroup(name: "G", childWorkspaceIds: [child1.id, child2.id]))
        note("explicitGroupDrop/setup", model)
        _ = reorder.reorderSidebarWorkspace(tabId: dragged.id, toIndex: 3, isDragOperation: true, explicitGroupId: g)
        note("explicitGroupDropJoinsTargetGroupAtBoundarySlot/after", model)
    }
    do {
        let model = WorkspacesModel<CoordinatorStubTab>()
        let host = StubGroupHost(model: model)
        let groups = WorkspaceGroupCoordinator(model: model)
        groups.attach(host: host)
        let reorder = WorkspaceReorderCoordinator(model: model)
        reorder.attach(host: host)
        let dragged = CoordinatorStubTab(), child1 = CoordinatorStubTab(), child2 = CoordinatorStubTab(), outside = CoordinatorStubTab()
        model.tabs = [dragged, child1, child2, outside]
        _ = try #require(groups.createWorkspaceGroup(name: "G", childWorkspaceIds: [child1.id, child2.id]))
        _ = reorder.reorderSidebarWorkspace(tabId: dragged.id, toIndex: 3, isDragOperation: true)
        note("boundaryDropWithoutExplicitGroupStaysTopLevel/after", model)
    }
    do {
        let model = WorkspacesModel<CoordinatorStubTab>()
        let host = StubGroupHost(model: model)
        let groups = WorkspaceGroupCoordinator(model: model)
        groups.attach(host: host)
        let reorder = WorkspaceReorderCoordinator(model: model)
        reorder.attach(host: host)
        let dragged = CoordinatorStubTab(), peer = CoordinatorStubTab(), t1 = CoordinatorStubTab(), t2 = CoordinatorStubTab(), outside = CoordinatorStubTab()
        model.tabs = [dragged, peer, t1, t2, outside]
        _ = try #require(groups.createWorkspaceGroup(name: "Source", childWorkspaceIds: [dragged.id, peer.id]))
        let target = try #require(groups.createWorkspaceGroup(name: "Target", childWorkspaceIds: [t1.id, t2.id]))
        note("explicitGroupDropFromAnotherGroup/setup", model)
        let last = try #require(model.tabs.indices.last { model.tabs[$0].groupId == target })
        _ = reorder.reorderSidebarWorkspace(tabId: dragged.id, toIndex: last, isDragOperation: true, explicitGroupId: target)
        note("explicitGroupDropFromAnotherGroupPreservesTargetGroupSlot/after", model)
    }
    do {
        let model = WorkspacesModel<CoordinatorStubTab>()
        let host = StubGroupHost(model: model)
        let reorder = WorkspaceReorderCoordinator(model: model)
        reorder.attach(host: host)
        let p1 = CoordinatorStubTab(isPinned: true), p2 = CoordinatorStubTab(isPinned: true), p3 = CoordinatorStubTab(isPinned: true)
        let q1 = CoordinatorStubTab(), q2 = CoordinatorStubTab(), q3 = CoordinatorStubTab(), q4 = CoordinatorStubTab()
        model.tabs = [p1, p2, p3, q1, q2, q3, q4]
        _ = reorder.reorderSidebarWorkspaces(tabIds: [p1.id, p3.id, q2.id, q4.id], draggedTabId: q2.id, toIndex: 3, isDragOperation: true)
        note("sidebarBlockClampsMixedPinTiers/after", model)
    }
    do {
        let model = WorkspacesModel<CoordinatorStubTab>()
        let host = StubGroupHost(model: model)
        let groups = WorkspaceGroupCoordinator(model: model)
        groups.attach(host: host)
        let reorder = WorkspaceReorderCoordinator(model: model)
        reorder.attach(host: host)
        let m1 = CoordinatorStubTab(), m2 = CoordinatorStubTab(), t1 = CoordinatorStubTab(), t2 = CoordinatorStubTab(), outside = CoordinatorStubTab()
        model.tabs = [m1, m2, t1, t2, outside]
        let g = try #require(groups.createWorkspaceGroup(name: "G", childWorkspaceIds: [t1.id, t2.id]))
        let index = try #require(model.tabs.filter { $0.id != m1.id }.firstIndex { $0.id == t2.id })
        _ = reorder.reorderSidebarWorkspaces(tabIds: [m1.id, m2.id], draggedTabId: m1.id, toIndex: index, isDragOperation: true, explicitGroupId: g)
        note("sidebarBlockExplicitGroupDropAssignsEveryMember/after", model)
    }
    do {
        let model = WorkspacesModel<CoordinatorStubTab>()
        let host = StubGroupHost(model: model)
        let groups = WorkspaceGroupCoordinator(model: model)
        groups.attach(host: host)
        let reorder = WorkspaceReorderCoordinator(model: model)
        reorder.attach(host: host)
        let c1 = CoordinatorStubTab(), c2 = CoordinatorStubTab(), o1 = CoordinatorStubTab(), o2 = CoordinatorStubTab()
        model.tabs = [c1, c2, o1, o2]
        _ = try #require(groups.createWorkspaceGroup(name: "G", childWorkspaceIds: [c1.id, c2.id]))
        _ = reorder.reorderSidebarWorkspaces(tabIds: [c1.id, c2.id], draggedTabId: c1.id, toIndex: 2, isDragOperation: true, usesTopLevelRows: true)
        note("sidebarBlockTopLevelDropPromotesGroupedChildren/after", model)
    }
    do {
        let model = WorkspacesModel<CoordinatorStubTab>()
        let host = StubGroupHost(model: model)
        let groups = WorkspaceGroupCoordinator(model: model)
        groups.attach(host: host)
        let c1 = CoordinatorStubTab(), other = CoordinatorStubTab(), c2 = CoordinatorStubTab()
        model.tabs = [c1, other, c2]
        _ = groups.createWorkspaceGroup(name: " ", childWorkspaceIds: [c1.id, c2.id])
        note("createWorkspaceGroupAdoptsChildrenAndKeepsSectionContiguous/after", model)
    }
    do {
        let model = WorkspacesModel<CoordinatorStubTab>()
        let host = StubGroupHost(model: model)
        let groups = WorkspaceGroupCoordinator(model: model)
        groups.attach(host: host)
        let pinned = CoordinatorStubTab(isPinned: true), plain = CoordinatorStubTab()
        model.tabs = [pinned, plain]
        _ = try #require(groups.createWorkspaceGroup(name: "Mixed", childWorkspaceIds: [pinned.id, plain.id]))
        note("createWorkspaceGroupAdoptsPinnedChildren/after", model)
    }
    do {
        let model = WorkspacesModel<CoordinatorStubTab>()
        let host = StubGroupHost(model: model)
        let groups = WorkspaceGroupCoordinator(model: model)
        groups.attach(host: host)
        let a = CoordinatorStubTab(), b = CoordinatorStubTab()
        model.tabs = [a, b]
        let g = try #require(groups.createWorkspaceGroup(name: "G", childWorkspaceIds: [a.id, b.id]))
        note("twoMemberGroup/setup", model)
        groups.setWorkspaceGroupAnchor(groupId: g, workspaceId: b.id)
        note("setWorkspaceGroupAnchorHoistsNewAnchorToSectionFront/after", model)
    }
    do {
        let model = WorkspacesModel<CoordinatorStubTab>()
        let host = StubGroupHost(model: model)
        let groups = WorkspaceGroupCoordinator(model: model)
        groups.attach(host: host)
        let a = CoordinatorStubTab(), b = CoordinatorStubTab()
        model.tabs = [a, b]
        _ = try #require(groups.createWorkspaceGroup(name: "G", childWorkspaceIds: [a.id, b.id]))
        let anchor = model.workspaceGroups[0].anchorWorkspaceId
        model.tabs.removeAll { $0.id == anchor }
        model.promoteAnchorOrRemoveGroupsAnchoredBy(closedWorkspaceId: anchor)
        note("anchorClosePromotesNextMemberAndKeepsGroup/after", model)
    }
    do {
        let model = WorkspacesModel<CoordinatorStubTab>()
        let host = StubGroupHost(model: model)
        let groups = WorkspaceGroupCoordinator(model: model)
        groups.attach(host: host)
        let a = CoordinatorStubTab(), outside = CoordinatorStubTab()
        model.tabs = [a, outside]
        let g = try #require(groups.createWorkspaceGroup(name: "G", childWorkspaceIds: [a.id]))
        groups.ungroupWorkspaceGroup(groupId: g)
        note("ungroupKeepsMemberPositionsAndDropsMembership/after", model)
    }
    do {
        let model = WorkspacesModel<CoordinatorStubTab>()
        let host = StubGroupHost(model: model)
        let groups = WorkspaceGroupCoordinator(model: model)
        groups.attach(host: host)
        let outside = CoordinatorStubTab()
        model.tabs = [outside]
        let g = try #require(groups.createWorkspaceGroup(name: "Pinned", childWorkspaceIds: []))
        groups.setWorkspaceGroupPinned(groupId: g, isPinned: true)
        note("pinnedEmptyGroup/pinned-with-anchor", model)
        let anchor = try #require(model.workspaceGroups.first { $0.id == g }).anchorWorkspaceId
        model.tabs.removeAll { $0.id == anchor }
        model.promoteAnchorOrRemoveGroupsAnchoredBy(closedWorkspaceId: anchor)
        note("pinnedAnchorClosePreservesEmptyGroup/after", model)
        let new = CoordinatorStubTab()
        model.tabs.append(new)
        note("addingWorkspaceToEmptyPinnedGroup/before-add", model)
        groups.addWorkspaceToGroup(workspaceId: new.id, groupId: g)
        note("addingWorkspaceToEmptyPinnedGroupPromotesItToAnchor/after", model)
    }
    do {
        let model = WorkspacesModel<CoordinatorStubTab>()
        let host = StubGroupHost(model: model)
        let groups = WorkspaceGroupCoordinator(model: model)
        groups.attach(host: host)
        let a = CoordinatorStubTab(), b = CoordinatorStubTab(), outside = CoordinatorStubTab()
        model.tabs = [a, b, outside]
        _ = try #require(groups.createWorkspaceGroup(name: "G", childWorkspaceIds: [a.id, b.id]))
        note("deleteGroupDrainsLiveAnchorLast/setup", model)
    }

    return out
}
