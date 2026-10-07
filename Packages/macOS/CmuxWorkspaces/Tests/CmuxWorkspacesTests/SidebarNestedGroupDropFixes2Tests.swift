import CoreGraphics
import Foundation
import Testing

@testable import CmuxFoundation

// Nested workspace groups (#cm-106): the line the table can paint, and a pinned row before a pinned group.
@Suite struct SidebarNestedGroupDropFixes2Tests {
    private func plan(_ w: NestedDropWindow, _ dragged: String, _ row: String, _ zone: DropZone, _ half: DropHalf) -> String {
        describePlan(
            SidebarWorkspaceReorderDropResolver().plan(for: w.request(dragged: w.id(dragged), at: w.point(row, zone, half))),
            in: w
        )
    }

    @Test func oneWorkspaceLeavingItsChildGroupWhereItStandsHasALineOnTheNextRowThatStays() {
        // `L | P[p0: Q[q0: q1, q2], a]`: q2 onto its own lower-left half, or onto the upper half of `a`, leaves Q and stays
        // where it is in P. The line is the top of `a`: a bottom-edge line under q1 would be painted as the top of q2, the
        // dragged row, which the table never paints on.
        let w = NestedDropWindow([
            .ws("L"),
            .grp("P", own: "p0", [.grp("Q", own: "q0", [.ws("q1"), .ws("q2")]), .ws("a")]),
        ])
        #expect(plan(w, "q2", "q2", .lower, .left) == "q2 line a.top in group P: reorder 4 workspaces group group P")
        #expect(plan(w, "q2", "a", .upper, .right) == "q2 line a.top in group P: reorder 4 workspaces group group P")
    }

    @Test func aPinnedRowDroppedBeforeAPinnedGroupLandsAboveAPinnedEmptyHeaderThatSitsBetween() {
        // `w9* | E*(none) | K*[k0] | P[p0: Q[q0: w7*]]`, w7 onto the upper half of K's header: E is drawn directly above K, so
        // the row lands above E, and the line is E's top.
        let w = NestedDropWindow([
            .ws("w9", pinned: true),
            .grp("E", own: nil, pinned: true, []),
            .grp("K", own: "k0", pinned: true, []),
            .grp("P", own: "p0", [.grp("Q", own: "q0", [.ws("w7", pinned: true)])]),
        ])
        #expect(plan(w, "w7", "k0", .upper, .right) == "w7 line hdr:E.top topLevel: reorder 1 top-level rows group none")
    }

    @Test func aWorkspaceOnTheUpperHalfOfAWorkspaceRowOfAGroupLandsBeforeIt() {
        // `L | P[p0: Q[q0: qa], pa, pb]`: L onto the upper half of pb lands before pb, among P's rows.
        let w = NestedDropWindow([
            .ws("L"),
            .grp("P", own: "p0", [.grp("Q", own: "q0", [.ws("qa")]), .ws("pa"), .ws("pb")]),
        ])
        #expect(plan(w, "L", "pb", .upper, .right) == "L line pb.top in group P: reorder 4 workspaces group group P")
        // The lower half of pa is the same place.
        #expect(plan(w, "L", "pa", .lower, .right) == "L line pb.top in group P: reorder 4 workspaces group group P")
    }
}
