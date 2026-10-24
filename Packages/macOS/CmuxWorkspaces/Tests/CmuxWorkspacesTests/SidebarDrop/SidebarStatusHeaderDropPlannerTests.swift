import CoreGraphics
import Foundation
import Testing
@testable import CmuxFoundation

struct SidebarStatusHeaderDropPlannerTests {
    private let pin = UUID(), loose = UUID(), area = UUID(), a = UUID(), a1 = UUID(), a2 = UUID(), b = UUID()
    private let group = UUID(), member = UUID(), color = UUID(), colorMember = UUID()

    private func row(_ id: UUID, _ y: CGFloat, _ owner: String? = nil, status: String? = nil,
                     area: Bool = false, pinned: Bool = false) -> SidebarStatusHeaderDropTarget {
        .init(rowId: id, frame: CGRect(x: 0, y: y, width: 300, height: 20), topLevelRowId: owner,
              statusId: status, isStatusesArea: area, isPinned: pinned)
    }
    private var rows: [SidebarStatusHeaderDropTarget] {
        [row(pin, 0, "workspace:pin", pinned: true), row(loose, 22, "workspace:loose"),
         row(area, 44, area: true), row(a, 66, status: "a"), row(a1, 88, status: "a"),
         row(a2, 110, status: "a"), row(b, 132, status: "b")]
    }
    private func plan(_ y: CGFloat, source: String? = "b", targets: [SidebarStatusHeaderDropTarget]? = nil) -> SidebarStatusHeaderDropPlan? {
        SidebarStatusHeaderDropPlanner().plan(point: CGPoint(x: 210, y: y), draggedStatusId: source, targets: targets ?? rows)
    }

    // 09:587 — expanded group's block midpoint, not the header's midpoint.
    @Test(arguments: [CGFloat(68), 82, 90, 100, 128])
    func anotherGroupsWholeVisibleBlockChoosesItsOuterEdge(_ y: CGFloat) throws {
        let result = try #require(plan(y))
        let before = y < 98
        #expect(result.action == .statusGroup(targetStatusId: "a", insertBefore: before))
        #expect(result.indicator == .init(tabId: before ? a : a2, edge: before ? .top : .bottom))
    }

    @Test(arguments: [CGFloat(134), 150])
    func foldedOrEmptyGroupUsesTheHeadersOwnHalves(_ y: CGFloat) throws {
        let result = try #require(plan(y, source: "a"))
        #expect(result.action == .statusGroup(targetStatusId: "b", insertBefore: y < 142))
        #expect(result.indicator == .init(tabId: b, edge: y < 142 ? .top : .bottom))
    }

    // 09:589/590.
    @Test func statusesHeaderMeansFirstGroup() throws {
        let result = try #require(plan(50))
        #expect(result.action == .statusGroup(targetStatusId: "a", insertBefore: true))
        #expect(result.indicator == .init(tabId: area, edge: .bottom))
    }
    @Test func belowAllMeansLastOnlyWhenAreaIsLast() throws {
        let result = try #require(plan(180, source: "a"))
        #expect(result.action == .statusGroup(targetStatusId: "b", insertBefore: false))
        #expect(result.indicator == .init(tabId: b, edge: .bottom))
    }

    // 09:591/592/594 and own-group refusal. Opposite accept-all stub must attack these.
    @Test func belowAllIsRefusedWhenAreaIsNotLast() {
        #expect(plan(200, source: "a", targets: rows + [row(loose, 170, "workspace:tail")]) == nil)
    }
    @Test(arguments: [CGFloat(5), 28])
    func aStatusCannotLeaveItsArea(_ y: CGFloat) { #expect(plan(y) == nil) }
    @Test func aStatusCannotLandOnItsOwnBlock() { #expect(plan(92, source: "a") == nil) }
    @Test(arguments: [CGFloat(50), 72, 92, 115, 140])
    func theAreaCannotLandOnItsOwnHeaderOrGroups(_ y: CGFloat) { #expect(plan(y, source: nil) == nil) }

    // 09:593.
    @Test func areaOnPinsClampsBelowEveryPinnedRow() throws {
        let result = try #require(plan(5, source: nil))
        #expect(result.action == .area(aboveRow: "top", belowRow: "workspace:loose", last: false))
        #expect(result.indicator == .init(tabId: loose, edge: .top))
    }

    @Test(arguments: [false, true])
    func areaOverALooseRowUsesTheRowsHalves(_ after: Bool) throws {
        let result = try #require(plan(after ? 39 : 24, source: nil))
        #expect(result.action == (after
            ? .area(aboveRow: "workspace:loose", belowRow: nil, last: true)
            : .area(aboveRow: "top", belowRow: "workspace:loose", last: false)))
    }

    @Test(arguments: ["group:g", "color:#AABBCC"], [false, true])
    func areaNeverSplitsAWholeGroupOrColorBlock(_ owner: String, _ after: Bool) throws {
        let top = owner.hasPrefix("group") ? group : color
        let bottom = owner.hasPrefix("group") ? member : colorMember
        let targets = [row(pin, 0, "workspace:pin", pinned: true), row(top, 22, owner),
                       row(bottom, 44, owner), row(area, 66, area: true), row(a, 88, status: "a")]
        let result = try #require(plan(after ? 60 : 30, source: nil, targets: targets))
        #expect(result.action == (after
            ? .area(aboveRow: owner, belowRow: nil, last: true)
            : .area(aboveRow: "top", belowRow: owner, last: false)))
        #expect(result.indicator == .init(tabId: after ? bottom : top, edge: after ? .bottom : .top))
    }

    @Test(arguments: ["group:g", "color:#AABBCC"])
    func statusHeaderRefusesWorkspaceAndColorGroups(_ owner: String) {
        #expect(plan(30, targets: [row(group, 22, owner)] + Array(rows.dropFirst(2))) == nil)
    }

    // cm-110.4 Experience #9: both source headers, both orders, both sidebar halves.
    private func sectionRows(statusesFirst: Bool, compact: Bool = false) -> [SidebarStatusHeaderDropTarget] {
        let w = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        var result = [row(pin, 0, "workspace:pin", pinned: true)]
        let blocks = statusesFirst ? [[area, a, a1], [w, loose, member]] : [[w, loose, member], [area, a, a1]]
        for block in blocks {
            for id in compact ? [block[0]] : block {
                result.append(.init(rowId: id, frame: CGRect(x: 0, y: result.count * 22, width: 300, height: 20),
                    statusId: block[0] == area && id != area ? "a" : nil,
                    isStatusesArea: id == area, isWorkspacesArea: id == w))
            }
        }
        return result
    }
    private func sectionPlan(rows: [SidebarStatusHeaderDropTarget], sourceW: Bool, y: CGFloat, x: CGFloat = 75) -> SidebarStatusHeaderDropPlan? {
        SidebarStatusHeaderDropPlanner().plan(point: .init(x: x, y: y), draggedStatusId: nil,
            targets: rows, draggedWorkspacesArea: sourceW)
    }
    private func checkOther(before: Bool, compact: Bool = false) throws {
        for first in [false, true] { for sourceW in [false, true] { for x in [CGFloat(75), 225] {
            let rows = sectionRows(statusesFirst: first, compact: compact)
            let otherStart = try #require(rows.firstIndex { sourceW ? $0.isStatusesArea : $0.isWorkspacesArea })
            let end = rows.dropFirst(otherStart + 1).firstIndex { $0.isStatusesArea || $0.isWorkspacesArea }.map { $0 - 1 } ?? (rows.count - 1)
            let midpoint = (rows[otherStart].frame.minY + rows[end].frame.maxY) / 2
            let probes = (otherStart...end).flatMap { i in
                [rows[i].frame.minY + 1, rows[i].frame.midY, rows[i].frame.maxY]
            }.filter { ($0 < midpoint) == before }
            for y in probes {
                let actual = try #require(sectionPlan(rows: rows, sourceW: sourceW, y: y, x: x))
                #expect(actual.action == .area(aboveRow: "top", belowRow: nil, last: sourceW == before))
                #expect(actual.indicator == .init(tabId: before ? rows[otherStart].rowId : rows[end].rowId, edge: before ? .top : .bottom))
            }
        } } }
    }
    @Test func upperHalfOfOtherSectionPlacesWholeSectionBeforeIt() throws { try checkOther(before: true) }
    @Test func lowerHalfOfOtherSectionPlacesWholeSectionAfterIt() throws { try checkOther(before: false) }
    @Test func foldedOrEmptySectionUsesOnlyItsHeaderHalves() throws {
        try checkOther(before: true, compact: true); try checkOther(before: false, compact: true)
    }
    @Test func ownSectionRefusesWithNoIndicator() {
        for first in [false, true] { for sourceW in [false, true] {
            let rows = sectionRows(statusesFirst: first)
            let start = rows.firstIndex { sourceW ? $0.isWorkspacesArea : $0.isStatusesArea }!
            for y in [rows[start].frame.midY, rows[start + 1].frame.midY, rows[start + 2].frame.maxY] {
                #expect(sectionPlan(rows: rows, sourceW: sourceW, y: y) == nil)
            }
        } }
    }
    @Test func pinnedRowsClampSectionFirstBelowAllPins() throws {
        for first in [false, true] { for sourceW in [false, true] {
            let rows = sectionRows(statusesFirst: first)
            let actual = try #require(sectionPlan(rows: rows, sourceW: sourceW, y: 5))
            #expect(actual.action == .area(aboveRow: "top", belowRow: nil, last: sourceW))
            #expect(actual.indicator == .init(tabId: rows[1].rowId, edge: .top))
        } }
    }
    @Test func belowAllPlacesDraggedSectionSecond() throws {
        for first in [false, true] { for sourceW in [false, true] {
            let rows = sectionRows(statusesFirst: first)
            let actual = try #require(sectionPlan(rows: rows, sourceW: sourceW, y: rows.last!.frame.maxY + 1))
            #expect(actual.action == .area(aboveRow: "top", belowRow: nil, last: !sourceW))
            #expect(actual.indicator == .init(tabId: rows.last!.rowId, edge: .bottom))
        } }
    }
}
