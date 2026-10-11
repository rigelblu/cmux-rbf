import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// The one write path (#cm-109.2): a status set, its color written, and what a workspace holds afterwards. Every
/// test passes its own list and its own color writer; none reads `~/.config/cmux/cmux.json` or `.standard`.
@MainActor
@Suite("Workspace status write path")
struct WorkspaceStatusActionsTests {
    typealias Entry = WorkspaceStatusEntry

    /// His list, in this order. `doing` extends Working and has a color; `plain` has none; `lost-color` names a
    /// color this app lacks; `done` is one of cmux's five with a color.
    nonisolated static let hisEntries = [
        Entry(id: "doing", name: "Doing", extends: .working, color: "1: DOING"),
        Entry(id: "parked", name: "Parked", extends: .todo, color: "5: PARKED"),
        Entry(id: "plain", name: "Plain", extends: .todo),
        Entry(id: "lost-color", name: "Lost", extends: .todo, color: "x9"),
        Entry(id: "done", name: "Done", color: "2: DONE"),
        Entry(id: "review", name: "Review", color: "3: REVIEW"),
    ]
    nonisolated static let hisList = WorkspaceStatusList(entries: hisEntries, source: .file)
    nonisolated static let palette = ["1: DOING": "#111111", "5: PARKED": "#555555", "2: DONE": "#222222", "3: REVIEW": "#333333"]

    /// Counts what the color writer is asked for.
    final class Writes {
        var all: [(hex: String, workspace: UUID)] = []
    }

    static func actions(
        _ list: WorkspaceStatusList = hisList,
        origin: WorkspaceStatusOrigin = .mac,
        controls: Bool = true,
        writes: Writes = Writes()
    ) -> WorkspaceStatusActions {
        WorkspaceStatusActions(
            list: list,
            origin: origin,
            controlsEnabled: controls,
            resolveColor: { palette[$0] },
            writeColor: { hex, workspace in
                writes.all.append((hex, workspace.id))
                workspace.setCustomColor(hex)
            }
        )
    }

    /// The table of what a workspace holds: the two are never both set, and None holds neither.
    static func expectTable(_ workspace: Workspace, _ note: String) {
        let state = workspace.todoState
        #expect(
            !(state.statusOverride != nil && state.ownStatus != nil),
            "both a cmux status and his own are held after \(note)"
        )
        if state.statusHidden {
            #expect(state.statusOverride == nil && state.ownStatus == nil, "None holds a status after \(note)")
        }
    }

    /// What a workspace holds, to compare before and after.
    struct Held: Equatable {
        var override: WorkspaceTaskStatus?
        var own: String?
        var hidden: Bool
    }

    static func held(_ workspace: Workspace) -> Held {
        Held(
            override: workspace.todoState.statusOverride?.status,
            own: workspace.todoState.ownStatus?.id,
            hidden: workspace.todoState.statusHidden
        )
    }

    /// Holds exactly these four values.
    static func expectHolds(
        _ workspace: Workspace,
        override: WorkspaceTaskStatus?,
        own: String?,
        hidden: Bool,
        _ note: String
    ) {
        #expect(workspace.todoState.statusOverride?.status == override, "statusOverride after \(note)")
        #expect(workspace.todoState.ownStatus?.id == own, "ownStatus after \(note)")
        #expect(workspace.todoState.statusHidden == hidden, "statusHidden after \(note)")
        expectTable(workspace, note)
    }

    // MARK: - Test 1: an id in the list is set

    @Test func anIdInTheListIsSet() {
        let workspace = Workspace()
        let result = Self.actions().apply(.status(id: "parked"), to: [workspace], requireControls: false)
        #expect(result == .set)
        Self.expectHolds(workspace, override: nil, own: "parked", hidden: false, "picking parked")
    }

    @Test func aCmuxIdInTheListIsSetAsCmuxsStatusAndNeverAsHisOwn() {
        let workspace = Workspace()
        Self.actions().apply(.done, to: [workspace], requireControls: false)
        Self.expectHolds(workspace, override: .done, own: nil, hidden: false, "picking done")
    }

    // MARK: - Test 4 and 5: the color

    @Test func aStatusWithAColorPutsItOnTheWorkspace() {
        let workspace = Workspace()
        let writes = Writes()
        Self.actions(writes: writes).apply(.done, to: [workspace], requireControls: false)
        #expect(workspace.customColor == "#222222")
        #expect(writes.all.count == 1)
    }

    @Test func aStatusOfHisOwnWithAColorPutsItOnTheWorkspace() {
        let workspace = Workspace()
        Self.actions().apply(.status(id: "parked"), to: [workspace], requireControls: false)
        #expect(workspace.customColor == "#555555")
    }

    /// The control for the color: the same pick from the phone sets the status and leaves the color.
    @Test func thePhoneSetsTheStatusAndWritesNoColor() {
        let workspace = Workspace()
        workspace.setCustomColor("#ABCDEF")
        let writes = Writes()
        Self.actions(origin: .phone, writes: writes).apply(.done, to: [workspace], requireControls: false)
        Self.expectHolds(workspace, override: .done, own: nil, hidden: false, "the phone picking done")
        #expect(workspace.customColor == "#ABCDEF")
        #expect(writes.all.isEmpty)
    }

    @Test func aColorThisAppLacksLeavesTheColorAndKeepsTheStatus() {
        let workspace = Workspace()
        workspace.setCustomColor("#ABCDEF")
        let writes = Writes()
        Self.actions(writes: writes).apply(.status(id: "lost-color"), to: [workspace], requireControls: false)
        Self.expectHolds(workspace, override: nil, own: "lost-color", hidden: false, "picking lost-color")
        #expect(workspace.customColor == "#ABCDEF")
        #expect(writes.all.isEmpty)
    }

    @Test func aStatusWithNoColorLeavesTheColor() {
        let workspace = Workspace()
        workspace.setCustomColor("#ABCDEF")
        Self.actions().apply(.status(id: "plain"), to: [workspace], requireControls: false)
        Self.expectHolds(workspace, override: nil, own: "plain", hidden: false, "picking plain")
        #expect(workspace.customColor == "#ABCDEF")
    }

    /// A cmux status the list leaves out, set by a script: set, with no entry and so no color.
    @Test func aCmuxStatusTheListLeavesOutIsSetWithNoColor() {
        let workspace = Workspace()
        workspace.setCustomColor("#ABCDEF")
        let writes = Writes()
        let list = WorkspaceStatusList(entries: Array(Self.hisEntries.prefix(3)), source: .file)
        let result = Self.actions(list, writes: writes).apply(.status(id: "working"), to: [workspace], requireControls: false)
        #expect(result == .set)
        Self.expectHolds(workspace, override: .working, own: nil, hidden: false, "setting working")
        #expect(workspace.customColor == "#ABCDEF")
        #expect(writes.all.isEmpty)
    }

    // MARK: - Test 9: an unknown id

    @Test func anUnknownIdIsRefusedWithTheAcceptedIdsAndNothingIsWritten() {
        let workspace = Workspace()
        workspace.setCustomColor("#ABCDEF")
        let before = Self.held(workspace)
        let list = WorkspaceStatusList(entries: Array(Self.hisEntries.prefix(3)), source: .file)
        let writes = Writes()
        let result = Self.actions(list, writes: writes).apply(.status(id: "nope"), to: [workspace], requireControls: false)
        // His ids in the file's order, then cmux's ids the list has no entry for in cmux's order, then auto and none.
        #expect(result == .unknown("nope", accepted: [
            "doing", "parked", "plain", "todo", "working", "needs-attention", "review", "done", "auto", "none",
        ]))
        #expect(Self.held(workspace) == before)
        #expect(workspace.customColor == "#ABCDEF")
        #expect(writes.all.isEmpty)
    }

    /// Targets that hold different things (one of his, a cmux status, nothing) are each left as they were, colors
    /// included. A single id is unknown to every target alike, so this shows the refusal happens before any write,
    /// not that a first target is written and a later one refused.
    @Test func anUnknownIdLeavesEveryTargetAsItWas() {
        let a = Workspace(), b = Workspace(), c = Workspace()
        Self.actions().apply(.status(id: "parked"), to: [a], requireControls: false)
        Self.actions().apply(.done, to: [b], requireControls: false)
        let before = [Self.held(a), Self.held(b), Self.held(c)]
        let colors = [a.customColor, b.customColor, c.customColor]
        let writes = Writes()
        Self.actions(writes: writes).apply(.status(id: "nope"), to: [a, b, c], requireControls: false)
        #expect([Self.held(a), Self.held(b), Self.held(c)] == before)
        #expect([a.customColor, b.customColor, c.customColor] == colors)
        #expect(writes.all.isEmpty)
    }

    // MARK: - Auto, None, controls, targets

    @Test func autoAndNoneLeaveTheColorAndClearTheStatus() {
        let workspace = Workspace()
        let writes = Writes()
        let actions = Self.actions(writes: writes)
        actions.apply(.status(id: "parked"), to: [workspace], requireControls: false)
        #expect(workspace.customColor == "#555555")
        actions.apply(.auto, to: [workspace], requireControls: false)
        Self.expectHolds(workspace, override: nil, own: nil, hidden: false, "Auto")
        #expect(workspace.customColor == "#555555")
        actions.apply(.status(id: "done"), to: [workspace], requireControls: false)
        #expect(workspace.customColor == "#222222")
        actions.apply(.hide, to: [workspace], requireControls: false)
        Self.expectHolds(workspace, override: nil, own: nil, hidden: true, "None")
        #expect(workspace.customColor == "#222222")
        #expect(writes.all.count == 2)
    }

    // "The Workspace Color menu leaves the status alone" (Expected Results line 57) is tested in
    // WorkspaceStatusHandOverTests, through the menu's own path (TabManager.applyWorkspaceColor). The test that was
    // here called Workspace.setCustomColor, which no line of this step can break, so it is deleted.

    @Test func theStatusControlsGateAnAppEntranceButNotTheSocket() {
        let workspace = Workspace()
        let before = Self.held(workspace)
        let writes = Writes()
        let off = Self.actions(controls: false, writes: writes)
        #expect(off.apply(.done, to: [workspace], requireControls: true) == .controlsOff)
        #expect(Self.held(workspace) == before)
        #expect(writes.all.isEmpty)
        #expect(off.apply(.done, to: [workspace], requireControls: false) == .set)
        Self.expectHolds(workspace, override: .done, own: nil, hidden: false, "the socket")
    }

    /// The menus that act on several selected workspaces: each gets the status and the color. A pinned one, and one
    /// inside a workspace group, too.
    @Test func severalWorkspacesEachGetTheStatusAndTheColor() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let child = try #require(manager.tabs.first)
        let groupId = try #require(manager.createWorkspaceGroup(name: "Group", childWorkspaceIds: [child.id]))
        #expect(child.groupId == groupId)
        let plain = Workspace(), pinned = Workspace()
        pinned.isPinned = true
        let targets = [plain, pinned, child]
        let writes = Writes()
        Self.actions(writes: writes).apply(.status(id: "parked"), to: targets, requireControls: true)
        for workspace in targets {
            Self.expectHolds(workspace, override: nil, own: "parked", hidden: false, "a multi-selection pick")
            #expect(workspace.customColor == "#555555")
        }
        #expect(Set(writes.all.map(\.workspace)) == Set(targets.map(\.id)))
    }

    @Test func markWorkspaceDoneIsTheDoneActionAndPutsDonesColor() {
        #expect(WorkspaceStatusPickAction.done == .status(id: "done"))
        let workspace = Workspace()
        Self.actions().apply(.done, to: [workspace], requireControls: true)
        #expect(workspace.customColor == "#222222")
    }

    // MARK: - The table of what a workspace holds, after every action

    @Test func theTableHoldsAfterEveryAction() {
        let workspace = Workspace()
        let actions = Self.actions()
        actions.apply(.status(id: "parked"), to: [workspace], requireControls: false)
        Self.expectHolds(workspace, override: nil, own: "parked", hidden: false, "one of his own")
        actions.apply(.done, to: [workspace], requireControls: false)
        Self.expectHolds(workspace, override: .done, own: nil, hidden: false, "a cmux status")
        actions.apply(.status(id: "doing"), to: [workspace], requireControls: false)
        Self.expectHolds(workspace, override: nil, own: "doing", hidden: false, "his own after a cmux status")
        actions.apply(.hide, to: [workspace], requireControls: false)
        Self.expectHolds(workspace, override: nil, own: nil, hidden: true, "None after his own")
        actions.apply(.status(id: "parked"), to: [workspace], requireControls: false)
        Self.expectHolds(workspace, override: nil, own: "parked", hidden: false, "his own after None")
        actions.apply(.auto, to: [workspace], requireControls: false)
        Self.expectHolds(workspace, override: nil, own: nil, hidden: false, "Auto after his own")
        actions.apply(.done, to: [workspace], requireControls: false)
        actions.apply(.auto, to: [workspace], requireControls: false)
        Self.expectHolds(workspace, override: nil, own: nil, hidden: false, "Auto after a cmux status")
        actions.apply(.done, to: [workspace], requireControls: false)
        actions.apply(.hide, to: [workspace], requireControls: false)
        Self.expectHolds(workspace, override: nil, own: nil, hidden: true, "None after a cmux status")
    }

    @Test func setOwnStatusTakesNoCmuxIdAndSetsHisAlone() {
        let workspace = Workspace()
        let before = Self.held(workspace)
        #expect(!workspace.setOwnStatus(Entry(id: "done", name: "Done")))
        #expect(Self.held(workspace) == before)
        workspace.setTaskStatusOverride(.review)
        #expect(workspace.setOwnStatus(Self.hisEntries[1]))
        Self.expectHolds(workspace, override: nil, own: "parked", hidden: false, "setOwnStatus")
    }

    // MARK: - The cycle

    private func running(_ workspace: Workspace) throws -> UUID {
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .running)
        return panelId
    }

    /// Test 8: on Auto with a running agent and his list, a press lands on `doing`, not on cmux's next status.
    @Test func aPressOnAutoWithARunningAgentLandsOnTheEntryThatExtendsWorking() throws {
        let workspace = Workspace()
        _ = try running(workspace)
        workspace.cycleStatusThroughList(actions: Self.actions())
        Self.expectHolds(workspace, override: nil, own: "doing", hidden: false, "a press")
        #expect(workspace.customColor == "#111111")
    }

    /// The cycle key and the socket's cycle are not gated by the status controls (Entrance 11, "still not gated"):
    /// with the controls off a press still sets the status and writes its color.
    @Test func aPressWithTheControlsOffStillSetsTheStatusAndItsColor() throws {
        let workspace = Workspace()
        _ = try running(workspace)
        workspace.cycleStatusThroughList(actions: Self.actions(controls: false))
        Self.expectHolds(workspace, override: nil, own: "doing", hidden: false, "a press with the controls off")
        #expect(workspace.customColor == "#111111")
    }

    @Test func aPressWithCmuxsFiveInUseIsCmuxsOwnAndWritesNoColor() {
        let workspace = Workspace()
        workspace.setCustomColor("#ABCDEF")
        let writes = Writes()
        workspace.cycleStatusThroughList(actions: Self.actions(.cmuxFive, writes: writes))
        Self.expectHolds(workspace, override: .working, own: nil, hidden: false, "a press with cmux's five")
        #expect(workspace.customColor == "#ABCDEF")
        #expect(writes.all.isEmpty)
    }

    @Test func aPressOnNoneActsAsAutoAndEngagesTheFeature() throws {
        let workspace = Workspace()
        _ = try running(workspace)
        workspace.hideTaskStatus()
        workspace.cycleStatusThroughList(actions: Self.actions())
        Self.expectHolds(workspace, override: nil, own: "doing", hidden: false, "a press on None")
    }

    @Test func aPressFromHisOwnStatusGoesOneUp() {
        let workspace = Workspace()
        Self.actions().apply(.status(id: "parked"), to: [workspace], requireControls: false)
        workspace.cycleStatusThroughList(actions: Self.actions())
        Self.expectHolds(workspace, override: nil, own: "doing", hidden: false, "a press from parked")
    }

    /// In a wait the press gives his `review` entry when the list has one, with its color (Decisions, 2026-10-12,
    /// point 13), and cmux's Review with no color when it has none.
    @Test func aPressDuringAWaitGivesHisReviewEntryWithItsColorOrCmuxsWithNone() throws {
        for (list, expectedColor) in [
            (Self.hisList, "#333333"),
            (WorkspaceStatusList(entries: Array(Self.hisEntries.prefix(3)), source: .file), "#ABCDEF"),
        ] {
            let workspace = Workspace()
            workspace.setCustomColor("#ABCDEF")
            let panelId = try #require(workspace.focusedPanelId)
            workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .needsInput)
            workspace.cycleStatusThroughList(actions: Self.actions(list))
            Self.expectHolds(workspace, override: .review, own: nil, hidden: false, "a press in a wait")
            #expect(workspace.customColor == expectedColor)
        }
    }

    @Test func anEmptyListChangesNothingOnAPress() {
        let workspace = Workspace()
        let before = Self.held(workspace)
        workspace.cycleStatusThroughList(actions: Self.actions(WorkspaceStatusList(entries: [], source: .file)))
        #expect(Self.held(workspace) == before)
    }
}
