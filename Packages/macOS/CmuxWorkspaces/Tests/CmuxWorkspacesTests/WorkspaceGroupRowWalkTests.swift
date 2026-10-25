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

    // MARK: - A nested root drawn under a status (#cm-110.3)

    private func groups(_ lab: Labels, _ window: NestWindow, folded: Set<String> = []) -> [WorkspaceGroup] {
        window.groups.map { g in
            WorkspaceGroup(id: g.id, name: lab.name(g.id), isCollapsed: folded.contains(lab.name(g.id)), isPinned: g.isPinned,
                           anchor: g.anchorWorkspaceId.map { .workspace($0) } ?? .empty(g.id), customColor: nil, iconSymbol: nil, parentGroupId: g.parentId)
        }
    }

    private func walk(_ lab: Labels, _ window: NestWindow, folded: Set<String> = [], shown: Set<String>) -> [String] {
        let items = window.tabs.map { WorkspaceGroupWorkspaceItem(id: $0.id, groupId: $0.groupId, isPinned: $0.isPinned) }
        return WorkspaceGroupRowWalk.rows(groups: groups(lab, window, folded: folded), workspaces: items,
                                          groupsShownUnderAStatus: Set(shown.map { lab.idByName[$0]! })).map { row in
            switch row.kind {
            case .header(let id): return "\(row.depth):H(\(lab.name(id)))"
            case .workspace(let id): return "\(row.depth):\(lab.name(id))"
            }
        }
    }

    /// u | P[p: r1, Q[q: n1, n2], r2] | v, with Q shown under a status.
    private func parentWithShownRoot(_ lab: inout Labels) -> NestWindow {
        NestWindow(
            tabs: [lab.ws("u"), lab.ws("p", in: "P"), lab.ws("r1", in: "P"), lab.ws("q", in: "Q"), lab.ws("n1", in: "Q"), lab.ws("n2", in: "Q"), lab.ws("r2", in: "P"), lab.ws("v")],
            groups: [lab.group("P", own: "p"), lab.group("Q", parent: "P", own: "q")]
        )
    }

    @Test
    func aFoldedParentStillListsTheRootShownUnderAStatusAndHidesItsOtherRows() {
        var lab = Labels()
        let window = parentWithShownRoot(&lab)
        #expect(walk(lab, window, folded: ["P"], shown: ["Q"]) == ["0:u", "0:H(P)", "1:H(Q)", "2:n1", "2:n2", "0:v"])
        // Without the status the folded parent hides it, as it always has.
        #expect(walk(lab, window, folded: ["P"], shown: []) == ["0:u", "0:H(P)", "0:v"])
        // Unfolded: the same rows as without the set, in the same places.
        #expect(walk(lab, window, shown: ["Q"]) == walk(lab, window))
    }

    @Test
    func theRootsOwnFoldAndTheFoldsInsideItStillHideWhatTheyHide() {
        var lab = Labels()
        let window = NestWindow(
            tabs: [lab.ws("p", in: "P"), lab.ws("q", in: "Q"), lab.ws("n1", in: "Q"), lab.ws("m", in: "M"), lab.ws("m1", in: "M")],
            groups: [lab.group("P", own: "p"), lab.group("Q", parent: "P", own: "q"), lab.group("M", parent: "Q", own: "m")]
        )
        #expect(walk(lab, window, folded: ["P", "Q"], shown: ["Q"]) == ["0:H(P)", "1:H(Q)"])
        #expect(walk(lab, window, folded: ["P", "M"], shown: ["Q"]) == ["0:H(P)", "1:H(Q)", "2:n1", "2:H(M)"])
    }

    @Test
    func aRootTwoLevelsDownAFoldedParentIsFoundAndAFoldedGroupBetweenDoesNotHideIt() {
        var lab = Labels()
        let window = NestWindow(
            tabs: [lab.ws("p", in: "P"), lab.ws("a", in: "A"), lab.ws("a1", in: "A"), lab.ws("q", in: "Q"), lab.ws("n1", in: "Q")],
            groups: [lab.group("P", own: "p"), lab.group("A", parent: "P", own: "a"), lab.group("Q", parent: "A", own: "q")]
        )
        #expect(walk(lab, window, folded: ["A"], shown: ["Q"]) == ["0:H(P)", "1:H(A)", "2:H(Q)", "3:n1"])
        // The parent folded too: A's own header is hidden with the rest of P's rows, the root still comes out.
        #expect(walk(lab, window, folded: ["P", "A"], shown: ["Q"]) == ["0:H(P)", "2:H(Q)", "3:n1"])
    }

    @Test
    func aGroupBelowAFoldedParentIsHiddenUnlessItIsTheRootOrInsideIt() {
        var lab = Labels()
        let window = NestWindow(
            tabs: [lab.ws("p", in: "P"), lab.ws("a", in: "A"), lab.ws("q", in: "Q"), lab.ws("m", in: "M")],
            groups: [lab.group("P", own: "p"), lab.group("A", parent: "P", own: "a"), lab.group("Q", parent: "P", own: "q"), lab.group("M", parent: "Q", own: "m")]
        )
        func hidden(_ folded: Set<String>, shown: Set<String>) -> Set<String> {
            Set(WorkspaceGroupRowWalk.groupIdsUnderAFoldedGroup(groups: groups(lab, window, folded: folded), groupsShownUnderAStatus: Set(shown.map { lab.idByName[$0]! })).map { lab.name($0) })
        }
        #expect(hidden(["P"], shown: []) == ["A", "Q", "M"])
        #expect(hidden(["P"], shown: ["Q"]) == ["A"])
        // The root's own fold hides what is inside it, and a fold below the root does too.
        #expect(hidden(["P", "Q"], shown: ["Q"]) == ["A", "M"])
        #expect(hidden(["P", "M"], shown: ["Q"]) == ["A"])
    }

    @Test
    func anEmptyRootShownUnderAStatusIsListedFirstAmongItsParentsRows() {
        var lab = Labels()
        let window = NestWindow(
            tabs: [lab.ws("p", in: "P"), lab.ws("a", in: "P"), lab.ws("b", in: "P")],
            groups: [lab.group("P", own: "p"), lab.group("E", parent: "P")]
        )
        #expect(walk(lab, window, folded: ["P"], shown: ["E"]) == ["0:H(P)", "1:H(E)"])
        // Ruling (26): it sorts where its parent's run starts, so it comes before a sibling root that has rows.
        let sibling = NestWindow(
            tabs: [lab.ws("p", in: "P"), lab.ws("a", in: "P"), lab.ws("m", in: "M"), lab.ws("m1", in: "M")],
            groups: [lab.group("P", own: "p"), lab.group("M", parent: "P", own: "m"), lab.group("E", parent: "P")]
        )
        #expect(walk(lab, sibling, folded: ["P"], shown: ["E", "M"]) == ["0:H(P)", "1:H(E)", "1:H(M)", "2:m1"])
    }
}
