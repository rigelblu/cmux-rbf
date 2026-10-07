import CmuxCore
import AppKit
import CmuxFoundation
import CmuxTerminalCore
import SwiftUI
import Bonsplit
import CmuxPanes
import CmuxSettings
import CmuxWorkspaces
import CmuxSidebar
import Combine
import CmuxTerminal
import CmuxBrowser
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Scenario 45 (#cm-106), through a real `TabManager`: two writers of the list of workspaces that did not end in
// the repair, in a window that holds a nested group.
@MainActor
@Suite("Workspace group nesting, TabManager's own writers", .serialized)
struct WorkspaceGroupNestedScenario45Tests {
    private final class DetachedTestPanel: Panel {
        let objectWillChange = ObservableObjectPublisher()
        let id: UUID
        let stableSurfaceIdentity = PanelStableSurfaceIdentity()
        let panelType: PanelType = .terminal
        let displayTitle = "Detached"
        let displayIcon: String? = "terminal.fill"
        let isDirty = false

        init(id: UUID = UUID()) {
            self.id = id
        }

        func close() {}
        func focus() {}
        func unfocus() {}
        func triggerFlash(reason: WorkspaceAttentionFlashReason) {}
    }

    private func detachedTransfer(sourceWorkspaceId: UUID) -> Workspace.DetachedSurfaceTransfer {
        let panel = DetachedTestPanel()
        return Workspace.DetachedSurfaceTransfer(
            sourceWorkspaceId: sourceWorkspaceId,
            sessionRestoreSourceWorkspaceId: nil,
            panelId: panel.id,
            panel: panel,
            title: panel.displayTitle,
            icon: panel.displayIcon,
            iconImageData: nil,
            kind: "terminal",
            isLoading: false,
            isPinned: false,
            directory: nil,
            directoryIsTrustedRemoteReport: false,
            directoryDisplayLabel: nil,
            ttyName: nil,
            cachedTitle: nil,
            customTitle: nil,
            customTitleSource: nil,
            manuallyUnread: false,
            restoredUnreadIndicator: nil,
            restorableAgent: nil,
            restorableAgentResumeState: nil, restoredAgentCompletedGeneration: nil,
            shellActivityState: nil, restoredResumeSessionWorkingDirectory: nil,
            resumeBinding: nil,
            managedAgentResumeBinding: nil,
            agentRuntime: nil,
            isRemoteTerminal: false,
            remoteRelayPort: nil,
            remotePTYSessionID: nil,
            remoteCleanupConfiguration: nil
        )
    }

    /// A window `w0 | P[p: Q[q], x] | w3`: P holds Q. Nested state is built directly.
    private func nestedManager() throws -> (manager: TabManager, outer: UUID, inner: UUID) {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        for _ in 0..<4 { manager.addWorkspace(autoWelcomeIfNeeded: false) }
        let ids = manager.tabs.map(\.id)
        let outer = try #require(manager.createWorkspaceGroup(name: "P", childWorkspaceIds: [ids[1], ids[3]]))
        let inner = try #require(manager.createWorkspaceGroup(name: "Q", childWorkspaceIds: [ids[2]]))
        let index = try #require(manager.workspaceGroups.firstIndex { $0.id == inner })
        manager.workspaceGroups[index].parentGroupId = outer
        manager.workspaces.normalizeWorkspaceGroupContiguity()
        return (manager, outer, inner)
    }

    /// The rows of every group are one unbroken stretch of `tabs`, at every level.
    private func everyRunIsUnbroken(_ manager: TabManager) -> Bool {
        let parents = Dictionary(uniqueKeysWithValues: manager.workspaceGroups.map { ($0.id, $0.parentGroupId) })
        func chain(_ groupId: UUID?) -> [UUID] {
            var out: [UUID] = []
            var cursor = groupId
            while let c = cursor, !out.contains(c) {
                out.append(c)
                cursor = parents[c] ?? nil
            }
            return out
        }
        for group in manager.workspaceGroups {
            let indices = manager.tabs.indices.filter { chain(manager.tabs[$0].groupId).contains(group.id) }
            if let first = indices.first, let last = indices.last, last - first + 1 != indices.count { return false }
        }
        return true
    }

    @Test func aWorkspaceMadeFromATabDraggedOutOfAPaneEndsInTheRepairInANestedWindow() throws {
        let (manager, outer, _) = try nestedManager()
        // Aim the new workspace between P's own workspace and the rest of its run.
        let runStart = try #require(manager.tabs.firstIndex { $0.groupId == outer })
        let source = try #require(manager.selectedWorkspace)
        let inserted = try #require(manager.addWorkspace(
            fromDetachedSurface: detachedTransfer(sourceWorkspaceId: source.id),
            select: false,
            insertionIndexOverride: runStart + 1
        ))
        #expect(manager.tabs.contains { $0.id == inserted.id })
        #expect(everyRunIsUnbroken(manager))
        #expect(inserted.groupId == nil)
    }

    /// A flat window `w0 | F[f, a] | w3`. No group holds another.
    private func flatManager() throws -> (manager: TabManager, group: UUID) {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        for _ in 0..<3 { manager.addWorkspace(autoWelcomeIfNeeded: false) }
        let ids = manager.tabs.map(\.id)
        let group = try #require(manager.createWorkspaceGroup(name: "F", childWorkspaceIds: [ids[1]]))
        #expect(!manager.workspaces.hasNestedWorkspaceGroup)
        return (manager, group)
    }

    @Test func inAFlatWindowAWorkspaceMadeFromAPaneTabIsPlacedWhereTheInsertIndexSaysAndNotRepaired() throws {
        let (manager, group) = try flatManager()
        let runStart = try #require(manager.tabs.firstIndex { $0.groupId == group })
        let source = try #require(manager.selectedWorkspace)
        let inserted = try #require(manager.addWorkspace(
            fromDetachedSurface: detachedTransfer(sourceWorkspaceId: source.id),
            select: false,
            insertionIndexOverride: runStart + 1
        ))
        // Upstream's code: the new workspace stays at the index it was given, inside the run, and ungrouped.
        #expect(manager.tabs.firstIndex { $0.id == inserted.id } == runStart + 1)
        #expect(inserted.groupId == nil)
        #expect(!everyRunIsUnbroken(manager))
    }

    @Test func inAFlatWindowAClosedUngroupedWorkspaceIsReopenedAtItsOldIndexAndNotRepaired() throws {
        ClosedItemHistoryStore.shared.removeAll()
        defer { ClosedItemHistoryStore.shared.removeAll() }
        let (manager, group) = try flatManager()
        let x = manager.addWorkspace(autoWelcomeIfNeeded: false)
        let oldIndex = try #require(manager.tabs.firstIndex { $0.id == x.id })
        manager.closeWorkspace(x)
        let extra = manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspaceToGroup(workspaceId: extra.id, groupId: group)
        let runEnd = try #require(manager.tabs.lastIndex { $0.groupId != nil })
        #expect(oldIndex <= runEnd, "the old place now falls inside the group's run")
        let idsBefore = Set(manager.tabs.map(\.id))
        #expect(manager.reopenMostRecentlyClosedItem())
        // Upstream's code puts it at the old index with no repair, so the group's run is broken.
        let reopenedIndex = try #require(manager.tabs.firstIndex { !idsBefore.contains($0.id) })
        #expect(reopenedIndex == oldIndex)
        #expect(manager.tabs[reopenedIndex].groupId == nil)
        #expect(!everyRunIsUnbroken(manager))
    }

    // MARK: - Nested by the entrances, saved and reopened

    /// The window's shape without workspace ids: each group with its parent, fold and pin, and the drawn rows as
    /// group names and the name of the group each workspace sits in.
    private func shape(_ manager: TabManager) -> [String] {
        let names = Dictionary(uniqueKeysWithValues: manager.workspaceGroups.map { ($0.id, $0.name) })
        let groups = manager.workspaceGroups.map { group in
            "\(group.name) in \(group.parentGroupId.flatMap { names[$0] } ?? "top")\(group.isCollapsed ? " folded" : "")\(group.isPinned ? " pinned" : "")"
        }
        let groupsById = Dictionary(uniqueKeysWithValues: manager.workspaceGroups.map { ($0.id, $0) })
        let membership = SidebarWorkspaceRenderItem.effectiveGroupIdByWorkspaceId(tabs: manager.tabs, groupsById: groupsById)
        let rows = SidebarWorkspaceRenderItem.renderItems(
            tabs: manager.tabs, groupsById: groupsById, orderedGroups: manager.workspaceGroups, effectiveMembership: membership
        ).map { item -> String in
            switch item {
            case .groupHeader(let groupId, _): return "header \(names[groupId] ?? "?")"
            case .workspace(let id): return "workspace in \(manager.tabs.first { $0.id == id }?.groupId.flatMap { names[$0] } ?? "top")"
            case .colorSectionHeader: return "color"
            }
        }
        return groups + ["--"] + rows
    }

    private func saveAndRestore(_ manager: TabManager) throws -> TabManager {
        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionTabManagerSnapshot.self, from: data)
        let restored = TabManager(autoWelcomeIfNeeded: false)
        restored.restoreSessionSnapshot(decoded)
        return restored
    }

    @Test func aWindowNestedByMoveGroupToDrawsTheSameRowsAfterSaveAndRestore() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        for _ in 0..<4 { manager.addWorkspace(autoWelcomeIfNeeded: false) }
        let ids = manager.tabs.map(\.id)
        let outer = try #require(manager.createWorkspaceGroup(name: "P", childWorkspaceIds: [ids[1]]))
        let inner = try #require(manager.createWorkspaceGroup(name: "Q", childWorkspaceIds: [ids[2]]))
        let third = try #require(manager.createWorkspaceGroup(name: "R", childWorkspaceIds: [ids[3]]))
        #expect(manager.moveWorkspaceGroup(groupId: inner, intoParent: outer) == .moved)
        #expect(manager.moveWorkspaceGroup(groupId: third, intoParent: inner) == .moved)
        manager.toggleWorkspaceGroupCollapsed(groupId: third)
        #expect(manager.workspaces.hasNestedWorkspaceGroup)
        let before = shape(manager)
        let restored = try saveAndRestore(manager)
        #expect(restored.workspaces.hasNestedWorkspaceGroup)
        #expect(shape(restored) == before)
        #expect(everyRunIsUnbroken(restored))
        // Saving the restored window gives the same shape again.
        #expect(shape(try saveAndRestore(restored)) == before)
    }

    @Test func aGroupMadeInPlaceFromWorkspacesInAGroupIsInsideItAfterSaveAndRestore() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        for _ in 0..<3 { manager.addWorkspace(autoWelcomeIfNeeded: false) }
        let ids = manager.tabs.map(\.id)
        let outer = try #require(manager.createWorkspaceGroup(name: "P", childWorkspaceIds: [ids[1], ids[2]]))
        let made = try #require(manager.createWorkspaceGroup(name: "N", childWorkspaceIds: [ids[2]]))
        #expect(manager.workspaceGroups.first { $0.id == made }?.parentGroupId == outer)
        let before = shape(manager)
        let restored = try saveAndRestore(manager)
        #expect(shape(restored) == before)
        #expect(everyRunIsUnbroken(restored))
    }

    @Test func aHeaderThatHoldsNothingWithAParentSurvivesSaveAndRestore() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let ids = manager.tabs.map(\.id)
        let outer = try #require(manager.createWorkspaceGroup(name: "P", childWorkspaceIds: [ids[1]]))
        let inner = try #require(manager.createWorkspaceGroup(name: "E", childWorkspaceIds: []))
        #expect(manager.moveWorkspaceGroup(groupId: inner, intoParent: outer) == .moved)
        // Close the inner group's own workspace: it is left holding nothing, pinned so it stays.
        manager.toggleWorkspaceGroupPinned(groupId: inner)
        manager.closeWorkspace(try #require(manager.workspaceGroupAnchor(for: inner)))
        #expect(manager.workspaceGroups.first { $0.id == inner }?.liveAnchorWorkspaceId == nil)
        let restored = try saveAndRestore(manager)
        let restoredInner = restored.workspaceGroups.first { $0.name == "E" }
        #expect(restoredInner != nil)
        #expect(restoredInner?.parentGroupId == restored.workspaceGroups.first { $0.name == "P" }?.id)
    }

    @Test func aClosedUngroupedWorkspaceWhoseOldPlaceNowFallsInsideAnAreaIsReopenedBesideThatArea() throws {
        ClosedItemHistoryStore.shared.removeAll()
        defer { ClosedItemHistoryStore.shared.removeAll() }
        let (manager, outer, _) = try nestedManager()
        // x sits right after P's run; close it, then grow P's run over its old place.
        let x = manager.addWorkspace(autoWelcomeIfNeeded: false)
        let oldIndex = try #require(manager.tabs.firstIndex { $0.id == x.id })
        manager.closeWorkspace(x)
        let extra = manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspaceToGroup(workspaceId: extra.id, groupId: outer)
        let runEnd = try #require(manager.tabs.lastIndex { $0.groupId != nil })
        #expect(oldIndex <= runEnd, "the old place now falls inside the area")
        #expect(manager.reopenMostRecentlyClosedItem())
        #expect(everyRunIsUnbroken(manager))
    }

    // MARK: - The three writers the earlier tests did not reach

    /// `u` at the top level; `P` holds `w1` and `Q`; `Q` holds `w2` and `R`; `R` holds `w3`. Every group has its own
    /// workspace (`pOwn`, `qOwn`, `rOwn`).
    private struct ThreeLevels {
        let manager: TabManager
        let u: UUID, w1: UUID, w2: UUID, w3: UUID
        let p: UUID, q: UUID, r: UUID
    }

    private func threeLevels() throws -> ThreeLevels {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        for _ in 0..<3 { manager.addWorkspace(autoWelcomeIfNeeded: false) }
        let ids = manager.tabs.map(\.id)
        let p = try #require(manager.createWorkspaceGroup(name: "P", childWorkspaceIds: [ids[1]]))
        let q = try #require(manager.createWorkspaceGroup(name: "Q", childWorkspaceIds: [ids[2]]))
        let r = try #require(manager.createWorkspaceGroup(name: "R", childWorkspaceIds: [ids[3]]))
        #expect(manager.moveWorkspaceGroup(groupId: q, intoParent: p) == .moved)
        #expect(manager.moveWorkspaceGroup(groupId: r, intoParent: q) == .moved)
        #expect(sixRules(manager).isEmpty, "the starting window: \(sixRules(manager))")
        return ThreeLevels(manager: manager, u: ids[0], w1: ids[1], w2: ids[2], w3: ids[3], p: p, q: q, r: r)
    }

    /// The six layout rules over the stored window; empty when they hold. The sentences are those of the rules block
    /// at the top of `WorkspaceGroupLayout.swift`.
    private func sixRules(_ manager: TabManager) -> [String] {
        var problems: [String] = []
        let groups = manager.workspaceGroups
        let byId = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Rule 6: every groupId names a group in the window, or is nil.
        for tab in manager.tabs { if let g = tab.groupId, byId[g] == nil { problems.append("6: a workspace names a missing group") } }
        // Rule 5: parents name a group of the window and form no loop.
        for group in groups {
            if let parent = group.parentGroupId, byId[parent] == nil { problems.append("5: \(group.name) has a missing parent") }
            var seen: Set<UUID> = [group.id]
            var cursor = group.parentGroupId
            while let c = cursor {
                if !seen.insert(c).inserted { problems.append("5: \(group.name) is on a loop"); break }
                cursor = byId[c]?.parentGroupId
            }
        }
        func chain(_ groupId: UUID?) -> [UUID] {
            var out: [UUID] = []
            var cursor = groupId
            while let c = cursor, !out.contains(c) { out.append(c); cursor = byId[c]?.parentGroupId }
            return out
        }
        // Rule 1: each group's run is one unbroken stretch, and a child's lies inside its parent's (the second follows
        // from the first for the chain of each workspace).
        for group in groups {
            let indices = manager.tabs.indices.filter { chain(manager.tabs[$0].groupId).contains(group.id) }
            if let first = indices.first, let last = indices.last, last - first + 1 != indices.count {
                problems.append("1: the run of \(group.name) is broken")
            }
        }
        // Rule 4: a parent is listed before its children.
        let position = Dictionary(uniqueKeysWithValues: groups.enumerated().map { ($1.id, $0) })
        for group in groups {
            if let parent = group.parentGroupId, let a = position[parent], let b = position[group.id], a > b {
                problems.append("4: \(group.name) is listed before its parent")
            }
        }
        // Rules 2 and 3: at every level, the group's own workspace first, then pinned rows, then unpinned rows.
        func rows(of level: UUID?) -> [(isPinned: Bool, isOwn: Bool)] {
            var out: [(Bool, Bool)] = []
            var seenGroups = Set<UUID>()
            for tab in manager.tabs {
                let tabChain = chain(tab.groupId)
                if let level, !tabChain.contains(level) { continue }
                let below = level.map { l in Array(tabChain.prefix(while: { $0 != l })) } ?? tabChain
                if let top = below.last {
                    if seenGroups.insert(top).inserted { out.append((byId[top]?.isPinned ?? false, false)) }
                } else if let level, byId[level]?.liveAnchorWorkspaceId == tab.id {
                    out.append((false, true))
                } else {
                    out.append((tab.isPinned, false))
                }
            }
            return out.map { (isPinned: $0.0, isOwn: $0.1) }
        }
        for level in [nil] + groups.map({ Optional($0.id) }) {
            let list = rows(of: level)
            if let own = list.firstIndex(where: \.isOwn), own != 0 { problems.append("2: the own workspace is not first") }
            let tiers = list.filter { !$0.isOwn }.map(\.isPinned)
            if tiers != tiers.sorted(by: { $0 && !$1 }) { problems.append("2/3: a pinned row is below an unpinned row") }
        }
        return problems
    }

    /// The ids each order-change notice named, in order, while `body` runs.
    private func notices(of manager: TabManager, _ body: () throws -> Void) rethrows -> [[UUID]] {
        var seen: [[UUID]] = []
        let token = NotificationCenter.default.addObserver(forName: .workspaceOrderDidChange, object: manager, queue: nil) { note in
            seen.append(note.userInfo?[WorkspaceOrderChangeNotificationKey.movedWorkspaceIds] as? [UUID] ?? [])
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try body()
        return seen
    }

    /// The workspaces that are in both orders and whose index among the workspaces in both orders differs.
    private func changedPlace(from before: [UUID], to after: [UUID]) -> [UUID] {
        let both = Set(before).intersection(after)
        let b = before.filter(both.contains), a = after.filter(both.contains)
        return a.enumerated().compactMap { index, id in b[index] == id ? nil : id }
    }

    @Test func aWorkspaceMovedInFromAnotherWindowIntoAThreeLevelWindowLeavesALegalHierarchy() throws {
        let w = try threeLevels()
        let other = TabManager(autoWelcomeIfNeeded: false)
        other.addWorkspace(autoWelcomeIfNeeded: false)
        let leavingId = try #require(other.tabs.last).id
        let leaving = try #require(other.detachWorkspace(tabId: leavingId))
        // Aim it between Q's own workspace and the rest of Q's run, the most damaging place.
        let qRunStart = try #require(w.manager.tabs.firstIndex { $0.groupId == w.q })
        let before = w.manager.tabs.map(\.id)
        let sent = notices(of: w.manager) { w.manager.attachWorkspace(leaving, at: qRunStart + 1, select: false) }
        let after = w.manager.tabs.map(\.id)
        #expect(sixRules(w.manager).isEmpty, "\(sixRules(w.manager))")
        #expect(leaving.groupId == nil, "it arrives in no group")
        #expect(after.contains(leaving.id))
        // The notice rule: the order of the workspaces already there changed, so the notice names them. If nothing that
        // was there changed place, v0.31.0 sends nothing on an attach and this window sends nothing.
        let moved = changedPlace(from: before, to: after)
        if moved.isEmpty {
            #expect(sent.isEmpty, "nothing already there moved, so no notice: \(sent)")
        } else {
            #expect(!sent.isEmpty && Set(sent.flatMap { $0 }).isSuperset(of: moved), "the notice names the workspaces that moved: moved \(moved), sent \(sent)")
        }
    }

    @Test func aClosedWorkspaceReopenedAfterItsGroupWasDeletedLeavesALegalHierarchy() throws {
        ClosedItemHistoryStore.shared.removeAll()
        defer { ClosedItemHistoryStore.shared.removeAll() }
        // `u | P[pOwn, a, Q[qOwn, x, R[rOwn, b], S[sOwn, y]]]`: R sits in the middle of Q's run. After R goes, the old
        // place of `b` is between `x` and S's workspaces, inside the runs of Q and P, and the window still holds a nested group (P in Q).
        let manager = TabManager(autoWelcomeIfNeeded: false)
        for _ in 0..<5 { manager.addWorkspace(autoWelcomeIfNeeded: false) }
        let ids = manager.tabs.map(\.id)
        let p = try #require(manager.createWorkspaceGroup(name: "P", childWorkspaceIds: [ids[1]]))
        let q = try #require(manager.createWorkspaceGroup(name: "Q", childWorkspaceIds: [ids[2]]))
        let r = try #require(manager.createWorkspaceGroup(name: "R", childWorkspaceIds: [ids[3]]))
        #expect(manager.moveWorkspaceGroup(groupId: q, intoParent: p) == .moved)
        #expect(manager.moveWorkspaceGroup(groupId: r, intoParent: q) == .moved)
        let s = try #require(manager.createWorkspaceGroup(name: "S", childWorkspaceIds: [ids[4]]))
        #expect(manager.moveWorkspaceGroup(groupId: s, intoParent: q) == .moved)
        let x = ids[2], b = ids[3], y = ids[4]
        func index(_ id: UUID) -> Int? { manager.tabs.firstIndex { $0.id == id } }
        let inR = try #require(index(b))
        #expect(try #require(index(x)) < inR && inR < (try #require(index(y))), "R's run sits between x and y: \(manager.tabs.map { $0.groupId == nil ? "-" : "g" })")
        #expect(sixRules(manager).isEmpty, "the starting window: \(sixRules(manager))")

        manager.closeWorkspace(try #require(manager.tabs.first { $0.id == b }))
        #expect(manager.deleteWorkspaceGroup(groupId: r, recordHistory: false) >= 1)
        #expect(!manager.workspaceGroups.contains { $0.id == r })
        #expect(manager.workspaces.hasNestedWorkspaceGroup, "P still holds Q")
        #expect(sixRules(manager).isEmpty, "after the delete: \(sixRules(manager))")
        let before = manager.tabs.map(\.id)
        var reopened = false
        let sent = notices(of: manager) { reopened = manager.reopenMostRecentlyClosedItem() }
        #expect(reopened)
        let after = manager.tabs.map(\.id)
        let back = try #require(manager.tabs.first { !before.contains($0.id) })
        #expect(back.groupId == nil || manager.workspaceGroups.contains { $0.id == back.groupId }, "it names no group that is gone")
        #expect(sixRules(manager).isEmpty, "after the reopen: \(sixRules(manager))")
        let moved = changedPlace(from: before, to: after)
        if moved.isEmpty {
            #expect(sent.isEmpty, "nothing already there moved, so no notice: \(sent)")
        } else {
            #expect(!sent.isEmpty && Set(sent.flatMap { $0 }).isSuperset(of: moved), "the notice names the workspaces that moved: moved \(moved), sent \(sent)")
        }
    }

    @Test func deleteGroupWhileOneWorkspaceJoinedAndAnotherMovedOutLeavesTheJoinerInTheParentAndKeepsTheMover() throws {
        let w = try threeLevels()
        let group = try #require(w.manager.workspaceGroups.first { $0.id == w.q })
        let confirmation = try #require(w.manager.workspaceGrouping.deletionConfirmation(
            groupId: w.q, fallbackGroupName: group.name, fallbackAnchorWorkspaceId: group.anchorWorkspaceId
        ))
        // While the question is open: u joins Q, and w2 leaves it.
        w.manager.addWorkspaceToGroup(workspaceId: w.u, groupId: w.q)
        w.manager.removeWorkspaceFromGroup(workspaceId: w.w2)
        #expect(confirmation.memberWorkspaceIds.contains(w.w2), "w2 was named in the question")
        #expect(!confirmation.memberWorkspaceIds.contains(w.u), "u was not")
        let before = w.manager.tabs.map(\.id)
        var closed = 0
        let sent = notices(of: w.manager) {
            closed = w.manager.workspaceGrouping.deleteWorkspaceGroup(confirmed: confirmation, recordHistory: false)
        }
        #expect(closed >= 1)
        #expect(!w.manager.workspaceGroups.contains { $0.id == w.q || $0.id == w.r }, "Q and the group inside it are gone")
        #expect(w.manager.tabs.contains { $0.id == w.w2 }, "the workspace that left is not closed")
        #expect(w.manager.tabs.contains { $0.id == w.u }, "the workspace that joined is not closed")
        #expect(w.manager.tabs.first { $0.id == w.u }?.groupId == w.p, "the joiner stays in the group that held Q")
        #expect(!w.manager.tabs.contains { $0.id == w.w3 }, "a workspace still inside Q's area was closed")
        #expect(sixRules(w.manager).isEmpty, "\(sixRules(w.manager))")
        let after = w.manager.tabs.map(\.id)
        let lastNotice = try #require(sent.last, "a delete that changed the order sends a notice")
        #expect(lastNotice.starts(with: confirmation.memberWorkspaceIds), "the confirmed workspaces come first")
        let named = Set(sent.flatMap { $0 })
        #expect(named.isSuperset(of: changedPlace(from: before, to: after)), "every workspace that took a new place is named")
    }
}
