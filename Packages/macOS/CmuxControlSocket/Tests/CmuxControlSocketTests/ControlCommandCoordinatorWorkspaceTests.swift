import Foundation
import CmuxSettings
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator workspace domain")
struct ControlCommandCoordinatorWorkspaceTests {
    private func coordinator() -> (ControlCommandCoordinator, FakeWorkspaceControlCommandContext) {
        let context = FakeWorkspaceControlCommandContext()
        return (ControlCommandCoordinator(context: context), context)
    }

    private func request(_ method: String, _ params: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }

    private func summary(id: UUID = UUID(), title: String, customTitle: String?) -> ControlWorkspaceSummary {
        ControlWorkspaceSummary(
            id: id,
            title: title,
            customTitle: customTitle,
            customDescription: nil,
            isPinned: false,
            listeningPorts: [],
            remoteStatus: .object([:]),
            currentDirectory: nil,
            customColor: nil,
            latestConversationMessage: nil,
            latestSubmittedMessage: nil,
            latestSubmittedAt: nil
        )
    }

    @Test func workspaceListExposesCustomTitleState() throws {
        let (coordinator, context) = coordinator()
        let workspaceID = UUID()
        context.listResolution = .resolved(
            windowID: nil,
            workspaces: [summary(id: workspaceID, title: "Manual name", customTitle: "Manual name")],
            selectedIndex: 0
        )

        guard case .ok(.object(let payload)) = coordinator.handle(request("workspace.list")),
              case .array(let rows) = payload["workspaces"],
              case .object(let row) = rows.first else {
            Issue.record("unexpected workspace.list shape")
            return
        }

        #expect(row["id"] == .string(workspaceID.uuidString))
        #expect(row["title"] == .string("Manual name"))
        #expect(row["custom_title"] == .string("Manual name"))
        #expect(row["has_custom_title"] == .bool(true))
    }

    @Test func workspaceCurrentExposesMissingCustomTitleState() throws {
        let (coordinator, context) = coordinator()
        let workspaceID = UUID()
        context.currentResolution = .resolved(
            windowID: nil,
            workspaceID: workspaceID,
            index: 0,
            summary: summary(id: workspaceID, title: "Terminal", customTitle: nil)
        )

        guard case .ok(.object(let payload)) = coordinator.handle(request("workspace.current")),
              case .object(let workspace) = payload["workspace"] else {
            Issue.record("unexpected workspace.current shape")
            return
        }

        #expect(workspace["title"] == .string("Terminal"))
        #expect(workspace["custom_title"] == .null)
        #expect(workspace["has_custom_title"] == .bool(false))
    }

    @Test func workspaceCloseReportsKnownTeardownFailureDistinctly() throws {
        let (coordinator, context) = coordinator()
        let workspaceID = UUID()
        let windowID = UUID()
        context.closeResolution = .closeFailed(windowID: windowID)

        guard case .err(let code, let message, .object(let data)) = coordinator.handle(request(
            "workspace.close",
            ["workspace_id": .string(workspaceID.uuidString)]
        )) else {
            Issue.record("unexpected workspace.close result")
            return
        }

        #expect(code == "internal_error")
        #expect(message == "close failed")
        #expect(data["window_id"] == .string(windowID.uuidString))
        #expect(data["workspace_id"] == .string(workspaceID.uuidString))
    }

    @Test func workspaceGroupAddForwardsPlacementAndReference() throws {
        let (coordinator, context) = coordinator()
        let groupID = UUID()
        let workspaceID = UUID()
        let referenceWorkspaceID = UUID()
        context.addWorkspaceToGroupResolution = .added

        guard case .ok(.object(let payload)) = coordinator.handle(request("workspace.group.add", [
            "group_id": .string(groupID.uuidString),
            "workspace_id": .string(workspaceID.uuidString),
            "placement": .string("after-current"),
            "reference_workspace_id": .string(referenceWorkspaceID.uuidString),
        ])) else {
            Issue.record("unexpected workspace.group.add result")
            return
        }

        #expect(payload["group_id"] == .string(groupID.uuidString))
        #expect(payload["workspace_id"] == .string(workspaceID.uuidString))
        #expect(context.addWorkspaceToGroupCall?.groupID == groupID)
        #expect(context.addWorkspaceToGroupCall?.workspaceID == workspaceID)
        #expect(context.addWorkspaceToGroupCall?.placement == .afterCurrent)
        #expect(context.addWorkspaceToGroupCall?.referenceWorkspaceID == referenceWorkspaceID)
    }

    @Test func workspaceGroupAddAcceptsNullReferenceWorkspaceID() throws {
        let (coordinator, context) = coordinator()
        let groupID = UUID()
        let workspaceID = UUID()
        context.addWorkspaceToGroupResolution = .added

        guard case .ok(.object(let payload)) = coordinator.handle(request("workspace.group.add", [
            "group_id": .string(groupID.uuidString),
            "workspace_id": .string(workspaceID.uuidString),
            "placement": .string("top"),
            "reference_workspace_id": .null,
        ])) else {
            Issue.record("unexpected workspace.group.add result")
            return
        }

        #expect(payload["group_id"] == .string(groupID.uuidString))
        #expect(payload["workspace_id"] == .string(workspaceID.uuidString))
        #expect(context.addWorkspaceToGroupCall?.groupID == groupID)
        #expect(context.addWorkspaceToGroupCall?.workspaceID == workspaceID)
        #expect(context.addWorkspaceToGroupCall?.placement == .top)
        #expect(context.addWorkspaceToGroupCall?.referenceWorkspaceID == nil)
    }

    @Test func workspaceGroupAddRejectsReferenceOutsideTargetGroup() throws {
        let (coordinator, context) = coordinator()
        let groupID = UUID()
        let workspaceID = UUID()
        let referenceWorkspaceID = UUID()
        context.addWorkspaceToGroupResolution = .invalidReferenceWorkspace

        guard case .err(let code, let message, let data) = coordinator.handle(request("workspace.group.add", [
            "group_id": .string(groupID.uuidString),
            "workspace_id": .string(workspaceID.uuidString),
            "placement": .string("afterCurrent"),
            "reference_workspace_id": .string(referenceWorkspaceID.uuidString),
        ])) else {
            Issue.record("unexpected workspace.group.add result")
            return
        }

        #expect(code == "invalid_params")
        #expect(message == "invalid reference workspace")
        #expect(data == .object(["reference_workspace_id": .string(referenceWorkspaceID.uuidString)]))
        #expect(context.addWorkspaceToGroupCall?.referenceWorkspaceID == referenceWorkspaceID)
    }

    @Test func workspaceGroupAddRejectsInvalidPlacement() throws {
        let (coordinator, context) = coordinator()
        let groupID = UUID()
        let workspaceID = UUID()

        guard case .err(let code, let message, _) = coordinator.handle(request("workspace.group.add", [
            "group_id": .string(groupID.uuidString),
            "workspace_id": .string(workspaceID.uuidString),
            "placement": .string("middle"),
        ])) else {
            Issue.record("unexpected workspace.group.add result")
            return
        }

        #expect(code == "invalid_params")
        #expect(message == "Invalid placement")
        #expect(context.addWorkspaceToGroupCall == nil)
    }

    @Test func terminalSessionEndForwardsLifecycleRetirementIntent() throws {
        let (coordinator, context) = coordinator()
        let workspaceID = UUID()
        let surfaceID = UUID()
        let sessionID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let lifecycleID = "11111111-2222-3333-4444-555555555555"
        context.terminalSessionEndResolution = .resolved(
            windowID: nil,
            workspaceID: workspaceID,
            remoteStatus: .object([:])
        )

        guard case .ok = coordinator.handle(request("workspace.remote.terminal_session_end", [
            "workspace_id": .string(workspaceID.uuidString),
            "surface_id": .string(surfaceID.uuidString),
            "session_id": .string(sessionID),
            "lifecycle_id": .string(lifecycleID),
            "lifecycle_only": .bool(true),
        ])) else {
            Issue.record("unexpected terminal_session_end result")
            return
        }

        #expect(context.terminalSessionEndCall?.workspaceID == workspaceID)
        #expect(context.terminalSessionEndCall?.surfaceID == surfaceID)
        #expect(context.terminalSessionEndCall?.relayPort == nil)
        #expect(context.terminalSessionEndCall?.sessionID == sessionID)
        #expect(context.terminalSessionEndCall?.lifecycleID == lifecycleID)
        #expect(context.terminalSessionEndCall?.lifecycleOnly == true)
    }

    @Test func lifecycleOnlySessionEndRejectsMissingGeneration() throws {
        let (coordinator, context) = coordinator()
        guard case .err(let code, _, _) = coordinator.handle(request(
            "workspace.remote.terminal_session_end",
            [
                "workspace_id": .string(UUID().uuidString),
                "surface_id": .string(UUID().uuidString),
                "lifecycle_only": .bool(true),
            ]
        )) else {
            Issue.record("incomplete lifecycle-only request was accepted")
            return
        }

        #expect(code == "invalid_params")
        #expect(context.terminalSessionEndCall == nil)
    }

    // MARK: - workspace.color.list (`#cm-11`)

    /// Read-only discovery, so automation can learn the vocabulary
    /// `workspace-action set-color` accepts without a human reading Settings.
    @Test func workspaceColorListExposesTheEffectivePalette() throws {
        let (coordinator, context) = coordinator()
        context.colorPalette = [
            ControlWorkspaceColorEntry(
                name: "Teal", label: "GOAL: Primary", displayName: "GOAL: Primary (Teal)", hex: "#006B6B"
            ),
            ControlWorkspaceColorEntry(name: "Red", label: nil, displayName: "Red", hex: "#C0392B"),
        ]

        guard case .ok(.object(let payload)) = coordinator.handle(request("workspace.color.list")),
              case .array(let rows) = payload["colors"],
              case .object(let labelled) = rows.first,
              case .object(let bare) = rows.last else {
            Issue.record("unexpected workspace.color.list shape")
            return
        }

        #expect(rows.count == 2)
        #expect(labelled["name"] == .string("Teal"))
        #expect(labelled["label"] == .string("GOAL: Primary"))
        #expect(labelled["display_name"] == .string("GOAL: Primary (Teal)"))
        #expect(labelled["hex"] == .string("#006B6B"))

        // Null rather than an omitted key or an echoed name, so a consumer can tell
        // "unlabelled" from "labelled with its own name".
        #expect(bare["label"] == .null)
        #expect(bare["display_name"] == .string("Red"))
    }

    @Test func workspaceColorListReportsAnEmptyPaletteAsAnEmptyList() throws {
        // `context` is bound rather than discarded: the coordinator holds it weakly, so
        // `let (coordinator, _)` deallocates it and every method answers `unavailable`.
        let (coordinator, context) = coordinator()
        context.colorPalette = []

        guard case .ok(.object(let payload)) = coordinator.handle(request("workspace.color.list")),
              case .array(let rows) = payload["colors"] else {
            Issue.record("unexpected workspace.color.list shape")
            return
        }
        // An empty array, never a missing key: scripts should be able to iterate
        // unconditionally rather than branch on presence.
        #expect(rows.isEmpty)
    }
}
