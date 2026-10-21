import Foundation
import Testing
import CmuxFoundation
import CmuxWorkspaces

@Suite("Group header status placement")
struct SidebarStatusGroupHeaderPlacementPlanTests {
    private typealias Plan = SidebarStatusGroupHeaderPlacementPlan
    private typealias Row = Plan.Row
    private static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }
    private func loose(_ n: Int, _ order: Int) -> Row {
        .init(referenceId: Self.id(n), workspaceIds: [Self.id(n)], isGroup: false, order: order)
    }
    private func group(_ n: Int, _ order: Int, folded: Bool = false) -> Row {
        .init(referenceId: Self.id(n), workspaceIds: [Self.id(n), Self.id(n + 1), Self.id(n + 2)],
              isGroup: true, order: order, lastVisibleRowId: Self.id(folded ? n : n + 2))
    }
    private func resolve(_ rows: [Row], source: Row, target: SidebarStatusGroupWorkspaceDropPlan.Placement,
                         folded: Bool = false, moves: Bool = true) throws -> Plan {
        try #require(Plan(rows: rows, source: source, placement: target,
                          statusHeaderId: Self.id(99), isFolded: folded, movesSource: moves))
    }
    private func moved(_ tabs: [UUID], source: Row, plan: Plan) -> [UUID] {
        var result = tabs
        for id in plan.workspaceIdsInMoveOrder {
            result.removeAll { $0 == id }
            let index: Int
            if plan.destinationSide == .beforeGroup { index = result.firstIndex(of: source.workspaceIds.first!)! }
            else { index = result.firstIndex(of: source.workspaceIds.last!)! + 1 }
            result.insert(id, at: index)
        }
        return result
    }

    @Test func workedExampleMovesOnlyTheInterveningStatusRows() throws {
        let source = group(10, 1), rows = [loose(20, 5), loose(21, 6), loose(22, 7)]
        let plan = try resolve(rows, source: source, target: .member(Self.id(22), insertBefore: true))
        #expect(plan.crossingWorkspaceIds == [Self.id(20), Self.id(21)])
        #expect(plan.destinationSide == .beforeGroup)
        #expect(plan.indicator == .init(tabId: Self.id(22), edge: .top))
        let before = [Self.id(1)] + source.workspaceIds + [Self.id(2), Self.id(20), Self.id(21), Self.id(22)]
        #expect(moved(before, source: source, plan: plan) ==
                [Self.id(1), Self.id(20), Self.id(21)] + source.workspaceIds + [Self.id(2), Self.id(22)])
    }

    @Test func reverseCrossingPreservesOrderAndSitsDirectlyAgainstTheRun() throws {
        let source = group(10, 4), rows = [loose(20, 1), loose(21, 2), loose(22, 8)]
        let plan = try resolve(rows, source: source, target: .first)
        #expect(plan.crossingWorkspaceIds == [Self.id(20), Self.id(21)])
        #expect(plan.workspaceIdsInMoveOrder == [Self.id(21), Self.id(20)])
        #expect(plan.destinationSide == .afterGroup)
        let before = [Self.id(1), Self.id(20), Self.id(21), Self.id(2)] + source.workspaceIds + [Self.id(3), Self.id(22)]
        #expect(moved(before, source: source, plan: plan) ==
                [Self.id(1), Self.id(2)] + source.workspaceIds + [Self.id(20), Self.id(21), Self.id(3), Self.id(22)])
    }

    @Test func projectedColorOnlyMembershipChangesTheCrossingAnswer() throws {
        let parked = WorkspaceStatusEntry(id: "parked", name: "Parked", extends: .todo, color: "#555555")
        let list = WorkspaceStatusList(entries: [parked], source: .file)
        let input: [WorkspaceStatusGroupProjectionItem] = [
            .init(workspaceId: Self.id(20), normalizedColorHex: "#555555", resolution: .detected(.todo)),
            .init(workspaceId: Self.id(21), resolution: .ownInEffect(parked))
        ]
        let projection = try #require(WorkspaceStatusGroupProjection.project(workspaces: input, list: list,
            resolvedHexByStatusId: ["parked": "#555555"]))
        let members = try #require(projection.group(for: "parked")).memberWorkspaceIds
        let byId = [Self.id(20): loose(20, 4), Self.id(21): loose(21, 5)]
        let source = group(10, 0)
        let plan = try resolve(members.compactMap { byId[$0] }, source: source,
            target: .member(Self.id(21), insertBefore: false))
        #expect(plan.crossingWorkspaceIds == [Self.id(20), Self.id(21)])
        let storedOnly = try resolve([byId[Self.id(21)]!], source: source,
            target: .member(Self.id(21), insertBefore: false))
        #expect(plan.crossingWorkspaceIds != storedOnly.crossingWorkspaceIds,
            "Dropping color-only projection membership must change the answer, not silently pass")
    }

    @Test(arguments: [false, true])
    func ownStatusNoopPaintsTheSourcesOwnPlaceForCQProbesAAndB(_ onBlockerMember: Bool) throws {
        let source = Row(referenceId: Self.id(10), workspaceIds: [Self.id(10), Self.id(11)], isGroup: true,
            order: 5, lastVisibleRowId: Self.id(11))
        let blocker = Row(referenceId: Self.id(30), workspaceIds: [Self.id(30), Self.id(31)], isGroup: true,
            order: 0, lastVisibleRowId: Self.id(31))
        let plan = try resolve([blocker, source, loose(20, 9)], source: source,
            target: onBlockerMember ? .member(Self.id(31), insertBefore: false) : .first)
        #expect(plan.crossingWorkspaceIds.isEmpty && plan.destinationSide == nil)
        #expect(plan.indicator == .init(tabId: source.firstVisibleRowId, edge: .top),
            "CQ probe A (.first clamped) and B (previous block member) both stay at the source")
    }

    @Test func ownStatusNoopOnTheNextRowKeepsTheLineWhereItPoints() throws {
        let source = Row(referenceId: Self.id(10), workspaceIds: [Self.id(10), Self.id(11)], isGroup: true,
            order: 5, lastVisibleRowId: Self.id(11))
        let plan = try resolve([loose(20, 3), source, loose(21, 9), loose(22, 10)], source: source,
            target: .member(Self.id(21), insertBefore: true))
        #expect(plan.crossingWorkspaceIds.isEmpty && plan.destinationSide == nil)
        #expect(plan.indicator == .init(tabId: Self.id(21), edge: .top),
            "An unclamped no-op keeps the line where he points, as for a workspace (2026-10-21 14:12)")
    }

    @Test(arguments: [false, true])
    func cannotPassALaterGroupEvenWhenDroppingLast(_ folded: Bool) throws {
        let source = group(10, 0), blocker = group(30, 5, folded: folded)
        let plan = try resolve([loose(20, 3), blocker, loose(21, 9)], source: source,
                               target: .member(Self.id(21), insertBefore: false))
        #expect(plan.crossingWorkspaceIds == [Self.id(20)])
        #expect(plan.landing == .member(blocker.referenceId, insertBefore: true))
        #expect(plan.indicator == .init(tabId: blocker.firstVisibleRowId, edge: .top))
    }

    @Test(arguments: [false, true])
    func firstClampsAfterAnEarlierGroup(_ folded: Bool) throws {
        let blocker = group(30, 0), source = group(10, 5)
        let plan = try resolve([blocker, loose(20, 3), loose(21, 9)], source: source, target: .first, folded: folded)
        #expect(plan.crossingWorkspaceIds == [Self.id(20)])
        #expect(plan.landing == .member(Self.id(20), insertBefore: true))
        #expect(plan.indicator == (folded ? .init(tabId: Self.id(99), edge: .bottom)
                                      : .init(tabId: Self.id(20), edge: .top)))
    }

    @Test(arguments: [false, true], [false, true])
    func anotherGroupsMemberUsesTheExistingSideForEitherHalf(_ sourceAfter: Bool, _ before: Bool) throws {
        let source = group(10, sourceAfter ? 9 : 0), blocker = group(30, 4)
        let plan = try resolve([loose(20, 3), blocker, loose(21, 8)], source: source,
                               target: .member(Self.id(before ? 31 : 32), insertBefore: before))
        #expect(plan.crossingWorkspaceIds == [Self.id(sourceAfter ? 21 : 20)])
        #expect(plan.indicator == (sourceAfter ? .init(tabId: Self.id(21), edge: .top)
                                              : .init(tabId: blocker.referenceId, edge: .top)))
    }

    @Test func betweenTwoBlockersOnlyTheInsideLooseRowsCross() throws {
        let source = group(10, 5), rows = [loose(20, 0), group(30, 1), loose(21, 4), loose(22, 9), group(40, 10), loose(23, 13)]
        let up = try resolve(rows, source: source, target: .first)
        let down = try resolve(rows, source: source, target: .member(Self.id(23), insertBefore: false))
        #expect(up.crossingWorkspaceIds == [Self.id(21)])
        #expect(down.crossingWorkspaceIds == [Self.id(22)])
    }

    @Test func foldedHeaderKeepsItsLineBelowTheHeaderWhenClamped() throws {
        let source = group(10, 5), blocker = group(30, 0)
        let plan = try resolve([blocker, loose(20, 9)], source: source, target: .first, folded: true)
        #expect(plan.crossingWorkspaceIds.isEmpty)
        #expect(plan.indicator == .init(tabId: Self.id(99), edge: .bottom))
    }

    @Test func ownStatusHeaderMovesToFirstWithoutIncludingTheSourceRun() throws {
        let source = group(10, 5)
        let plan = try resolve([loose(20, 0), source, loose(21, 9)], source: source, target: .first)
        #expect(plan.crossingWorkspaceIds == [Self.id(20)])
        #expect(plan.indicator == .init(tabId: Self.id(99), edge: .bottom))
    }

    @Test(arguments: [false, true])
    func targetingTheSourcesOwnRowsDoesNotMoveItsMembers(_ before: Bool) throws {
        let source = group(10, 5)
        let plan = try resolve([loose(20, 0), source, loose(21, 9)], source: source,
                               target: .member(Self.id(11), insertBefore: before))
        #expect(plan.crossingWorkspaceIds.isEmpty)
        #expect(plan.destinationSide == nil)
    }

    @Test func emptyTargetStatusAcceptsANonemptySource() throws {
        let plan = try resolve([], source: group(10, 0), target: .first)
        #expect(plan.crossingWorkspaceIds.isEmpty)
        #expect(plan.indicator == .init(tabId: Self.id(99), edge: .bottom))
    }

    @Test(arguments: [false, true])
    func stationaryHeadersDoNotCrossLooseRows(_ before: Bool) throws {
        let plan = try resolve([loose(20, 3)], source: group(10, 0),
                               target: .member(Self.id(20), insertBefore: before), moves: false)
        #expect(plan.crossingWorkspaceIds.isEmpty)
        #expect(plan.indicator == .init(tabId: Self.id(20), edge: before ? .top : .bottom))
    }

    @Test func stationaryHeaderOnAGroupMemberStillPaintsOutsideItsBlock() throws {
        let blocker = group(30, 4)
        let plan = try resolve([blocker], source: group(10, 0),
                               target: .member(Self.id(32), insertBefore: false), moves: false)
        #expect(plan.crossingWorkspaceIds.isEmpty)
        #expect(plan.indicator == .init(tabId: blocker.referenceId, edge: .top))
    }

    @Test func anEmptyTargetGroupIsStillABarrier() throws {
        let empty = Row(referenceId: Self.id(30), workspaceIds: [], isGroup: true, order: 4)
        let plan = try resolve([loose(20, 3), empty, loose(21, 8)], source: group(10, 0),
                               target: .member(Self.id(21), insertBefore: false))
        #expect(plan.crossingWorkspaceIds == [Self.id(20)])
        #expect(plan.indicator == .init(tabId: empty.referenceId, edge: .top))
    }

    @Test(arguments: [false, true])
    func stationaryNestedHeaderOnAnAncestorOrItsOwnMemberPaintsAboveTheWholeBlock(_ ownMember: Bool) throws {
        let source = group(10, 2)
        let ancestor = Row(referenceId: Self.id(30), workspaceIds: [Self.id(30), Self.id(31)] + source.workspaceIds,
                           isGroup: true, order: 0, lastVisibleRowId: Self.id(12))
        let plan = try resolve([ancestor, loose(20, 9)], source: source,
                               target: .member(Self.id(ownMember ? 11 : 31), insertBefore: false), moves: false)
        #expect(plan.crossingWorkspaceIds.isEmpty)
        #expect(plan.indicator == .init(tabId: ancestor.referenceId, edge: .top))
    }

}
