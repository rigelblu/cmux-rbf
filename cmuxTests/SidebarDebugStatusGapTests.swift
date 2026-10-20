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

#if DEBUG
@MainActor
@Suite(.serialized)
struct SidebarDebugStatusGapTests {
    private nonisolated static let zones: [SidebarDebugHeaderDrop.Zone] = [.gap25, .gap50, .gap75]

    private func fraction(_ zone: SidebarDebugHeaderDrop.Zone) -> CGFloat {
        switch zone {
        case .gap25: return 0.25
        case .gap50: return 0.5
        case .gap75: return 0.75
        default: return -1
        }
    }

    @MainActor
    private struct Fixture {
        let source: UUID
        let previous: UUID
        let trailingOrdinary: Bool
        let trailingGroup = UUID()
        let trailingAnchor = UUID()
        let area = SidebarStatusHeaderIdentity.statusesAreaUUID
        let nextHeader = SidebarStatusHeaderIdentity.uuid(forStatusId: "next")
        let parkedHeader = SidebarStatusHeaderIdentity.uuid(forStatusId: "parked")

        init(source: UUID = UUID(), previous: UUID = UUID(), trailingOrdinary: Bool = false) {
            self.source = source
            self.previous = previous
            self.trailingOrdinary = trailingOrdinary
        }

        var previousRow: SidebarWorkspaceRenderItemID { .workspace(previous) }
        var followingId: UUID { trailingOrdinary ? trailingAnchor : parkedHeader }
        var followingRow: SidebarWorkspaceRenderItemID {
            trailingOrdinary ? .group(trailingGroup) : .statusGroup("parked")
        }
        var targets: [SidebarWorkspaceReorderDropOverlay.Target] {
            [
                .init(workspaceId: area, groupId: nil, isGroupHeader: false,
                    frame: CGRect(x: 10, y: -30, width: 200, height: 28), renderItemId: .statusesArea()),
                .init(workspaceId: nextHeader, groupId: nil, isGroupHeader: false,
                    frame: CGRect(x: 10, y: 0, width: 200, height: 28), renderItemId: .statusGroup("next")),
                .init(workspaceId: previous, groupId: nil, isGroupHeader: false,
                    frame: CGRect(x: 10, y: 30, width: 200, height: 28), renderItemId: previousRow),
                .init(workspaceId: followingId, groupId: trailingOrdinary ? trailingGroup : nil,
                    isGroupHeader: trailingOrdinary, frame: CGRect(x: 10, y: 60, width: 200, height: 28), renderItemId: followingRow)
            ]
        }
        var typedTargets: [SidebarWorkspaceReorderDropTarget] {
            targets.map { target in
                let kind: SidebarWorkspaceReorderDropTargetKind
                if target.renderItemId == .statusesArea() { kind = .statusesArea }
                else if target.renderItemId == .statusGroup("next") { kind = .statusGroupHeader(statusId: "next") }
                else if target.renderItemId == .statusGroup("parked") { kind = .statusGroupHeader(statusId: "parked") }
                else { kind = .workspace }
                return .init(workspaceId: target.workspaceId, groupId: target.groupId,
                    isGroupHeader: target.isGroupHeader, frame: target.frame, kind: kind)
            }
        }
    }

    @Test(arguments: zones, SidebarDebugHeaderDrop.Side.allCases)
    func interiorCoordinatesUseTheActualPositiveGapAndSidebarHalf(_ zone: SidebarDebugHeaderDrop.Zone, _ side: SidebarDebugHeaderDrop.Side) throws {
        let f = Fixture(), targets = f.targets
        let row = try #require(targets.first { $0.renderItemId == f.previousRow })
        let next = try #require(targets.first { $0.renderItemId == f.followingRow })
        try #require(next.frame.minY - row.frame.maxY == 2)
        let point = try #require(SidebarDebugHeaderDrop.point(targetId: f.previous, zone: zone, side: side,
            targets: targets, renderItemId: f.previousRow))
        #expect(point == CGPoint(x: side == .left ? 60 : 160, y: row.frame.maxY + 2 * fraction(zone)))
        #expect(point.y > row.frame.maxY && point.y < next.frame.minY)
    }

    enum InvalidGap: CaseIterable, Sendable { case noNext, touching, overlapping, unknownRow, wrongTypedRow, zeroWidth }

    @Test(arguments: InvalidGap.allCases)
    func missingOrNonpositiveMeasuredGapsFailClosed(_ invalid: InvalidGap) {
        let f = Fixture()
        var targets = f.targets
        var target = f.previous
        var rowId = f.previousRow
        switch invalid {
        case .noNext: targets.removeLast()
        case .touching, .overlapping:
            targets[3] = .init(workspaceId: f.followingId, groupId: nil, isGroupHeader: false,
                frame: CGRect(x: 10, y: invalid == .touching ? 58 : 57, width: 200, height: 28), renderItemId: f.followingRow)
            let later = UUID()
            targets.append(.init(workspaceId: later, groupId: nil, isGroupHeader: false,
                frame: CGRect(x: 10, y: 100, width: 200, height: 28), renderItemId: .workspace(later)))
        case .unknownRow: target = UUID(); rowId = .workspace(target)
        case .wrongTypedRow: rowId = .statusGroup("missing")
        case .zeroWidth:
            targets[2] = .init(workspaceId: f.previous, groupId: nil, isGroupHeader: false,
                frame: CGRect(x: 10, y: 30, width: 0, height: 28), renderItemId: f.previousRow)
        }
        #expect(SidebarDebugHeaderDrop.point(targetId: target, zone: .gap50, side: .left, targets: targets, renderItemId: rowId) == nil)
        var plans = 0, commits = 0
        let performed = SidebarDebugHeaderDrop.perform(draggedId: f.source, targetId: target, zone: .gap50, side: .left,
            targets: targets, renderItemId: rowId, plan: { _, _, id in
                plans += 1
                return .init(draggedWorkspaceId: id, indicator: .init(tabId: f.previous, edge: .bottom),
                    indicatorScope: .raw, action: .reorder(targetIndex: 0, usesTopLevelRows: true, explicitGroupId: nil))
            }, commit: { _ in commits += 1; return true })
        #expect(!performed && plans == 0 && commits == 0)
    }

    private struct GapCase: Sendable {
        let zone: SidebarDebugHeaderDrop.Zone
        let side: SidebarDebugHeaderDrop.Side
        let trailingOrdinary: Bool
    }

    private nonisolated static var pipelineCases: [GapCase] {
        zones.flatMap { zone in
            SidebarDebugHeaderDrop.Side.allCases.flatMap { side in
                [false, true].map { GapCase(zone: zone, side: side, trailingOrdinary: $0) }
            }
        }
    }

    @Test(arguments: Self.pipelineCases)
    private func theInteriorPointUsesTheStatusPlannerAndCommitsItsExactPlan(_ example: GapCase) throws {
        let zone = example.zone, side = example.side, trailingOrdinary = example.trailingOrdinary
        let model = PerformFixture(trailingOrdinary: trailingOrdinary)
        let f = Fixture(source: model.source.id, previous: model.previous.id, trailingOrdinary: trailingOrdinary)
        let portion = fraction(zone), token = UUID()
        let previousWins = trailingOrdinary || portion < 0.5
        let expectedStatus = previousWins ? "next" : "parked"
        let expectedColor = expectedStatus == "next" ? "#111111" : "#555555"
        let beforeOther = [Held(model.previous), Held(model.unrelated)]
        try #require(model.projection()?.group(for: "next")?.memberWorkspaceIds == [model.previous.id])
        try #require(model.projection()?.contains(workspaceId: model.source.id) == false)
        if trailingOrdinary {
            try #require(model.list.entries.map(\.id) == ["next"])
            try #require(f.targets.last?.isGroupHeader == true)
        } else {
            try #require(model.projection()?.group(for: "parked")?.memberWorkspaceIds.isEmpty == true)
        }
        let expectedValue = SidebarStatusGroupWorkspaceDropPlan(statusId: expectedStatus,
            placement: previousWins ? .member(f.previous, insertBefore: false) : .first, setsStatus: true,
            indicator: .init(tabId: previousWins ? f.previous : f.parkedHeader, edge: .bottom))
        let expected = SidebarWorkspaceReorderDropPlan(draggedWorkspaceId: f.source, indicator: expectedValue.indicator,
            indicatorScope: .group(SidebarStatusHeaderIdentity.uuid(forStatusId: expectedStatus)),
            action: .statusGroupDrop(plan: expectedValue, sessionId: token))
        var plans = 0, performerCalls = 0
        var committed: SidebarWorkspaceReorderDropPlan?
        let performed = SidebarDebugHeaderDrop.perform(draggedId: f.source, targetId: f.previous, zone: zone, side: side,
            targets: f.targets, renderItemId: f.previousRow, plan: { point, measured, source in
                plans += 1
                #expect(point == CGPoint(x: side == .left ? 60 : 160, y: 58 + 2 * portion))
                #expect(source == f.source && measured == f.targets)
                let groups = model.projection()?.groups.map {
                    SidebarStatusGroupDropRules.Group(statusId: $0.statusId, memberWorkspaceIds: $0.memberWorkspaceIds)
                } ?? []
                let request = SidebarStatusGroupDropRules.Request(point: point,
                    source: .init(workspaceId: source, isColorSectionMember: true), targets: f.typedTargets,
                    groups: groups, areaIsLast: !trailingOrdinary)
                guard case .statusGroup(let actual) = SidebarStatusGroupDropRules().plan(request) else { return nil }
                #expect(actual == expectedValue)
                return .init(draggedWorkspaceId: source, indicator: actual.indicator, indicatorScope: expected.indicatorScope,
                    action: .statusGroupDrop(plan: actual, sessionId: token))
            }, commit: { plan in
                committed = plan
                guard case .statusGroupDrop(let value, let actualToken) = plan.action, actualToken == token else { return false }
                performerCalls += 1
                return model.performer().perform(value, dragged: model.source, sourceKind: .workspace)
            })
        #expect(performed && plans == 1 && performerCalls == 1)
        #expect(committed == expected)
        #expect(model.source.todoState.ownStatus?.id == expectedStatus)
        #expect(!model.source.todoState.statusHidden && model.source.customColor == expectedColor)
        #expect(model.resolutions == [expectedColor])
        #expect(model.colors == [.init(workspaceId: f.source, hex: expectedColor)])
        #expect([Held(model.previous), Held(model.unrelated)] == beforeOther)
        #expect(model.projection()?.group(for: expectedStatus)?.memberWorkspaceIds.contains(f.source) == true)
        if previousWins {
            #expect(model.moves == [.init(dragged: f.source, target: f.previous, before: false,
                members: [f.source, f.previous])])
            #expect(model.writesBeforeMove == [1])
        } else {
            #expect(model.moves.isEmpty && model.writesBeforeMove.isEmpty)
        }
    }

    private struct Held: Equatable {
        let own: String?, cmux: WorkspaceTaskStatus?, hidden: Bool, color: String?, pinned: Bool, group: UUID?
        @MainActor
        init(_ workspace: Workspace) {
            own = workspace.todoState.ownStatus?.id
            cmux = workspace.todoState.statusOverride?.status
            hidden = workspace.todoState.statusHidden
            color = workspace.customColor
            pinned = workspace.isPinned
            group = workspace.groupId
        }
    }

    @MainActor
    private final class PerformFixture {
        struct ColorWrite: Equatable { let workspaceId: UUID; let hex: String }
        struct Move: Equatable { let dragged: UUID; let target: UUID; let before: Bool; let members: [UUID] }
        let source = Workspace(), previous = Workspace(), unrelated = Workspace()
        let list: WorkspaceStatusList
        var all: [Workspace] { [source, previous, unrelated] }
        var resolutions: [String] = [], colors: [ColorWrite] = [], moves: [Move] = []
        var writesBeforeMove: [Int] = []

        init(trailingOrdinary: Bool) {
            var entries: [WorkspaceStatusEntry] = [.init(id: "next", name: "Next", extends: .todo, color: "#111111")]
            if !trailingOrdinary { entries.append(.init(id: "parked", name: "Parked", extends: .todo, color: "#555555")) }
            list = .init(entries: entries, source: .file)
            source.hideTaskStatus(); source.setCustomColor("#ABCDEF")
            unrelated.hideTaskStatus(); unrelated.setCustomColor("#AABBCC")
            previous.setOwnStatus(list.entry(id: "next")!, list: list)
            previous.setCustomColor("#111111")
        }

        func projection() -> WorkspaceStatusGroupProjection? {
            VerticalTabsSidebar.statusGroupProjection(
                items: VerticalTabsSidebar.statusGroupProjectionItems(tabs: all, list: list, groups: []), list: list,
                colorHexes: ["next": "#111111", "parked": "#555555"], controlsEnabled: true, workspaceGroups: [])
        }

        func performer() -> StatusGroupDropPerformer {
            let actions = WorkspaceStatusActions(list: list, origin: .mac, controlsEnabled: true,
                resolveColor: { [self] color in
                    resolutions.append(color)
                    return ["#111111": "#111111", "#555555": "#555555"][color]
                }, writeColor: { [self] hex, workspace in
                    colors.append(.init(workspaceId: workspace.id, hex: hex))
                    workspace.setCustomColor(hex)
                })
            return .init(statusActions: actions, currentProjection: { [self] in projection() },
                reorder: { [self] dragged, target, before, members in
                    writesBeforeMove.append(colors.count)
                    moves.append(.init(dragged: dragged, target: target, before: before, members: members))
                    return true
                })
        }
    }
}
#endif
