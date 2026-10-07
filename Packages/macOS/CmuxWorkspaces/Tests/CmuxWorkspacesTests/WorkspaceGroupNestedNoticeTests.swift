import Foundation
import Testing
@testable import CmuxWorkspaces

// Nested workspace groups (#cm-106): an operation that changes the order of `tabs` in a window with a nested group tells the host
// every workspace that changed place with it, at every level. A parent with no workspace of its own has no direct
// workspace to name, so a notice built from direct workspaces is empty and nothing downstream hears of the change.
@MainActor
struct WorkspaceGroupNestedNoticeTests {
    /// `u1 | P[(p): Q[q: q2, (S[s: s2])], X[x]] (| R[r]) | u2`. `p` exists when `parentOwn`; `S` when `threeLevels`.
    private func tower(
        _ lab: inout Labels,
        parentOwn: Bool,
        threeLevels: Bool,
        pinQ: Bool = false,
        withR: Bool = false
    ) -> NestedWorld {
        var tabs = [lab.ws("u1")]
        if parentOwn { tabs.append(lab.ws("p", in: "P")) }
        tabs += [lab.ws("q", in: "Q"), lab.ws("q2", in: "Q")]
        if threeLevels { tabs += [lab.ws("s", in: "S"), lab.ws("s2", in: "S")] }
        tabs.append(lab.ws("x", in: "X"))
        if withR { tabs.append(lab.ws("r", in: "R")) }
        tabs.append(lab.ws("u2"))
        var groups = [
            lab.group("P", own: parentOwn ? "p" : nil),
            lab.group("Q", parent: "P", pinned: pinQ, own: "q"),
            lab.group("X", parent: "P", own: "x")
        ]
        if threeLevels { groups.insert(lab.group("S", parent: "Q", own: "s"), at: 2) }
        if withR { groups.append(lab.group("R", own: "r")) }
        var window = NestWindow(tabs: tabs, groups: groups)
        window.bareRepair()
        return NestedWorld(window)
    }

    private typealias Case = (name: String, parentOwn: Bool, threeLevels: Bool)

    private let cases: [Case] = [
        ("two levels, parent with no workspace of its own", false, false),
        ("two levels, parent with a workspace of its own", true, false),
        ("three levels, parent with no workspace of its own", false, true),
        ("three levels, parent with a workspace of its own", true, true)
    ]

    /// The workspaces inside `P`, at every level.
    private func insideP(_ c: Case) -> [String] {
        (c.parentOwn ? ["p"] : []) + ["q", "q2"] + (c.threeLevels ? ["s", "s2"] : []) + ["x"]
    }

    private func expectOneNotice(
        _ w: NestedWorld,
        _ lab: inout Labels,
        orderBefore: [UUID],
        noticesBefore: Int,
        names expected: [String],
        _ what: String
    ) {
        #expect(w.model.tabs.map(\.id) != orderBefore, "\(what): the rows changed place")
        #expect(w.host.orderChanges.count == noticesBefore + 1, "\(what): one notice")
        #expect(
            Set((w.host.orderChanges.last ?? []).map { lab.name($0) }) == Set(expected),
            "\(what): names \((w.host.orderChanges.last ?? []).map { lab.name($0) })"
        )
        #expect(w.violations(lab).isEmpty, "\(what): rules hold")
    }

    @Test
    func pinningAParentNamesEveryWorkspaceInsideAtEveryLevel() {
        for c in cases {
            var lab = Labels()
            let w = tower(&lab, parentOwn: c.parentOwn, threeLevels: c.threeLevels)
            let order = w.model.tabs.map(\.id)
            let notices = w.host.orderChanges.count
            w.groups.setWorkspaceGroupPinned(groupId: lab.id("P"), isPinned: true)
            expectOneNotice(w, &lab, orderBefore: order, noticesBefore: notices, names: insideP(c), "pin, \(c.name)")
        }
    }

    @Test
    func ungroupingAParentNamesEveryWorkspaceThatWasInsideAtEveryLevel() {
        for c in cases {
            var lab = Labels()
            let w = tower(&lab, parentOwn: c.parentOwn, threeLevels: c.threeLevels, pinQ: true)
            let order = w.model.tabs.map(\.id)
            let notices = w.host.orderChanges.count
            _ = w.groups.ungroupWorkspaceGroup(groupId: lab.id("P"))
            expectOneNotice(w, &lab, orderBefore: order, noticesBefore: notices, names: insideP(c), "ungroup, \(c.name)")
        }
    }

    @Test
    func moveToTopAndTheNotificationMoveNameEveryWorkspaceInTheGroupsTheRowWentUpThrough() {
        for c in cases {
            let deepest = c.threeLevels ? "s2" : "q2"
            var lab = Labels()
            var w = tower(&lab, parentOwn: c.parentOwn, threeLevels: c.threeLevels)
            var order = w.model.tabs.map(\.id)
            var notices = w.host.orderChanges.count
            w.reorder.moveTabsToTop([lab.id(deepest)])
            expectOneNotice(w, &lab, orderBefore: order, noticesBefore: notices, names: insideP(c), "move to top, \(c.name)")

            lab = Labels()
            w = tower(&lab, parentOwn: c.parentOwn, threeLevels: c.threeLevels)
            order = w.model.tabs.map(\.id)
            notices = w.host.orderChanges.count
            w.reorder.moveTabToTopForNotification(lab.id(deepest))
            expectOneNotice(w, &lab, orderBefore: order, noticesBefore: notices, names: insideP(c), "notification, \(c.name)")
        }
    }

    @Test
    func aStepByAGroupsOwnWorkspaceNamesEveryWorkspaceInsideThatGroupAndNoOther() {
        for threeLevels in [false, true] {
            // The top-level parent steps below `u2`.
            var lab = Labels()
            var w = tower(&lab, parentOwn: true, threeLevels: threeLevels)
            var order = w.model.tabs.map(\.id)
            var notices = w.host.orderChanges.count
            var index = w.model.tabs.firstIndex { $0.id == lab.id("p") }!
            #expect(w.reorder.reorderWorkspace(tabId: lab.id("p"), toIndex: index + 1))
            let c: Case = ("step by p", true, threeLevels)
            expectOneNotice(w, &lab, orderBefore: order, noticesBefore: notices, names: insideP(c), "step, three levels \(threeLevels)")

            // The child group `Q` steps below `X`, inside `P`: `x` and `p` stay unnamed.
            lab = Labels()
            w = tower(&lab, parentOwn: true, threeLevels: threeLevels)
            order = w.model.tabs.map(\.id)
            notices = w.host.orderChanges.count
            index = w.model.tabs.firstIndex { $0.id == lab.id("q") }!
            #expect(w.reorder.reorderWorkspace(tabId: lab.id("q"), toIndex: index + 1))
            expectOneNotice(
                w, &lab, orderBefore: order, noticesBefore: notices,
                names: ["q", "q2"] + (threeLevels ? ["s", "s2"] : []),
                "step by q, three levels \(threeLevels)"
            )
        }
    }

    @Test
    func aDragOfATopLevelParentsHeaderNamesEveryWorkspaceInsideAtEveryLevel() {
        for threeLevels in [false, true] {
            var lab = Labels()
            let w = tower(&lab, parentOwn: true, threeLevels: threeLevels)
            let order = w.model.tabs.map(\.id)
            let notices = w.host.orderChanges.count
            #expect(w.reorder.reorderSidebarWorkspace(tabId: lab.id("p"), toIndex: 2, isDragOperation: true, usesTopLevelRows: true))
            let c: Case = ("drag p", true, threeLevels)
            expectOneNotice(w, &lab, orderBefore: order, noticesBefore: notices, names: insideP(c), "drag one header, three levels \(threeLevels)")
        }
    }

    @Test
    func aDragOfSeveralTopLevelHeadersNamesEveryWorkspaceInsideEachAtEveryLevel() {
        for threeLevels in [false, true] {
            var lab = Labels()
            let w = tower(&lab, parentOwn: true, threeLevels: threeLevels, withR: true)
            let order = w.model.tabs.map(\.id)
            let notices = w.host.orderChanges.count
            #expect(w.reorder.reorderSidebarWorkspaces(
                tabIds: [lab.id("p"), lab.id("r")], draggedTabId: lab.id("p"), toIndex: 3,
                isDragOperation: true, usesTopLevelRows: true
            ))
            let c: Case = ("drag p, r", true, threeLevels)
            expectOneNotice(
                w, &lab, orderBefore: order, noticesBefore: notices,
                names: insideP(c) + ["r"], "drag two headers, three levels \(threeLevels)"
            )
        }
    }

    @Test
    func pinningAGroupInAWindowWithNoNestedGroupNamesItsDirectWorkspacesAsBefore() {
        var lab = Labels()
        let tabs = [lab.ws("u1"), lab.ws("p", in: "P"), lab.ws("p2", in: "P"), lab.ws("u2")]
        let w = NestedWorld(NestWindow(tabs: tabs, groups: [lab.group("P", own: "p")]))
        #expect(!w.model.hasNestedWorkspaceGroup)
        let notices = w.host.orderChanges.count
        w.groups.setWorkspaceGroupPinned(groupId: lab.id("P"), isPinned: true)
        #expect(w.host.orderChanges.count == notices + 1)
        #expect(w.host.orderChanges.last == [lab.id("p"), lab.id("p2")])
    }

    @Test
    func changingTheAnchorOfAParentThatHoldsAChildGroupNamesEveryRowThatChangedPlace() {
        // `P[p: p2, p3, Q[q: q2, (S[s: s2])]]`: a parent with three workspaces of its own and a child group (and below it).
        for threeLevels in [false, true] {
            var lab = Labels()
            var tabs = [lab.ws("u1"), lab.ws("p", in: "P"), lab.ws("p2", in: "P"), lab.ws("p3", in: "P"), lab.ws("q", in: "Q"), lab.ws("q2", in: "Q")]
            var groups = [lab.group("P", own: "p"), lab.group("Q", parent: "P", own: "q")]
            if threeLevels {
                tabs += [lab.ws("s", in: "S"), lab.ws("s2", in: "S")]
                groups.append(lab.group("S", parent: "Q", own: "s"))
            }
            tabs.append(lab.ws("u2"))
            var window = NestWindow(tabs: tabs, groups: groups)
            window.bareRepair()
            let w = NestedWorld(window)
            let order = w.model.tabs.map(\.id)
            let notices = w.host.orderChanges.count
            w.groups.setWorkspaceGroupAnchor(groupId: lab.id("P"), workspaceId: lab.id("p3"))
            let after = w.model.tabs.map(\.id)
            let changed = Set(after.enumerated().compactMap { index, id in order[index] == id ? nil : lab.name(id) })
            let named = Set((w.host.orderChanges.last ?? []).map { lab.name($0) })
            print("ANCHOR three levels \(threeLevels): \(order.map { lab.name($0) }) -> \(after.map { lab.name($0) }); named \(named)")
            #expect(!changed.isEmpty, "three levels \(threeLevels): the rows changed place")
            #expect(w.host.orderChanges.count == notices + 1, "three levels \(threeLevels): one notice")
            #expect(changed.isSubset(of: named), "three levels \(threeLevels): names \(named), but \(changed) changed place")
            #expect(w.violations(lab).isEmpty)
        }
    }

    // MARK: - The moved workspaces first, and only the groups that moved after them

    private func name(_ ids: [UUID], _ lab: Labels) -> [String] { ids.map { lab.name($0) } }

    @Test
    func theWorkspaceMovedToTheTopOrByNotificationComesFirstInTheNotice() {
        for c in cases {
            let deepest = c.threeLevels ? "s2" : "q2"
            for byNotification in [false, true] {
                var lab = Labels()
                let w = tower(&lab, parentOwn: c.parentOwn, threeLevels: c.threeLevels)
                let notices = w.host.orderChanges.count
                if byNotification { w.reorder.moveTabToTopForNotification(lab.id(deepest)) } else { w.reorder.moveTabsToTop([lab.id(deepest)]) }
                #expect(w.host.orderChanges.count == notices + 1, "\(c.name), notification \(byNotification)")
                #expect(w.host.orderChanges.last?.first == lab.id(deepest), "\(c.name), notification \(byNotification): first is \(name(w.host.orderChanges.last ?? [], lab))")
            }
        }
    }

    @Test
    func aWorkspaceInNoGroupMovedToTheTopOrByNotificationInANestedWindowIsNamedAlone() {
        for byNotification in [false, true] {
            var lab = Labels()
            let w = tower(&lab, parentOwn: true, threeLevels: true)
            let order = w.model.tabs.map(\.id)
            let notices = w.host.orderChanges.count
            if byNotification { w.reorder.moveTabToTopForNotification(lab.id("u2")) } else { w.reorder.moveTabsToTop([lab.id("u2")]) }
            #expect(w.model.tabs.map(\.id) != order, "notification \(byNotification): the rows changed place")
            #expect(w.host.orderChanges.count == notices + 1, "notification \(byNotification): one notice")
            #expect(name(w.host.orderChanges.last ?? [], lab) == ["u2"], "notification \(byNotification): \(name(w.host.orderChanges.last ?? [], lab))")
        }
    }

    @Test
    func aWorkspaceInAGroupThatDoesNotMoveIsNamedAloneInANestedWindow() {
        // `G` is first at the top and holds no group; `P[p: Q[q]]` is nested elsewhere in the window.
        for byNotification in [false, true] {
            var lab = Labels()
            var window = NestWindow(
                tabs: [lab.ws("g", in: "G"), lab.ws("g2", in: "G"), lab.ws("g3", in: "G"), lab.ws("p", in: "P"), lab.ws("q", in: "Q")],
                groups: [lab.group("G", own: "g"), lab.group("P", own: "p"), lab.group("Q", parent: "P", own: "q")]
            )
            window.bareRepair()
            let w = NestedWorld(window)
            #expect(w.compact(lab) == "G[g: g2, g3] | P[p: Q[q]]")
            let order = w.model.tabs.map(\.id)
            let notices = w.host.orderChanges.count
            if byNotification { w.reorder.moveTabToTopForNotification(lab.id("g3")) } else { w.reorder.moveTabsToTop([lab.id("g3")]) }
            #expect(w.compact(lab) == "G[g: g3, g2] | P[p: Q[q]]", "notification \(byNotification)")
            #expect(w.model.tabs.map(\.id) != order)
            #expect(w.host.orderChanges.count == notices + 1)
            #expect(name(w.host.orderChanges.last ?? [], lab) == ["g3"], "notification \(byNotification): \(name(w.host.orderChanges.last ?? [], lab))")
        }
    }

    @Test
    func aGroupCarriedUpByTheMoveHasItsRowsNamedAfterTheMovedWorkspaceAndNothingThatStayedIsNamed() {
        // `P` is first and stays; inside it `Q` stands below `X` and goes up past it (and `S` goes first inside `Q`).
        // `p` and `x` are not named.
        for (threeLevels, deepest, expected) in [(false, "q2", ["q2", "q", "s"]), (true, "s2", ["s2", "q", "s", "q2"])] {
            for byNotification in [false, true] {
                var lab = Labels()
                var tabs = [lab.ws("p", in: "P"), lab.ws("x", in: "X"), lab.ws("q", in: "Q")]
                var groups = [lab.group("P", own: "p"), lab.group("X", parent: "P", own: "x"), lab.group("Q", parent: "P", own: "q")]
                tabs.append(lab.ws("q2", in: "Q"))
                if threeLevels {
                    tabs += [lab.ws("s", in: "S"), lab.ws("s2", in: "S")]
                    groups.append(lab.group("S", parent: "Q", own: "s"))
                }
                tabs.append(lab.ws("u2"))
                var window = NestWindow(tabs: tabs, groups: groups)
                window.bareRepair()
                let w = NestedWorld(window)
                let before = w.compact(lab)
                #expect(before.hasPrefix("P[p: X[x], Q[q: q2"), "fixture: \(before)")
                let notices = w.host.orderChanges.count
                if byNotification { w.reorder.moveTabToTopForNotification(lab.id(deepest)) } else { w.reorder.moveTabsToTop([lab.id(deepest)]) }
                #expect(w.compact(lab).hasPrefix("P[p: Q["), "three levels \(threeLevels), notification \(byNotification): Q went up: \(w.compact(lab))")
                #expect(w.host.orderChanges.count == notices + 1)
                let named = name(w.host.orderChanges.last ?? [], lab)
                // The moved workspace first; after it Q's rows in tabs order. The expectation for two levels lists `s` only
                // when the window has it.
                let want = expected.filter { $0 != "s" || threeLevels }
                #expect(named == want, "three levels \(threeLevels), notification \(byNotification): \(named), wanted \(want)")
            }
        }
    }

    @Test
    func theNotificationMoveStopsAtAPinnedGroupButNamesTheUnpinnedParentThatWentUp() {
        // `G0` goes up past `G4`; the walk stops at the pinned `G1`, so `w8` itself stays where it is.
        var lab = Labels()
        var window = NestWindow(
            tabs: [lab.ws("a", in: "G4"), lab.ws("w10", in: "G0"), lab.ws("w1", in: "G1"), lab.ws("w2", in: "G2"), lab.ws("w8", in: "G2"), lab.ws("w7", in: "G3")],
            groups: [
                lab.group("G4", own: "a"), lab.group("G0", own: "w10"), lab.group("G1", parent: "G0", pinned: true, own: "w1"),
                lab.group("G2", parent: "G1", pinned: true, own: "w2"), lab.group("G3", parent: "G1", own: "w7")
            ]
        )
        window.bareRepair()
        let w = NestedWorld(window)
        #expect(w.compact(lab).hasPrefix("G4[a] | G0[w10: G1*[w1: G2*[w2: w8], G3[w7]]]"), "fixture: \(w.compact(lab))")
        let notices = w.host.orderChanges.count
        w.reorder.moveTabToTopForNotification(lab.id("w8"))
        #expect(w.compact(lab).hasPrefix("G0["), "G0 passed G4: \(w.compact(lab))")
        #expect(w.host.orderChanges.count == notices + 1)
        let named = name(w.host.orderChanges.last ?? [], lab)
        #expect(named.first == "w8", "the bumped workspace first: \(named)")
        #expect(Set(named) == ["w8", "w10", "w1", "w2", "w7"], "then the rows of G0, which changed place: \(named)")
        #expect(!named.contains("a"), "G4's row only stood aside")
    }
}
