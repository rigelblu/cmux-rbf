import Foundation
import Testing
import CmuxSettings
@testable import CmuxWorkspaces

// Nested workspace groups (#cm-106): the nested list of rows the sidebar draws, from plain values.
@MainActor
struct WorkspaceGroupRowWalkTests {
    private func walk(_ lab: Labels, _ window: NestWindow, folded: Set<String> = []) -> [String] {
        let items = window.tabs.map { WorkspaceGroupWorkspaceItem(id: $0.id, groupId: $0.groupId, isPinned: $0.isPinned) }
        let groups = window.groups.map { g in
            WorkspaceGroup(
                id: g.id,
                name: lab.name(g.id),
                isCollapsed: folded.contains(lab.name(g.id)),
                isPinned: g.isPinned,
                anchor: g.anchorWorkspaceId.map { .workspace($0) } ?? .empty(g.id),
                customColor: nil,
                iconSymbol: nil,
                parentGroupId: g.parentId
            )
        }
        return WorkspaceGroupRowWalk.rows(groups: groups, workspaces: items).map { row in
            switch row.kind {
            case .header(let id): return "\(row.depth):H(\(lab.name(id)))"
            case .workspace(let id): return "\(row.depth):\(lab.name(id))"
            }
        }
    }

    private func nested(_ lab: inout Labels) -> NestWindow {
        // u | P[p: a, Q[q: b], c] | v
        NestWindow(
            tabs: [lab.ws("u"), lab.ws("p", in: "P"), lab.ws("a", in: "P"), lab.ws("q", in: "Q"), lab.ws("b", in: "Q"), lab.ws("c", in: "P"), lab.ws("v")],
            groups: [lab.group("P", own: "p"), lab.group("Q", parent: "P", own: "q")]
        )
    }

    @Test
    func theWalkListsAHeaderThenTheRowsInsideAtOneLevelMoreEach() {
        var lab = Labels()
        let window = nested(&lab)
        #expect(walk(lab, window) == ["0:u", "0:H(P)", "1:a", "1:H(Q)", "2:b", "1:c", "0:v"])
    }

    @Test
    func aFoldedGroupHidesEverythingInsideAtEveryLevel() {
        var lab = Labels()
        let window = nested(&lab)
        #expect(walk(lab, window, folded: ["P"]) == ["0:u", "0:H(P)", "0:v"])
        #expect(walk(lab, window, folded: ["Q"]) == ["0:u", "0:H(P)", "1:a", "1:H(Q)", "1:c", "0:v"])
        #expect(walk(lab, window, folded: ["P", "Q"]) == ["0:u", "0:H(P)", "0:v"])
    }

    @Test
    func aHeaderWithNoWorkspaceOfItsOwnStillGetsARowAndItsChildrenFollow() {
        var lab = Labels()
        let window = NestWindow(
            tabs: [lab.ws("c", in: "C"), lab.ws("d", in: "C"), lab.ws("u")],
            groups: [lab.group("P", pinned: false), lab.group("C", parent: "P", own: "c")]
        )
        #expect(walk(lab, window) == ["0:H(P)", "1:H(C)", "2:d", "0:u"])
    }

    @Test
    func anEmptyHeaderIsListedAmongItsSiblingsAndAGroupWithNoRunKeepsItsPlace() {
        var lab = Labels()
        let window = NestWindow(
            tabs: [lab.ws("p", in: "P"), lab.ws("a", in: "P"), lab.ws("u")],
            groups: [lab.group("P", own: "p"), lab.group("E", parent: "P"), lab.group("Z", pinned: true)]
        )
        let rows = walk(lab, window)
        #expect(rows.contains("1:H(E)"))
        #expect(rows.contains("0:H(Z)"))
        // The empty child sits inside its parent's rows, after the parent's header.
        let p = rows.firstIndex(of: "0:H(P)")!, e = rows.firstIndex(of: "1:H(E)")!
        #expect(p < e)
    }

    @Test
    func pinnedRowsComeBeforeUnpinnedRowsInsideAGroup() {
        var lab = Labels()
        let window = NestWindow(
            tabs: [lab.ws("p", in: "P"), lab.ws("x", in: "P"), lab.ws("y", in: "P", pinned: true)],
            groups: [lab.group("P", own: "p")]
        )
        #expect(walk(lab, window) == ["0:H(P)", "1:y", "1:x"])
    }

    @Test
    func aFlatWindowIsListedOneLevelDeep() {
        var lab = Labels()
        let window = NestWindow(
            tabs: [lab.ws("a"), lab.ws("p", in: "P"), lab.ws("b", in: "P"), lab.ws("c")],
            groups: [lab.group("P", own: "p")]
        )
        #expect(walk(lab, window) == ["0:a", "0:H(P)", "1:b", "0:c"])
    }

    @Test
    func everyWorkspaceInsideAGroupIsListedForTheGroupAndEveryGroupAboveIt() {
        var lab = Labels()
        let window = nested(&lab)
        let items = window.tabs.map { WorkspaceGroupWorkspaceItem(id: $0.id, groupId: $0.groupId, isPinned: false) }
        let groups = window.groups.map { g in
            WorkspaceGroup(id: g.id, name: "", isCollapsed: false, isPinned: false, anchor: g.anchorWorkspaceId.map { .workspace($0) } ?? .empty(g.id), customColor: nil, iconSymbol: nil, parentGroupId: g.parentId)
        }
        let inside = WorkspaceGroupRowWalk.workspaceIdsInside(groups: groups, workspaces: items)
        #expect(inside[lab.id("P")]?.map { lab.name($0) } == ["p", "a", "q", "b", "c"])
        #expect(inside[lab.id("Q")]?.map { lab.name($0) } == ["q", "b"])
    }

    // MARK: - Part (f): what the sidebar's table rows read

    @Test
    func theWorkspacesInsideAGroupAreListedAtEveryLevelFromTheModel() {
        var lab = Labels()
        let window = nested(&lab)
        let w = NestedWorld(window)
        #expect(w.model.workspaceIdsInside(lab.id("P")).map { lab.name($0) } == ["p", "a", "q", "b", "c"])
        #expect(w.model.workspaceIdsInside(lab.id("Q")).map { lab.name($0) } == ["q", "b"])
        // A window with no nested group: the direct members, as `groupId` says.
        var lab2 = Labels()
        let flat = NestedWorld(NestWindow(
            tabs: [lab2.ws("a"), lab2.ws("p", in: "P"), lab2.ws("b", in: "P")],
            groups: [lab2.group("P", own: "p")]
        ))
        #expect(flat.model.workspaceIdsInside(lab2.id("P")).map { lab2.name($0) } == ["p", "b"])
    }

    @Test
    func aGroupUnderAFoldedGroupIsHiddenAtAnyDepthAndNoGroupIsHiddenWithoutNesting() {
        var lab = Labels()
        let window = NestWindow(
            tabs: [lab.ws("p", in: "P"), lab.ws("q", in: "Q"), lab.ws("r", in: "R"), lab.ws("s", in: "S")],
            groups: [lab.group("P", own: "p"), lab.group("Q", parent: "P", own: "q"), lab.group("R", parent: "Q", own: "r"), lab.group("S", own: "s")]
        )
        func groups(folded: Set<String>) -> [WorkspaceGroup] {
            window.groups.map { g in
                WorkspaceGroup(id: g.id, name: lab.name(g.id), isCollapsed: folded.contains(lab.name(g.id)), isPinned: false, anchor: g.anchorWorkspaceId.map { .workspace($0) } ?? .empty(g.id), customColor: nil, iconSymbol: nil, parentGroupId: g.parentId)
            }
        }
        func hidden(_ folded: Set<String>) -> Set<String> {
            Set(WorkspaceGroupRowWalk.groupIdsUnderAFoldedGroup(groups: groups(folded: folded)).map { lab.name($0) })
        }
        #expect(hidden(["P"]) == ["Q", "R"])
        #expect(hidden(["Q"]) == ["R"])
        #expect(hidden(["R"]) == [])
        #expect(hidden([]) == [])
        // A folded group with nothing nested is not hidden by itself.
        #expect(hidden(["S"]) == [])
        // No nested group at all: nothing is hidden, whatever is folded.
        let flat = [WorkspaceGroup(id: UUID(), name: "F", isCollapsed: true, isPinned: false, anchor: .empty(UUID()), customColor: nil, iconSymbol: nil)]
        #expect(WorkspaceGroupRowWalk.groupIdsUnderAFoldedGroup(groups: flat).isEmpty)
    }
}
