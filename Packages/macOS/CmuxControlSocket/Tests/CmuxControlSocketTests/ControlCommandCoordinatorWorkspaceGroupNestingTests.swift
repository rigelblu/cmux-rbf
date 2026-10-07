import Foundation
import Testing
@testable import CmuxControlSocket

// Nested workspace groups (#cm-106): `parent_group_id` and the new meaning of `is_empty` in the list payload,
// and the third answer of `workspace.group.move`.
@MainActor
@Suite("Control command workspace-group nesting")
struct ControlCommandCoordinatorWorkspaceGroupNestingTests {
    private func request(_ method: String, _ params: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }

    private func snapshot(
        _ id: UUID,
        parent: UUID? = nil,
        anchor: UUID? = nil,
        members: [UUID] = [],
        holdsNothing: Bool? = nil
    ) -> ControlWorkspaceGroupSnapshot {
        ControlWorkspaceGroupSnapshot(
            id: id,
            name: "G",
            isCollapsed: false,
            isPinned: false,
            anchorWorkspaceID: anchor,
            customColor: nil,
            iconSymbol: nil,
            memberWorkspaceIDs: members,
            parentGroupID: parent,
            holdsNothing: holdsNothing
        )
    }

    private func listed(_ groups: [ControlWorkspaceGroupSnapshot]) -> [[String: JSONValue]] {
        let context = FakeWorkspaceGroupSafetyContext()
        context.listResolution = .resolved(windowID: nil, groups: groups)
        let coordinator = ControlCommandCoordinator(context: context)
        guard case .ok(.object(let body)) = coordinator.handle(request("workspace.group.list")),
              case .array(let rows)? = body["groups"] else {
            Issue.record("list did not succeed")
            return []
        }
        return rows.compactMap { if case .object(let o) = $0 { return o } else { return nil } }
    }

    @Test func parentGroupIdIsNullAtTheTopLevelAndTheParentsIdBelow() {
        let parent = UUID(), child = UUID()
        let rows = listed([
            snapshot(parent, anchor: UUID()),
            snapshot(child, parent: parent, anchor: UUID())
        ])
        #expect(rows.count == 2)
        #expect(rows[0]["parent_group_id"] == .null)
        #expect(rows[1]["parent_group_id"] == .string(parent.uuidString))
        // Groups come in the order they were handed over, a parent before its child.
        #expect(rows[0]["id"] == .string(parent.uuidString))
        #expect(rows[1]["id"] == .string(child.uuidString))
        // No `_ref` twin.
        #expect(rows[1]["parent_group_ref"] == nil)
    }

    @Test func isEmptyIsTrueOnlyWhenTheGroupHoldsNothing() {
        let a = UUID(), b = UUID(), c = UUID()
        let rows = listed([
            // A: has its own workspace.
            snapshot(a, anchor: UUID(), members: [UUID()], holdsNothing: false),
            // B: no workspace of its own, holds a group.
            snapshot(b, anchor: nil, members: [], holdsNothing: false),
            // C: holds nothing.
            snapshot(c, anchor: nil, members: [], holdsNothing: true)
        ])
        #expect(rows.map { $0["is_empty"] } == [.bool(false), .bool(false), .bool(true)])
        // `member_count` keeps counting the group's direct workspaces only.
        #expect(rows.map { $0["member_count"] } == [.int(1), .int(0), .int(0)])
    }

    @Test func aSnapshotWithoutTheNewValuesReadsAsAFlatGroupDid() {
        let withAnchor = snapshot(UUID(), anchor: UUID())
        let header = snapshot(UUID(), anchor: nil)
        #expect(!withAnchor.holdsNothing && withAnchor.parentGroupID == nil)
        #expect(header.holdsNothing)
    }

    @Test func moveAnswersForEachResolution() {
        let gid = UUID()
        func answer(_ resolution: ControlWorkspaceGroupMoveResolution) -> ControlCallResult? {
            let context = FakeWorkspaceGroupSafetyContext()
            context.moveResolution = resolution
            return ControlCommandCoordinator(context: context)
                .handle(request("workspace.group.move", ["group_id": .string(gid.uuidString), "to_index": .int(0)]))
        }
        if case .ok? = answer(.moved) {} else { Issue.record("moved should succeed") }
        if case .err(let code, let message, _)? = answer(.unresolved) {
            #expect(code == "invalid_params" && message == "Missing or unresolvable target position")
        } else { Issue.record("unresolved should fail") }
        if case .ok(.object(let body))? = answer(.unchanged) {
            #expect(body["group_id"] == .string(gid.uuidString))
            #expect(body["moved"] == nil, "a move that changes nothing carries no moved key")
            if case .ok(.object(let real))? = answer(.moved) {
                #expect(body == real, "a move that changes nothing answers the payload of a real move")
                #expect(real["moved"] == nil)
            } else { Issue.record("moved should succeed with an object") }
        } else { Issue.record("unchanged should succeed") }
        if case .err(let code, let message, let data)? = answer(.targetNotBeside) {
            #expect(code == "invalid_params")
            #expect(message == "Target group is not beside this group")
            #expect(data == .object(["group_id": .string(gid.uuidString)]))
        } else { Issue.record("not beside should fail") }
        if case .err(let code, _, _)? = answer(.tabManagerUnavailable) {
            #expect(code == "unavailable")
        } else { Issue.record("unavailable should fail") }
    }
}
