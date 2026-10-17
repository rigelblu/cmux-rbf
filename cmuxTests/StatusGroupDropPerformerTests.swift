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
struct StatusGroupDropPerformerTests {
    private typealias Plan = SidebarStatusGroupWorkspaceDropPlan
    private typealias Kind = SidebarStatusGroupDropRules.SourceKind
    private struct Held: Equatable {
        let own: String?, cmux: WorkspaceTaskStatus?, hidden: Bool, color: String?, pinned: Bool, group: UUID?
        @MainActor init(_ workspace: Workspace) {
            own = workspace.todoState.ownStatus?.id; cmux = workspace.todoState.statusOverride?.status
            hidden = workspace.todoState.statusHidden; color = workspace.customColor
            pinned = workspace.isPinned; group = workspace.groupId
        }
    }
    private struct Move: Equatable { let dragged: UUID, target: UUID, before: Bool, members: [UUID] }
    @MainActor
    private final class Fixture {
        let dragged = Workspace(), selectedOther = Workspace(), a = Workspace(), b = Workspace()
        var all: [Workspace]
        var list: WorkspaceStatusList
        var controls = true, noProjection = false
        var origin: WorkspaceStatusOrigin = .mac
        var resolutions: [String] = [], colors: [(UUID, String)] = [], moves: [Move] = []
        var writesBeforeMove: [Int] = []
        init() {
            list = .init(entries: [
                .init(id: "parked", name: "Parked", extends: .todo, color: "5: PARKED"),
                .init(id: "next", name: "Next", extends: .working, color: "1: NEXT"),
                .init(id: "done", name: "Done", color: "2: DONE")
            ], source: .file)
            all = [selectedOther, dragged, a, b]
            dragged.hideTaskStatus(); dragged.setCustomColor("#ABCDEF")
            selectedOther.hideTaskStatus(); selectedOther.setCustomColor("#AABBCC")
            for member in [a, b] {
                member.setOwnStatus(list.entry(id: "parked")!, list: list)
                member.setCustomColor("#555555")
            }
        }
        func projection() -> WorkspaceStatusGroupProjection? {
            guard !noProjection else { return nil }
            return VerticalTabsSidebar.statusGroupProjection(
                items: VerticalTabsSidebar.statusGroupProjectionItems(tabs: all, list: list), list: list,
                colorHexes: ["parked": "#555555", "next": "#111111", "done": "#222222"], controlsEnabled: controls)
        }
        func performer() -> StatusGroupDropPerformer {
            let actions = WorkspaceStatusActions(list: list, origin: origin, controlsEnabled: controls,
                resolveColor: { [self] color in
                    resolutions.append(color)
                    return ["5: PARKED": "#555555", "1: NEXT": "#111111", "2: DONE": "#222222"][color]
                }, writeColor: { [self] hex, workspace in
                    colors.append((workspace.id, hex)); workspace.setCustomColor(hex)
                })
            return .init(statusActions: actions, currentProjection: { [self] in projection() },
                reorder: { [self] source, target, before, ids in
                    writesBeforeMove.append(colors.count)
                    moves.append(.init(dragged: source, target: target, before: before, members: ids))
                    return true
                })
        }
        func plan(status: String = "parked", placement: Plan.Placement? = nil, writes: Bool = true) -> Plan {
            let placement = placement ?? .member(b.id, insertBefore: false)
            let indicator: SidebarDropIndicator
            switch placement {
            case .first: indicator = .init(tabId: SidebarStatusHeaderIdentity.uuid(forStatusId: status), edge: .bottom)
            case .member(let id, let before): indicator = .init(tabId: id, edge: before ? .top : .bottom)
            }
            return .init(statusId: status, placement: placement, setsStatus: writes, indicator: indicator)
        }
    }

    @Test(arguments: [false, true], [WorkspaceStatusList.Source.file, .stored])
    private func oneSharedWriteTouchesOnlyTheDraggedWorkspaceThenUsesFreshMembers(_ before: Bool, _ source: WorkspaceStatusList.Source) throws {
        let f = Fixture()
        f.list = .init(entries: f.list.entries, source: source)
        let selectedBefore = Held(f.selectedOther), aBefore = Held(f.a), bBefore = Held(f.b)
        try #require(f.projection()?.group(for: "parked")?.memberWorkspaceIds == [f.a.id, f.b.id])
        #expect(f.performer().perform(f.plan(placement: .member(f.b.id, insertBefore: before)), dragged: f.dragged, sourceKind: .workspace))
        #expect(f.dragged.todoState.ownStatus?.id == "parked")
        #expect(!f.dragged.todoState.statusHidden)
        #expect(f.resolutions == ["5: PARKED"])
        #expect(f.colors.count == 1 && f.colors.first?.0 == f.dragged.id && f.colors.first?.1 == "#555555")
        #expect(f.moves == [.init(dragged: f.dragged.id, target: f.b.id, before: before, members: [f.dragged.id, f.a.id, f.b.id])])
        #expect(f.writesBeforeMove == [1])
        #expect(Held(f.selectedOther) == selectedBefore && Held(f.a) == aBefore && Held(f.b) == bBefore)
    }

    enum FixedSource: CaseIterable, Sendable { case pinned, grouped, pinnedAndGrouped }
    @Test(arguments: FixedSource.allCases)
    func aPinnedOrGroupedWorkspaceTakesStatusAndColorWithoutStructuralMovement(_ role: FixedSource) {
        let f = Fixture()
        f.dragged.isPinned = role != .grouped
        f.dragged.groupId = role == .pinned ? nil : UUID()
        let pin = f.dragged.isPinned, group = f.dragged.groupId
        #expect(f.performer().perform(f.plan(), dragged: f.dragged, sourceKind: .workspace))
        #expect(f.dragged.todoState.ownStatus?.id == "parked")
        #expect(f.resolutions == ["5: PARKED"] && f.colors.count == 1)
        #expect(f.moves.isEmpty)
        #expect(f.dragged.isPinned == pin && f.dragged.groupId == group)
    }

    @Test(arguments: [false, true])
    func authoritativeMembershipIncludingColorOnlyPerformsNoStatusOrColorWrite(_ colorOnly: Bool) throws {
        let f = Fixture()
        if !colorOnly { f.dragged.setOwnStatus(f.list.entry(id: "parked")!, list: f.list) }
        f.dragged.setCustomColor("#555555")
        let before = Held(f.dragged)
        try #require(f.projection()?.group(for: "parked")?.memberWorkspaceIds.contains(f.dragged.id) == true)
        #expect(f.performer().perform(f.plan(writes: false), dragged: f.dragged, sourceKind: .workspace))
        #expect(f.resolutions.isEmpty && f.colors.isEmpty)
        #expect(f.moves == [.init(dragged: f.dragged.id, target: f.b.id, before: false, members: [f.dragged.id, f.a.id, f.b.id])])
        #expect(Held(f.dragged) == before)
    }

    @Test func membershipThatChangedToTheTargetAfterHoverStillAvoidsAStatusWrite() throws {
        let f = Fixture()
        let acceptedWhileOutside = f.plan()
        f.dragged.setCustomColor("#555555")
        try #require(f.projection()?.contains(workspaceId: f.dragged.id) == true)
        let before = Held(f.dragged)
        #expect(f.performer().perform(acceptedWhileOutside, dragged: f.dragged, sourceKind: .workspace))
        #expect(f.colors.isEmpty && f.resolutions.isEmpty)
        #expect(Held(f.dragged) == before)
        #expect(f.moves.count == 1)
    }

    enum Refusal: CaseIterable, Sendable {
        case controlsOff, removedCustomStatus, removedBaseDone, fallbackList, emptyList, noCurrentGroup,
             closedMemberAnchor, movedMemberAnchor, workspaceGroupHeader, unknownSourceKind, ownMembershipChanged
    }
    @Test(arguments: Refusal.allCases)
    func staleOrRefusedAdmissionMakesNoPartialStatusColorOrPlacementWrite(_ reason: Refusal) throws {
        let f = Fixture()
        try #require(f.list.entry(id: "parked") != nil)
        try #require(f.projection()?.group(for: "parked")?.memberWorkspaceIds.contains(f.b.id) == true)
        var plan = f.plan(), kind = Kind.workspace
        switch reason {
        case .controlsOff: f.controls = false
        case .removedCustomStatus:
            f.list = .init(entries: f.list.entries.filter { $0.id != "parked" }, source: .file)
        case .removedBaseDone:
            try #require(f.list.entry(id: "done") != nil && f.projection()?.group(for: "done") != nil)
            plan = f.plan(status: "done", placement: .first)
            f.list = .init(entries: f.list.entries.filter { $0.id != "done" }, source: .file)
        case .fallbackList: f.list = .cmuxFive
        case .emptyList: f.list = .init(entries: [], source: .file)
        case .noCurrentGroup: f.noProjection = true
        case .closedMemberAnchor: f.all.removeAll { $0.id == f.b.id }
        case .movedMemberAnchor: f.b.setOwnStatus(f.list.entry(id: "next")!, list: f.list)
        case .workspaceGroupHeader: kind = .workspaceGroupHeader(groupId: UUID())
        case .unknownSourceKind: kind = .unknown
        case .ownMembershipChanged:
            f.dragged.setOwnStatus(f.list.entry(id: "parked")!, list: f.list)
            try #require(f.projection()?.group(for: "parked")?.memberWorkspaceIds == [f.dragged.id, f.a.id, f.b.id])
            plan = f.plan(writes: false)
            f.dragged.setOwnStatus(f.list.entry(id: "next")!, list: f.list)
        }
        let before = f.all.map(Held.init)
        #expect(!f.performer().perform(plan, dragged: f.dragged, sourceKind: kind))
        #expect(f.all.map(Held.init) == before)
        #expect(f.resolutions.isEmpty && f.colors.isEmpty && f.moves.isEmpty)
    }

    @Test(arguments: [false, true])
    func headerInsertionResolvesItsCurrentFirstMemberRatherThanACachedClosedMember(_ empty: Bool) {
        let f = Fixture()
        f.all.removeAll { $0.id == f.a.id || (empty && $0.id == f.b.id) }
        #expect(f.performer().perform(f.plan(placement: .first), dragged: f.dragged, sourceKind: .workspace))
        #expect(f.dragged.todoState.ownStatus?.id == "parked")
        #expect(f.colors.count == 1)
        if empty { #expect(f.moves.isEmpty) }
        else { #expect(f.moves == [.init(dragged: f.dragged.id, target: f.b.id, before: true, members: [f.dragged.id, f.b.id])]) }
    }

    @Test func aFoldedTargetKeepsItsFoldAndTheNewMemberIsActuallyHidden() throws {
        let f = Fixture()
        let folds = WorkspaceStatusGroupsState(collapsedStatusIds: ["parked"])
        #expect(f.performer().perform(f.plan(placement: .first), dragged: f.dragged, sourceKind: .workspace))
        let projection = try #require(f.projection())
        let result = VerticalTabsSidebar.resolveRenderItems(
            colorSectionProjection: .project(workspaces: [], paletteEntries: [], collapsedHexes: []),
            baseItems: f.all.map { .workspace(workspaceId: $0.id) }, statusGroupProjection: projection, folds: folds)
        #expect(folds.collapsedStatusIds == ["parked"])
        #expect(result.items.contains { if case .statusGroupHeader(statusId: "parked") = $0 { return true }; return false })
        #expect(!result.items.contains { if case .workspace(let id) = $0 { return id == f.dragged.id }; return false })
    }

    @Test func aListedCmuxBaseIdUsesTheSharedOverrideAndItsColor() {
        let f = Fixture()
        #expect(f.performer().perform(f.plan(status: "done", placement: .first), dragged: f.dragged, sourceKind: .workspace))
        #expect(f.dragged.todoState.statusOverride?.status == .done && f.dragged.todoState.ownStatus == nil)
        #expect(f.resolutions == ["2: DONE"] && f.colors.count == 1 && f.colors.first?.1 == "#222222")
        #expect(f.moves.isEmpty) // The header was empty: after the shared set it has only the dragged workspace.
    }

    @Test func aPhoneOriginStillUsesTheSharedActionsNoColorPolicy() {
        let f = Fixture(); f.origin = .phone
        let colorBefore = f.dragged.customColor
        #expect(f.performer().perform(f.plan(), dragged: f.dragged, sourceKind: .workspace))
        #expect(f.dragged.todoState.ownStatus?.id == "parked")
        #expect(f.dragged.customColor == colorBefore && f.resolutions.isEmpty && f.colors.isEmpty)
        #expect(f.moves.count == 1)
    }
}
