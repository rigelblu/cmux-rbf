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

@MainActor
@Suite("Workspace group header status drops", .serialized)
struct SidebarWorkspaceGroupStatusHeaderDropTests {
    private typealias F = SidebarNestedStatusDropFixture

    private func fixture(sourceAfter: Bool = false) throws -> (F, UUID) {
        let f = try F(scene: .f2b, role: .colorOnlyOwn)
        f.projectsWorkspaceGroups = true
        let group = try #require(f.manager.createWorkspaceGroup(name: "Dragged", childWorkspaceIds: [f.w("u").id]))
        let anchor = try #require(f.manager.workspaceGroupAnchor(for: group))
        let parent = try #require(f.manager.createWorkspaceGroup(name: "Nested source parent", childWorkspaceIds: [f.w("color").id]))
        _ = f.manager.moveWorkspaceGroup(groupId: f.q, intoParent: parent)
        let parentAnchor = try #require(f.manager.workspaceGroupAnchor(for: parent))
        let p = try #require(f.manager.workspaceGroups.firstIndex { $0.id == f.p })
        f.manager.workspaceGroups[p].statusId = "parked"
        f.manager.workspaceGroups[p].customColor = "#555555"
        let source = [anchor, f.w("u")]
        let middle = [parentAnchor, f.w("color"), f.w("qAnchor"), f.w("qa"), f.w("l1"), f.w("c1"),
                      f.w("pAnchor"), f.w("pa"), f.w("c2"), f.w("c3")]
        f.manager.tabs = [f.w("pinA"), f.w("pinB")] + (sourceAfter ? middle + source : source + middle)
            + [f.w("n1"), f.w("n2")]
        return (f, group)
    }

    private func target(_ f: F, native: Bool, id: UUID, edge: SidebarDropEdge = .top,
                        right: Bool = false) throws -> (CGPoint, [SidebarWorkspaceReorderDropOverlay.Target]) {
        let targets = f.targets(native ? .native : .swiftUI)
        let measured = try #require(targets.first { $0.workspaceId == id })
        let frame = measured.statusContentFrame ?? measured.frame
        return (.init(x: right ? 180 : 60, y: edge == .top ? frame.minY : frame.maxY), targets)
    }

    private func statusPlan(_ f: F, at point: CGPoint, targets: [SidebarWorkspaceReorderDropOverlay.Target]) throws
        -> (SidebarWorkspaceReorderDropPlan, SidebarStatusGroupWorkspaceDropPlan) {
        let plan = try #require(try f.route(point: point, targets: targets))
        guard case .statusGroupDrop(let value, _) = plan.action else {
            Issue.record("A header must get status placement, never cm-106's nesting/join action")
            throw HeaderPlanError.wrongAction
        }
        return (plan, value)
    }
    private enum HeaderPlanError: Error { case wrongAction }

    @Test(arguments: [false, true], SidebarDebugHeaderDrop.Side.allCases)
    func debugHeaderLastEdgesUseTheSameCellBoundsAsStatusAdmission(_ native: Bool, _ side: SidebarDebugHeaderDrop.Side) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let (f, group) = try fixture(); defer { f.close() }
            try makeUnblocked(f)
            await f.applyRows(); try f.begin(row: .group(group))
            let targets = f.targets(native ? .native : .swiftUI)
            let source = try #require(f.manager.workspaceGroupAnchor(for: group)).id
            let last = f.w("c3").id
            let frames = VerticalTabsSidebar.workspaceStatusDebugPointFrames(sourceId: source, sourceRowId: .group(group),
                targetId: last, targetRowId: .workspace(last), items: f.rendered(), projection: f.projection(), targets: targets)
            let point = try #require(SidebarDebugHeaderDrop.point(targetId: last, zone: .bottomEdge, side: side,
                targets: targets, renderItemId: .workspace(last), pointFrames: frames))
            let (_, value) = try statusPlan(f, at: point, targets: targets)
            #expect(value.statusId == "parked")
            #expect(value.indicator == .init(tabId: last, edge: .bottom))
            let physical = try #require(targets.first { $0.workspaceId == last })
            #expect(point.y == (physical.statusContentFrame ?? physical.frame).maxY)
        }
    }

    @Test(arguments: [false, true])
    func selectedHeadersPlanOnlyTheDraggedGroup(_ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let (f, group) = try fixture(); defer { f.close() }
            let anchor = try #require(f.manager.workspaceGroupAnchor(for: group))
            f.selected = [anchor.id, f.w("pAnchor").id]
            await f.applyRows(); try f.begin(row: .group(group))
            let (point, targets) = try target(f, native: native, id: SidebarStatusHeaderIdentity.uuid(forStatusId: "parked"))
            let (plan, value) = try statusPlan(f, at: point, targets: targets)
            #expect(plan.draggedWorkspaceId == anchor.id)
            #expect(value.statusId == "parked" && value.setsStatus)
            #expect(plan.indicator == .init(tabId: SidebarStatusHeaderIdentity.uuid(forStatusId: "parked"), edge: .bottom))
        }
    }

    @Test(arguments: [false, true], [false, true])
    func memberBottomRightNeverDrawsTheWorkspaceJoinLine(_ native: Bool, _ sourceAfter: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let (f, group) = try fixture(sourceAfter: sourceAfter); defer { f.close() }
            await f.applyRows(); try f.begin(row: .group(group))
            let (point, targets) = try target(f, native: native, id: f.w("pa").id, edge: .bottom, right: true)
            let (plan, value) = try statusPlan(f, at: point, targets: targets)
            #expect(value.statusId == "parked")
            #expect(plan.indicator == .init(tabId: sourceAfter ? f.w("c2").id : f.w("pAnchor").id, edge: .top))
            #expect(plan.indicator != .init(tabId: f.w("pa").id, edge: .bottom))
            #expect(VerticalTabsSidebar.workspaceProjectedStatusDropLineLevel(for: plan,
                depthById: f.depths(), projection: f.projection()) == 2)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func nestedAndPinnedHeadersUseStatusOnlyLinesAmongLooseRows(_ native: Bool, _ pinned: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let (f, group) = try fixture(); defer { f.close() }
            let source = pinned ? group : f.q
            if pinned {
                let index = try #require(f.manager.workspaceGroups.firstIndex { $0.id == group })
                f.manager.workspaceGroups[index].isPinned = true
            }
            if !pinned {
                let parent = try #require(f.manager.workspaceGroups.first { $0.id == f.q }?.parentGroupId)
                let index = try #require(f.manager.workspaceGroups.firstIndex { $0.id == parent })
                f.manager.workspaceGroups[index].statusId = "parked"
            }
            await f.applyRows(); try f.begin(row: .group(source))
            let (point, targets) = try target(f, native: native, id: f.w("c3").id)
            let (plan, value) = try statusPlan(f, at: point, targets: targets)
            #expect(value.setsStatus) // Q inherits its parent's Parked placement, but its own stored status is nil.
            #expect(plan.indicator == .init(tabId: f.w("c3").id, edge: .top))
        }
    }

    @Test(arguments: [false, true], [false, true])
    func stationaryHeadersUseTheWholeBlockLineOnMemberBottomRight(_ native: Bool, _ pinned: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let (f, group) = try fixture(); defer { f.close() }
            let source = pinned ? group : f.q
            if pinned {
                let index = try #require(f.manager.workspaceGroups.firstIndex { $0.id == group })
                f.manager.workspaceGroups[index].isPinned = true
            }
            await f.applyRows(); try f.begin(row: .group(source))
            let (point, targets) = try target(f, native: native, id: f.w("pa").id, edge: .bottom, right: true)
            let (plan, _) = try statusPlan(f, at: point, targets: targets)
            // Both sources precede the target P block; ruling (12) paints above its whole run.
            #expect(plan.indicator == .init(tabId: f.w("pAnchor").id, edge: .top))
        }
    }

    @Test(arguments: [false, true])
    func foldedHeaderKeepsItsBottomLineWhenFirstIsBlocked(_ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let (f, group) = try fixture(sourceAfter: true); defer { f.close() }
            var folds = try #require(f.state.statusGroups); folds.collapsedStatusIds.insert("parked")
            f.state.setStatusGroups(folds)
            await f.applyRows(); try f.begin(row: .group(group))
            let header = SidebarStatusHeaderIdentity.uuid(forStatusId: "parked")
            let (point, targets) = try target(f, native: native, id: header)
            let (plan, value) = try statusPlan(f, at: point, targets: targets)
            #expect(plan.indicator == .init(tabId: header, edge: .bottom))
            #expect(value.headerPlacement?.landing == .member(f.w("c2").id, insertBefore: true))
        }
    }

    @Test(arguments: [false, true])
    func ownStatusHeaderOnlyMovesAndNeverSetsTheStatusAgain(_ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let (f, group) = try fixture(sourceAfter: true); defer { f.close() }
            let index = try #require(f.manager.workspaceGroups.firstIndex { $0.id == group })
            f.manager.workspaceGroups[index].statusId = "parked"
            f.manager.workspaceGroups[index].customColor = "#555555"
            await f.applyRows(); try f.begin(row: .group(group))
            let (point, targets) = try target(f, native: native, id: SidebarStatusHeaderIdentity.uuid(forStatusId: "parked"))
            let (plan, value) = try statusPlan(f, at: point, targets: targets)
            #expect(!value.setsStatus)
            #expect(plan.indicator == .init(tabId: f.w("c2").id, edge: .top))
        }
    }

    @Test(arguments: [false, true], [false, true])
    func nestedHeaderOnItsProjectedParentOrOwnMemberPaintsAboveTheAncestor(_ native: Bool, _ ownMember: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let (f, _) = try fixture(); defer { f.close() }
            let parent = try #require(f.manager.workspaceGroups.first { $0.id == f.q }?.parentGroupId)
            let index = try #require(f.manager.workspaceGroups.firstIndex { $0.id == parent })
            f.manager.workspaceGroups[index].statusId = "parked"
            let anchor = try #require(f.manager.workspaceGroupAnchor(for: parent))
            await f.applyRows(); try f.begin(row: .group(f.q))
            let (point, targets) = try target(f, native: native, id: f.w(ownMember ? "qa" : "color").id,
                                               edge: .bottom, right: true)
            let (plan, value) = try statusPlan(f, at: point, targets: targets)
            #expect(value.statusId == "parked" && value.setsStatus)
            #expect(plan.indicator == .init(tabId: anchor.id, edge: .top))
        }
    }


    private func groupActions(_ f: F) -> WorkspaceGroupStatusUIActions {
        let actions = f.statusActions()
        return .init(tabManager: f.manager,
                     writer: .init(list: actions.list, resolveColor: actions.resolveColor), controlsEnabled: f.controls)
    }

    private func makeUnblocked(_ f: F) throws {
        try #require(groupActions(f).applyGroup(.hide, groupId: f.p))
    }

    private func eligibility(_ f: F) -> [UUID: Bool] {
        let result = WorkspaceShortcutEligibility.resolve(workspaces: f.manager.tabs,
            groups: f.manager.workspaceGroups, todoControlsEnabled: true)
        return Dictionary(uniqueKeysWithValues: f.manager.tabs.enumerated().map {
            ($0.element.id, result.position(forFlatIndex: $0.offset) != nil)
        })
    }

    @Test(arguments: [false, true])
    func dropAndClearKeepTheRunOutsideRowsMemberStatusesAndShortcutEligibility(_ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let (f, group) = try fixture(); defer { f.close() }
            try makeUnblocked(f)
            f.w("u").setOwnStatus(try #require(f.list.entry(id: "next")), list: f.list)
            f.w("u").setCustomColor("#111111")
            await f.applyRows()
            let before = f.manager.tabs.map(\.id), rowsBefore = f.rendered().map(\.id)
            let anchor = try #require(f.manager.workspaceGroupAnchor(for: group))
            let run = f.manager.tabs.filter { $0.groupId == group }.map(\.id)
            let statusIds = f.projection()?.allDisplayMemberWorkspaceIds ?? []
            let outside = before.filter { !statusIds.contains($0) && !run.contains($0) }
            let memberState = Dictionary(uniqueKeysWithValues: f.manager.tabs.map { ($0.id, F.Held($0)) })
            let eligibleBefore = eligibility(f)
            try f.begin(row: .group(group))
            let (point, targets) = try target(f, native: native, id: f.w("c3").id)
            let (plan, _) = try statusPlan(f, at: point, targets: targets)
            try #require(f.commit(plan))
            var expected = before.filter { $0 != f.w("c1").id && $0 != f.w("c2").id }
            expected.insert(contentsOf: [f.w("c1").id, f.w("c2").id], at: try #require(expected.firstIndex(of: anchor.id)))
            #expect(f.manager.tabs.map(\.id) == expected)
            let after = f.manager.tabs.map(\.id)
            #expect(after.filter { run.contains($0) } == run)
            #expect(after.filter { outside.contains($0) } == outside)
            for id in outside {
                #expect((try #require(before.firstIndex(of: anchor.id)) < before.firstIndex(of: id)!) ==
                        (try #require(after.firstIndex(of: anchor.id)) < after.firstIndex(of: id)!))
                #expect(eligibility(f)[id] == eligibleBefore[id])
            }
            #expect(Dictionary(uniqueKeysWithValues: f.manager.tabs.map { ($0.id, F.Held($0)) }) == memberState)
            #expect(f.manager.workspaceGroups.first { $0.id == group }?.statusId == "parked")
            #expect(f.manager.workspaceGroups.first { $0.id == group }?.customColor == "#555555")
            try #require(groupActions(f).applyGroup(.hide, groupId: group))
            #expect(f.rendered().map(\.id) == rowsBefore)
            #expect(f.manager.tabs.map(\.id) == expected)
            #expect(f.manager.workspaceGroups.first { $0.id == group }?.statusId == nil)
            #expect(f.manager.workspaceGroups.first { $0.id == group }?.customColor == nil)
            #expect(Dictionary(uniqueKeysWithValues: f.manager.tabs.map { ($0.id, F.Held($0)) }) == memberState)
            for id in outside { #expect(eligibility(f)[id] == eligibleBefore[id]) }
        }
    }

    @Test(arguments: [false, true])
    func reverseCommitPutsCrossingsAgainstTheRunInTheirExistingOrder(_ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let (f, group) = try fixture(sourceAfter: true); defer { f.close() }; try makeUnblocked(f)
            await f.applyRows(); let before = f.manager.tabs.map(\.id)
            try f.begin(row: .group(group))
            let (point, targets) = try target(f, native: native, id: SidebarStatusHeaderIdentity.uuid(forStatusId: "parked"))
            let (plan, _) = try statusPlan(f, at: point, targets: targets)
            try #require(f.commit(plan))
            let crossings = [f.w("c1").id, f.w("c2").id, f.w("c3").id]
            var expected = before.filter { !crossings.contains($0) }
            expected.insert(contentsOf: crossings, at: try #require(expected.firstIndex(of: f.w("u").id)) + 1)
            #expect(f.manager.tabs.map(\.id) == expected)
        }
    }

    enum StationarySource: CaseIterable, Sendable { case pinnedRoot, nested, nestedInPinnedParent }

    private func stationarySource(_ f: F, group: UUID, role: StationarySource) throws -> UUID {
        if role == .pinnedRoot {
            f.manager.setWorkspaceGroupPinned(groupId: group, isPinned: true)
            return group
        }
        let parent = try #require(f.manager.workspaceGroups.first { $0.id == f.q }?.parentGroupId)
        try #require(groupActions(f).applyGroup(.status(id: "parked"), groupId: parent))
        if role == .nestedInPinnedParent {
            f.manager.setWorkspaceGroupPinned(groupId: parent, isPinned: true)
            try #require(f.manager.workspaceGroups.first { $0.id == parent }?.isPinned == true)
            try #require(f.manager.workspaceGroups.first { $0.id == f.q }?.isPinned == false)
        }
        return f.q
    }

    @Test(arguments: [false, true], StationarySource.allCases)
    func nestedAndPinnedCommitSetOnlyTheGroupsOwnStatus(_ native: Bool, _ role: StationarySource) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let (f, group) = try fixture(); defer { f.close() }
            let source = try stationarySource(f, group: group, role: role)
            await f.applyRows()
            let before = f.manager.tabs.map(\.id), groups = f.manager.workspaceGroups
            let members = f.held
            try f.begin(row: .group(source))
            let (point, targets) = try target(f, native: native, id: f.w("c3").id)
            let (plan, _) = try statusPlan(f, at: point, targets: targets)
            try #require(f.commit(plan))
            #expect(f.manager.tabs.map(\.id) == before && f.held == members)
            let actual = try #require(f.manager.workspaceGroups.first { $0.id == source })
            let held = try #require(groups.first { $0.id == source })
            #expect(actual.statusId == "parked" && actual.customColor == "#555555")
            #expect(actual.parentGroupId == held.parentGroupId && actual.isPinned == held.isPinned)
            for held in groups where held.id != source { #expect(f.manager.workspaceGroups.first { $0.id == held.id } == held) }
        }
    }

    @Test(arguments: [false, true])
    func selectedHeaderCommitLeavesTheOtherSelectedGroupUntouched(_ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let (f, group) = try fixture(); defer { f.close() }
            let anchor = try #require(f.manager.workspaceGroupAnchor(for: group))
            f.selected = [anchor.id, f.w("pAnchor").id]
            let held = try #require(f.manager.workspaceGroups.first { $0.id == f.p })
            await f.applyRows(); try f.begin(row: .group(group))
            let (point, targets) = try target(f, native: native, id: SidebarStatusHeaderIdentity.uuid(forStatusId: "next"))
            let (plan, _) = try statusPlan(f, at: point, targets: targets)
            try #require(f.commit(plan))
            #expect(f.manager.workspaceGroups.first { $0.id == group }?.statusId == "next")
            #expect(f.manager.workspaceGroups.first { $0.id == f.p } == held)
        }
    }

    @Test(arguments: [false, true])
    func ownStatusCommitNeverReappliesItsColor(_ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let (f, group) = try fixture(sourceAfter: true); defer { f.close() }
            let index = try #require(f.manager.workspaceGroups.firstIndex { $0.id == group })
            f.manager.workspaceGroups[index].statusId = "parked"
            f.manager.workspaceGroups[index].customColor = "#123456"
            await f.applyRows(); try f.begin(row: .group(group))
            let (point, targets) = try target(f, native: native, id: SidebarStatusHeaderIdentity.uuid(forStatusId: "parked"))
            let (plan, _) = try statusPlan(f, at: point, targets: targets)
            f.resolutions.removeAll()
            try #require(f.commit(plan))
            #expect(f.resolutions.isEmpty)
            #expect(f.manager.workspaceGroups.first { $0.id == group }?.customColor == "#123456")
        }
    }

    @Test(arguments: [false, true])
    func aMembershipChangeBetweenHoverAndDropIsRefusedBeforeAnyWrite(_ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            // The fresh control proves rejection is not an unreachable or permanently refused commit path.
            do {
                let (f, group) = try fixture(); defer { f.close() }; try makeUnblocked(f)
                await f.applyRows(); try f.begin(row: .group(group))
                let (point, targets) = try target(f, native: native, id: f.w("c3").id)
                let (plan, _) = try statusPlan(f, at: point, targets: targets)
                try #require(f.commit(plan))
            }
            let (f, group) = try fixture(); defer { f.close() }; try makeUnblocked(f)
            await f.applyRows(); try f.begin(row: .group(group))
            let (point, targets) = try target(f, native: native, id: f.w("c3").id)
            let (plan, _) = try statusPlan(f, at: point, targets: targets)
            f.manager.setPinned(f.w("c1"), pinned: true)
            f.resolutions.removeAll()
            let before = f.manager.tabs.map(\.id), groups = f.manager.workspaceGroups
            #expect(!f.commit(plan))
            #expect(f.resolutions.isEmpty, "Fresh membership rejects before the group's status/color write")
            #expect(f.manager.tabs.map(\.id) == before)
            #expect(f.manager.workspaceGroups == groups)
        }
    }

    @Test(arguments: [false, true])
    func aDeadSourceAnchorBetweenHoverAndDropIsRefusedBeforeAnyWrite(_ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let (f, group) = try fixture(); defer { f.close() }; try makeUnblocked(f)
            await f.applyRows(); try f.begin(row: .group(group))
            let (point, targets) = try target(f, native: native, id: f.w("c3").id)
            let (plan, _) = try statusPlan(f, at: point, targets: targets)
            let index = try #require(f.manager.workspaceGroups.firstIndex { $0.id == group })
            let missing = UUID()
            f.manager.workspaceGroups[index].anchorWorkspaceId = missing
            try #require(!f.manager.tabs.contains { $0.id == missing })
            let before = f.manager.tabs.map(\.id), groups = f.manager.workspaceGroups, selected = f.manager.selectedTabId
            #expect(try f.route(point: point, targets: targets) == nil)
            #expect(!f.commit(plan))
            #expect(f.manager.tabs.map(\.id) == before && f.manager.workspaceGroups == groups)
            #expect(f.manager.selectedTabId == selected)
        }
    }

    @Test(arguments: [false, true])
    func aTargetBlockEndingInAnEmptyNestedHeaderPaintsThePromisedGap(_ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let (f, group) = try fixture(sourceAfter: true); defer { f.close() }
            _ = f.manager.moveWorkspaceGroup(groupId: f.q, intoParent: f.p)
            f.manager.selectTab(f.w("l1"))
            f.manager.setWorkspaceGroupPinned(groupId: f.q, isPinned: true)
            f.manager.closeWorkspace(f.w("qa"), recordHistory: false)
            f.manager.closeWorkspace(f.w("qAnchor"), recordHistory: false)
            f.manager.closeWorkspace(f.w("pa"), recordHistory: false)
            let empty = try #require(f.manager.workspaceGroups.first { $0.id == f.q })
            try #require(empty.isEmpty && empty.parentGroupId == f.p && empty.liveAnchorWorkspaceId == nil)
            for name in ["c2", "c3"] { f.w(name).hideTaskStatus(); f.w(name).setCustomColor(nil) }
            try #require(f.rendered().last?.id == .group(f.q), "The target status must actually end at the empty nested header")
            await f.applyRows(); try f.begin(row: .group(group))
            let (point, targets) = try target(f, native: native, id: f.w("pAnchor").id)
            let (plan, _) = try statusPlan(f, at: point, targets: targets)
            let items = f.rendered(), projection = try #require(f.projection())
            let header = try #require(items.first { $0.id == .group(f.q) }?.headerDropIdentity)
            #expect(plan.indicator == .init(tabId: header, edge: .bottom))
            let members = VerticalTabsSidebar.workspaceStatusDisplayDropMembers(statusId: "parked", projection: projection, items: items)
            let frames = Dictionary(uniqueKeysWithValues: targets.map { ($0.workspaceId, $0.statusContentFrame ?? $0.frame) })
            let gap = VerticalTabsSidebar.workspaceStatusDropGapFrame(statusId: "parked", draggedId: plan.draggedWorkspaceId,
                indicator: plan.indicator, items: items, memberWorkspaceIds: members, frames: frames, width: 240)
            #expect(gap != nil, "The admitted empty-tail indicator must draw in the real status painter")
            let tailFrame = try #require(frames[header])
            #expect(gap?.midY == tailFrame.maxY)
            try #require(f.commit(plan))
            #expect(f.manager.workspaceGroups.first { $0.id == group }?.statusId == "parked")
        }
    }

    @Test(arguments: [false, true])
    func aFailedSecondCrossingRestoresModelStateAfterTheFirstMoveAndStatusWrite(_ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let (f, group) = try fixture(); defer { f.close() }; try makeUnblocked(f)
            f.manager.selectedTabId = f.w("l1").id
            await f.applyRows(); try f.begin(row: .group(group))
            let (point, targets) = try target(f, native: native, id: f.w("c3").id)
            let (plan, value) = try statusPlan(f, at: point, targets: targets)
            try #require(value.headerPlacement?.workspaceIdsInMoveOrder.count == 2)
            let before = f.manager.tabs.map(\.id), groups = f.manager.workspaceGroups, selected = f.manager.selectedTabId
            let members = f.held
            var calls = 0, firstMoved = false
            var firstOrder: [UUID]?, statusAtFirstMove: String?
            let performer = WorkspaceGroupStatusDropPerformer(tabManager: f.manager, sidebarState: f.state,
                actions: f.statusActions(), projection: f.projection(), renderItems: f.rendered(), reorder: { id, index in
                    calls += 1
                    if calls == 2 { f.manager.selectedTabId = f.w("c3").id; return false }
                    statusAtFirstMove = f.manager.workspaceGroups.first { $0.id == group }?.statusId
                    firstMoved = f.manager.reorderSidebarWorkspace(tabId: id, toIndex: index,
                        isDragOperation: true, usesTopLevelRows: true, explicitGroupId: nil)
                    firstOrder = f.manager.tabs.map(\.id)
                    return firstMoved
                })
            #expect(!performer.perform(value, groupId: group, draggedId: plan.draggedWorkspaceId))
            #expect(calls == 2 && firstMoved && firstOrder != before && statusAtFirstMove == "parked")
            #expect(f.manager.tabs.map(\.id) == before && f.manager.workspaceGroups == groups)
            #expect(f.manager.selectedTabId == selected && f.held == members)
        }
    }

    @Test(arguments: [false, true])
    func aGroupAlreadyUnderParkedCommitsNextCrossingsAndTheFullTabOrder(_ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let (f, group) = try fixture(); defer { f.close() }
            try #require(groupActions(f).applyGroup(.status(id: "parked"), groupId: group))
            await f.applyRows(); try f.begin(row: .group(group))
            let before = f.manager.tabs.map(\.id), groups = f.manager.workspaceGroups, members = f.held
            let anchor = try #require(f.manager.workspaceGroupAnchor(for: group)).id
            let (point, targets) = try target(f, native: native, id: f.w("n2").id)
            let (plan, value) = try statusPlan(f, at: point, targets: targets)
            #expect(value.statusId == "next" && value.setsStatus)
            #expect(value.headerPlacement?.crossingWorkspaceIds == [f.w("n1").id])
            try #require(f.commit(plan))
            var expected = before.filter { $0 != f.w("n1").id }
            expected.insert(f.w("n1").id, at: try #require(expected.firstIndex(of: anchor)))
            #expect(f.manager.tabs.map(\.id) == expected && f.held == members)
            let actual = try #require(f.manager.workspaceGroups.first { $0.id == group })
            #expect(actual.statusId == "next" && actual.customColor == "#111111")
            for held in groups where held.id != group { #expect(f.manager.workspaceGroups.first { $0.id == held.id } == held) }
        }
    }

    @Test(arguments: [false, true])
    func aBlockerClampsACommittedDropAndTheFullTabOrder(_ native: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let (f, group) = try fixture(); defer { f.close() }
            await f.applyRows(); try f.begin(row: .group(group))
            let before = f.manager.tabs.map(\.id), groups = f.manager.workspaceGroups, members = f.held
            let anchor = try #require(f.manager.workspaceGroupAnchor(for: group)).id
            let (point, targets) = try target(f, native: native, id: f.w("c3").id, edge: .bottom, right: true)
            let (plan, value) = try statusPlan(f, at: point, targets: targets)
            #expect(value.headerPlacement?.crossingWorkspaceIds == [f.w("c1").id])
            #expect(plan.indicator == .init(tabId: f.w("pAnchor").id, edge: .top))
            try #require(f.commit(plan))
            var expected = before.filter { $0 != f.w("c1").id }
            expected.insert(f.w("c1").id, at: try #require(expected.firstIndex(of: anchor)))
            #expect(f.manager.tabs.map(\.id) == expected && f.held == members)
            #expect(f.manager.workspaceGroups.first { $0.id == group }?.statusId == "parked")
            for held in groups where held.id != group { #expect(f.manager.workspaceGroups.first { $0.id == held.id } == held) }
        }
    }

    @Test(arguments: [false, true], StationarySource.allCases.flatMap { role in [false, true].map { (role, $0) } })
    func stationaryMemberRowCommitsSetOnlyOwnStatusWithoutAnyTabMove(_ native: Bool, _ targetCase: (StationarySource, Bool)) async throws {
        let (role, bottomRight) = targetCase
        try await AppContextSerialGate.withExclusiveAppContext {
            let (f, group) = try fixture(); defer { f.close() }
            let source = try stationarySource(f, group: group, role: role)
            await f.applyRows(); try f.begin(row: .group(source))
            let before = f.manager.tabs.map(\.id), groups = f.manager.workspaceGroups, members = f.held
            let (point, targets) = try target(f, native: native, id: f.w("pa").id,
                edge: bottomRight ? .bottom : .top, right: bottomRight)
            let (plan, value) = try statusPlan(f, at: point, targets: targets)
            #expect(plan.indicator == .init(tabId: f.w("pAnchor").id, edge: .top))
            #expect(value.headerPlacement?.crossingWorkspaceIds.isEmpty == true)
            try #require(f.commit(plan))
            #expect(f.manager.tabs.map(\.id) == before && f.held == members)
            let actual = try #require(f.manager.workspaceGroups.first { $0.id == source })
            let held = try #require(groups.first { $0.id == source })
            #expect(actual.statusId == "parked" && actual.customColor == "#555555")
            #expect(actual.parentGroupId == held.parentGroupId && actual.isPinned == held.isPinned)
            for held in groups where held.id != source { #expect(f.manager.workspaceGroups.first { $0.id == held.id } == held) }
        }
    }

}
