import CoreGraphics
import Foundation
import Testing
@testable import CmuxFoundation

@Suite
struct SidebarStatusGroupDropRulesTests {
    private typealias Rules = SidebarStatusGroupDropRules
    private typealias Target = SidebarWorkspaceReorderDropTarget
    private typealias Plan = SidebarStatusGroupWorkspaceDropPlan

    private struct Case: Sendable, CustomStringConvertible {
        let name: String
        let request: Rules.Request
        let expected: Rules.Decision
        var description: String { name }
    }

    private struct Fixture {
        let loose = Self.id(1), color = Self.id(2), anchor = Self.id(3), grouped = Self.id(4)
        let group = Self.id(5), area = Self.id(6), nextHeader = Self.id(7), n1 = Self.id(8), n2 = Self.id(9)
        let parkedHeader = Self.id(10), p1 = Self.id(11), p2 = Self.id(12), p3 = Self.id(13)
        let trailingHeader = Self.id(14), trailingGroup = Self.id(15)
        let folded: Bool
        let empty: Bool
        let areaLast: Bool
        let emptySourceHeader: Bool
        init(folded: Bool = false, empty: Bool = false, areaLast: Bool = true, emptySourceHeader: Bool = false) {
            self.folded = folded; self.empty = empty; self.areaLast = areaLast; self.emptySourceHeader = emptySourceHeader
        }
        static func id(_ value: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", value))! }
        var groups: [Rules.Group] {
            [.init(statusId: "next", memberWorkspaceIds: [n1, n2]),
             .init(statusId: "parked", memberWorkspaceIds: empty ? [] : [p1, p2, p3])]
        }
        var targets: [Target] {
            var data: [(UUID, UUID?, Bool, SidebarWorkspaceReorderDropTargetKind)] = [
                (loose, nil, false, .workspace), (color, nil, false, .workspace),
                (emptySourceHeader ? group : anchor, group, true, .workspace),
                (grouped, group, false, .workspace), (area, nil, false, .statusesArea),
                (nextHeader, nil, false, .statusGroupHeader(statusId: "next")),
                (n1, nil, false, .workspace), (n2, nil, false, .workspace),
                (parkedHeader, nil, false, .statusGroupHeader(statusId: "parked"))
            ]
            if !folded && !empty { data += [(p1, nil, false, .workspace), (p2, nil, false, .workspace), (p3, nil, false, .workspace)] }
            if !areaLast { data.append((trailingHeader, trailingGroup, true, .workspace)) }
            return data.enumerated().map { index, value in
                .init(workspaceId: value.0, groupId: value.1, isGroupHeader: value.2,
                    frame: CGRect(x: 0, y: CGFloat(index) * 30, width: 240, height: 28), kind: value.3)
            }
        }
        func row(_ id: UUID) -> Target { targets.first { $0.workspaceId == id }! }
        func point(_ id: UUID, _ fraction: CGFloat, x: CGFloat) -> CGPoint {
            let frame = row(id).frame
            return CGPoint(x: x, y: frame.minY + frame.height * fraction)
        }
        func gap(_ id: UUID, _ fraction: CGFloat, x: CGFloat) -> CGPoint {
            let rows = targets, i = rows.firstIndex { $0.workspaceId == id }!
            return CGPoint(x: x, y: rows[i].frame.maxY + (rows[i + 1].frame.minY - rows[i].frame.maxY) * fraction)
        }
        func request(_ source: Rules.Source, _ point: CGPoint, controls: Bool = true, list: Bool = true) -> Rules.Request {
            .init(point: point, source: source, targets: targets, groups: groups,
                areaIsLast: areaLast, controlsEnabled: controls, hasUserStatusList: list)
        }
        func status(_ id: String, _ placement: Plan.Placement, _ row: UUID, _ edge: SidebarDropEdge,
                    write: Bool = true) -> Rules.Decision {
            .statusGroup(.init(statusId: id, placement: placement, setsStatus: write, indicator: .init(tabId: row, edge: edge)))
        }
    }

    private static var cases: [Case] {
        var result: [Case] = []
        let f = Fixture()
        func add(_ name: String, _ fixture: Fixture, _ source: Rules.Source, _ point: CGPoint, _ expected: Rules.Decision) {
            result.append(.init(name: name, request: fixture.request(source, point), expected: expected))
        }
        for x: CGFloat in [60, 180] {
            let side = x == 60 ? "left" : "right"
            let outside = Rules.Source(workspaceId: f.loose)
            let own = Rules.Source(workspaceId: f.p1)
            let color = Rules.Source(workspaceId: f.color, isColorSectionMember: true)
            let pinned = Rules.Source(workspaceId: f.loose, isPinned: true)
            let grouped = Rules.Source(workspaceId: f.grouped, groupId: f.group)
            let header = Rules.Source(workspaceId: f.anchor, kind: .workspaceGroupHeader(groupId: f.group))
            for fraction: CGFloat in [0, 0.25, 0.75, 1] {
                add("09_574_headerFull_\(fraction)_\(side)", f, outside, f.point(f.parkedHeader, fraction, x: x),
                    f.status("parked", .first, f.parkedHeader, .bottom))
            }
            for (name, variant) in [("09_575_foldedHeader", Fixture(folded: true)), ("09_576_emptyHeader", Fixture(empty: true))] {
                for fraction: CGFloat in [0.25, 0.75] {
                    add("\(name)_\(fraction)_\(side)", variant, outside, variant.point(variant.parkedHeader, fraction, x: x),
                        variant.status("parked", .first, variant.parkedHeader, .bottom))
                }
            }
            add("09_574_ownHeader_moveOnly_\(side)", f, own, f.point(f.parkedHeader, 0.25, x: x),
                f.status("parked", .first, f.parkedHeader, .bottom, write: false))
            add("09_574_colorOnlyMember_ownHeader_moveOnly_\(side)", f, own, f.point(f.parkedHeader, 0.75, x: x),
                f.status("parked", .first, f.parkedHeader, .bottom, write: false))
            add("09_577_betweenMembers_upper_\(side)", f, outside, f.gap(f.p1, 0.25, x: x),
                f.status("parked", .member(f.p1, insertBefore: false), f.p1, .bottom))
            add("09_577_betweenMembers_lower_\(side)", f, outside, f.gap(f.p1, 0.75, x: x),
                f.status("parked", .member(f.p2, insertBefore: true), f.p2, .top))
            add("09_577_ownMember_moveOnly_\(side)", f, own, f.point(f.p2, 0.75, x: x),
                f.status("parked", .member(f.p2, insertBefore: false), f.p2, .bottom, write: false))
            add("09_578_firstRowTop_\(side)", f, outside, f.point(f.p1, 0, x: x),
                f.status("parked", .member(f.p1, insertBefore: true), f.p1, .top))
            for (role, source, write) in [("outside", outside, true), ("own", own, false),
                                         ("colorOnlyOwn", own, false), ("plainColor", color, true),
                                         ("pinned", pinned, true), ("grouped", grouped, true),
                                         ("otherStatus", Rules.Source(workspaceId: f.n1), true)] {
                add("09_579_lastBottom_\(role)_\(side)", f, source, f.point(f.p3, 1, x: x),
                    f.status("parked", .member(f.p3, insertBefore: false), f.p3, .bottom, write: write))
            }
            for fraction: CGFloat in [0.25, 0.5, 0.75] {
                let upper = fraction < 0.5
                add("09_580_betweenStatusGroups_gap\(fraction)_\(side)", f, outside, f.gap(f.n2, fraction, x: x),
                    upper ? f.status("next", .member(f.n2, insertBefore: false), f.n2, .bottom)
                          : f.status("parked", .first, f.parkedHeader, .bottom))
                let trailing = Fixture(areaLast: false)
                add("09_581_lastGroupBeforeOrdinary_gap\(fraction)_\(side)", trailing, outside,
                    trailing.gap(trailing.p3, fraction, x: x),
                    trailing.status("parked", .member(trailing.p3, insertBefore: false), trailing.p3, .bottom))
            }
            add("09_582_workspaceOnStatuses_\(side)", f, outside, f.point(f.area, 0.5, x: x), .refused)
            let below = CGPoint(x: x, y: f.targets.last!.frame.maxY + 20)
            for (role, source, expected) in [("loose", outside, Rules.Decision.areaBoundary(.belowAll, indicator: .init(tabId: nil, edge: .bottom))),
                                            ("own", own, .refused), ("colorOnlyOwn", own, .refused), ("plainColor", color, .refused),
                                            ("grouped", grouped, .areaBoundary(.belowAll, indicator: .init(tabId: nil, edge: .bottom))),
                                            ("pinnedLegacy", pinned, .unrelated)] {
                add("09_583_belowAll_\(role)_\(side)", f, source, below, expected)
            }
            for (role, source) in [("pinned", pinned), ("grouped", grouped)] {
                add("09_584_\(role)_header_\(side)", f, source, f.point(f.parkedHeader, 0.25, x: x),
                    f.status("parked", .first, f.parkedHeader, .bottom))
            }
            add("09_585_groupedWorkspaceOutsideArea_\(side)", f, grouped, f.point(f.loose, 0.5, x: x), .unrelated)
            for (role, source) in [("nonemptyHeader", header), ("selectedHeaders", header)] {
                add("09_586_\(role)_statusHeaderRefused_\(side)", f, source, f.point(f.parkedHeader, 0.75, x: x), .refused)
                add("09_586_\(role)_memberRefused_\(side)", f, source, f.point(f.p2, 0.25, x: x), .refused)
                add("09_586_\(role)_statusesBoundaryAbove_\(side)", f, source, f.point(f.area, 0.75, x: x),
                    .areaBoundary(.aboveArea, indicator: .init(tabId: f.area, edge: .top)))
                add("09_586_\(role)_belowBoundary_\(side)", f, source, below,
                    .areaBoundary(.belowAll, indicator: .init(tabId: nil, edge: .bottom)))
            }
            let e = Fixture(emptySourceHeader: true)
            let emptyHeader = Rules.Source(workspaceId: e.group, kind: .workspaceGroupHeader(groupId: e.group))
            add("09_586_emptyHeader_statusRefused_\(side)", e, emptyHeader, e.point(e.parkedHeader, 0.5, x: x), .refused)
            add("09_586_emptyHeader_statusesBoundaryAbove_\(side)", e, emptyHeader, e.point(e.area, 0.5, x: x),
                .areaBoundary(.aboveArea, indicator: .init(tabId: e.area, edge: .top)))
            add("09_586_emptyHeader_belowBoundary_\(side)", e, emptyHeader,
                CGPoint(x: x, y: e.targets.last!.frame.maxY + 20), .areaBoundary(.belowAll, indicator: .init(tabId: nil, edge: .bottom)))
            add("04_60_ownRowLooseEscapeRefused_\(side)", f, own, f.point(f.loose, 0.5, x: x), .refused)
            add("04_59_ownRowPlainColorEscapeRefused_\(side)", f, own, f.point(f.color, 0.5, x: x), .refused)
            add("crossWindow_statusGuard_\(side)", f, .init(workspaceId: f.loose, isLocal: false), f.point(f.parkedHeader, 0.5, x: x), .refused)
            add("crossWindow_ordinaryUnchanged_\(side)", f, .init(workspaceId: f.loose, isLocal: false), f.point(f.color, 0.5, x: x), .unrelated)
            add("unknownSourceKind_statusRefused_\(side)", f, .init(workspaceId: f.loose, kind: .unknown), f.point(f.parkedHeader, 0.5, x: x), .refused)
            add("sameGroupAcceptedCanonicalSourceGap_\(side)", f, .init(workspaceId: f.p2), f.point(f.p1, 0.75, x: x),
                f.status("parked", .member(f.p1, insertBefore: false), f.p1, .bottom, write: false))
        }
        result.append(.init(name: "controlsOff_currentTargetRefused", request: f.request(.init(workspaceId: f.loose), f.point(f.parkedHeader, 0.5, x: 60), controls: false), expected: .refused))
        result.append(.init(name: "fallbackOrAbsentList_currentTargetRefused", request: f.request(.init(workspaceId: f.loose), f.point(f.parkedHeader, 0.5, x: 60), list: false), expected: .refused))
        return result
    }

    @Test(.serialized, arguments: Self.cases)
    private func everyFlatZoneHasItsDecidedResult(_ example: Case) {
        #expect(Rules().plan(example.request) == example.expected)
    }

    @Test(arguments: [false, true])
    func onlyWorkspaceGroupMembershipAllowsAStatusRowToLeave(_ intoWorkspaceGroup: Bool) {
        let action = SidebarWorkspaceReorderDropAction.reorder(targetIndex: 3, usesTopLevelRows: !intoWorkspaceGroup,
            explicitGroupId: intoWorkspaceGroup ? Fixture.id(30) : nil)
        #expect(Rules().permitsLeavingStatusGroup(action: action) == intoWorkspaceGroup)
    }
}
