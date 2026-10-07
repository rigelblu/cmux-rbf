import Foundation
import Testing
@testable import CmuxWorkspaces

@MainActor
struct WorkspaceGroupLayoutTests {

    // MARK: - A — Empty group landings (cases a1 to a5, u1 to u4)

    @Test
    func emptyGroupLandings() {
        func check(
            _ title: String,
            expected: String,
            _ build: (inout Labels) -> NestWindow,
            _ edit: (inout NestWindow, Labels) -> Void
        ) {
            var lab = Labels()
            var window = build(&lab)
            window.bareRepair()
            edit(&window, lab)
            let after = compact(window, lab)
            var repaired = window
            repaired.bareRepair()
            let still = repaired == window
            #expect(after == expected, "\(title)")
            #expect(still, "\(title): bare repair moved something")
        }

        func moveEToTop(_ window: inout NestWindow, _ lab: Labels) {
            guard let e = lab.idByName["E"] else { return }
            window.moveGroup(e, into: nil)
        }

        check(
            "a1 move E to top level; later group Q with workspace, workspaces between",
            expected: "w1 | P[p] | w2 | w3 | E[-] | Q[q] | w4",
            { lab in
                NestWindow(
                    tabs: [lab.ws("w1"), lab.ws("p", in: "P"), lab.ws("w2"), lab.ws("w3"), lab.ws("q", in: "Q"), lab.ws("w4")],
                    groups: [lab.group("P", own: "p"), lab.group("E", parent: "P"), lab.group("Q", own: "q")]
                )
            },
            moveEToTop
        )

        check(
            "a2 move E to top level; no group after P",
            expected: "w1 | P[p] | w2 | w3 | E[-]",
            { lab in
                NestWindow(
                    tabs: [lab.ws("w1"), lab.ws("p", in: "P"), lab.ws("w2"), lab.ws("w3")],
                    groups: [lab.group("P", own: "p"), lab.group("E", parent: "P")]
                )
            },
            moveEToTop
        )

        check(
            "a3 move E to top level; row directly below P is group with workspace",
            expected: "w1 | P[p] | E[-] | Q[q] | w2",
            { lab in
                NestWindow(
                    tabs: [lab.ws("w1"), lab.ws("p", in: "P"), lab.ws("q", in: "Q"), lab.ws("w2")],
                    groups: [lab.group("P", own: "p"), lab.group("E", parent: "P"), lab.group("Q", own: "q")]
                )
            },
            moveEToTop
        )

        check(
            "a4 move pinned E to top level out of unpinned P",
            expected: "u1* | Q*[q] | E*[-] | w1 | P[p] | w2",
            { lab in
                NestWindow(
                    tabs: [lab.ws("u1", pinned: true), lab.ws("q", in: "Q"), lab.ws("w1"), lab.ws("p", in: "P"), lab.ws("w2")],
                    groups: [lab.group("Q", pinned: true, own: "q"), lab.group("P", own: "p"), lab.group("E", parent: "P", pinned: true)]
                )
            },
            moveEToTop
        )

        check(
            "a5 move pinned E to top level out of pinned P",
            expected: "u1* | P*[p] | u2* | Q*[q] | u3* | E*[-] | w1",
            { lab in
                NestWindow(
                    tabs: [lab.ws("u1", pinned: true), lab.ws("p", in: "P"), lab.ws("u2", pinned: true), lab.ws("q", in: "Q"), lab.ws("u3", pinned: true), lab.ws("w1")],
                    groups: [lab.group("P", pinned: true, own: "p"), lab.group("E", parent: "P", pinned: true), lab.group("Q", pinned: true, own: "q")]
                )
            },
            moveEToTop
        )

        let unpinWindow: (inout Labels) -> NestWindow = { lab in
            NestWindow(
                tabs: [lab.ws("o", in: "O"), lab.ws("pa", in: "O", pinned: true), lab.ws("a", in: "O"), lab.ws("b", in: "O"), lab.ws("r", in: "R"), lab.ws("z", in: "O")],
                groups: [lab.group("O", own: "o"), lab.group("E", parent: "O", pinned: true), lab.group("R", parent: "O", own: "r")]
            )
        }

        let unpinWindowNoLaterGroup: (inout Labels) -> NestWindow = { lab in
            NestWindow(
                tabs: [lab.ws("o", in: "O"), lab.ws("pa", in: "O", pinned: true), lab.ws("a", in: "O"), lab.ws("b", in: "O"), lab.ws("z", in: "O")],
                groups: [lab.group("O", own: "o"), lab.group("E", parent: "O", pinned: true)]
            )
        }

        // A pin is not an edit: the caller stores the flag and runs the bare repair.
        let unpinAsFlagThenBareRepair: (inout NestWindow, Labels) -> Void = { window, lab in
            guard let e = lab.idByName["E"] else { return }
            window.setGroupPinned(e, false)
        }

        check("u2 unpin empty E inside O, as flag + bare repair", expected: "O[o: pa*, a, b, E[-], R[r], z]", unpinWindow, unpinAsFlagThenBareRepair)
        check("u4 unpin empty E inside O, no group after, as flag + bare repair", expected: "O[o: pa*, a, b, z, E[-]]", unpinWindowNoLaterGroup, unpinAsFlagThenBareRepair)
    }

    // MARK: - Reviewer's example

    @Test
    func reviewersExample() {
        var lab = Labels()
        let window = NestWindow(
            tabs: [lab.ws("a", in: "A"), lab.ws("a2", in: "A"), lab.ws("b", in: "B"), lab.ws("b2", in: "B")],
            groups: [lab.group("E"), lab.group("A", own: "a"), lab.group("B", own: "b")]
        )
        let op = FlatOp.moveToTop(lab.id("b2"))
        let up = upstreamApply(op, window)
        let combined = nestedApply(op, window)
        #expect(compact(up, lab) == "B[b: b2] | E[-] | A[a: a2]")
        #expect(combined.tabs.map(\.id) == up.tabs.map(\.id))
        #expect(combined.groups.map(\.id) == up.groups.map(\.id))
    }

    // MARK: - Reorder inside a parent (cases d1 to d3b)

    @Test
    func reorderInsideAParent() {
        func check(
            _ title: String,
            group: String,
            toSiblingIndex: Int,
            expected: String,
            expectMoved: Bool = true,
            _ build: (inout Labels) -> NestWindow
        ) {
            var lab = Labels()
            var window = build(&lab)
            window.bareRepair()
            let moved = window.reorderGroupInList(lab.id(group), toSiblingIndex: toSiblingIndex)
            let after = compact(window, lab)
            let problems = nestViolations(window, lab)
            var repaired = window
            repaired.bareRepair()
            #expect(after == expected, "\(title)")
            #expect(moved == expectMoved, "\(title)")
            #expect(problems.isEmpty, "\(title)")
            #expect(repaired == window, "\(title)")
        }

        check(
            "d1 three groups with parent workspaces between; C1 to C3 place",
            group: "C1",
            toSiblingIndex: 2,
            expected: "P[p: C2[c2], x, C3[c3], y, C1[c1]]"
        ) { lab in
            NestWindow(
                tabs: [lab.ws("p", in: "P"), lab.ws("c1", in: "C1"), lab.ws("x", in: "P"), lab.ws("c2", in: "C2"), lab.ws("y", in: "P"), lab.ws("c3", in: "C3")],
                groups: [lab.group("P", own: "p"), lab.group("C1", parent: "P", own: "c1"), lab.group("C2", parent: "P", own: "c2"), lab.group("C3", parent: "P", own: "c3")]
            )
        }

        check(
            "d2 nested twin of A[w0] | w1 | B[-]: A to E index",
            group: "A",
            toSiblingIndex: 1,
            expected: "P[p: E[-], A[a], x]"
        ) { lab in
            NestWindow(
                tabs: [lab.ws("p", in: "P"), lab.ws("a", in: "A"), lab.ws("x", in: "P")],
                groups: [lab.group("P", own: "p"), lab.group("A", parent: "P", own: "a"), lab.group("E", parent: "P")]
            )
        }

        let clampWindow: (inout Labels) -> NestWindow = { lab in
            NestWindow(
                tabs: [lab.ws("p", in: "P"), lab.ws("k", in: "K"), lab.ws("u1", in: "U1"), lab.ws("x", in: "P"), lab.ws("u2", in: "U2")],
                groups: [lab.group("P", own: "p"), lab.group("K", parent: "P", pinned: true, own: "k"), lab.group("U1", parent: "P", own: "u1"), lab.group("U2", parent: "P", own: "u2")]
            )
        }

        check(
            "d3 clamp: unpinned U2 sent to index 0, pinned group index",
            group: "U2",
            toSiblingIndex: 0,
            expected: "P[p: K*[k], U2[u2], x, U1[u1]]",
            clampWindow
        )

        check(
            "d3b clamp: pinned K sent to index 2, unpinned group index; reports false",
            group: "K",
            toSiblingIndex: 2,
            expected: "P[p: K*[k], U1[u1], x, U2[u2]]",
            expectMoved: false,
            clampWindow
        )
    }

    // MARK: - Six rules hold across random sequences

    @Test
    func sixRulesHoldAcrossRandomSequences() {
        let seeds = Int(ProcessInfo.processInfo.environment["CM106_SEEDS"] ?? "") ?? 50
        var failures = 0
        var counts = SequenceCounts()
        for index in 0..<seeds {
            let seed = UInt64(50_000 + index)
            var rng = SplitMix64(seed: seed)
            var lab = Labels()
            var counter = 0
            let scrambled = randomNestedWindow(&rng, &lab)
            var window = scrambled
            window.bareRepair()
            let firstWrite = nestViolations(window, lab) + tierOrderProblems(before: scrambled, after: window, lab)
            if !firstWrite.isEmpty {
                failures += 1
                Issue.record("Seed \(seed) after the first write: \(firstWrite) | input \(stored(scrambled, lab)) | output \(stored(window, lab))")
                continue
            }
            for step in 0..<150 {
                let previous = window
                let force: Int? = Bool.random(using: &rng) ? 9 : nil
                guard let edit = randomEdit(&window, &rng, &lab, counter: &counter, forceKind: force) else {
                    continue
                }
                counts.record(edit, after: window)
                var problems = nestViolations(window, lab)
                problems += untouchedNoRunOrderProblems(before: previous, after: window, touched: edit.touchedGroups)
                var again = window
                again.bareRepair()
                if again != window {
                    problems.append("second bare repair changed window: \(stored(again, lab))")
                }
                if !problems.isEmpty {
                    failures += 1
                    Issue.record("Seed \(seed) step \(step): \(edit.text) -> \(problems) | before \(stored(previous, lab)) | after \(stored(window, lab))")
                    break
                }
            }
        }
        print("sixRulesHoldAcrossRandomSequences: \(seeds) seeds, \(counts.summary)")
        #expect(failures == 0)
        #expect(counts.zeroCounts.isEmpty, "the sequences never reached: \(counts.zeroCounts)")
    }

    // MARK: - Refusals leave the layout as it was

    private func refusalWindow(_ lab: inout Labels) -> NestWindow {
        NestWindow(
            tabs: [lab.ws("w1"), lab.ws("p", in: "P"), lab.ws("c", in: "C"), lab.ws("d", in: "D"), lab.ws("x", in: "P")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", own: "c"), lab.group("D", parent: "C", own: "d")]
        )
    }

    @Test
    func movingTheWorkspaceBehindAGroupNameIsRefused() {
        var lab = Labels()
        let window = refusalWindow(&lab)
        var layout = window.layout()
        let before = compact(window, lab, layout: layout)
        #expect(before == "w1 | P[p: C[c: D[d]], x]")
        for (destination, place) in [
            (lab.id("P") as UUID?, WorkspaceGroupLayout.Place.lastOfTier),
            (nil, .lastOfTier),
            (lab.id("D"), .firstOfTier)
        ] {
            let result = layout.move(.workspace(lab.id("p")), to: destination, at: place)
            #expect(result == .standsBehindGroupName)
            #expect(compact(window, lab, layout: layout) == before)
        }
        #expect(!layout.edited)
        #expect(layout.output() == window.layout().output())
    }

    @Test
    func movingAGroupIntoItselfOrOneOfItsDescendantsIsRefused() {
        var lab = Labels()
        let window = refusalWindow(&lab)
        var layout = window.layout()
        let before = compact(window, lab, layout: layout)
        for destination in ["P", "C", "D"] {
            let result = layout.move(.group(lab.id("P")), to: lab.id(destination), at: .lastOfTier)
            #expect(result == .destinationIsSelfOrInside, "P into \(destination)")
            #expect(compact(window, lab, layout: layout) == before, "P into \(destination)")
        }
        #expect(!layout.edited)
    }

    @Test
    func aRowOrDestinationThatDoesNotExistIsRefused() {
        var lab = Labels()
        let window = refusalWindow(&lab)
        var layout = window.layout()
        let before = compact(window, lab, layout: layout)
        #expect(layout.move(.workspace(UUID()), to: nil, at: .lastOfTier) == .rowNotFound)
        #expect(layout.move(.group(UUID()), to: nil, at: .lastOfTier) == .rowNotFound)
        #expect(layout.move(.workspace(lab.id("x")), to: UUID(), at: .lastOfTier) == .destinationNotFound)
        #expect(layout.move(.group(lab.id("D")), to: UUID(), at: .lastOfTier) == .destinationNotFound)
        #expect(compact(window, lab, layout: layout) == before)
        #expect(!layout.edited)
    }

    @Test
    func movingTheWorkspaceBehindANestedGroupNameIsRefusedToo() {
        var lab = Labels()
        let window = refusalWindow(&lab)
        var layout = window.layout()
        let before = compact(window, lab, layout: layout)
        #expect(before == "w1 | P[p: C[c: D[d]], x]")
        #expect(layout.move(.workspace(lab.id("c")), to: nil, at: .lastOfTier) == .standsBehindGroupName)
        #expect(compact(window, lab, layout: layout) == before)
        #expect(layout.move(.workspace(lab.id("d")), to: lab.id("P"), at: .lastOfTier) == .standsBehindGroupName)
        #expect(compact(window, lab, layout: layout) == before)
        #expect(!layout.edited)
    }

    // MARK: - Landing after the last workspace of a tier

    @Test
    func afterLastWorkspaceOfTierLandsAfterTheLastWorkspaceRowAndBeforeGroups() {
        func landing(_ build: (inout Labels) -> NestWindow) -> String {
            var lab = Labels()
            let window = build(&lab)
            var layout = window.layout()
            #expect(layout.move(.workspace(lab.id("w")), to: lab.id("G"), at: .afterLastWorkspaceOfTier) == .moved)
            return compact(window, lab, layout: layout)
        }
        // No workspace row in G: the first of the tier.
        #expect(landing { lab in
            NestWindow(
                tabs: [lab.ws("x", in: "G"), lab.ws("c", in: "C"), lab.ws("w")],
                groups: [lab.group("G", own: "x"), lab.group("C", parent: "G", own: "c")]
            )
        } == "G[x: w, C[c]]")
        // One workspace row y before the group row: right after y.
        #expect(landing { lab in
            NestWindow(
                tabs: [lab.ws("x", in: "G"), lab.ws("y", in: "G"), lab.ws("c", in: "C"), lab.ws("w")],
                groups: [lab.group("G", own: "x"), lab.group("C", parent: "G", own: "c")]
            )
        } == "G[x: y, w, C[c]]")
    }

    // MARK: - A bare repair inside a parent

    @Test
    func aBareRepairKeepsAGroupWithNoWorkspaceAtItsIndexInsideAParentToo() {
        var lab = Labels()
        var window = NestWindow(
            tabs: [lab.ws("p", in: "P"), lab.ws("b", in: "B"), lab.ws("a", in: "A")],
            groups: [lab.group("P", own: "p"), lab.group("E", parent: "P"), lab.group("A", parent: "P", own: "a"), lab.group("B", parent: "P", own: "b")]
        )
        window.bareRepair()
        #expect(window.groups.map { lab.name($0.id) } == ["P", "E", "B", "A"])
        #expect(window.tabs.map { lab.name($0.id) } == ["p", "b", "a"])
        #expect(nestViolations(window, lab).isEmpty)
    }

    // MARK: - Two edits on one layout value

    /// Two edits on one value must write what the same two edits write with a write and a read between them.
    /// Both paths must also agree on which edit changed something.
    private func twoEditsOnOneValueAndTwoWrites(
        _ build: (inout Labels) -> NestWindow,
        first: (Labels) -> LayoutEdit,
        second: (Labels) -> LayoutEdit,
        expectSecondApplied: Bool = true
    ) -> (lab: Labels, oneValue: NestWindow, twoWrites: NestWindow) {
        var lab = Labels()
        var start = build(&lab)
        start.bareRepair()
        let firstEdit = first(lab)
        let secondEdit = second(lab)

        var oneValue = start
        var layout = start.layout()
        let firstApplied = firstEdit.apply(to: &layout)
        let secondApplied = secondEdit.apply(to: &layout)
        #expect(firstApplied)
        #expect(secondApplied == expectSecondApplied, "one value: the second edit applied=\(secondApplied)")
        oneValue.apply(layout)

        var twoWrites = start
        var firstLayout = start.layout()
        firstEdit.apply(to: &firstLayout)
        twoWrites.apply(firstLayout)
        var secondLayout = twoWrites.layout()
        let secondAppliedAfterWrite = secondEdit.apply(to: &secondLayout)
        #expect(secondAppliedAfterWrite == expectSecondApplied, "two writes: the second edit applied=\(secondAppliedAfterWrite)")
        twoWrites.apply(secondLayout)
        return (lab, oneValue, twoWrites)
    }

    @Test
    func aMovedGroupThenAReorderOnTheSameValueWritesWhatTwoWritesWould() {
        let result = twoEditsOnOneValueAndTwoWrites(
            { lab in
                NestWindow(
                    tabs: [lab.ws("a", in: "A"), lab.ws("c", in: "C"), lab.ws("b", in: "B")],
                    groups: [lab.group("A", own: "a"), lab.group("C", parent: "A", own: "c"), lab.group("B", own: "b")]
                )
            },
            first: { .moveGroup($0.idByName["C"]!, nil, .firstOfTier) },
            second: { .reorder($0.idByName["B"]!, 0) }
        )
        let lab = result.lab
        #expect(result.twoWrites.groups.map { lab.name($0.id) } == ["B", "C", "A"])
        #expect(result.oneValue.groups.map { lab.name($0.id) } == ["B", "C", "A"])
        #expect(result.oneValue == result.twoWrites)
        #expect(nestViolations(result.oneValue, lab).isEmpty)
    }

    @Test
    func aMovedGroupThenAReorderWithAGroupHoldingNoWorkspaceAtTheDestinationLevel() {
        let result = twoEditsOnOneValueAndTwoWrites(
            { lab in
                NestWindow(
                    tabs: [lab.ws("a", in: "A"), lab.ws("c", in: "C"), lab.ws("b", in: "B")],
                    groups: [lab.group("A", own: "a"), lab.group("C", parent: "A", own: "c"), lab.group("E"), lab.group("B", own: "b")]
                )
            },
            first: { .moveGroup($0.idByName["C"]!, nil, .firstOfTier) },
            second: { .reorder($0.idByName["B"]!, 0) }
        )
        let lab = result.lab
        // E keeps its place at the end of the top-level groups, behind the groups with a workspace.
        #expect(result.twoWrites.groups.map { lab.name($0.id) } == ["B", "C", "A", "E"])
        #expect(result.oneValue.groups.map { lab.name($0.id) } == ["B", "C", "A", "E"])
        #expect(result.oneValue == result.twoWrites)
        #expect(nestViolations(result.oneValue, lab).isEmpty)
    }

    @Test
    func aReorderThenAReorderBesideAGroupWithNoWorkspaceWritesWhatTwoWritesWould() {
        let result = twoEditsOnOneValueAndTwoWrites(
            { lab in
                NestWindow(
                    tabs: [lab.ws("a", in: "A"), lab.ws("b", in: "B")],
                    groups: [lab.group("E"), lab.group("A", own: "a"), lab.group("B", own: "b")]
                )
            },
            first: { .reorder($0.idByName["B"]!, 0) },
            second: { .reorder($0.idByName["A"]!, 1) }
        )
        let lab = result.lab
        #expect(result.twoWrites.groups.map { lab.name($0.id) } == ["A", "E", "B"])
        #expect(result.twoWrites.tabs.map { lab.name($0.id) } == ["a", "b"])
        #expect(result.oneValue == result.twoWrites)
        #expect(nestViolations(result.oneValue, lab).isEmpty)
    }

    @Test
    func aSecondReorderThatWouldChangeNothingAfterTheFirstIsRefusedOnOneValueToo() {
        let result = twoEditsOnOneValueAndTwoWrites(
            { lab in
                NestWindow(
                    tabs: [lab.ws("p1", in: "P1"), lab.ws("p2", in: "P2")],
                    groups: [lab.group("E"), lab.group("P1", pinned: true, own: "p1"), lab.group("P2", pinned: true, own: "p2")]
                )
            },
            first: { .reorder($0.idByName["P1"]!, 2) },
            second: { .reorder($0.idByName["P1"]!, 1) },
            expectSecondApplied: false
        )
        let lab = result.lab
        #expect(result.twoWrites.groups.map { lab.name($0.id) } == ["P2", "P1", "E"])
        #expect(result.oneValue == result.twoWrites)
        #expect(nestViolations(result.oneValue, lab).isEmpty)
    }

    @Test
    func aGroupWithNoWorkspaceMovedThenGivenAWorkspaceIsPlacedAgainBetweenTheTwoEdits() {
        var lab = Labels()
        var window = NestWindow(
            tabs: [lab.ws("x"), lab.ws("y"), lab.ws("a", in: "A")],
            groups: [lab.group("A", own: "a"), lab.group("E")]
        )
        window.bareRepair()
        var layout = window.layout()
        #expect(compact(window, lab, layout: layout) == "x | y | A[a] | E[-]")
        let moved = layout.move(.group(lab.id("E")), to: nil, at: .index(0))
        let joined = layout.move(.workspace(lab.id("x")), to: lab.id("E"), at: .lastOfTier)
        #expect(moved == .moved)
        #expect(joined == .moved)
        #expect(compact(window, lab, layout: layout) == "y | E[x] | A[a]")
    }

    @Test
    func aParentWhoseOnlyWorkspacesAreInAChildGroupStaysWhereItIsAfterARefresh() {
        var lab = Labels()
        var window = NestWindow(
            tabs: [lab.ws("c", in: "C"), lab.ws("w"), lab.ws("a", in: "A")],
            groups: [lab.group("P"), lab.group("C", parent: "P", own: "c"), lab.group("A", own: "a")]
        )
        window.bareRepair()
        var layout = window.layout()
        #expect(compact(window, lab, layout: layout) == "P[-: C[c]] | w | A[a]")
        let result = layout.move(.workspace(lab.id("w")), to: nil, at: .index(1))
        #expect(result == .moved)
        #expect(compact(window, lab, layout: layout) == "P[-: C[c]] | w | A[a]")
        #expect(layout.output().tabOrder.map { lab.name($0) } == ["c", "w", "a"])
    }

    @Test
    func aReorderRefreshesEveryLevelNotOnlyItsOwn() {
        let result = twoEditsOnOneValueAndTwoWrites(
            { lab in
                NestWindow(
                    tabs: [lab.ws("p1", in: "P1"), lab.ws("c1", in: "C1"), lab.ws("c2", in: "C2"), lab.ws("p2", in: "P2")],
                    groups: [
                        lab.group("E"),
                        lab.group("P1", pinned: true, own: "p1"),
                        lab.group("C1", parent: "P1", own: "c1"),
                        lab.group("C2", parent: "P1", own: "c2"),
                        lab.group("P2", pinned: true, own: "p2")
                    ]
                )
            },
            first: { .reorder($0.idByName["C1"]!, 1) },
            second: { .reorder($0.idByName["P1"]!, 1) }
        )
        let lab = result.lab
        #expect(result.twoWrites.groups.map { lab.name($0.id) } == ["P2", "P1", "C2", "C1", "E"])
        #expect(result.oneValue == result.twoWrites)
        #expect(nestViolations(result.oneValue, lab).isEmpty)
    }

    @Test
    func aReorderThatChangesNothingLeavesTheStoredListAndTheEditedFlagAlone() {
        var lab = Labels()
        let window = NestWindow(
            tabs: [lab.ws("p1", in: "P1"), lab.ws("p2", in: "P2")],
            groups: [lab.group("E"), lab.group("P1", pinned: true, own: "p1"), lab.group("P2", pinned: true, own: "p2")]
        )
        var layout = window.layout()
        let changed = layout.moveGroupInList(lab.id("P1"), toSiblingIndex: 1)
        #expect(!changed)
        #expect(!layout.edited)
        #expect(layout.output().groupOrder.map { lab.name($0) } == ["E", "P1", "P2"])
    }

    @Test
    func setRowsThenAReorderOnOneValueWritesWhatAWriteBetweenWould() {
        var lab = Labels()
        var start = NestWindow(tabs: [], groups: [lab.group("G1"), lab.group("G0")])
        start.bareRepair()
        let g0 = WorkspaceGroupLayout.Row.group(lab.id("G0"))
        let g1 = WorkspaceGroupLayout.Row.group(lab.id("G1"))

        var oneValue = start
        var layout = start.layout()
        let setOne = layout.setRows(of: nil, [g0, g1])
        let reorderedOne = layout.moveGroupInList(lab.id("G1"), toSiblingIndex: 0)
        oneValue.apply(layout)

        var twoWrites = start
        var first = start.layout()
        let setTwo = first.setRows(of: nil, [g0, g1])
        twoWrites.apply(first)
        var second = twoWrites.layout()
        let reorderedTwo = second.moveGroupInList(lab.id("G1"), toSiblingIndex: 0)
        twoWrites.apply(second)

        #expect(setOne && setTwo)
        #expect(reorderedTwo)
        #expect(reorderedOne == reorderedTwo)
        #expect(twoWrites.groups.map { lab.name($0.id) } == ["G1", "G0"])
        #expect(oneValue == twoWrites)
    }

    @Test
    func aRefusedMoveLeavesTheStoredGroupListAlone() {
        var lab = Labels()
        let window = NestWindow(
            tabs: [lab.ws("p1", in: "P1"), lab.ws("p2", in: "P2")],
            groups: [lab.group("E"), lab.group("P1", pinned: true, own: "p1"), lab.group("P2", pinned: true, own: "p2")]
        )
        var layout = window.layout()
        #expect(layout.output().groupOrder.map { lab.name($0) } == ["E", "P1", "P2"])
        let result = layout.move(.workspace(lab.id("p1")), to: nil, at: .lastOfTier)
        #expect(result == .standsBehindGroupName)
        #expect(layout.output().groupOrder.map { lab.name($0) } == ["E", "P1", "P2"])
    }

    @Test
    func randomEditSequencesOnOneValueWriteWhatTheSameEditsWithWritesBetweenWould() {
        let seeds = Int(ProcessInfo.processInfo.environment["CM106_SEEDS"] ?? "") ?? 50
        var pairs = 0
        var triples = 0
        var moveThenReorder = 0
        var reorderThenMove = 0
        var reorderThenReorder = 0
        var reorderThenReorderAtNoWorkspaceLevel = 0
        var sameLevelReorderPairsAtNoWorkspaceLevel = 0
        var sameLevelPinnedReorderPairs = 0
        var failures = 0
        for index in 0..<seeds {
            let seed = UInt64(70_000 + index)
            var rng = SplitMix64(seed: seed)
            var lab = Labels()
            var window = randomNestedWindow(&rng, &lab)
            // Two groups with no workspace inside, anywhere in the tree, so reorders meet them often.
            for extra in 0..<2 {
                let parent = Bool.random(using: &rng) ? window.groups.randomElement(using: &rng)?.id : nil
                let empty = NestGroup(id: lab.id("E\(extra)"), parentId: parent, isPinned: Int.random(in: 0..<4, using: &rng) == 0, anchorWorkspaceId: nil)
                window.groups.insert(empty, at: Int.random(in: 0...window.groups.count, using: &rng))
            }
            window.bareRepair()
            for _ in 0..<100 {
                // Three edits on one value, each compared with the path that writes and reads between edits.
                var oneValue = window.layout()
                var written = window
                var history: [LayoutEdit] = []
                var previous: LayoutEdit?
                for step in 0..<3 {
                    guard let edit = randomLayoutEdit(written, &rng, after: previous) else { break }
                    var next = written.layout()
                    guard edit.apply(to: &next) else { break }
                    edit.apply(to: &oneValue)
                    let beforeWindow = written
                    written.apply(next)
                    history.append(edit)
                    if step >= 1 {
                        if step == 1 { pairs += 1 } else { triples += 1 }
                        if let previous {
                            if !previous.isReorder && edit.isReorder { moveThenReorder += 1 }
                            if previous.isReorder && !edit.isReorder { reorderThenMove += 1 }
                            if previous.isReorder && edit.isReorder {
                                reorderThenReorder += 1
                                if case .reorder(let g, _) = edit, case .reorder(let g0, _) = previous {
                                    let tree = beforeWindow.tree
                                    let pinned = Set(beforeWindow.groups.filter(\.isPinned).map(\.id))
                                    if tree.parent(of: g0) == tree.parent(of: g) {
                                        if pinned.contains(g) && pinned.contains(g0) { sameLevelPinnedReorderPairs += 1 }
                                        let noRun = WindowFacts(beforeWindow).noRunGroups
                                        let level = tree.parent(of: g)
                                        if beforeWindow.groups.contains(where: { noRun.contains($0.id) && tree.parent(of: $0.id) == level }) {
                                            sameLevelReorderPairsAtNoWorkspaceLevel += 1
                                        }
                                    }
                                    let noRun = WindowFacts(beforeWindow).noRunGroups
                                    let level = beforeWindow.tree.parent(of: g)
                                    let beside = beforeWindow.groups.contains {
                                        $0.id != g && noRun.contains($0.id) && beforeWindow.tree.parent(of: $0.id) == level
                                    }
                                    if beside { reorderThenReorderAtNoWorkspaceLevel += 1 }
                                }
                            }
                        }
                        if oneValue.output() != next.output() {
                            failures += 1
                            var oneWindow = window
                            oneWindow.apply(oneValue)
                            Issue.record("Seed \(seed): \(history.map { $0.text(lab) }) | start \(stored(window, lab)) | one value \(stored(oneWindow, lab)) | with writes between \(stored(written, lab))")
                        }
                    }
                    previous = edit
                    if failures > 0 { break }
                }
                if failures > 0 { break }
                window = written
            }
            if failures > 0 { break }
        }
        print("randomEditSequences: \(seeds) seeds, \(pairs) pairs and \(triples) triples compared; pairs by kind: \(moveThenReorder) move then reorder, \(reorderThenMove) reorder then move, \(reorderThenReorder) reorder then reorder, of which \(reorderThenReorderAtNoWorkspaceLevel) at a level holding a group with no workspace; reorder pairs at one level that holds a group with no workspace: \(sameLevelReorderPairsAtNoWorkspaceLevel); same-level reorder pairs of two pinned groups: \(sameLevelPinnedReorderPairs)")
        #expect(failures == 0)
        #expect(pairs > 0)
        #expect(triples > 0)
        #expect(moveThenReorder > 0)
        #expect(reorderThenMove > 0)
        #expect(reorderThenReorder >= 50, "reorder then reorder: \(reorderThenReorder)")
        #expect(sameLevelReorderPairsAtNoWorkspaceLevel >= 30, "same-level reorder pairs at a level holding a group with no workspace: \(sameLevelReorderPairsAtNoWorkspaceLevel)")
        #expect(sameLevelPinnedReorderPairs >= 20, "same-level reorder pairs of two pinned groups: \(sameLevelPinnedReorderPairs)")
        #expect(reorderThenReorderAtNoWorkspaceLevel >= 30, "reorder then reorder at a level with a group holding no workspace: \(reorderThenReorderAtNoWorkspaceLevel)")
    }

    // MARK: - The workspace behind a name

    @Test
    func theStoredOwnWorkspaceStandsBehindTheNameEvenWhenItIsNotTheFirstMember() {
        var lab = Labels()
        var window = NestWindow(
            tabs: [lab.ws("x", in: "G"), lab.ws("a", in: "G"), lab.ws("y", in: "G")],
            groups: [lab.group("G", own: "a")]
        )
        window.bareRepair()
        #expect(window.groups.first?.anchorWorkspaceId == lab.id("a"))
        #expect(window.tabs.map(\.id) == [lab.id("a"), lab.id("x"), lab.id("y")])
        #expect(compact(window, lab) == "G[a: x, y]")
    }

    // MARK: - Reading from live tabs

    @MainActor
    @Test
    func aLayoutFromLiveTabsReadsLikeOneFromItems() {
        var lab = Labels()
        let window = NestWindow(
            tabs: [lab.ws("w1", pinned: true), lab.ws("p", in: "P"), lab.ws("c", in: "C", pinned: true), lab.ws("w2")],
            groups: [lab.group("P", own: "p"), lab.group("C", parent: "P", pinned: true, own: "c"), lab.group("E", pinned: true)]
        )
        let tabs = window.tabs.map { NestingStubTab(id: $0.id, groupId: $0.groupId, isPinned: $0.isPinned) }
        let fromTabs = WorkspaceGroupLayout(
            tree: window.tree,
            groups: window.groups.map { $0.toWorkspaceGroup() },
            tabs: tabs
        )
        let fromItems = window.layout()
        #expect(compact(window, lab, layout: fromTabs) == "w1* | E*[-] | P[p: C*[c]] | w2")
        #expect(compact(window, lab, layout: fromTabs) == compact(window, lab, layout: fromItems))
        #expect(fromTabs.output() == fromItems.output())
    }

    // MARK: - Flat operations comparison with upstream

    @Test
    func flatOperationsAgreeWithUpstream() throws {
        let restingCount = Int(ProcessInfo.processInfo.environment["CM106_OPS"] ?? "") ?? 500
        let fixtures = try upstreamFixtureStates()

        var readerDiffers = 0
        var rngR = SplitMix64(seed: 2001)
        for _ in 0..<restingCount {
            let window = upstreamNormalized(randomFlatWindow(&rngR))
            let model = upstreamModel(window)
            let upstreamRows = model.sidebarTopLevelWorkspaceIdsIncludingEmptyGroups()
            let layout = window.layout()
            let mine = layout.rows(of: nil).map { rowIdentity($0, layout) }
            if upstreamRows != mine { readerDiffers += 1 }
        }
        #expect(readerDiffers == 0)

        var bareRepairDiffers = 0
        var rngB = SplitMix64(seed: 107)
        for _ in 0..<restingCount {
            let input = upstreamNormalized(randomFlatWindow(&rngB))
            let diff = flatDifference(input)
            if diff.any { bareRepairDiffers += 1 }
        }
        #expect(bareRepairDiffers == 0)

        var totalDifferences = 0
        var comparisons = [Int](repeating: 0, count: flatOpKinds.count)
        var upstreamChanges = [Int](repeating: 0, count: flatOpKinds.count)
        for (setName, count) in [("resting", restingCount), ("fixtures", fixtures.count * 8)] {
            for kind in flatOpKinds.indices {
                var rngW = SplitMix64(seed: 3000)
                var rngO = SplitMix64(seed: UInt64(4000 + kind))
                for index in 0..<count {
                    let window: NestWindow
                    switch setName {
                    case "resting":
                        window = upstreamNormalized(randomFlatWindow(&rngW))
                        if !isUpstreamResting(window) { continue }
                    default:
                        window = fixtures[index % fixtures.count].1
                    }
                    guard let op = pickFlatOp(kind, window, &rngO) else { continue }
                    let difference = opDifference(op, window)
                    comparisons[kind] += 1
                    if difference.upstreamChanged { upstreamChanges[kind] += 1 }
                    if difference.any {
                        totalDifferences += 1
                        Issue.record("Difference on [\(setName)] \(flatOpKinds[kind]) at index \(index)")
                        break
                    }
                }
            }
        }
        #expect(totalDifferences == 0)
        for kind in flatOpKinds.indices {
            print("flatOperationsAgreeWithUpstream: \(comparisons[kind]) comparisons, \(upstreamChanges[kind]) in which upstream changed the window, for \(flatOpKinds[kind])")
            #expect(comparisons[kind] > 0, "no comparison was made for \(flatOpKinds[kind])")
            #expect(upstreamChanges[kind] > 0, "upstream never changed the window for \(flatOpKinds[kind])")
        }
    }
}
