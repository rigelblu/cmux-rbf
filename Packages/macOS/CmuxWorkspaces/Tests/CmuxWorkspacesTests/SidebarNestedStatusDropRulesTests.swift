import CoreGraphics
import Foundation
import Testing
@testable import CmuxFoundation

@Suite
struct SidebarNestedStatusDropRulesTests {
    private typealias Rules = SidebarStatusGroupDropRules
    private typealias Target = SidebarWorkspaceReorderDropTarget
    private typealias Plan = SidebarStatusGroupWorkspaceDropPlan
    private struct Example: Sendable, CustomStringConvertible {
        let name: String, request: Rules.Request, expected: Rules.Decision
        let legacy: SidebarWorkspaceReorderDropRequest?
        let legacyIndicator: SidebarDropIndicator?
        var description: String { name }
    }
    private struct Fixture {
        let last: Bool, folded: Bool, empty: Bool, followingStatus: Bool
        init(last: Bool, folded: Bool = false, empty: Bool = false, followingStatus: Bool = false) {
            self.last = last; self.folded = folded; self.empty = empty; self.followingStatus = followingStatus
        }
        static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "50000000-0000-4000-8000-%012d", n))! }
        let loose = Self.id(1), c1 = Self.id(2), c2 = Self.id(3), c3 = Self.id(4), p = Self.id(5), pa = Self.id(6), q = Self.id(7), qa = Self.id(8)
        let area = Self.id(9), header = Self.id(10), next = Self.id(11), n1 = Self.id(12), n2 = Self.id(13), outside = Self.id(14)
        var groups: [Rules.Group] {
            [.init(statusId: "parked", memberWorkspaceIds: empty ? [] : [c1,c2,c3]),
             .init(statusId: "next", memberWorkspaceIds: [n1,n2])]
        }
        var targets: [Target] {
            var statuses: [(UUID, UUID?, Bool, SidebarWorkspaceReorderDropTargetKind)] = [
                (area,nil,false,.statusesArea), (header,nil,false,.statusGroupHeader(statusId: "parked"))]
            if !folded && !empty { statuses += [c1,c2,c3].map { ($0,nil,false,.workspace) } }
            if followingStatus { statuses += [(next,nil,false,.statusGroupHeader(statusId: "next")),(n1,nil,false,.workspace),(n2,nil,false,.workspace)] }
            let nested: [(UUID, UUID?, Bool, SidebarWorkspaceReorderDropTargetKind)] = [
                (p,p,true,.workspace),(pa,p,false,.workspace),(q,q,true,.workspace),(qa,q,false,.workspace)]
            let prefix: [(UUID, UUID?, Bool, SidebarWorkspaceReorderDropTargetKind)] = [(loose,nil,false,.workspace),(outside,nil,false,.workspace)]
            return (prefix + (last ? nested + statuses : statuses + nested)).enumerated().map { i, row in
                .init(workspaceId: row.0, groupId: row.1, isGroupHeader: row.2,
                    frame: CGRect(x: 0,y: CGFloat(i)*30,width: 240,height: 28),kind: row.3)
            }
        }
        func row(_ id: UUID) -> Target { targets.first { $0.workspaceId == id }! }
        func point(_ id: UUID, _ fraction: CGFloat, _ x: CGFloat) -> CGPoint {
            let frame = row(id).frame; return .init(x: x,y: frame.minY + fraction*frame.height)
        }
        func gap(_ id: UUID, _ fraction: CGFloat, _ x: CGFloat) -> CGPoint {
            let rows = targets, index = rows.firstIndex { $0.workspaceId == id }!
            return .init(x: x,y: rows[index].frame.maxY + (rows[index+1].frame.minY-rows[index].frame.maxY)*fraction)
        }
        func request(_ source: Rules.Source, _ point: CGPoint, controls: Bool = true, list: Bool = true) -> Rules.Request {
            .init(point: point,source: source,targets: targets,groups: groups,areaIsLast: last,controlsEnabled: controls,hasUserStatusList: list)
        }
        func legacy(_ point: CGPoint) -> SidebarWorkspaceReorderDropRequest {
            let ordinary = targets.filter { $0.kind == .workspace }
            let raw = ordinary.map { row in SidebarWorkspaceReorderWorkspaceSnapshot(id: row.workspaceId,isPinned: false,
                groupId: row.workspaceId == p || row.workspaceId == pa ? p : (row.workspaceId == q || row.workspaceId == qa ? q : nil)) }
            return .init(point: point,draggedWorkspaceId: c1,workspaces: raw,
                groups: [.init(id: p,anchorWorkspaceId: p,isPinned: false,isEmpty: false),
                         .init(id: q,anchorWorkspaceId: q,isPinned: false,isEmpty: false,parentGroupId: p)],targets: ordinary)
        }
        func status(_ target: UUID, before: Bool, own: Bool = false) -> Rules.Decision {
            .statusGroup(.init(statusId: "parked",placement: .member(target,insertBefore: before),setsStatus: !own,
                indicator: .init(tabId: target,edge: before ? .top : .bottom)))
        }
        func headerPlan(_ id: String = "parked", own: Bool = false) -> Rules.Decision {
            .statusGroup(.init(statusId: id,placement: .first,setsStatus: !own,indicator: .init(tabId: id == "parked" ? header : next,edge: .bottom)))
        }
    }
    private static var accepted: [Example] {
        var result: [Example] = []
        func add(_ name: String,_ f: Fixture,_ source: Rules.Source,_ point: CGPoint,_ expected: Rules.Decision,
                 legacyIndicator: SidebarDropIndicator? = nil) {
            result.append(.init(name: name,request: f.request(source,point),expected: expected,
                legacy: legacyIndicator == nil ? nil : f.legacy(point),legacyIndicator: legacyIndicator))
        }
        for last in [false,true] { for x: CGFloat in [60,180] {
            let f = Fixture(last: last), side = x == 60 ? "left" : "right", scene = last ? "F2b" : "F1"
            let own = Rules.Source(workspaceId: f.c1), outside = Rules.Source(workspaceId: f.outside)
            add("N1_\(scene)_lowerC2_\(side)",f,own,f.point(f.c2,0.75,x),f.status(f.c2,before: false,own: true))
            add("N1_\(scene)_lowerC3_\(side)",f,own,f.point(f.c3,0.75,x),f.status(f.c3,before: false,own: true),
                legacyIndicator: last ? .init(tabId: nil,edge: .bottom) : .init(tabId: f.p,edge: .top))
            for fraction: CGFloat in [0,0.25,0.75,1] {
                add("N3_\(scene)_header\(fraction)_\(side)",f,outside,f.point(f.header,fraction,x),f.headerPlan())
            }
            add("N5_\(scene)_firstTop_\(side)",f,outside,f.point(f.c1,0,x),f.status(f.c1,before: true))
            for (role,source,ownMember) in [("outside",outside,false),("own",own,true),
                ("pinned",Rules.Source(workspaceId: f.outside,isPinned: true),false),
                ("grouped",Rules.Source(workspaceId: f.qa,groupId: f.q),false),
                ("plainColor",Rules.Source(workspaceId: f.outside,isColorSectionMember: true),false)] {
                for inset: CGFloat in [1,0] {
                    let point = CGPoint(x: x,y: f.row(f.c3).frame.maxY-inset)
                    add("N6_\(scene)_\(role)_maxYminus\(inset)_\(side)",f,source,point,f.status(f.c3,before: false,own: ownMember))
                }
            }
            for fraction: CGFloat in [0.25,0.5,0.75] {
                add("N4_\(scene)_memberGap\(fraction)_\(side)",f,outside,f.gap(f.c2,fraction,x),
                    fraction < 0.5 ? f.status(f.c2,before: false) : f.status(f.c3,before: true))
                if !last { add("N7_F1_beforeNestedP_gap\(fraction)_\(side)",f,outside,f.gap(f.c3,fraction,x),f.status(f.c3,before: false)) }
            }
            if last {
                for (name,source) in [("outside",outside),("grouped",Rules.Source(workspaceId: f.qa,groupId: f.q))] {
                    add("N8_F2b_\(name)_belowAll_\(side)",f,source,.init(x: x,y: f.targets.last!.frame.maxY+20),
                        .areaBoundary(.belowAll,indicator: .init(tabId: nil,edge: .bottom)))
                }
            }
            for variant in [Fixture(last: last,folded: true),Fixture(last: last,empty: true)] {
                add("N3_\(scene)_folded\(variant.folded)_empty\(variant.empty)_\(side)",variant,outside,
                    variant.point(variant.header,0.25,x),variant.headerPlan())
            }
            let g = Fixture(last: last,followingStatus: true)
            for fraction: CGFloat in [0.25,0.5,0.75] {
                add("N7_\(scene)_statusGap\(fraction)_\(side)",g,outside,g.gap(g.c3,fraction,x),
                    fraction < 0.5 ? g.status(g.c3,before: false) : g.headerPlan("next"))
            }
        }}
        return result
    }
    private static var refusals: [Example] {
        var result: [Example] = []
        for x: CGFloat in [60,180] {
            let f = Fixture(last: true), below = CGPoint(x: x,y: f.targets.last!.frame.maxY+20)
            for (name,source) in [("own",Rules.Source(workspaceId: f.c1)),("colorOnlyOwn",Rules.Source(workspaceId: f.c2)),
                ("plainColor",Rules.Source(workspaceId: f.outside,isColorSectionMember: true))] {
                result.append(.init(name: "N8_\(name)_belowAll_\(x)",request: f.request(source,below),expected: .refused,legacy: nil,legacyIndicator: nil))
            }
            let point = f.point(f.header,0.25,x), source = Rules.Source(workspaceId: f.outside)
            result.append(.init(name: "N2_controlsOff_\(x)",request: f.request(source,point,controls: false),expected: .refused,legacy: nil,legacyIndicator: nil))
            result.append(.init(name: "N2_noUserList_\(x)",request: f.request(source,point,list: false),expected: .refused,legacy: nil,legacyIndicator: nil))
        }
        return result
    }
    @Test(.serialized,arguments: Self.accepted)
    private func nestedActualPointsKeepStatusOwnershipBeforeTheMeasuredLegacyAlias(_ example: Example) throws {
        if let legacy = example.legacy { let plan = try #require(SidebarWorkspaceReorderDropResolver().plan(for: legacy)); try #require(plan.indicator == example.legacyIndicator) }
        #expect(Rules().plan(example.request) == example.expected)
    }
    @Test(.serialized,arguments: Self.refusals)
    private func nestedBelowAllAndDisabledControlsNeverAdmitAStatusDrop(_ example: Example) {
        #expect(Rules().plan(example.request) == example.expected)
    }
}
