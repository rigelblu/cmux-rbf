import CmuxControlSocket
import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// The hand-over lines in files upstream owns, under an app delegate that holds his list (#cm-109.2). In a bare test
/// host the list in use is cmux's five, where one of his statuses resolves to what cmux detects and upstream's own
/// line cannot be told from this fork's. The delegate gets a store on a temporary file and its own defaults suite; the
/// app's store is never started.
@MainActor
@Suite("Workspace status hand-over lines", .serialized)
struct WorkspaceStatusHandOverTests {
    private typealias A = WorkspaceStatusActionsTests
    private struct NoDefaultsSuite: Error {}

    private static let hisText = """
    { "workspaceStatuses": [
      { "id": "doing", "name": "Doing", "extends": "working", "color": "#112233" },
      { "id": "parked", "name": "Parked", "extends": "todo", "color": "#445566" },
      { "id": "done", "name": "Done", "color": "#778899" }
    ] }
    """

    /// Runs `body` with `AppDelegate.shared` holding a store that has loaded his list.
    private func underHisList(_ body: () throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceStatusHandOverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("cmux.json")
        try Self.hisText.write(to: file, atomically: true, encoding: .utf8)
        let suite = "WorkspaceStatusHandOverTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw NoDefaultsSuite() }
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = WorkspaceStatusListStore(
            fileURL: file,
            defaults: defaults,
            resolveColor: { _ in nil },
            paletteFingerprint: { "fixed" },
            clock: ContinuousClock()
        )
        store.load()
        let previous = AppDelegate.shared
        let delegate = AppDelegate()
        delegate.workspaceStatusListStore = store
        AppDelegate.shared = delegate
        defer { AppDelegate.shared = previous }
        try body()
    }

    /// Runs `body` with a workspace a `TabManager` holds, registered with the delegate so the app's own color writer
    /// finds it, on a customization store of its own (a defaults suite removed afterwards, never `.standard`).
    private func inATabManager(
        _ body: (TabManager, Workspace, WorkspaceCustomizationStore) throws -> Void
    ) throws {
        let suite = "WorkspaceStatusHandOverTests.customizations.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw NoDefaultsSuite() }
        defer { defaults.removePersistentDomain(forName: suite) }
        let customizations = WorkspaceCustomizationStore(
            defaults: defaults,
            storageKey: "test.customizations",
            legacyStorageKey: "test.legacy-customizations"
        )
        let manager = TabManager(autoWelcomeIfNeeded: false, workspaceCustomizationStore: customizations)
        let workspace = try #require(manager.selectedWorkspace)
        let delegate = try #require(AppDelegate.shared)
        let windowId = delegate.registerMainWindowContextForTesting(tabManager: manager)
        defer { delegate.unregisterMainWindowContextForTesting(windowId: windowId) }
        try body(manager, workspace, customizations)
    }

    private func recordedColor(_ customizations: WorkspaceCustomizationStore, _ workspace: Workspace) -> String? {
        guard case .value(let hex)? = customizations.customization(for: workspace.stableId)?.customColor else {
            return nil
        }
        return hex
    }

    private let routing = ControlRoutingSelectors(
        hasWindowIDParam: false, windowID: nil, groupID: nil, workspaceID: nil, surfaceID: nil, paneID: nil
    )

    /// S1 and S2. The phone's press sets the status and leaves the color; the same press from this Mac, through the
    /// socket's cycle, writes it through the app's own resolver and writer, to the workspace and to the store that
    /// outlives a session. Delete the `withValue(.phone)` line and the first half fails.
    @Test func thePhonesCycleLeavesTheColorAndThisMacsCycleWritesIt() throws {
        try underHisList {
            try inATabManager { _, workspace, customizations in
                let panelId = try #require(workspace.focusedPanelId)
                workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .running)
                let colorBefore = workspace.customColor
                let recordedBefore = recordedColor(customizations, workspace)

                let phone = TerminalController.shared.v2MobileTodoDispatch(
                    method: "mobile.status.cycle",
                    params: ["workspace_id": workspace.id.uuidString]
                )
                guard case .ok = phone else {
                    Issue.record("the phone's cycle was not answered ok: \(phone)")
                    return
                }
                A.expectHolds(workspace, override: nil, own: "doing", hidden: false, "the phone's press")
                #expect(workspace.customColor == colorBefore, "the phone's press recolored the workspace")
                #expect(recordedColor(customizations, workspace) == recordedBefore)

                // The control: the same press from this Mac.
                workspace.clearTaskStatusOverride()
                let mac = TerminalController.shared.controlCycleWorkspaceTaskStatus(
                    routing: routing, workspaceID: workspace.id
                )
                guard case .resolved = mac else {
                    Issue.record("the socket's cycle did not resolve the workspace: \(mac)")
                    return
                }
                A.expectHolds(workspace, override: nil, own: "doing", hidden: false, "this Mac's press")
                #expect(workspace.customColor == "#112233")
                #expect(recordedColor(customizations, workspace) == "#112233")
            }
        }
    }

    /// The color menu's own path (`TabManager.applyWorkspaceColor`) leaves a status alone, and a status leaves the
    /// color a menu pick chose until he picks a status again.
    @Test func theColorMenuLeavesTheStatusAlone() throws {
        try underHisList {
            try inATabManager { manager, workspace, _ in
                WorkspaceStatusActions.app().apply(.status(id: "parked"), to: [workspace], requireControls: false)
                #expect(workspace.customColor == "#445566")
                manager.applyWorkspaceColor("#ABCDEF", to: [workspace])
                A.expectHolds(workspace, override: nil, own: "parked", hidden: false, "a color menu pick")
                manager.applyWorkspaceColor(nil, to: [workspace])
                A.expectHolds(workspace, override: nil, own: "parked", hidden: false, "clearing the color")
            }
        }
    }

    /// S5. With cmux's five, a cmux status set during a wait is removed when the wait ends, and the removal writes no
    /// color. The color the menu chose after the pick must still be there.
    @Test func theEndOfAWaitWritesNoColorThroughTheAppsWriter() throws {
        try inATabManager { manager, workspace, customizations in
            let panelId = try #require(workspace.focusedPanelId)
            workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .needsInput)
            WorkspaceStatusActions.app(list: .cmuxFive).apply(.done, to: [workspace], requireControls: false)
            #expect(workspace.todoState.statusOverride?.status == .done)
            manager.applyWorkspaceColor("#ABCDEF", to: [workspace])
            #expect(workspace.customColor == "#ABCDEF")
            #expect(recordedColor(customizations, workspace) == "#ABCDEF")

            workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .running)
            #expect(workspace.todoState.statusOverride == nil, "the status set during the wait is still stored")
            #expect(workspace.customColor == "#ABCDEF", "the end of the wait wrote a color")
            #expect(recordedColor(customizations, workspace) == "#ABCDEF")
        }
    }

    /// Sub-step 3f. Under his list, status set during wait is kept after wait ends; with .cmuxFive, it is cleared.
    @Test func statusSetDuringWaitIsKeptUnderHisListAndClearedWithCmuxFive() throws {
        try inATabManager { manager, workspace, _ in
            let panelId = try #require(workspace.focusedPanelId)

            // 1. Under his list: status set during wait is kept after wait ends.
            try underHisList {
                workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .needsInput)
                WorkspaceStatusActions.app().apply(.done, to: [workspace], requireControls: false)
                workspace.todoState.statusOverride = WorkspaceTaskStatusOverride(
                    status: .done,
                    inferredAtOverride: .needsAttention
                )
                #expect(workspace.todoState.statusOverride?.status == .done)

                workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .running)
                #expect(workspace.todoState.statusOverride != nil, "status set during wait is kept under his list")
                #expect(workspace.todoState.statusOverride?.status == .done)
            }

            // 2. With .cmuxFive: status set during wait is cleared when wait ends.
            workspace.todoState.statusOverride = nil
            workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .needsInput)
            WorkspaceStatusActions.app(list: .cmuxFive).apply(.done, to: [workspace], requireControls: false)
            #expect(workspace.todoState.statusOverride?.status == .done)
            #expect(workspace.todoState.statusOverride?.inferredAtOverride == .needsAttention)

            workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .running)
            #expect(workspace.todoState.statusOverride == nil, "status set during wait is cleared with cmuxFive")
        }
    }

    /// S3. `applyStatusOverride` is what both Status menus, the popover, the todo pane, the palette and the keys call. It
    /// must ask for the controls' gate: with the controls off it sets nothing, for each kind of action. The host's gate
    /// is off by default (a beta setting, off); this reads it and fails loudly if it is not.
    @Test func applyStatusOverrideSetsNothingWithTheControlsOff() throws {
        try #require(!WorkspaceTodoFeature.isEnabled, "this test needs the status controls off in the test host")
        let workspace = Workspace()
        let before = A.held(workspace)
        WorkspaceTodoActions.applyStatusOverride(.status(id: "review"), to: [workspace])
        WorkspaceTodoActions.applyStatusOverride(.auto, to: [workspace])
        WorkspaceTodoActions.applyStatusOverride(.done, to: [workspace])
        #expect(A.held(workspace) == before)
    }

    @Test func theListInUseIsTheStoresListUnderADelegateAndCmuxsFiveWithNone() throws {
        let previous = AppDelegate.shared
        AppDelegate.shared = nil
        #expect(AppDelegate.statusListInUse == .cmuxFive)
        AppDelegate.shared = previous
        try underHisList {
            #expect(AppDelegate.statusListInUse.source == .file)
            #expect(AppDelegate.statusListInUse.entries.map(\.id) == ["doing", "parked", "done"])
        }
    }

    @Test func effectiveTaskStatusReadsHisList() throws {
        try underHisList {
            let workspace = Workspace()
            let entry = try #require(AppDelegate.statusListInUse.entry(id: "doing"))
            workspace.setOwnStatus(entry)
            #expect(workspace.statusResolution(list: .cmuxFive).effective == .todo)
            #expect(workspace.effectiveTaskStatus == .working, "his status read as what cmux detects")
        }
    }

    @Test func cycleTaskStatusGoesThroughHisList() throws {
        try underHisList {
            let workspace = Workspace()
            let panelId = try #require(workspace.focusedPanelId)
            workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .running)
            workspace.cycleTaskStatus()
            A.expectHolds(workspace, override: nil, own: "doing", hidden: false, "cycleTaskStatus")
        }
    }

    @Test func theAppsWriteReadsTheOriginOfTheCallInProgress() {
        #expect(WorkspaceStatusActions.app(list: .cmuxFive).origin == .mac)
        WorkspaceStatusOrigin.$current.withValue(.phone) {
            #expect(WorkspaceStatusActions.app(list: .cmuxFive).origin == .phone)
        }
    }

    @Test func theSetterFamilyClearsHisOwnStatus() throws {
        for clear in [
            { (w: Workspace) in w.setTaskStatusOverride(.done) },
            { (w: Workspace) in w.clearTaskStatusOverride() },
            { (w: Workspace) in w.hideTaskStatus() },
        ] {
            let workspace = Workspace()
            workspace.setOwnStatus(A.hisEntries[1])
            #expect(workspace.todoState.ownStatus != nil)
            clear(workspace)
            #expect(workspace.todoState.ownStatus == nil)
            A.expectTable(workspace, "a setter")
        }
    }
}
