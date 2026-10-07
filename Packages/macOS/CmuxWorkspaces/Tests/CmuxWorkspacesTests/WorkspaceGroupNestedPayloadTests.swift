import Foundation
import Testing
import CmuxSettings
@testable import CmuxWorkspaces

// Nested workspace groups (#cm-106): what the list payload and the move refusal read from the model.
@MainActor
struct WorkspaceGroupNestedPayloadTests {
    private func world(_ lab: inout Labels, tabs: [NestWorkspace], groups: [NestGroup]) -> NestedWorld {
        NestedWorld(NestWindow(tabs: tabs, groups: groups))
    }

    @Test
    func aGroupHoldsNothingOnlyWhenNoWorkspaceAndNoGroupNamesIt() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("a", in: "A"), lab.ws("c", in: "C"), lab.ws("u")],
            // A has its own workspace (state A); P has none and holds C (state B); E holds nothing (state C).
            groups: [lab.group("A", own: "a"), lab.group("P", pinned: true), lab.group("C", parent: "P", own: "c"), lab.group("E", pinned: true)]
        )
        #expect(!w.model.groupHoldsNothing(lab.id("A")))
        #expect(!w.model.groupHoldsNothing(lab.id("P")))
        #expect(!w.model.groupHoldsNothing(lab.id("C")))
        #expect(w.model.groupHoldsNothing(lab.id("E")))
    }

    @Test
    func theGroupsAreListedAParentBeforeItsChildrenAndAFlatWindowIsListedAsStored() {
        var lab = Labels()
        let w = world(
            &lab,
            tabs: [lab.ws("a", in: "A"), lab.ws("b", in: "B"), lab.ws("c", in: "C")],
            groups: [lab.group("A", own: "a"), lab.group("B", own: "b"), lab.group("C", parent: "B", own: "c")]
        )
        // Stored with the child ahead of its parent (an at-rest-broken list).
        w.model.workspaceGroups = [w.model.workspaceGroups[2], w.model.workspaceGroups[0], w.model.workspaceGroups[1]]
        #expect(w.model.workspaceGroupsParentFirst().map { lab.name($0.id) } == ["B", "C", "A"])
        var lab2 = Labels()
        let flat = world(&lab2, tabs: [lab2.ws("a", in: "A"), lab2.ws("b", in: "B")], groups: [lab2.group("A", own: "a"), lab2.group("B", own: "b")])
        flat.model.workspaceGroups.reverse()
        #expect(flat.model.workspaceGroupsParentFirst().map { lab2.name($0.id) } == ["B", "A"])
    }
}
