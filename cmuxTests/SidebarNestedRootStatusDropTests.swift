import AppKit
import CmuxFoundation
import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// `cm-110.3`: drags and drops around a nested group drawn under its status. Real per-window model, the production target
// builders and the guarded status-aware commit (`SidebarNestedStatusDropFixture`). Decisions: the 2026-10-24 Grill Me Q8 and Q9,
// rulings (16) as narrowed 2026-10-25 ((16a) to (16c)), (20) and (24).
@MainActor
@Suite("A nested group under its status, drags and drops", .serialized)
struct SidebarNestedRootStatusDropTests {
    private typealias F = SidebarNestedStatusDropFixture

    /// `pinA pinB u l1 color c1 [Mid: midAnchor [P: pAnchor pa [Q: qAnchor qa]]] c2 c3 n1 n2`, with Q (and nothing else of the three)
    /// holding Parked. Without `deep`, P sits at the top level and Q is one level down. Parked's rows by tab order are
    /// `c1`, Q's block, `c2`, `c3`; Next holds `n1`, `n2`.
    private func scene(deep: Bool, qStatus: String? = "parked", looseBefore: Bool = true) throws -> F {
        let f = try F(scene: .f2b, role: .outside)
        f.projectsWorkspaceGroups = true
        f.named["l2"]?.hideTaskStatus()
        var order = ["pinA", "pinB", "u", "l1", "color"] + (looseBefore ? ["c1"] : [])
        if deep {
            let mid = try #require(f.manager.createWorkspaceGroup(name: "Mid", childWorkspaceIds: []))
            f.named["midAnchor"] = try #require(f.manager.workspaceGroupAnchor(for: mid))
            f.named["midAnchor"]?.hideTaskStatus()
            _ = f.manager.moveWorkspaceGroup(groupId: f.p, intoParent: mid)
            order.append("midAnchor")
        }
        order += ["pAnchor", "pa", "qAnchor", "qa"] + (looseBefore ? [] : ["c1"]) + ["c2", "c3", "n1", "n2", "l2"]
        f.manager.tabs = order.compactMap { f.named[$0] }
        if let qStatus {
            let q = try #require(f.manager.workspaceGroups.firstIndex { $0.id == f.q })
            f.manager.workspaceGroups[q].statusId = qStatus
            f.manager.workspaceGroups[q].customColor = qStatus == "parked" ? "#555555" : "#111111"
        }
        return f
    }

    private func group(_ f: F, _ id: UUID) -> WorkspaceGroup { f.manager.workspaceGroups.first { $0.id == id }! }

    private func target(_ f: F, native: Bool, id: UUID, edge: SidebarDropEdge = .top, right: Bool = false)
        throws -> (CGPoint, [SidebarWorkspaceReorderDropOverlay.Target]) {
        let targets = f.targets(native ? .native : .swiftUI)
        let measured = try #require(targets.first { $0.workspaceId == id }, "row \(id) is not measured")
        let frame = measured.statusContentFrame ?? measured.frame
        return (.init(x: right ? 180 : 60, y: edge == .top ? frame.minY : frame.maxY), targets)
    }

    private func statusValue(_ plan: SidebarWorkspaceReorderDropPlan) throws -> SidebarStatusGroupWorkspaceDropPlan {
        guard case .statusGroupDrop(let value, _) = plan.action else {
            Issue.record("Expected a status landing, got \(plan.action)")
            throw DropTestError.wrongAction
        }
        return value
    }
    private enum DropTestError: Error { case wrongAction }

    private func rows(_ f: F, under status: String) -> [SidebarWorkspaceRenderItemID] {
        let items = f.rendered().map(\.id)
        guard let start = items.firstIndex(of: .statusGroup(status)) else { return [] }
        let others: [SidebarWorkspaceRenderItemID] = ["parked", "next", "done"].filter { $0 != status }.map { .statusGroup($0) }
        let tail = items[(start + 1)...]
        let end = tail.firstIndex { others.contains($0) } ?? items.endIndex
        return Array(items[(start + 1)..<end])
    }
    private func parkedRows(_ f: F) -> [SidebarWorkspaceRenderItemID] { rows(f, under: "parked") }
    /// The rows by the fixture's names (`#Q` is Q's header), for a failure message that can be read.
    private func label(_ f: F, _ items: [SidebarWorkspaceRenderItemID], extra: [SidebarWorkspaceRenderItemID: String] = [:]) -> Comment {
        var names = extra
        for (key, workspace) in f.named { names[.workspace(workspace.id)] = key }
        for (key, id) in [("#P", f.p), ("#Q", f.q)] { names[.group(id)] = key }
        return Comment(rawValue: items.map { names[$0] ?? "?" }.joined(separator: " "))
    }

    // MARK: a nested header dropped on a status group

    @Test(arguments: [false, true])
    func aNestedHeaderDroppedOnAStatusTakesItAndIsDrawnUnderItWithoutMovingAnyTab(_ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try scene(deep: false, qStatus: nil); defer { f.close() }
            let tabs = f.manager.tabs.map(\.id), parent = group(f, f.q).parentGroupId
            #expect(parkedRows(f).contains(.group(f.q)) == false)
            await f.applyRows(); try f.begin(row: .group(f.q))
            let (point, targets) = try target(f, native: native, id: f.w("c3").id)
            let plan = try #require(try f.route(point: point, targets: targets))
            let value = try statusValue(plan)
            #expect(value.statusId == "parked" && value.setsStatus)
            #expect(plan.indicator == .init(tabId: f.w("c3").id, edge: .top), "the line marks the status it sets, at the row it is held over")
            try #require(f.commit(plan))
            #expect(f.manager.tabs.map(\.id) == tabs, "the tab order never changes")
            #expect(group(f, f.q).parentGroupId == parent, "and neither does its parent")
            #expect(group(f, f.q).statusId == "parked" && group(f, f.q).customColor == "#555555")
            let rows = parkedRows(f)
            let qAt = try #require(rows.firstIndex(of: .group(f.q)))
            #expect(rows[qAt + 1] == .workspace(f.w("qa").id))
            #expect(rows.first == .workspace(f.w("c1").id) && rows[qAt - 1] == .workspace(f.w("c1").id), "at its tab-order place: after c1, before c2")
            #expect(rows.contains(.workspace(f.w("c2").id)))
        }
    }

    @Test(arguments: [false, true])
    func aNestedRootDraggedAmongItsOwnStatusRowsSpringsBackWithNoLine(_ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try scene(deep: false); defer { f.close() }
            let tabs = f.manager.tabs.map(\.id), groups = f.manager.workspaceGroups
            await f.applyRows(); try f.begin(row: .group(f.q))
            let header = SidebarStatusHeaderIdentity.uuid(forStatusId: "parked")
            for id in [f.w("c3").id, f.w("c1").id, header] {
                let (point, targets) = try target(f, native: native, id: id)
                #expect(try f.route(point: point, targets: targets) == nil, "dropped on \(id): refused, so no line and it springs back (16a)")
            }
            #expect(f.manager.tabs.map(\.id) == tabs && f.manager.workspaceGroups == groups)
        }
    }

    @Test(arguments: [false, true])
    func aNestedRootDroppedOnAnotherStatusTakesItAndShowsAtItsTabOrderPlaceThere(_ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try scene(deep: false); defer { f.close() }
            let tabs = f.manager.tabs.map(\.id)
            await f.applyRows(); try f.begin(row: .group(f.q))
            let (point, targets) = try target(f, native: native, id: f.w("n2").id)
            let plan = try #require(try f.route(point: point, targets: targets))
            let value = try statusValue(plan)
            #expect(value.statusId == "next" && value.setsStatus)
            try #require(f.commit(plan))
            #expect(f.manager.tabs.map(\.id) == tabs)
            #expect(group(f, f.q).statusId == "next" && group(f, f.q).customColor == "#111111")
            #expect(!parkedRows(f).contains(.group(f.q)))
            #expect(rows(f, under: "next").first == .group(f.q), "n1 and n2 sit after Q in the tab order, so Q is first under Next")
        }
    }

    @Test(arguments: [false, true])
    func aNestedRootDroppedOutsideTheStatusGroupsIsRefused(_ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try scene(deep: false); defer { f.close() }
            let tabs = f.manager.tabs.map(\.id)
            await f.applyRows(); try f.begin(row: .group(f.q))
            let (point, targets) = try target(f, native: native, id: f.w("l1").id)
            #expect(try f.route(point: point, targets: targets) == nil, "(16c)")
            let bottom = try #require(targets.map { $0.frame.maxY }.max())
            #expect(try f.route(point: .init(x: 180, y: bottom + 20), targets: targets) == nil)
            #expect(f.manager.tabs.map(\.id) == tabs)
        }
    }

    // MARK: loose workspaces around a nested root under its status (ruling (24))

    private func dropLooseU(_ f: F, onRow id: UUID, edge: SidebarDropEdge, right: Bool, native: Bool) async throws
        -> (SidebarWorkspaceReorderDropPlan?, [SidebarWorkspaceReorderDropOverlay.Target]) {
        await f.applyRows(); try f.begin(row: .workspace(f.w("u").id))
        let (point, targets) = try target(f, native: native, id: id, edge: edge, right: right)
        return (try f.route(point: point, targets: targets), targets)
    }

    private func ids(_ f: F, _ keys: [String]) -> [UUID] { keys.map { f.w($0).id } }

    @Test(arguments: [false, true], [false, true])
    func aLooseWorkspaceDroppedJustAboveTheRootLandsJustBeforeItsTopLevelAncestorsWholeRun(_ deep: Bool, _ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try scene(deep: deep); defer { f.close() }
            let (plan, _) = try await dropLooseU(f, onRow: f.w("qAnchor").id, edge: .top, right: false, native: native)
            let value = try statusValue(try #require(plan))
            #expect(value.statusId == "parked" && value.setsStatus)
            try #require(f.commit(try #require(plan)))
            let run = deep ? ["midAnchor", "pAnchor", "pa", "qAnchor", "qa"] : ["pAnchor", "pa", "qAnchor", "qa"]
            #expect(f.manager.tabs.map(\.id) == ids(f, ["pinA", "pinB", "l1", "color", "c1", "u"] + run + ["c2", "c3", "n1", "n2", "l2"]),
                "u sits just before the whole run of the top-level ancestor, never inside it")
            #expect(f.w("u").todoState.ownStatus?.id == "parked")
            let rows = parkedRows(f)
            #expect(rows.first == .workspace(f.w("c1").id) && rows.dropFirst().first == .workspace(f.w("u").id), "and it shows above the root under Parked")
            #expect(rows.firstIndex(of: .group(f.q))! > rows.firstIndex(of: .workspace(f.w("u").id))!)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func aLooseWorkspaceDroppedJustBelowTheRootLandsJustAfterItsTopLevelAncestorsWholeRun(_ deep: Bool, _ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try scene(deep: deep); defer { f.close() }
            let (plan, _) = try await dropLooseU(f, onRow: f.w("qa").id, edge: .bottom, right: false, native: native)
            let value = try statusValue(try #require(plan))
            #expect(value.statusId == "parked")
            try #require(f.commit(try #require(plan)))
            let run = deep ? ["midAnchor", "pAnchor", "pa", "qAnchor", "qa"] : ["pAnchor", "pa", "qAnchor", "qa"]
            #expect(f.manager.tabs.map(\.id) == ids(f, ["pinA", "pinB", "l1", "color", "c1"] + run + ["u", "c2", "c3", "n1", "n2", "l2"]),
                "u sits just after the whole run of the top-level ancestor")
            let rows = parkedRows(f)
            let q = try #require(rows.firstIndex(of: .group(f.q)))
            #expect(rows[q...].contains(.workspace(f.w("u").id)) && rows.firstIndex(of: .workspace(f.w("u").id))! < rows.firstIndex(of: .workspace(f.w("c2").id))!)
        }
    }

    @Test(arguments: [false, true])
    func aLooseWorkspaceDroppedFirstWhereTheRootSortsFirstLandsBeforeItsTopLevelAncestorsRun(_ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try scene(deep: true, looseBefore: false); defer { f.close() }
            try #require(parkedRows(f).first == .group(f.q), "Q sorts first under Parked")
            let header = SidebarStatusHeaderIdentity.uuid(forStatusId: "parked")
            let (plan, _) = try await dropLooseU(f, onRow: header, edge: .top, right: false, native: native)
            let value = try statusValue(try #require(plan))
            #expect(value.placement == .first)
            try #require(f.commit(try #require(plan)))
            #expect(f.manager.tabs.map(\.id) == ids(f, ["pinA", "pinB", "l1", "color", "u", "midAnchor", "pAnchor", "pa", "qAnchor", "qa", "c1", "c2", "c3", "n1", "n2", "l2"]))
            #expect(parkedRows(f).first == .workspace(f.w("u").id))
        }
    }

    @Test(arguments: [false, true])
    func aLooseWorkspaceDroppedBetweenTheRootsMemberRowsJoinsIt(_ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try scene(deep: true); defer { f.close() }
            let (plan, _) = try await dropLooseU(f, onRow: f.w("qa").id, edge: .top, right: true, native: native)
            let action = try #require(plan).action
            guard case .reorder(_, false, let joined?) = action else { Issue.record("Expected a join, got \(action)"); return }
            #expect(joined == f.q)
            try #require(f.commit(try #require(plan)))
            #expect(f.w("u").groupId == f.q)
            #expect(parkedRows(f).contains(.workspace(f.w("u").id)), "a member goes where its group goes")
        }
    }

    // MARK: a top-level header cannot pass a nested root

    @Test(arguments: [false, true])
    func aTopLevelHeaderDroppedPastTheRootStaysOnItsSideOfTheRoot(_ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try scene(deep: true); defer { f.close() }
            f.named["l2"]?.hideTaskStatus()
            let top = try #require(f.manager.createWorkspaceGroup(name: "Top", childWorkspaceIds: [f.w("l2").id]))
            f.named["topAnchor"] = try #require(f.manager.workspaceGroupAnchor(for: top))
            f.named["topAnchor"]?.hideTaskStatus()
            let index = try #require(f.manager.workspaceGroups.firstIndex { $0.id == top })
            f.manager.workspaceGroups[index].statusId = "parked"; f.manager.workspaceGroups[index].customColor = "#555555"
            f.manager.tabs = ["pinA", "pinB", "u", "l1", "color", "c1", "midAnchor", "pAnchor", "pa", "qAnchor", "qa", "topAnchor", "l2", "c2", "c3", "n1", "n2"].compactMap { f.named[$0] }
            await f.applyRows(); try f.begin(row: .group(top))
            let header = SidebarStatusHeaderIdentity.uuid(forStatusId: "parked")
            let (point, targets) = try target(f, native: native, id: header)
            let plan = try #require(try f.route(point: point, targets: targets))
            _ = try statusValue(plan)
            let before = f.manager.tabs.map(\.id)
            try #require(f.commit(plan))
            let after = f.manager.tabs.map(\.id)
            let qRun = ids(f, ["midAnchor", "pAnchor", "pa", "qAnchor", "qa"])
            #expect(after.filter(qRun.contains) == qRun && after.firstIndex(of: f.w("topAnchor").id)! > after.firstIndex(of: f.w("qa").id)!,
                "the top-level group stays after the root's whole run: it cannot pass it")
            #expect(after == before, "and no loose row crosses it either: the nearest place it can go is where it already is")
            #expect(group(f, top).statusId == "parked")
        }
    }

    // MARK: a group inside a root, and the root's own block

    private func withInnerGroup(_ f: F) throws -> UUID {
        let inner = try #require(f.manager.createWorkspaceGroup(name: "Inner", childWorkspaceIds: [f.w("l2").id]))
        _ = f.manager.moveWorkspaceGroup(groupId: inner, intoParent: f.q)
        f.named["innerAnchor"] = try #require(f.manager.workspaceGroupAnchor(for: inner))
        f.named["innerAnchor"]?.hideTaskStatus()
        f.manager.tabs = ["pinA", "pinB", "u", "l1", "color", "c1", "midAnchor", "pAnchor", "pa", "qAnchor", "qa", "innerAnchor", "l2", "c2", "c3", "n1", "n2"].compactMap { f.named[$0] }
        return inner
    }

    @Test(arguments: [false, true])
    func aGroupInsideTheRootDroppedOnAStatusTakesItAndStaysInsideTheRootUnderTheRootsStatus(_ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try scene(deep: true); defer { f.close() }
            let inner = try withInnerGroup(f)
            let tabs = f.manager.tabs.map(\.id)
            await f.applyRows(); try f.begin(row: .group(inner))
            let (point, targets) = try target(f, native: native, id: f.w("n2").id)
            let plan = try #require(try f.route(point: point, targets: targets))
            let value = try statusValue(plan)
            #expect(value.statusId == "next" && value.setsStatus)
            try #require(f.commit(plan))
            #expect(f.manager.tabs.map(\.id) == tabs)
            #expect(group(f, inner).parentGroupId == f.q && group(f, inner).statusId == "next", "it takes the status and stays inside Q")
            #expect(parkedRows(f).contains(.group(inner)), "and is still drawn under Q's status")
            #expect(!rows(f, under: "next").contains(.group(inner)))
        }
    }

    @Test(arguments: [false, true])
    func aGroupInsideTheRootDroppedOnTheRootsOwnBlockTakesItsStatusWithTheLineOnTheBlocksTopEdge(_ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try scene(deep: true); defer { f.close() }
            let inner = try withInnerGroup(f)
            await f.applyRows(); try f.begin(row: .group(inner))
            let (point, targets) = try target(f, native: native, id: f.w("qa").id, edge: .bottom, right: true)
            let plan = try #require(try f.route(point: point, targets: targets))
            let value = try statusValue(plan)
            #expect(value.statusId == "parked" && value.setsStatus)
            #expect(plan.indicator == .init(tabId: f.w("qAnchor").id, edge: .top), "ruling (12) own-block case: the line is on the top edge of the block it sits in")
            try #require(f.commit(plan))
            #expect(group(f, inner).statusId == "parked" && group(f, inner).parentGroupId == f.q)
        }
    }

    @Test(arguments: [false, true])
    func aNestedHeaderInsideAPinnedGroupDroppedOnAStatusTakesItAndStaysInPinned(_ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try scene(deep: false, qStatus: nil); defer { f.close() }
            f.manager.setWorkspaceGroupPinned(groupId: f.p, isPinned: true)
            let tabs = f.manager.tabs.map(\.id)
            await f.applyRows(); try f.begin(row: .group(f.q))
            let (point, targets) = try target(f, native: native, id: f.w("c3").id)
            let plan = try #require(try f.route(point: point, targets: targets))
            _ = try statusValue(plan)
            try #require(f.commit(plan))
            #expect(f.manager.tabs.map(\.id) == tabs)
            #expect(group(f, f.q).statusId == "parked" && group(f, f.q).parentGroupId == f.p)
            #expect(!parkedRows(f).contains(.group(f.q)), "it stays among the pinned rows")
            let items = f.rendered().map(\.id)
            let pinned = Array(items.prefix { $0 != .workspacesArea() })
            #expect(pinned.contains(.group(f.q)))
        }
    }

    // MARK: the drag line while a nested header is held over a status group

    @Test(arguments: [false, true])
    func theLineMarksTheStatusOnItsHeaderAndNextToAnotherGroupsWholeBlockOnItsMemberRows(_ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let f = try scene(deep: true); defer { f.close() }
            f.named["l2"]?.hideTaskStatus()
            let other = try #require(f.manager.createWorkspaceGroup(name: "Other", childWorkspaceIds: [f.w("l2").id]))
            _ = f.manager.moveWorkspaceGroup(groupId: other, intoParent: try #require(f.manager.workspaceGroups.first { $0.id == f.p }?.parentGroupId))
            f.named["otherAnchor"] = try #require(f.manager.workspaceGroupAnchor(for: other))
            f.named["otherAnchor"]?.hideTaskStatus()
            f.manager.tabs = ["pinA", "pinB", "u", "l1", "color", "c1", "midAnchor", "pAnchor", "pa", "qAnchor", "qa", "otherAnchor", "l2", "c2", "c3", "n1", "n2"].compactMap { f.named[$0] }
            await f.applyRows(); try f.begin(row: .group(other))
            // On the status header: the status header's bottom edge.
            let header = SidebarStatusHeaderIdentity.uuid(forStatusId: "parked")
            let (headerPoint, targets) = try target(f, native: native, id: header)
            let onHeader = try #require(try f.route(point: headerPoint, targets: targets))
            #expect(onHeader.indicator == .init(tabId: header, edge: .bottom))
            // On a loose member row: that row's edge.
            let (loosePoint, looseTargets) = try target(f, native: native, id: f.w("c3").id)
            #expect(try #require(try f.route(point: loosePoint, targets: looseTargets)).indicator == .init(tabId: f.w("c3").id, edge: .top))
            // On the root's member rows: next to the root's whole block, never between its rows.
            let (memberPoint, memberTargets) = try target(f, native: native, id: f.w("qa").id, edge: .bottom, right: true)
            let onMember = try #require(try f.route(point: memberPoint, targets: memberTargets))
            let edge = try #require(onMember.indicator)
            #expect([SidebarDropIndicator(tabId: f.w("qAnchor").id, edge: .top), SidebarDropIndicator(tabId: f.w("c2").id, edge: .top)].contains(edge),
                "the line is on a block edge: \(edge)")
        }
    }

    // MARK: two roots of one parent (ruling (28))

    /// `... qAnchor qa [Q2: q2Anchor l2] ...` with Q and Q2 both nested in P, both Parked, and adjacent under Parked.
    private func sceneWithTwoRoots() throws -> (F, UUID) {
        let f = try scene(deep: false)
        f.named["l2"]?.hideTaskStatus()
        let second = try #require(f.manager.createWorkspaceGroup(name: "Q2", childWorkspaceIds: [f.w("l2").id]))
        _ = f.manager.moveWorkspaceGroup(groupId: second, intoParent: f.p)
        f.named["q2Anchor"] = try #require(f.manager.workspaceGroupAnchor(for: second))
        f.named["q2Anchor"]?.hideTaskStatus()
        let index = try #require(f.manager.workspaceGroups.firstIndex { $0.id == second })
        f.manager.workspaceGroups[index].statusId = "parked"; f.manager.workspaceGroups[index].customColor = "#555555"
        f.manager.tabs = ["pinA", "pinB", "u", "l1", "color", "c1", "pAnchor", "pa", "qAnchor", "qa", "q2Anchor", "l2", "c2", "c3", "n1", "n2"].compactMap { f.named[$0] }
        try #require(parkedRows(f).prefix(5) == [.workspace(f.w("c1").id), .group(f.q), .workspace(f.w("qa").id), .group(second), .workspace(f.w("l2").id)],
            label(f, parkedRows(f), extra: [.group(second): "#Q2"]))
        return (f, second)
    }

    private func gapPoint(_ f: F, _ targets: [SidebarWorkspaceReorderDropOverlay.Target], fraction: CGFloat) throws -> CGPoint {
        let above = try #require(targets.first { $0.workspaceId == f.w("qa").id })
        let below = try #require(targets.first { $0.workspaceId == f.w("q2Anchor").id })
        let upper = above.statusContentFrame ?? above.frame, lower = below.statusContentFrame ?? below.frame
        try #require(lower.minY > upper.maxY, "a gap separates the two rows")
        return CGPoint(x: 60, y: upper.maxY + (lower.minY - upper.maxY) * fraction)
    }

    /// Ruling (28): by ruling (24) anything dropped in the gap lands after both roots, outside their top-level ancestor's whole
    /// run, so no line between them could show where it lands: the lower half of the gap is refused, with no line.
    @Test(arguments: [false, true])
    func theLowerHalfOfTheGapBetweenTwoRootsOfOneParentIsRefusedWithNoLineForAWorkspaceAndATab(_ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let (f, _) = try sceneWithTwoRoots(); defer { f.close() }
            let tabs = f.manager.tabs.map(\.id), held = f.held
            await f.applyRows(); try f.begin(row: .workspace(f.w("u").id))
            let targets = f.targets(native ? .native : .swiftUI)
            let point = try gapPoint(f, targets, fraction: 0.75)
            #expect(try f.route(point: point, targets: targets) == nil, "no plan, so no line and no drop")
            let landing = VerticalTabsSidebar.tabStatusLanding(point: point, targets: targets, snapshot: f.snapshot(), headersOnly: false,
                controlsEnabled: true, hasUserStatusList: true)
            #expect(landing == nil, "a dragged tab is refused there too")
            #expect(f.manager.tabs.map(\.id) == tabs && f.held == held)
        }
    }

    /// What stays of the gap: the right-hand half of its upper part is the bottom edge of the first root's last row, where a
    /// workspace joins that root, as it does under a top-level group. The left-hand half would be a status landing: refused.
    @Test(arguments: [false, true])
    func theUpperPartOfTheGapBetweenTwoRootsOfOneParentJoinsTheFirstRootFromTheRightAndIsRefusedFromTheLeft(_ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let (f, _) = try sceneWithTwoRoots(); defer { f.close() }
            await f.applyRows(); try f.begin(row: .workspace(f.w("u").id))
            let targets = f.targets(native ? .native : .swiftUI)
            var point = try gapPoint(f, targets, fraction: 0.25)
            #expect(try f.route(point: point, targets: targets) == nil, "left half: no status landing, no line")
            point.x = 180
            let plan = try #require(try f.route(point: point, targets: targets))
            guard case .reorder(_, false, let joined?) = plan.action else { Issue.record("Expected a join, got \(plan.action)"); return }
            #expect(joined == f.q)
        }
    }
}
