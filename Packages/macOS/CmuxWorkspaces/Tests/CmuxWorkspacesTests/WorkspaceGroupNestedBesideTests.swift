import Foundation
import Testing
import CmuxSettings
@testable import CmuxWorkspaces

// Nested workspace groups (#cm-106): `workspace.group.move --before/--after` among nested groups, what the move says happened,
// the log line for a refused move, and the menu as a value.
@MainActor
struct WorkspaceGroupNestedBesideTests {
    private func world(_ lab: inout Labels, tabs: [NestWorkspace], groups: [NestGroup]) -> NestedWorld {
        NestedWorld(NestWindow(tabs: tabs, groups: groups))
    }

    /// Groups listed `B, A, A1 (in A), C`.
    private func firstWindow(_ lab: inout Labels) -> NestedWorld {
        world(
            &lab,
            tabs: [lab.ws("b", in: "B"), lab.ws("a", in: "A"), lab.ws("a1", in: "A1"), lab.ws("c", in: "C")],
            groups: [lab.group("B", own: "b"), lab.group("A", own: "a"), lab.group("A1", parent: "A", own: "a1"), lab.group("C", own: "c")]
        )
    }

    @Test
    func bMovedBeforeCAmongTopLevelGroupsLandsDirectlyBeforeIt() {
        var lab = Labels()
        let w = firstWindow(&lab)
        #expect(w.compact(lab) == "B[b] | A[a: A1[a1]] | C[c]")
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("B"), beside: lab.id("C"), after: false) == .moved)
        #expect(w.compact(lab) == "A[a: A1[a1]] | B[b] | C[c]")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func cMovedAfterATakesThePlaceDirectlyAfterAsWholeRun() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("a", in: "A"), lab.ws("a1", in: "A1"), lab.ws("b", in: "B"), lab.ws("c", in: "C")],
            groups: [lab.group("A", own: "a"), lab.group("A1", parent: "A", own: "a1"), lab.group("B", own: "b"), lab.group("C", own: "c")]
        )
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("C"), beside: lab.id("A"), after: true) == .moved)
        #expect(w.compact(lab) == "A[a: A1[a1]] | C[c] | B[b]")
        #expect(w.violations(lab).isEmpty)
    }

    @Test
    func aMoveBesideASiblingInsideAParentStaysInsideIt() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("p", in: "P"), lab.ws("x", in: "X"), lab.ws("y", in: "Y"), lab.ws("z", in: "Z")],
            groups: [lab.group("P", own: "p"), lab.group("X", parent: "P", own: "x"), lab.group("Y", parent: "P", own: "y"), lab.group("Z", parent: "P", own: "z")]
        )
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("Z"), beside: lab.id("X"), after: false) == .moved)
        #expect(w.compact(lab) == "P[p: Z[z], X[x], Y[y]]")
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("Z"), beside: lab.id("Y"), after: true) == .moved)
        #expect(w.compact(lab) == "P[p: X[x], Y[y], Z[z]]")
    }

    @Test
    func aGroupMovedAfterASiblingBelowItTakesTheSlotDirectlyAfterAndNotTheOneBeyond() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("a", in: "A"), lab.ws("b", in: "B"), lab.ws("c", in: "C"), lab.ws("d", in: "D")],
            groups: [lab.group("A", own: "a"), lab.group("B", own: "b"), lab.group("C", own: "c"), lab.group("D", parent: "C", own: "d")]
        )
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("A"), beside: lab.id("B"), after: true) == .moved)
        #expect(w.compact(lab) == "B[b] | A[a] | C[c: D[d]]")
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("B"), beside: lab.id("A"), after: false) == .unchanged)
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("B"), beside: lab.id("C"), after: false) == .moved)
        #expect(w.compact(lab) == "A[a] | B[b] | C[c: D[d]]")
    }

    @Test
    func aGroupAlreadyThereIsUnchangedAndSoIsOneBesideItself() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("a", in: "A"), lab.ws("b", in: "B"), lab.ws("c", in: "C"), lab.ws("d", in: "D")],
            groups: [lab.group("A", own: "a"), lab.group("B", own: "b"), lab.group("C", own: "c"), lab.group("D", parent: "C", own: "d")]
        )
        let before = w.window
        let notices = w.host.orderChanges.count
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("B"), beside: lab.id("C"), after: false) == .unchanged)
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("B"), beside: lab.id("A"), after: true) == .unchanged)
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("B"), beside: lab.id("B"), after: false) == .unchanged)
        #expect(w.window == before)
        #expect(w.host.orderChanges.count == notices)
    }

    @Test
    func aGroupMovedAfterItselfIsUnchangedAndDoesNotStepOnePlaceDown() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("a", in: "A"), lab.ws("b", in: "B"), lab.ws("c", in: "C")],
            groups: [lab.group("A", own: "a"), lab.group("B", own: "b"), lab.group("C", own: "c")]
        )
        let before = w.window
        let notices = w.host.orderChanges.count
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("A"), beside: lab.id("A"), after: true) == .unchanged)
        #expect(w.compact(lab) == "A[a] | B[b] | C[c]")
        #expect(w.window == before)
        #expect(w.host.orderChanges.count == notices)
    }

    @Test
    func aMovedParentTellsTheHostEveryWorkspaceInsideAtEveryLevelByAllThreeEntrances() {
        // `P` has no workspace of its own; `Q` inside it holds q and q2.
        func parentWithoutOwn(_ lab: inout Labels) -> NestedWorld {
            world(
                &lab,
                tabs: [lab.ws("q", in: "Q"), lab.ws("q2", in: "Q"), lab.ws("r", in: "R")],
                groups: [lab.group("P"), lab.group("Q", parent: "P", own: "q"), lab.group("R", own: "r")]
            )
        }
        // `P` has a workspace of its own and the same `Q` inside it.
        func parentWithOwn(_ lab: inout Labels) -> NestedWorld {
            world(
                &lab,
                tabs: [lab.ws("p", in: "P"), lab.ws("q", in: "Q"), lab.ws("q2", in: "Q"), lab.ws("r", in: "R")],
                groups: [lab.group("P", own: "p"), lab.group("Q", parent: "P", own: "q"), lab.group("R", own: "r")]
            )
        }
        // `P` holds `Q`, which holds `S`: three levels, each with workspaces of its own.
        func threeLevels(_ lab: inout Labels) -> NestedWorld {
            world(
                &lab,
                tabs: [lab.ws("p", in: "P"), lab.ws("q", in: "Q"), lab.ws("q2", in: "Q"), lab.ws("s", in: "S"), lab.ws("s2", in: "S"), lab.ws("r", in: "R")],
                groups: [lab.group("P", own: "p"), lab.group("Q", parent: "P", own: "q"), lab.group("S", parent: "Q", own: "s"), lab.group("R", own: "r")]
            )
        }
        // The same, with no workspace behind `P`'s name.
        func threeLevelsWithoutOwn(_ lab: inout Labels) -> NestedWorld {
            world(
                &lab,
                tabs: [lab.ws("q", in: "Q"), lab.ws("q2", in: "Q"), lab.ws("s", in: "S"), lab.ws("s2", in: "S"), lab.ws("r", in: "R")],
                groups: [lab.group("P"), lab.group("Q", parent: "P", own: "q"), lab.group("S", parent: "Q", own: "s"), lab.group("R", own: "r")]
            )
        }
        for (name, build, expected) in [
            ("no workspace of its own", parentWithoutOwn, ["q", "q2"]),
            ("a workspace of its own", parentWithOwn, ["p", "q", "q2"]),
            ("three levels", threeLevels, ["p", "q", "q2", "s", "s2"]),
            ("three levels, no workspace behind P", threeLevelsWithoutOwn, ["q", "q2", "s", "s2"]),
        ] as [(String, (inout Labels) -> NestedWorld, [String])] {
            // Before or after a sibling.
            var lab = Labels()
            var w = build(&lab)
            var notices = w.host.orderChanges.count
            #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("P"), beside: lab.id("R"), after: true) == .moved, "\(name): after")
            #expect(w.host.orderChanges.count == notices + 1, "\(name): after sends one notice")
            #expect(Set(w.host.orderChanges.last ?? []) == Set(expected.map { lab.id($0) }), "\(name): after names every workspace inside")
            // By index, the way the socket and a header drag send it.
            lab = Labels()
            w = build(&lab)
            notices = w.host.orderChanges.count
            let rIndex = w.window.groups.map(\.id).firstIndex(of: lab.id("R"))!
            #expect(w.groups.moveWorkspaceGroupReportingResult(groupId: lab.id("P"), toIndex: rIndex) == .moved, "\(name): by index")
            #expect(w.host.orderChanges.count == notices + 1, "\(name): by index sends one notice")
            #expect(Set(w.host.orderChanges.last ?? []) == Set(expected.map { lab.id($0) }), "\(name): by index names every workspace inside")
            // The index move a header drag uses (no answer wanted).
            lab = Labels()
            w = build(&lab)
            notices = w.host.orderChanges.count
            let r2 = w.window.groups.map(\.id).firstIndex(of: lab.id("R"))!
            w.groups.moveWorkspaceGroup(groupId: lab.id("P"), toIndex: r2)
            #expect(w.host.orderChanges.count == notices + 1, "\(name): drag sends one notice")
            #expect(Set(w.host.orderChanges.last ?? []) == Set(expected.map { lab.id($0) }), "\(name): drag names every workspace inside")
        }
    }

    @Test
    func aTargetInAnotherParentOrMissingChangesNothingAndSaysWhy() {
        var lab = Labels()
        let w = firstWindow(&lab)
        let before = w.window
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("B"), beside: lab.id("A1"), after: false) == .targetNotBeside)
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("A1"), beside: lab.id("C"), after: true) == .targetNotBeside)
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("B"), beside: UUID(), after: false) == .targetNotFound)
        #expect(w.groups.moveWorkspaceGroup(groupId: UUID(), beside: lab.id("C"), after: false) == .groupNotFound)
        #expect(w.window == before)
    }

    @Test
    func theMoveByIndexSaysWhatHappened() {
        var lab = Labels()
        let w = firstWindow(&lab)
        // Index 3 is C: B goes last among the top-level groups.
        #expect(w.groups.moveWorkspaceGroupReportingResult(groupId: lab.id("B"), toIndex: 3) == .moved)
        #expect(w.compact(lab) == "A[a: A1[a1]] | C[c] | B[b]")
        // Already last: the same request again moves nothing.
        #expect(w.groups.moveWorkspaceGroupReportingResult(groupId: lab.id("B"), toIndex: 99) == .unchanged)
        // The group now at index 2 is A1, which sits inside A.
        let list = w.window.groups.map(\.id)
        let a1 = list.firstIndex(of: lab.id("A1"))!
        #expect(w.groups.moveWorkspaceGroupReportingResult(groupId: lab.id("B"), toIndex: a1) == .targetNotBeside)
        #expect(w.groups.moveWorkspaceGroupReportingResult(groupId: UUID(), toIndex: 0) == .groupNotFound)
    }

    @Test
    func aRefusedMoveLogsOneLineWithTheReasonAndAMoveThatHappenedLogsNone() {
        var lab = Labels()
        let w = firstWindow(&lab)
        var lines: [String] = []
        w.model.nestedGroupLog = { lines.append($0) }
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("A"), intoParent: lab.id("A1")) == .destinationIsSelfOrInside)
        #expect(lines.count == 1)
        #expect(lines.last?.contains("destinationIsSelfOrInside") == true)
        #expect(lines.last?.contains(lab.id("A").uuidString) == true)
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("A"), intoParent: UUID()) == .destinationNotFound)
        #expect(lines.count == 2 && lines.last?.contains("destinationNotFound") == true)
        #expect(w.groups.moveWorkspaceGroup(groupId: UUID(), intoParent: nil) == .groupNotFound)
        #expect(lines.count == 3 && lines.last?.contains("groupNotFound") == true)
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("B"), beside: lab.id("A1"), after: false) == .targetNotBeside)
        #expect(lines.count == 4 && lines.last?.contains("targetNotBeside") == true)
        // A refused move by index logs one line too.
        let a1Index = w.window.groups.map(\.id).firstIndex(of: lab.id("A1"))!
        #expect(w.groups.moveWorkspaceGroupReportingResult(groupId: lab.id("B"), toIndex: a1Index) == .targetNotBeside)
        #expect(lines.count == 5 && lines.last?.contains("targetNotBeside") == true && lines.last?.contains(lab.id("B").uuidString) == true)
        // Moved and unchanged log nothing.
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("C"), intoParent: lab.id("A")) == .moved)
        #expect(w.groups.moveWorkspaceGroup(groupId: lab.id("C"), intoParent: lab.id("A")) == .unchanged)
        #expect(lines.count == 5)
    }

    @Test
    func theMoveMenuIsWhatWeWroteDownForAThreeLevelWindowFromTheCoordinatorAndFromTheStoredList() {
        var lab = Labels()
        // A holds B holds C; D sits at the top level beside A.
        let w = world(
            &lab,
            tabs: [lab.ws("a", in: "A"), lab.ws("b", in: "B"), lab.ws("c", in: "C"), lab.ws("d", in: "D")],
            groups: [lab.group("A", own: "a"), lab.group("B", parent: "A", own: "b"), lab.group("C", parent: "B", own: "c"), lab.group("D", own: "d")]
        )
        func destination(_ name: String, depth: Int, current: Bool) -> WorkspaceGroupMoveDestination {
            WorkspaceGroupMoveDestination(id: lab.id(name), name: w.model.workspaceGroups.first { $0.id == lab.id(name) }!.name, depth: depth, isCurrent: current)
        }
        // C: inside B. Offered A (0), B (1, where it is now), D (0). Not Top Level's tick.
        let forC = WorkspaceGroupMoveMenu(
            topLevelIsCurrent: false,
            destinations: [destination("A", depth: 0, current: false), destination("B", depth: 1, current: true), destination("D", depth: 0, current: false)]
        )
        // A: at the top. Offered D only; A, B and C (inside it) are left out.
        let forA = WorkspaceGroupMoveMenu(topLevelIsCurrent: true, destinations: [destination("D", depth: 0, current: false)])
        // B: inside A. Offered A (where it is now) and D; C (inside B) is left out.
        let forB = WorkspaceGroupMoveMenu(
            topLevelIsCurrent: false,
            destinations: [destination("A", depth: 0, current: true), destination("D", depth: 0, current: false)]
        )
        for (name, expected) in [("C", forC), ("A", forA), ("B", forB)] {
            // The SwiftUI header's value is built from the stored list.
            #expect(WorkspaceGroupMoveMenu.menu(for: lab.id(name), groups: w.model.workspaceGroups) == expected, "stored list, \(name)")
            // The AppKit header reads the coordinator.
            #expect(w.groups.moveMenu(for: lab.id(name)) == expected, "coordinator, \(name)")
        }
        #expect(WorkspaceGroupMoveMenu.menu(for: UUID(), groups: w.model.workspaceGroups) == nil)
        #expect(w.groups.moveMenu(for: UUID()) == nil)
    }
}
