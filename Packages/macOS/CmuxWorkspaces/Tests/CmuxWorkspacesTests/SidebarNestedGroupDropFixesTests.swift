import CoreGraphics
import Foundation
import Testing

@testable import CmuxFoundation

// Nested workspace groups (#cm-106): the drops the review's breaks left uncovered, and the lines around a header with nothing.
@Suite struct SidebarNestedGroupDropFixesTests {
    private func plan(
        _ w: NestedDropWindow, _ dragged: UUID, _ row: String, _ zone: DropZone, _ half: DropHalf, block: Set<UUID> = []
    ) -> String {
        describePlan(
            SidebarWorkspaceReorderDropResolver().plan(for: w.request(dragged: dragged, at: w.point(row, zone, half), block: block)),
            in: w
        )
    }

    /// `L1 | P[pa | Q[qa] | R[ra] | S[sa]]`. Storage: L1 0, p0 1, pa 2, q0 3, qa 4, r0 5, ra 6, s0 7, sa 8.
    private func threeChildren() -> NestedDropWindow {
        NestedDropWindow([
            .ws("L1"),
            .grp("P", own: "p0", [
                .ws("pa"),
                .grp("Q", own: "q0", [.ws("qa")]),
                .grp("R", own: "r0", [.ws("ra")]),
                .grp("S", own: "s0", [.ws("sa")]),
            ]),
        ])
    }

    @Test func aPlaceInsideAChildGroupsStretchIsNoBoundaryOfItsParent() {
        let w = threeChildren()
        let context = SidebarNestedGroupDropContext(request: w.request(dragged: w.id("L1"), at: .zero), sortedTargets: w.targets)
        // 4 is between q0 and qa, inside Q's stretch; 3 is the start of Q's stretch.
        #expect(context.legalBoundary(level: w.group("P"), isPinned: false, requested: 4) == nil)
        #expect(context.legalBoundary(level: w.group("P"), isPinned: false, requested: 3) == 3)
    }

    @Test func aHeaderOverItsOwnStretchIsNoDropEvenWhenSeveralAreDragged() {
        let w = threeChildren()
        let block: Set<UUID> = [w.id("q0"), w.id("r0")]
        // On a row of its own stretch.
        #expect(plan(w, w.id("q0"), "qa", .upper, .right, block: block) == "no plan")
        #expect(plan(w, w.id("q0"), "qa", .lower, .left, block: block) == "no plan")
        // Over S's stretch, a row of P that stays, it is a drop: after S.
        #expect(plan(w, w.id("q0"), "sa", .lower, .right, block: block) == "q0 line sa.bottom in group P: reorder 5 workspaces group group P")
    }

    @Test func theUpperHalfOfAGroupsRowIsTheBoundaryBeforeItAndTheLowerHalfTheBoundaryAfter() {
        let w = threeChildren()
        // S dragged over Q: the upper half of Q's row puts it before Q, the lower half after Q (before R).
        #expect(plan(w, w.id("s0"), "q0", .upper, .right) == "s0 line q0.top in group P: reorder 3 workspaces group group P")
        #expect(plan(w, w.id("s0"), "qa", .lower, .right) == "s0 line r0.top in group P: reorder 5 workspaces group group P")
    }

    @Test func aHeaderWithNoWorkspaceIsHeldToItsPinTierAndTheLineSaysWhereItStays() {
        // `P[E1(pinned)[ea] | E2[fa]]`: E2, unpinned, cannot go above the pinned E1.
        let w = NestedDropWindow([
            .grp("P", own: "p0", [
                .grp("E1", own: nil, pinned: true, [.ws("ea")]),
                .grp("E2", own: nil, [.ws("fa")]),
            ]),
        ])
        let dragged = w.group("E2")
        let plan = describePlan(
            SidebarWorkspaceReorderDropResolver().plan(for: w.request(dragged: dragged, at: w.point("hdr:E1", .upper, .right))),
            in: w
        )
        #expect(plan == "group E2 line hdr:E2.top in group P: reorderGroup 2")
    }

    @Test func theLineBeforeAGroupDoesNotStopAtAnEmptyHeaderInsideTheGroupAbove() {
        // `L | P[p0: Q[q0: q1, E(none)], R[r0: r1]]`: on the upper half of R's header the line is above R, not above E.
        let w = NestedDropWindow([
            .ws("L"),
            .grp("P", own: "p0", [
                .grp("Q", own: "q0", [.ws("q1"), .grp("E", own: nil, [])]),
                .grp("R", own: "r0", [.ws("r1")]),
            ]),
        ])
        #expect(describePlan(w.plan("L", "r0", .upper, .right), in: w) == "L line r0.top in group P: reorder 3 workspaces group group P")
    }

    @Test func aHeaderWithNoWorkspaceDroppedAfterTheLastGroupLandsAtTheEndOfTheLevel() {
        // `P[pa | E(none) | Q[qa] | pb]`: E is drawn before Q. Dropped after Q it is last of the level: below pb.
        let w = NestedDropWindow([
            .grp("P", own: "p0", [
                .ws("pa"),
                .grp("E", own: nil, []),
                .grp("Q", own: "q0", [.ws("qa")]),
                .ws("pb"),
            ]),
        ])
        #expect(plan(w, w.group("E"), "qa", .lower, .right) == "group E line pb.bottom in group P: reorderGroup 2")
    }

    @Test func aPinnedTopLevelHeaderWithNoWorkspaceHasItsLineAtTheEndOfThePinnedRows() {
        // `E*(none) | G*[ga] | w2 | P(none)[Q*[qa]]`: dropped over P's header, E goes after G, still among the pinned rows.
        // It is drawn at the end of the pinned rows (above w2), not above P, where the unchanged planner puts its line.
        let w = NestedDropWindow([
            .grp("E", own: nil, pinned: true, []),
            .grp("G", own: "g0", pinned: true, [.ws("ga")]),
            .ws("w2"),
            .grp("P", own: nil, [.grp("Q", own: "q0", pinned: true, [.ws("qa")])]),
        ])
        let plan = describePlan(
            SidebarWorkspaceReorderDropResolver().plan(for: w.request(dragged: w.group("E"), at: w.point("hdr:P", .upper, .right))),
            in: w
        )
        #expect(plan == "group E line w2.top topLevel: reorderGroup 1")
    }

    @Test func aTopLevelHeaderWithNoWorkspaceSplitsByTheHalfOfTheRowAsInV0_31_0() {
        // `E(none) | G[g0: ga] | P[p0: Q[q0: qa]]`: over the lower half of G's header (the upper half of G's block) E goes
        // after G, as v0.31.0 does; a split by the half of the whole block would put it before G.
        let w = NestedDropWindow([
            .grp("E", own: nil, []),
            .grp("G", own: "g0", [.ws("ga")]),
            .grp("P", own: "p0", [.grp("Q", own: "q0", [.ws("qa")])]),
        ])
        let nested = SidebarWorkspaceReorderDropResolver().plan(for: w.request(dragged: w.group("E"), at: w.point("g0", .lower, .right)))
        // The unchanged resolver on the same window with the nesting taken out (P holds nothing but its own rows).
        let flat = NestedDropWindow([
            .grp("E", own: nil, []),
            .grp("G", own: "g0", [.ws("ga")]),
            .grp("P", own: "p0", [.ws("q0"), .ws("qa")]),
        ])
        let base = FrozenV0_31_0DropResolver().plan(for: flat.request(dragged: flat.group("E"), at: flat.point("g0", .lower, .right)))
        guard case .reorderGroup(let nestedIndex)? = nested?.action, case .reorderGroup(let baseIndex)? = base?.action else {
            Issue.record("both plans are expected: nested \(String(describing: nested)), v0.31.0 \(String(describing: base))")
            return
        }
        #expect(nestedIndex == baseIndex, "nested window \(nestedIndex), v0.31.0 \(baseIndex)")
    }
}
