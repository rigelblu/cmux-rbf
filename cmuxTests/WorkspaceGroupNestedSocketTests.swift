import CmuxControlSocket
import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Nested workspace groups (#cm-106): what `workspace.group.move` answers, through the app's context, in a window that holds
// a nested group and in a flat one.
@MainActor
@Suite("Workspace group nesting, socket move", .serialized)
struct WorkspaceGroupNestedSocketTests {
    private let routing = ControlRoutingSelectors(
        hasWindowIDParam: false, windowID: nil, groupID: nil, workspaceID: nil, surfaceID: nil, paneID: nil
    )

    /// Groups listed `B, A, A1 (in A), C`.
    private func manager() throws -> (manager: TabManager, b: UUID, a: UUID, a1: UUID, c: UUID) {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        for _ in 0..<4 { manager.addWorkspace(autoWelcomeIfNeeded: false) }
        let ids = manager.tabs.map(\.id)
        let b = try #require(manager.createWorkspaceGroup(name: "B", childWorkspaceIds: [ids[1]]))
        let a = try #require(manager.createWorkspaceGroup(name: "A", childWorkspaceIds: [ids[2]]))
        let a1 = try #require(manager.createWorkspaceGroup(name: "A1", childWorkspaceIds: [ids[3]]))
        let c = try #require(manager.createWorkspaceGroup(name: "C", childWorkspaceIds: [ids[4]]))
        return (manager, b, a, a1, c)
    }

    private func move(
        _ manager: TabManager,
        _ group: UUID,
        toIndex: Int? = nil,
        before: UUID? = nil,
        after: UUID? = nil
    ) -> ControlWorkspaceGroupMoveResolution {
        let previous = TerminalController.shared.activeTabManagerForCallerNotification()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previous) }
        return TerminalController.shared.controlMoveWorkspaceGroup(
            routing: routing, groupID: group, toIndex: toIndex, beforeGroupID: before, afterGroupID: after
        )
    }

    private func order(_ manager: TabManager) -> [String] {
        manager.workspaceGroups.map(\.name)
    }

    @Test func beforeAndAfterAmongNestedSiblingsMoveTheGroupAndSayMoved() throws {
        let (manager, b, a, a1, c) = try manager()
        #expect(manager.moveWorkspaceGroup(groupId: a1, intoParent: a) == .moved)
        #expect(order(manager) == ["B", "A", "A1", "C"])
        #expect(move(manager, b, before: c) == .moved)
        #expect(order(manager) == ["A", "A1", "B", "C"])
        #expect(move(manager, c, after: a) == .moved)
        #expect(order(manager) == ["A", "A1", "C", "B"])
    }

    @Test func aMoveThatMovesNothingIsNotAnsweredMoved() throws {
        let (manager, b, a, a1, c) = try manager()
        #expect(manager.moveWorkspaceGroup(groupId: a1, intoParent: a) == .moved)
        _ = c
        // B is already directly before A, and last among the groups beside it after the first move.
        #expect(move(manager, b, before: a) == .unchanged)
        #expect(move(manager, b, toIndex: 0) == .unchanged)
        #expect(order(manager) == ["B", "A", "A1", "C"])
    }

    @Test func aTargetInAnotherParentIsRefusedAndNothingMoves() throws {
        let (manager, b, a, a1, c) = try manager()
        #expect(manager.moveWorkspaceGroup(groupId: a1, intoParent: a) == .moved)
        _ = c
        #expect(move(manager, b, before: a1) == .targetNotBeside)
        #expect(move(manager, b, after: a1) == .targetNotBeside)
        #expect(move(manager, a1, after: b) == .targetNotBeside)
        let indexOfA1 = try #require(manager.workspaceGroups.firstIndex { $0.id == a1 })
        #expect(move(manager, b, toIndex: indexOfA1) == .targetNotBeside)
        #expect(order(manager) == ["B", "A", "A1", "C"])
    }

    @Test func aGroupOrTargetThatIsNotThereIsUnresolved() throws {
        let (manager, b, a, a1, _) = try manager()
        #expect(manager.moveWorkspaceGroup(groupId: a1, intoParent: a) == .moved)
        #expect(move(manager, UUID(), toIndex: 0) == .unresolved)
        #expect(move(manager, b) == .unresolved)
        #expect(move(manager, b, before: UUID()) == .unresolved)
    }

    @Test func aFlatWindowKeepsTheOldAnswers() throws {
        let (manager, b, _, _, c) = try manager()
        #expect(!manager.workspaces.hasNestedWorkspaceGroup)
        #expect(move(manager, b, before: c) == .moved)
        // Already there: the flat window still answers success, as it always did.
        #expect(move(manager, b, before: c) == .moved)
        #expect(move(manager, UUID(), toIndex: 0) == .unresolved)
        #expect(move(manager, b) == .unresolved)
    }

    /// The wire answer to `workspace.group.move`, through the real context.
    private func wireAnswer(_ manager: TabManager, _ group: UUID, before: UUID? = nil, toIndex: Int? = nil) -> JSONValue? {
        let previous = TerminalController.shared.activeTabManagerForCallerNotification()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previous) }
        var params: [String: JSONValue] = ["group_id": .string(group.uuidString)]
        if let before { params["before_group_id"] = .string(before.uuidString) }
        if let toIndex { params["to_index"] = .int(Int64(toIndex)) }
        let request = ControlRequest(id: .int(1), method: "workspace.group.move", params: params)
        guard case .ok(let body)? = ControlCommandCoordinator(context: TerminalController.shared).handle(request) else {
            return nil
        }
        return body
    }

    @Test func aMoveThatChangesNothingAnswersTheSamePayloadAsARealMove() throws {
        let (manager, b, a, a1, c) = try manager()
        // Flat window: a real move, then the same move again, which changes nothing.
        let real = try #require(wireAnswer(manager, b, before: c))
        #expect(real == .object(["group_id": .string(b.uuidString)]))
        var tabs = manager.tabs.map(\.id)
        #expect(wireAnswer(manager, b, before: c) == real)
        #expect(manager.tabs.map(\.id) == tabs, "flat window: the repeated --before moved nothing")
        // Nested window: a real move, then the same move again (--before), and a move by index to the group's own index.
        #expect(manager.moveWorkspaceGroup(groupId: a1, intoParent: a) == .moved)
        let nestedReal = try #require(wireAnswer(manager, c, before: b))
        #expect(nestedReal == .object(["group_id": .string(c.uuidString)]))
        tabs = manager.tabs.map(\.id)
        #expect(wireAnswer(manager, c, before: b) == nestedReal)
        #expect(manager.tabs.map(\.id) == tabs, "nested window: the repeated --before moved nothing")
        let ownIndex = try #require(manager.workspaceGroups.firstIndex { $0.id == c })
        #expect(wireAnswer(manager, c, toIndex: ownIndex) == nestedReal)
        #expect(manager.tabs.map(\.id) == tabs, "nested window: a move to the group's own index moved nothing")
    }

    // MARK: - List snapshot

    private func list(_ manager: TabManager) throws -> [UUID: ControlWorkspaceGroupSnapshot] {
        let previous = TerminalController.shared.activeTabManagerForCallerNotification()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previous) }
        guard case .resolved(_, let groups) = TerminalController.shared.controlWorkspaceGroupList(routing: routing) else {
            Issue.record("the list did not resolve")
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
    }

    @Test func theListSnapshotCarriesTheParentAndCallsAHeaderThatHoldsOnlyGroupsNotEmpty() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        for _ in 0..<2 { manager.addWorkspace(autoWelcomeIfNeeded: false) }
        let ids = manager.tabs.map(\.id)
        // P holds only Q (its own workspace is closed); Q holds a workspace; E is a pinned header that holds nothing.
        let p = try #require(manager.createWorkspaceGroup(name: "P", childWorkspaceIds: []))
        let q = try #require(manager.createWorkspaceGroup(name: "Q", childWorkspaceIds: [ids[1]]))
        #expect(manager.moveWorkspaceGroup(groupId: q, intoParent: p) == .moved)
        manager.closeWorkspace(try #require(manager.workspaceGroupAnchor(for: p)))
        let e = try #require(manager.createWorkspaceGroup(name: "E", childWorkspaceIds: []))
        manager.toggleWorkspaceGroupPinned(groupId: e)
        manager.closeWorkspace(try #require(manager.workspaceGroupAnchor(for: e)))
        #expect(manager.workspaceGroups.first { $0.id == p }?.liveAnchorWorkspaceId == nil)
        #expect(manager.workspaceGroups.first { $0.id == e }?.liveAnchorWorkspaceId == nil)

        let snapshots = try list(manager)
        #expect(snapshots[p]?.parentGroupID == nil)
        #expect(snapshots[q]?.parentGroupID == p)
        #expect(snapshots[e]?.parentGroupID == nil)
        // The header with only a group inside is not empty; the one that holds nothing is.
        #expect(snapshots[p]?.holdsNothing == false)
        #expect(snapshots[e]?.holdsNothing == true)
        #expect(snapshots[q]?.holdsNothing == false)
    }

    // MARK: - The phone's list

    /// `P` holds `w1` and `Q`; `Q` holds `w2` and `R`; `R` holds `w3`. Four workspaces stand behind group names.
    @Test func nestedGroupsKeepEveryWorkspace() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        for _ in 0..<3 { manager.addWorkspace(autoWelcomeIfNeeded: false) }
        let ids = manager.tabs.map(\.id)
        let p = try #require(manager.createWorkspaceGroup(name: "P", childWorkspaceIds: [ids[1]]))
        let q = try #require(manager.createWorkspaceGroup(name: "Q", childWorkspaceIds: [ids[2]]))
        let r = try #require(manager.createWorkspaceGroup(name: "R", childWorkspaceIds: [ids[3]]))
        #expect(manager.moveWorkspaceGroup(groupId: q, intoParent: p) == .moved)
        #expect(manager.moveWorkspaceGroup(groupId: r, intoParent: q) == .moved)
        #expect(manager.workspaces.hasNestedWorkspaceGroup)

        guard case .ok(let payload) = TerminalController.shared.v2MobileWorkspaceList(params: [:], tabManager: manager),
              let result = payload as? [String: Any],
              let rows = result["workspaces"] as? [[String: Any]] else {
            Issue.record("the phone's list did not answer with a workspaces array")
            return
        }
        let listed = rows.compactMap { $0["id"] as? String }
        let expected = manager.tabs.map { $0.id.uuidString }
        #expect(expected.count == 7, "the window holds 7 workspaces: 3 group headers, 3 inside, 1 loose")
        #expect(listed.sorted() == expected.sorted(), "every workspace appears exactly once in the phone's list")
        #expect(Set(listed).count == listed.count, "no workspace appears twice")
        let groupRows = try #require(result["groups"] as? [[String: Any]])
        #expect(groupRows.count == 3, "the three groups are listed")
    }
}
