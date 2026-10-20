import CmuxFoundation
import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct StatusAreaDropPerformerTests {
    enum Role: CaseIterable, Sendable { case loose, alreadyLastLoose, groupedMember, groupHeader, emptyHeader, selectedHeaders }
    private typealias Kind = SidebarStatusGroupDropRules.SourceKind
    private struct Held: Equatable {
        let own: String?, cmux: WorkspaceTaskStatus?, hidden: Bool, color: String?, pinned: Bool
        @MainActor init(_ w: Workspace) {
            own = w.todoState.ownStatus?.id; cmux = w.todoState.statusOverride?.status
            hidden = w.todoState.statusHidden; color = w.customColor; pinned = w.isPinned
        }
    }

    @Test(arguments: Role.allCases)
    func anExplicitBelowDropActuallyRendersTheMovedBlockAfterTheAreaAndSavesThatPlace(_ role: Role) throws {
        let f = Fixture(role)
        let otherOrder = f.unmovedIds
        let groupValues = Dictionary(uniqueKeysWithValues: f.groups.map { ($0.id, $0) })
        let original = try #require(f.state.statusGroups)
        if role == .alreadyLastLoose {
            try #require(original.last == true && original.aboveRow == f.movingOwnerKeys.first)
        }
        try #require(f.sourceRows.allSatisfy { row in f.index(row) >= 0 && f.index(row) < f.index(.statusesArea()) })
        let plan = f.plan(.belowAll)
        #expect(f.performer().perform(plan, workspaceId: f.sourceId, sourceKind: f.kind))
        #expect(f.moves == [plan.move])
        #expect(f.heldById == f.originalHeld)
        #expect(Dictionary(uniqueKeysWithValues: f.groups.map { ($0.id, $0) }) == groupValues)
        #expect(f.unmovedIds == otherOrder)
        let rows = f.rendered()
        let lastStatusMember = try #require(rows.firstIndex { $0.id == .workspace(f.statusMember.id) })
        for row in f.sourceRows { #expect(f.index(row) > lastStatusMember) }
        let record = try #require(f.state.statusGroups)
        #expect(record.last == false)
        #expect(record.belowRow == f.movingOwnerKeys.first)
        #expect(record.order == original.order && record.collapsedStatusIds == original.collapsedStatusIds && record.areaCollapsed == original.areaCollapsed)
        let saved = try #require(SidebarStatusAreaLayout(items: rows, tabs: f.tabs, groups: f.groups, statusProjection: f.projection()).saving(state: record))
        #expect(saved.last == false && saved.belowRow == record.belowRow)
        let snapshot = SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 300, statusGroups: saved)
        let restored = try JSONDecoder().decode(SessionSidebarSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(restored.statusGroups == saved)
    }

    @Test(arguments: [Role.groupHeader, .emptyHeader, .selectedHeaders])
    func aWorkspaceGroupHeaderOnStatusesLandsAboveTheWholeAreaWithoutStatusOrColorWrites(_ role: Role) throws {
        let f = Fixture(role), original = f.state.statusGroups
        let otherOrder = f.unmovedIds
        let groupValues = Dictionary(uniqueKeysWithValues: f.groups.map { ($0.id, $0) })
        let plan = f.plan(.aboveArea)
        #expect(f.performer().perform(plan, workspaceId: f.sourceId, sourceKind: f.kind))
        #expect(f.moves == [plan.move])
        #expect(f.heldById == f.originalHeld && f.unmovedIds == otherOrder)
        #expect(Dictionary(uniqueKeysWithValues: f.groups.map { ($0.id, $0) }) == groupValues)
        for row in f.sourceRows { #expect(f.index(row) >= 0 && f.index(row) < f.index(.statusesArea())) }
        #expect(f.state.statusGroups?.aboveRow == f.movingOwnerKeys.last)
        #expect(f.state.statusGroups?.order == original?.order && f.state.statusGroups?.collapsedStatusIds == original?.collapsedStatusIds)
    }

    @Test(arguments: [false, true])
    func leavingAWorkspaceGroupProjectsTheUnchangedExistingStatusOrColorRatherThanForcingLoosePlacement(_ colorOnly: Bool) throws {
        let f = Fixture(.groupedMember)
        if colorOnly { f.source.setCustomColor("#555555") }
        else { f.source.setOwnStatus(f.list.entry(id: "parked")!, list: f.list) }
        let held = Held(f.source), record = f.state.statusGroups
        try #require(f.projection()?.contains(workspaceId: f.source.id) == false)
        #expect(f.performer().perform(f.plan(.belowAll), workspaceId: f.sourceId, sourceKind: f.kind))
        #expect(f.source.groupId == nil)
        #expect(Held(f.source) == held)
        #expect(f.projection()?.group(for: "parked")?.memberWorkspaceIds.contains(f.source.id) == true)
        #expect(f.state.statusGroups == record)
        #expect(f.moves.count == 1)
    }

    enum Refusal: CaseIterable, Sendable { case noArea, closedSource, statusMember, plainColorMember, unknownKind, workspaceOnStatuses, removedHeaderGroup }
    @Test(arguments: Refusal.allCases)
    func anInvalidBoundaryPerformsNoOrdinaryMoveAndKeepsTheExistingRecord(_ refusal: Refusal) throws {
        let f = Fixture(refusal == .removedHeaderGroup ? .groupHeader : .loose)
        try #require(f.rendered().contains { $0.id == .statusesArea() })
        var kind = f.kind
        var goal = SidebarStatusGroupDropRules.AreaBoundary.belowAll
        switch refusal {
        case .noArea: f.controls = false
        case .closedSource: f.tabs.removeAll { $0.id == f.sourceId }
        case .statusMember: f.source.setOwnStatus(f.list.entry(id: "parked")!, list: f.list)
        case .plainColorMember: f.source.setCustomColor("#119933")
        case .unknownKind: kind = .unknown
        case .workspaceOnStatuses: goal = .aboveArea
        case .removedHeaderGroup: f.groups.removeAll { $0.id == f.g1 }
        }
        let ids = f.tabs.map(\.id), held = f.heldById, record = f.state.statusGroups
        #expect(!f.performer().perform(f.plan(goal), workspaceId: f.sourceId, sourceKind: kind))
        #expect(f.moves.isEmpty && f.tabs.map(\.id) == ids && f.heldById == held)
        #expect(f.state.statusGroups == record)
    }

    @MainActor
    private final class Fixture {
        let role: Role
        let loose = Workspace(), other = Workspace(), anchor = Workspace(), member = Workspace()
        let anchorB = Workspace(), memberB = Workspace(), statusMember = Workspace()
        let g1 = UUID(), g2 = UUID()
        let state = SidebarState(statusGroups: .init(collapsedStatusIds: ["not-listed"], order: ["parked", "not-listed"], last: true))
        let list = WorkspaceStatusList(entries: [.init(id: "parked", name: "Parked", extends: .todo, color: "5: PARKED")], source: .file)
        var tabs: [Workspace] = [], groups: [WorkspaceGroup] = []
        var controls = true
        var moves: [SidebarStatusAreaBoundaryDropPlan.Move] = []
        var originalHeld: [UUID: Held] = [:]
        var source: Workspace { role == .groupedMember ? member : (role == .groupHeader || role == .selectedHeaders ? anchor : loose) }
        var sourceId: UUID { role == .emptyHeader ? g1 : source.id }
        var kind: Kind { role == .groupHeader || role == .emptyHeader || role == .selectedHeaders ? .workspaceGroupHeader(groupId: g1) : .workspace }
        var movingGroups: [UUID] { role == .selectedHeaders ? [g1, g2] : (role == .groupHeader || role == .emptyHeader ? [g1] : []) }
        var movingOwnerKeys: [String] { movingGroups.isEmpty ? ["workspace:\(source.id.uuidString)"] : movingGroups.map { "group:\($0.uuidString)" } }
        var sourceRows: [SidebarWorkspaceRenderItemID] { movingGroups.isEmpty ? [.workspace(source.id)] : movingGroups.map { .group($0) } }
        var heldById: [UUID: Held] { Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, Held($0)) }) }
        var unmovedIds: [UUID] {
            let selected = movingGroups, sourceId = source.id
            return tabs.filter { w in selected.isEmpty ? w.id != sourceId : w.groupId.map(selected.contains) != true }.map(\.id)
        }
        init(_ role: Role) {
            self.role = role
            for w in [loose, other, anchor, member, anchorB, memberB] { w.hideTaskStatus() }
            statusMember.setOwnStatus(list.entry(id: "parked")!, list: list); statusMember.setCustomColor("#555555")
            switch role {
            case .loose: tabs = [loose, other, statusMember]
            case .alreadyLastLoose: tabs = [other, statusMember, loose]
            case .emptyHeader:
                tabs = [other, statusMember]
                groups = [.init(id: g1, name: "Empty", isCollapsed: false, isPinned: false, anchor: .empty(g1), customColor: nil, iconSymbol: nil)]
            case .groupedMember, .groupHeader, .selectedHeaders:
                anchor.groupId = g1; member.groupId = g1
                groups = [.init(id: g1, name: "Group", isCollapsed: false, isPinned: false, anchorWorkspaceId: anchor.id, customColor: nil, iconSymbol: nil)]
                tabs = [anchor, member, other, statusMember]
                if role == .selectedHeaders {
                    anchorB.groupId = g2; memberB.groupId = g2
                    groups.append(.init(id: g2, name: "Other Group", isCollapsed: false, isPinned: false, anchorWorkspaceId: anchorB.id, customColor: nil, iconSymbol: nil))
                    tabs += [anchorB, memberB]
                }
            }
            originalHeld = heldById
            if role == .alreadyLastLoose {
                let layout = SidebarStatusAreaLayout(items: rendered(), tabs: tabs, groups: groups, statusProjection: projection())
                state.setStatusGroups(layout.saving(state: state.statusGroups))
            }
        }
        func projection() -> WorkspaceStatusGroupProjection? {
            VerticalTabsSidebar.statusGroupProjection(items: VerticalTabsSidebar.statusGroupProjectionItems(tabs: tabs, list: list, groups: []),
                list: list, colorHexes: ["parked": "#555555"], controlsEnabled: controls, storedOrder: state.statusGroups?.order, workspaceGroups: [])
        }
        func rendered() -> [SidebarWorkspaceRenderItem] {
            let projection = projection()
            let base = SidebarWorkspaceRenderItem.renderItems(tabs: tabs, groupsById: Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) }), orderedGroups: groups)
            let color = VerticalTabsSidebar.colorSectionProjection(workspaces: tabs.map { .init(id: $0.id, groupId: $0.groupId, isPinned: $0.isPinned, customColor: $0.customColor) },
                collapsedHexes: [], statusGroupProjection: projection, colorHexes: ["parked": "#555555"], paletteEntries: [.init(name: "Plain", hex: "#119933")])
            return VerticalTabsSidebar.resolveRenderItems(colorSectionProjection: color, baseItems: base, statusGroupProjection: projection,
                folds: state.statusGroups ?? .init(), tabs: tabs, groups: groups).items
        }
        func index(_ id: SidebarWorkspaceRenderItemID) -> Int { rendered().firstIndex { $0.id == id } ?? -1 }
        func plan(_ boundary: SidebarStatusGroupDropRules.AreaBoundary) -> SidebarStatusAreaBoundaryDropPlan {
            .init(boundary: boundary, move: role == .emptyHeader ? .group(targetIndex: groups.count - 1) : .workspaces(targetIndex: tabs.count, usesTopLevelRows: true, explicitGroupId: nil))
        }
        func performer() -> StatusAreaDropPerformer {
            .init(state: state, movingGroupIds: movingGroups, currentTabs: { [self] in tabs }, currentGroups: { [self] in groups },
                currentProjection: { [self] in projection() }, currentRenderItems: { [self] in rendered() }, performOrdinary: { [self] move in
                    moves.append(move)
                    let old = tabs.map(\.id)
                    let selected = self.movingGroups, dragged = self.source
                    if !selected.isEmpty {
                        let moved = tabs.filter { $0.groupId.map(selected.contains) == true }
                        tabs.removeAll { $0.groupId.map(selected.contains) == true }; tabs += moved
                        let movedGroups = groups.filter { selected.contains($0.id) }
                        groups.removeAll { selected.contains($0.id) }; groups += movedGroups
                    } else {
                        dragged.groupId = nil
                        tabs.removeAll { $0.id == dragged.id }; tabs.append(dragged)
                    }
                    return old != tabs.map(\.id)
                })
        }
    }
}
