import AppKit
import SwiftUI
import CmuxAppKitSupportUI
import CmuxCommandPalette
import CmuxControlSocket
import CmuxSettings
import CmuxSidebar
import CmuxWorkspaces
import Combine
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// The places a status is offered or shown, with a list handed in (#cm-109.2, step 2g): the palette, the rows a picker
/// draws, the snapshot the factory builds and what tells the sidebar and the phone that a status changed. Every test
/// passes its own list; none reads the store, `~/.config/cmux/cmux.json` or `.standard`. A status of his is put on a
/// workspace the way the app does (`setOwnStatus`), except where a test is about one field and says so.
@MainActor
@Suite("Workspace status entrances", .serialized)
struct WorkspaceStatusEntrancesTests {
    typealias Entry = WorkspaceStatusEntry

    /// His eleven, in the file's order. `review` and `done` are cmux's own ids under his words.
    nonisolated static let hisEntries = [
        Entry(id: "inbox", name: "Inbox", extends: .todo, color: "#101010"),
        Entry(id: "parked", name: "Parked", extends: .todo, color: "#445566"),
        Entry(id: "doing", name: "Doing", extends: .working, color: "#112233"),
        Entry(id: "blocked", name: "Blocked", extends: .needsAttention, color: "Mauve"),
        Entry(id: "waiting", name: "Waiting", extends: .needsAttention),
        Entry(id: "review", name: "Reviewing", icon: .shape(.threeQuarters)),
        Entry(id: "qa", name: "QA", extends: .review, color: "#334455"),
        Entry(id: "shipped", name: "Shipped", extends: .done, color: "#00AA00"),
        Entry(id: "done", name: "Done"),
        Entry(id: "later", name: "Later", extends: .todo),
        Entry(id: "idea", name: "Idea", extends: .todo, color: "#ABCDEF"),
    ]
    nonisolated static let hisList = WorkspaceStatusList(entries: hisEntries, source: .file)
    /// Parked, Doing and Done only; `working` is a cmux status this list leaves out.
    nonisolated static let shortList = WorkspaceStatusList(
        entries: [hisEntries[1], hisEntries[2], hisEntries[8]], source: .file
    )

    private func subtitle(_ context: CommandPaletteContextSnapshot) -> String { "" }

    /// Ids of the status-related contributions, in the order the palette lists them.
    private func statusCommandIDs(_ contributions: [CommandPaletteCommandContribution]) -> [String] {
        contributions.map(\.commandId).filter {
            $0.hasPrefix("palette.workspaceStatus") || $0 == WorkspaceTodoPaletteCommands.markWorkspaceDoneCommandId
        }
    }

    private func settings(showAgentActivity: Bool = true) -> (SidebarTabItemSettingsSnapshot, () -> Void) {
        let suite = "WorkspaceStatusEntrancesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        if !showAgentActivity {
            defaults.set(false, forKey: "sidebarShowAgentActivity")
            defaults.set(false, forKey: "sidebar.showAgentActivity")
        }
        return (SidebarTabItemSettingsSnapshot(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }

    private func factory(
        _ workspace: Workspace,
        list: WorkspaceStatusList,
        hexes: [String: String] = [:],
        settings: SidebarTabItemSettingsSnapshot,
        showsAgentActivity: Bool = false
    ) -> SidebarWorkspaceSnapshotFactory {
        SidebarWorkspaceSnapshotFactory(
            workspace: workspace, settings: settings, showsAgentActivity: showsAgentActivity, todoControlsEnabled: true,
            statusList: list, statusColorHexes: hexes
        )
    }

    private func picker(
        _ list: WorkspaceStatusList,
        override: WorkspaceTaskStatusOverride? = nil,
        own: WorkspaceOwnStatus? = nil,
        inferred: WorkspaceTaskStatus = .todo,
        hidden: Bool = false
    ) -> WorkspaceStatusPickerState {
        let resolution = WorkspaceStatusResolution.resolve(override: override, own: own, inferred: inferred, list: list)
        return WorkspaceStatusPicker().rows(resolution: resolution, inferred: inferred, isHidden: hidden, list: list)
    }

    // MARK: - Test 6 and entrance row 9: the palette

    /// Test 6. Built with his list, the palette holds one command for each entry in the file's order, between Auto and
    /// Mark Workspace as Done, with the id `palette.workspaceStatus.<id>`.
    @Test func thePalettesContributionsFollowHisListInTheFilesOrder() {
        let contributions = WorkspaceTodoPaletteCommands.contributions(
            workspaceSubtitle: subtitle, list: Self.hisList, controlsEnabled: true
        )
        let expected = ["palette.workspaceStatusAuto"]
            + Self.hisEntries.map { "palette.workspaceStatus.\($0.id)" }
            + [WorkspaceTodoPaletteCommands.markWorkspaceDoneCommandId]
        #expect(statusCommandIDs(contributions) == expected)
        #expect(statusCommandIDs(contributions).contains("palette.workspaceStatus.parked"))
    }

    @Test func withCmuxsFiveTheContributionIDsAndTitlesAreToday() {
        let contributions = WorkspaceTodoPaletteCommands.contributions(
            workspaceSubtitle: subtitle, list: .cmuxFive, controlsEnabled: true
        )
        let expected = ["palette.workspaceStatusAuto"]
            + WorkspaceTaskStatus.allCases.map { "palette.workspaceStatus.\($0.rawValue)" }
            + [WorkspaceTodoPaletteCommands.markWorkspaceDoneCommandId]
        #expect(statusCommandIDs(contributions) == expected)
        for status in WorkspaceTaskStatus.allCases {
            let contribution = contributions.first { $0.commandId == "palette.workspaceStatus.\(status.rawValue)" }
            let today = String(
                format: String(localized: "command.workspaceStatus.title", defaultValue: "Workspace Status: %@"),
                locale: .current,
                status.displayName
            )
            #expect(contribution?.title(CommandPaletteContextSnapshot()) == today)
        }
    }

    @Test func aCommandsTitleUsesHisWordAndCmuxsNameWhereHeGaveNone() {
        let contributions = WorkspaceTodoPaletteCommands.contributions(
            workspaceSubtitle: subtitle, list: Self.hisList, controlsEnabled: true
        )
        func title(_ id: String) -> String? {
            contributions.first { $0.commandId == "palette.workspaceStatus.\(id)" }?.title(CommandPaletteContextSnapshot())
        }
        let format = String(localized: "command.workspaceStatus.title", defaultValue: "Workspace Status: %@")
        #expect(title("parked") == String(format: format, locale: .current, "Parked"))
        #expect(title("review") == String(format: format, locale: .current, "Reviewing"))
    }

    @Test func theControlsOffLeaveNoStatusCommands() {
        let contributions = WorkspaceTodoPaletteCommands.contributions(
            workspaceSubtitle: subtitle, list: Self.hisList, controlsEnabled: false
        )
        #expect(statusCommandIDs(contributions).isEmpty)
    }

    /// Auto's handler passes `.auto`, a status's handler passes its id, Mark Workspace as Done passes `.done`; with the
    /// controls off none of them applies anything.
    @Test func theHandlersApplyTheActionOfTheirCommand() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        for enabled in [true, false] {
            var registry = CommandPaletteHandlerRegistry()
            var applied: [(WorkspaceStatusPickAction, [UUID])] = []
            WorkspaceTodoPaletteCommands.registerHandlers(
                in: &registry,
                tabManager: manager,
                list: Self.hisList,
                controlsEnabled: enabled,
                apply: { action, workspaces in applied.append((action, workspaces.map(\.id))) }
            )
            registry.handler(for: "palette.workspaceStatusAuto")?()
            registry.handler(for: "palette.workspaceStatus.parked")?()
            registry.handler(for: "palette.workspaceStatus.done")?()
            registry.handler(for: WorkspaceTodoPaletteCommands.markWorkspaceDoneCommandId)?()
            if enabled {
                #expect(applied.map(\.0) == [.auto, .status(id: "parked"), .status(id: "done"), .done])
                #expect(applied.allSatisfy { $0.1 == [workspace.id] })
            } else {
                #expect(applied.isEmpty, "the controls are off and \(applied.count) actions were applied")
            }
        }
    }

    // MARK: - Test 7 and entrance row 3: the rows

    /// Test 7. The rows from the form of `lanes` that takes the picker's state, with his list: Auto, his eleven in the
    /// file's order, None; each status row carries its id as the action and the color the snapshot was given.
    @Test func theRowsAreAutoHisElevenInTheFilesOrderAndNone() {
        let hexes = ["parked": "#445566", "doing": "#112233"]
        let lanes = WorkspaceTodoStatusLane.lanes(picker: picker(Self.hisList), colorHexes: hexes)
        #expect(lanes.map(\.id) == ["auto"] + Self.hisEntries.map(\.id) + ["none"])
        #expect(lanes.map(\.action) == [.auto] + Self.hisEntries.map { .status(id: $0.id) } + [.hide])
        #expect(lanes.dropFirst().dropLast().map(\.title) == [
            "Inbox", "Parked", "Doing", "Blocked", "Waiting", "Reviewing", "QA", "Shipped", "Done", "Later", "Idea",
        ])
        #expect(lanes.dropFirst().dropLast().map(\.colorHex) == Self.hisEntries.map { hexes[$0.id] })
        #expect(lanes.last?.isNone == true)
        #expect(lanes.first?.isSelected == true, "Auto is checked when nothing is held")
    }

    /// With cmux's five in use the rows are upstream's, one for one, in every state a workspace can be in.
    @Test func withCmuxsFiveInUseTheRowsEqualUpstreamsOneForOne() {
        for inferred in WorkspaceTaskStatus.allCases {
            for active in [nil] + WorkspaceTaskStatus.allCases.map(Optional.some) {
                for hidden in [false, true] {
                    let override = active.map { WorkspaceTaskStatusOverride(status: $0, inferredAtOverride: inferred) }
                    let ours = WorkspaceTodoStatusLane.lanes(
                        picker: picker(.cmuxFive, override: override, inferred: inferred, hidden: hidden)
                    )
                    let upstream = WorkspaceTodoStatusLane.lanes(inferred: inferred, activeOverride: active, isHidden: hidden)
                    #expect(
                        ours == upstream,
                        "inferred \(inferred) override \(String(describing: active)) hidden \(hidden)"
                    )
                }
            }
        }
    }

    /// The greyed row, in both of its forms: a cmux status the list leaves out, and one of his own the list lacks. It
    /// has no action, its words, no color, and the id the picker gives it; Auto is unchecked beside it.
    @Test func theGreyedRowHasNoActionItsWordsAndAutoIsUncheckedBesideIt() {
        let leftOut = WorkspaceTodoStatusLane.lanes(picker: picker(
            Self.shortList,
            override: WorkspaceTaskStatusOverride(status: .working, inferredAtOverride: .todo)
        ))
        let lacking = WorkspaceTodoStatusLane.lanes(picker: picker(Self.shortList, own: WorkspaceOwnStatus(id: "gone")))
        let format = String(localized: "sidebar.status.notInList", defaultValue: "%@ · not in your list")
        for (lanes, words, glyph) in [
            (leftOut, String(format: format, locale: .current, WorkspaceTaskStatus.working.displayName), WorkspaceTaskStatus.working),
            (lacking, String(format: format, locale: .current, "gone"), nil),
        ] {
            let greyed = lanes.filter { $0.action == nil }
            #expect(greyed.count == 1)
            #expect(greyed.first?.title == words)
            #expect(greyed.first?.status == glyph)
            #expect(greyed.first?.colorHex == nil)
            #expect(greyed.first?.id == " held")
            #expect(greyed.first?.isSelected == true)
            #expect(lanes.first?.action == .auto)
            #expect(lanes.first?.isSelected == false, "Auto is checked beside a greyed row")
            #expect(Set(lanes.map(\.id)).count == lanes.count, "two rows share an id")
        }
    }

    /// Promise (11_expected-results.md, line 42): Auto names a status he left out by cmux's own name, and names one he
    /// listed by his word.
    @Test func autoNamesAStatusHeLeftOutByCmuxsNameAndOneHeListedByHisWord() {
        func autoTitle(_ list: WorkspaceStatusList, inferred: WorkspaceTaskStatus) -> String? {
            WorkspaceTodoStatusLane.lanes(picker: picker(list, inferred: inferred)).first?.title
        }
        func expected(_ name: String) -> String {
            String(format: String(localized: "contextMenu.workspaceStatus.auto", defaultValue: "Auto — %@"), locale: .current, name)
        }
        #expect(autoTitle(Self.shortList, inferred: .working) == expected(WorkspaceTaskStatus.working.displayName))
        #expect(autoTitle(Self.hisList, inferred: .review) == expected("Reviewing"))
        #expect(autoTitle(Self.hisList, inferred: .working) == expected(WorkspaceTaskStatus.working.displayName))
    }

    // MARK: - Entrance row 3: the row input

    func rowInput(_ snapshot: SidebarWorkspaceSnapshotBuilder.Snapshot, settings: SidebarTabItemSettingsSnapshot, workspaceId: UUID = UUID()) -> SidebarWorkspaceRowInput {
        SidebarWorkspaceRowInput(
            workspaceId: workspaceId, groupId: nil, isColorSectionMember: false, index: 0, workspaceCount: 1,
            workspace: snapshot, isActive: false, isMultiSelected: false, hasUserCustomTitle: false,
            hasCustomTitle: false, hasCustomDescription: false, customTitle: nil, workspaceShortcutDigit: nil,
            workspaceShortcutModifierSymbol: "⌘", canCloseWorkspace: true, unreadCount: 0, latestNotificationText: nil,
            showsAgentActivity: false, rowSpacing: 0, showsModifierShortcutHints: false, isPointerHovering: false,
            isBeingDragged: false, topDropIndicatorVisible: false, bottomDropIndicatorVisible: false,
            settings: settings, isChecklistExpanded: false, checklistAddFieldActivationToken: 0,
            isChecklistPopoverPresented: false, isRemoteContextMenuEligible: false, remoteConnectionState: .disconnected,
            contextMenuPinState: nil, inferredTaskStatus: .todo, activeTodoOverride: nil, isTodoStatusHidden: false
        )
    }

    func rowSnapshot(_ input: SidebarWorkspaceRowInput) -> SidebarWorkspaceRowSnapshot {
        let list = SidebarWorkspaceRowsSnapshot(
            workspaceRowsById: [input.workspaceId: input], groupRowsById: [:],
            selectedContextTargetIds: [input.workspaceId], anchorWorkspaceIds: [],
            workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot(items: []), canCreateEmptyGroup: false,
            notificationIndex: SidebarWorkspaceNotificationIndex(notifications: [])
        )
        return input.rowSnapshot(list: list)
    }

    /// Entrance row 3: the row input's `rowSnapshot` reads his eleven from the snapshot's picker, with the colors the
    /// snapshot holds; a row whose snapshot has no picker reads no status rows, and never upstream's five.
    @Test func theRowInputReadsHisElevenFromThePickerAndAnEmptyRowGetsNone() {
        let (settings, cleanUp) = settings()
        defer { cleanUp() }
        let workspace = Workspace()
        workspace.clearTaskStatusOverride()
        let hexes = ["parked": "#445566"]
        let snapshot = factory(workspace, list: Self.hisList, hexes: hexes, settings: settings).makeSnapshot()
        let lanes = rowSnapshot(rowInput(snapshot, settings: settings)).contextMenu.todoStatusLanes
        #expect(lanes.map(\.id) == ["auto"] + Self.hisEntries.map(\.id) + ["none"])
        #expect(lanes.first { $0.id == "parked" }?.colorHex == "#445566")

        let bare = SidebarWorkspaceSnapshotRefreshPolicyTests.snapshot()
        #expect(bare.taskStatusInput.picker == nil)
        #expect(rowSnapshot(rowInput(bare, settings: settings)).contextMenu.todoStatusLanes.isEmpty)
    }

    // MARK: - Entrance rows 15 and 22: the snapshot the factory builds

    @Test func theSnapshotForOneWorkspaceDiffersWithAnotherListAndAnotherColor() {
        let (settings, cleanUp) = settings()
        defer { cleanUp() }
        let workspace = Workspace()
        workspace.clearTaskStatusOverride()
        let withHis = factory(workspace, list: Self.hisList, settings: settings).makeSnapshot()
        let withShort = factory(workspace, list: Self.shortList, settings: settings).makeSnapshot()
        let withFive = factory(workspace, list: .cmuxFive, settings: settings).makeSnapshot()
        #expect(withHis != withShort)
        #expect(withHis != withFive)
        #expect(withHis.taskStatusInput.picker?.rows.count == Self.hisEntries.count + 2)
        #expect(withShort.taskStatusInput.picker?.rows.count == Self.shortList.entries.count + 2)
        let colored = factory(workspace, list: Self.hisList, hexes: ["parked": "#445566"], settings: settings).makeSnapshot()
        #expect(withHis != colored, "a color the app resolved did not change the snapshot")
        #expect(withHis == factory(workspace, list: Self.hisList, settings: settings).makeSnapshot())
    }

    /// Entrance row 15. Under his list, one of his statuses in effect makes the glyph show, in the shape of the status
    /// it extends; under cmux's five the same id is not in the list and nothing shows.
    @Test func theFactoryUnderHisListShowsTheGlyphForTheStatusItExtends() throws {
        let (settings, cleanUp) = settings()
        defer { cleanUp() }
        let workspace = Workspace()
        workspace.setOwnStatus(try #require(Self.hisList.entry(id: "doing")))
        let his = factory(workspace, list: Self.hisList, settings: settings).makeSnapshot()
        #expect(his.taskStatus == .working)
        #expect(his.hasManualTaskStatus)
        #expect(his.todoStatusMenuModel?.picker == his.taskStatusInput.picker, "the small model does not carry the snapshot's picker")
        #expect(his.taskStatusInput.picker != nil)
        let five = factory(workspace, list: .cmuxFive, settings: settings).makeSnapshot()
        #expect(five.taskStatus == workspace.inferredTaskStatus)
        #expect(!five.hasManualTaskStatus)
        // A cmux status set by hand still shows under cmux's five, as today.
        workspace.setTaskStatusOverride(.review)
        let cmux = factory(workspace, list: .cmuxFive, settings: settings).makeSnapshot()
        #expect(cmux.taskStatus == .review)
        #expect(cmux.hasManualTaskStatus)
    }

    /// While an agent waits, a workspace that holds one of his statuses keeps drawing the glyph of that status: a wait
    /// is an event, not a status. The row stays in play (`attentionTaskStatus`) and the status the workspace reports
    /// stays needs-attention.
    @Test func aWaitLeavesTheGlyphOfTheStatusHeHolds() throws {
        let (settings, cleanUp) = settings()
        defer { cleanUp() }
        let workspace = Workspace()
        workspace.setOwnStatus(try #require(Self.hisList.entry(id: "parked")), list: Self.hisList)
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .needsInput)
        // The fixture checks upstream's live inference, independent of another suite's installed status list.
        #expect(workspace.inferredTaskStatus(list: .cmuxFive) == .needsAttention, "no wait was detected, so the test proves nothing")
        let snapshot = factory(workspace, list: Self.hisList, settings: settings).makeSnapshot()
        #expect(snapshot.hasManualTaskStatus, "his status is held through the wait but the glyph is not drawn")
        #expect(snapshot.taskStatus == .todo, "the glyph shows \(String(describing: snapshot.taskStatus)), not the status he holds")
        #expect(snapshot.attentionTaskStatus == .needsAttention, "the row is no longer in play during the wait")
    }

    /// Entrance row: the snapshot factory passes the status color hexes to the compact status menu model, and the
    /// picker's checked entry carries Review's icon (#cm-109.3).
    @Test func theSnapshotFactoryPassesColorHexesAndIconToTheCompactMenuModel() throws {
        let (settings, cleanUp) = settings()
        defer { cleanUp() }
        let workspace = Workspace()
        workspace.setTaskStatusOverride(.review)
        let hexes = ["review": "#336699"]
        let snapshot = factory(workspace, list: Self.hisList, hexes: hexes, settings: settings).makeSnapshot()
        #expect(snapshot.todoStatusMenuModel?.colorHexes == hexes)
        let checked = try #require(WorkspaceStatusPresentation.checkedEntry(in: snapshot.todoStatusMenuModel?.picker))
        #expect(checked.icon == .shape(.threeQuarters))
    }

    // MARK: - Entrance rows 13 and 19

    #if DEBUG
    /// Entrance row 13. The phone's re-send check hashes `ownStatus`. The field is written directly so that
    /// `statusHidden`, which `setOwnStatus` also writes, does not change: this test is about that one line.
    @Test func thePhonesHashChangesWithHisOwnStatus() {
        let workspace = Workspace()
        let before = MobileWorkspaceListObserver.summaryHashForTesting(tabs: [workspace], selectedTabID: workspace.id)
        workspace.todoState.ownStatus = WorkspaceOwnStatus(id: "parked")
        let after = MobileWorkspaceListObserver.summaryHashForTesting(tabs: [workspace], selectedTabID: workspace.id)
        #expect(before != after, "his own status is not in the hash the phone's re-send check compares")
    }
    #endif

    /// Entrance row 19. The sidebar's immediate observation emits when only `ownStatus` changes. The field is written
    /// directly, as above. The observation's coalescer forwards the current state at once on subscription and the first
    /// change after an idle period at once (`Sources/CoalesceLatestPublisher.swift`), so both emissions have happened by
    /// the time the statement that caused them returns: the test counts, and waits for nothing. (`@Published` publishes
    /// in `willSet`, so a sink that reads the property during the emission still sees the old value; the count is
    /// what carries the proof.)
    @Test func theSidebarObservationEmitsWhenOnlyHisOwnStatusChanges() {
        let workspace = Workspace()
        var emissions = 0
        let cancellable = workspace.sidebarImmediateObservationPublisher.sink { emissions += 1 }
        #expect(emissions == 1, "the subscription did not replay the current state at once: \(emissions) emissions")
        workspace.todoState.ownStatus = WorkspaceOwnStatus(id: "parked")
        #expect(emissions == 2, "a change of his own status alone did not reach the sidebar's observation: \(emissions) emissions")
        cancellable.cancel()
    }

    // MARK: - Entrance row 6 and the glyph's name: the todo pane's working-out, over the six resolutions

    /// The six cases of what a workspace shows, each reached through `resolve` the way the app reaches it.
    private func sixResolutions() -> [(String, WorkspaceStatusResolution)] {
        let his = Self.hisList
        return [
            ("detected", .resolve(override: nil, own: nil, inferred: .todo, list: his)),
            ("cmux status in effect, in his list under his word", .resolve(
                override: WorkspaceTaskStatusOverride(status: .review, inferredAtOverride: .todo), own: nil, inferred: .todo, list: his
            )),
            ("cmux status the list leaves out, in effect", .resolve(
                override: WorkspaceTaskStatusOverride(status: .working, inferredAtOverride: .todo), own: nil, inferred: .todo, list: his
            )),
            ("cmux status lapsed", .resolve(
                override: WorkspaceTaskStatusOverride(status: .done, inferredAtOverride: .todo), own: nil, inferred: .working, list: his
            )),
            ("his own in effect", .resolve(override: nil, own: WorkspaceOwnStatus(id: "doing"), inferred: .todo, list: his)),
            ("his own while an agent waits", .resolve(override: nil, own: WorkspaceOwnStatus(id: "parked"), inferred: .needsAttention, list: his)),
            ("his own the list lacks", .resolve(override: nil, own: WorkspaceOwnStatus(id: "gone"), inferred: .todo, list: his)),
        ]
    }

    /// The pane's working-out over every resolution: whether a status shows as set, what pins the footnote, his word for
    /// the glyph's tooltip and the header, and the rows. His word is for a status in effect; a status of his stays
    /// in effect even while an agent waits.
    @Test func thePaneStateOverTheSixResolutions() {
        let expected: [(hasOverride: Bool, cmux: WorkspaceTaskStatus?, word: String?)] = [
            (false, nil, nil), (true, .review, "Reviewing"), (true, .working, nil), (false, nil, nil),
            (true, nil, "Doing"), (true, nil, "Parked"), (false, nil, nil),
        ]
        for ((name, resolution), want) in zip(sixResolutions(), expected) {
            let inferred = resolution.effective
            let pane = WorkspaceStatusPaneState.make(resolution: resolution, inferred: inferred, list: Self.hisList, controlsEnabled: true, statusHidden: false)
            #expect(pane.hasOverride == want.hasOverride, "\(name): hasOverride")
            #expect(pane.cmuxOverride == want.cmux, "\(name): cmuxOverride")
            #expect(pane.hisWord == want.word, "\(name): hisWord")
            let off = WorkspaceStatusPaneState.make(resolution: resolution, inferred: inferred, list: Self.hisList, controlsEnabled: false, statusHidden: false)
            #expect(!off.hasOverride && off.hisWord == nil, "\(name): the controls are off")
        }
    }

    /// (#cm-110.13) Changed deliberately: the pane's picker agrees with None, as the row's picker does.
    @Test func thePanesRowsForAWorkspaceOnNoneHaveNoneChecked() {
        let workspace = Workspace()
        workspace.hideTaskStatus()
        let pane = WorkspaceStatusPaneState.make(
            resolution: workspace.statusResolution(list: .cmuxFive),
            inferred: workspace.inferredTaskStatus(list: .cmuxFive), list: .cmuxFive, controlsEnabled: true,
            statusHidden: workspace.todoState.statusHidden
        )
        let lanes = WorkspaceTodoStatusLane.lanes(picker: pane.picker)
        #expect(lanes.first?.isSelected == false, "None must not check Auto in the pane")
        #expect(lanes.last?.isNone == true && lanes.last?.isSelected == true, "the pane must check None")
        #expect(lanes == WorkspaceTodoStatusLane.lanes(inferred: .todo, activeOverride: nil, isHidden: true))
    }

    /// `checkedName`, over the same six: the name on the checked entry row, and nothing for a greyed row or none.
    @Test func theCheckedNameOverTheSixResolutions() {
        let expected: [String?] = [nil, "Reviewing", nil, nil, "Doing", "Parked", nil]
        for ((name, resolution), want) in zip(sixResolutions(), expected) {
            let picker = WorkspaceStatusPicker().rows(
                resolution: resolution, inferred: resolution.effective, isHidden: false, list: Self.hisList
            )
            #expect(WorkspaceStatusPresentation.checkedName(in: picker) == want, "\(name)")
        }
        #expect(WorkspaceStatusPresentation.checkedName(in: nil) == nil)
    }

    // MARK: - Entrance row 4: the AppKit Status menu

    private static let hisText = """
    { "workspaceStatuses": [
      { "id": "inbox", "name": "Inbox", "extends": "todo", "color": "#101010" },
      { "id": "parked", "name": "Parked", "extends": "todo", "color": "#445566" },
      { "id": "doing", "name": "Doing", "extends": "working", "color": "#112233" },
      { "id": "blocked", "name": "Blocked", "extends": "needs-attention", "color": "Mauve" },
      { "id": "waiting", "name": "Waiting", "extends": "needs-attention" },
      { "id": "review", "name": "Reviewing", "color": "#778800" },
      { "id": "qa", "name": "QA", "extends": "review", "color": "#334455" },
      { "id": "shipped", "name": "Shipped", "extends": "done", "color": "#00AA00" },
      { "id": "done", "name": "Done", "color": "#778899" },
      { "id": "later", "name": "Later", "extends": "todo" },
      { "id": "idea", "name": "Idea", "extends": "todo", "color": "#ABCDEF" }
    ] }
    """

    /// Runs `body` with `AppDelegate.shared` holding a store that has loaded his eleven, with the colors it names
    /// resolved (`#RRGGBB` resolves, `Mauve` does not). The store is never started.
    private func underHisList(_ body: () throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceStatusEntrancesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("cmux.json")
        try Self.hisText.write(to: file, atomically: true, encoding: .utf8)
        let suite = "WorkspaceStatusEntrancesTests.store.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = WorkspaceStatusListStore(
            fileURL: file, defaults: defaults,
            resolveColor: { $0.hasPrefix("#") ? $0.uppercased() : nil },
            paletteFingerprint: { "fixed" }, clock: ContinuousClock()
        )
        store.load()
        let previous = AppDelegate.shared
        let delegate = AppDelegate()
        delegate.workspaceStatusListStore = store
        AppDelegate.shared = delegate
        defer { AppDelegate.shared = previous }
        try body()
    }

    private struct MenuRow: Equatable {
        let title: String
        let isSeparator: Bool
        let isEnabled: Bool
        let isOn: Bool
        let hasImage: Bool
    }

    /// The items of the Status submenu the AppKit builder makes for `workspace` under the delegate's list.
    private func appKitStatusMenu(for workspace: Workspace, in manager: TabManager) throws -> [MenuRow] {
        let commands = SidebarWorkspaceRowCommands(
            tab: workspace, tabManager: manager, notificationStore: nil, index: 0,
            contextMenuWorkspaceIds: [workspace.id], remoteContextMenuWorkspaceIds: [],
            allRemoteContextMenuTargetsConnecting: false, allRemoteContextMenuTargetsDisconnected: false,
            contextMenuPinState: nil, workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot(items: []),
            colorScheme: .dark, refreshSnapshot: {}, readSelectedTabIds: { [] }, writeSelectedTabIds: { _ in },
            readLastSelectionIndex: { nil }, writeLastSelectionIndex: { _ in }, setSelectionToTabs: {},
            snapshotProvider: { nil }
        )
        let menu = NSMenu()
        SidebarWorkspaceRowMenuBuilder(commands: commands).addTodoSection(to: menu, tabManager: manager)
        let submenu = try #require(menu.items.first?.submenu, "the Status item has no submenu")
        return submenu.items.map {
            MenuRow(title: $0.title, isSeparator: $0.isSeparatorItem, isEnabled: $0.isEnabled, isOn: $0.state == .on, hasImage: $0.image != nil)
        }
    }

    /// Entrance row 4. The AppKit Status menu, built under his list: Auto, a divider, his eleven in the file's order,
    /// a divider, None; a dot on each row whose color the app resolved; a cmux status the list leaves out is a greyed
    /// row that is disabled with its check on, and Auto is unchecked beside it.
    @Test func theAppKitStatusMenuHasHisElevenWithDotsAndADisabledGreyedRow() throws {
        try underHisList {
            let manager = TabManager(autoWelcomeIfNeeded: false)
            let workspace = try #require(manager.selectedWorkspace)
            workspace.setTaskStatusOverride(.working)
            let rows = try appKitStatusMenu(for: workspace, in: manager)
            try #require(rows.count == 16, "the Status submenu has \(rows.count) items, not 16: \(rows.map(\.title))")
            let format = String(localized: "sidebar.status.notInList", defaultValue: "%@ · not in your list")
            let greyed = String(format: format, locale: .current, WorkspaceTaskStatus.working.displayName)
            let titles = rows.map { $0.isSeparator ? "-" : $0.title }
            #expect(Array(titles.dropFirst().dropFirst().prefix(11)) == [
                "Inbox", "Parked", "Doing", "Blocked", "Waiting", "Reviewing", "QA", "Shipped", "Done", "Later", "Idea",
            ])
            #expect(titles[1] == "-", "no divider after Auto")
            #expect(titles[13] == greyed)
            #expect(titles[14] == "-" && titles.count == 16, "the divider before None: \(titles)")
            let entries = Array(rows[2..<13])
            // `blocked` names a color this app lacks, `waiting` and `later` have none: no dot on those three.
            #expect(entries.map(\.hasImage) == [true, true, true, false, false, true, true, true, true, false, true])
            #expect(rows[13].isEnabled == false && rows[13].isOn, "the greyed row must be disabled with its check on")
            #expect(rows[13].hasImage == false)
            #expect(rows[0].isOn == false, "Auto is checked beside a greyed row")
            #expect(entries.allSatisfy { $0.isEnabled })
        }
    }

    /// The same menu for one of his own statuses the list lacks: that greyed row has no glyph status, and still no
    /// divider follows it (the divider after Auto tests the row's action, not the glyph).
    @Test func noDividerFollowsAGreyedRowOfHisOwnTheListLacks() throws {
        try underHisList {
            let manager = TabManager(autoWelcomeIfNeeded: false)
            let workspace = try #require(manager.selectedWorkspace)
            // Written directly: a held id the list lacks is what a restored session or an edited file produces.
            workspace.todoState.statusHidden = false
            workspace.todoState.ownStatus = WorkspaceOwnStatus(id: "gone")
            let rows = try appKitStatusMenu(for: workspace, in: manager)
            try #require(rows.count == 16, "the Status submenu has \(rows.count) items, not 16: \(rows.map(\.title))")
            let separators = rows.indices.filter { rows[$0].isSeparator }
            #expect(separators == [1, 14], "dividers at \(separators) in \(rows.map(\.title))")
            #expect(rows[13].isEnabled == false && rows[13].isOn)
        }
    }

    // MARK: - Sub-step 3b: Detection without states callers

    /// Sub-step 3b. When a list is in use, detection without states applies across the three entrances
    /// (`inferredTaskStatus`, sidebar capture, and control socket status): an agent running or waiting
    /// yields `.todo` (not `.working` or `.needsAttention`), while with `.cmuxFive` upstream's detection applies.
    @Test func threePlacesWorkOutDetectionWithoutStatesWhenListIsInUse() throws {
        try underHisList {
            let manager = TabManager(autoWelcomeIfNeeded: false)
            let workspace = try #require(manager.selectedWorkspace)
            let panelID = try #require(workspace.focusedPanelId)
            workspace.agentLifecycleStatesByPanelId[panelID] = ["agent": .running]

            // 1. Workspace inference: detection without states yields .todo with his list,
            // while .cmuxFive yields upstream's live inference .working.
            #expect(workspace.inferredTaskStatus(list: Self.hisList) == .todo)
            #expect(workspace.inferredTaskStatus(list: .cmuxFive) == .working)
            #expect(workspace.inferredTaskStatus == .todo)

            // 2. Sidebar snapshot capture yields .todo for his list, .working for .cmuxFive.
            let sidebarHis = SidebarWorkspaceTaskStatusSnapshot.capture(
                workspace: workspace,
                orderedPanelIds: [panelID],
                list: Self.hisList
            )
            #expect(sidebarHis.inferred == .todo)
            let sidebarCmux = SidebarWorkspaceTaskStatusSnapshot.capture(
                workspace: workspace,
                orderedPanelIds: [panelID],
                list: .cmuxFive
            )
            #expect(sidebarCmux.inferred == .working)

            // 3. Control socket snapshot read reports .todo for inferred under his list.
            let delegate = try #require(AppDelegate.shared)
            let windowId = delegate.registerMainWindowContextForTesting(tabManager: manager)
            defer { delegate.unregisterMainWindowContextForTesting(windowId: windowId) }
            let routing = ControlRoutingSelectors(
                hasWindowIDParam: false,
                windowID: nil,
                groupID: nil,
                workspaceID: nil,
                surfaceID: nil,
                paneID: nil
            )
            let resolution = TerminalController.shared.controlWorkspaceTaskStatus(
                routing: routing,
                workspaceID: workspace.id
            )
            guard case .resolved(_, let status) = resolution else {
                Issue.record("controlWorkspaceTaskStatus did not resolve")
                return
            }
            #expect(status.inferred == WorkspaceTaskStatus.todo.rawValue)
        }
    }

    /// Sub-step 3b (Change 2). Setting Working by hand while an agent runs records `inferredAtOverride == .working`
    /// (the status being set decides, preserving upstream's inference on write) and stays in effect
    /// (`effectiveTaskStatus == .working`) while the agent runs, even with a status list in use.
    @Test func workingSetByHandRecordsUpstreamInferenceOnWrite() throws {
        try underHisList {
            let manager = TabManager(autoWelcomeIfNeeded: false)
            let workspace = try #require(manager.selectedWorkspace)
            let panelID = try #require(workspace.focusedPanelId)
            workspace.agentLifecycleStatesByPanelId[panelID] = ["agent": .running]

            // Setting .working while an agent runs:
            workspace.setTaskStatusOverride(.working)
            #expect(workspace.todoState.statusOverride?.inferredAtOverride == .working)
            #expect(workspace.effectiveTaskStatus == .working)
            guard case .cmuxInEffect = workspace.statusResolution(list: Self.hisList) else {
                Issue.record("override should be in effect while agent is running")
                return
            }

            // When the agent stops (now idle):
            workspace.agentLifecycleStatesByPanelId[panelID] = ["agent": .idle]
            // When the agent stops, upstream detection becomes idle (.todo), so the override lapses, as today.
            #expect(workspace.effectiveTaskStatus == .todo)

            // Setting .working while idle records .todo:
            workspace.setTaskStatusOverride(.working)
            #expect(workspace.todoState.statusOverride?.inferredAtOverride == .todo)
            #expect(workspace.effectiveTaskStatus == .working)
        }
    }

    /// Sub-step 3e. Quiet rows on Auto or Done get strip & ⌘-number when waiting agent is present;
    /// running agent on Auto stays quiet; no-list .cmuxFive keeps upstream behavior.
    @Test func quietRowsOnAutoOrDoneGetStripAndCommandNumberWhenWaitingAgentIsPresent() throws {
        let (settings, cleanUp) = settings()
        defer { cleanUp() }
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)

        func check(list: WorkspaceStatusList) -> (attention: WorkspaceTaskStatus?, suppressesStrip: Bool, hasCommandDigit: Bool) {
            let snapshot = factory(workspace, list: list, settings: settings).makeSnapshot()
            let attention = snapshot.attentionTaskStatus
            let suppresses = SidebarWorkspaceRowVisualPalette.suppressesAccentStrip(attentionTaskStatus: attention)
            let eligibility = WorkspaceShortcutEligibility.resolve(candidates: [
                WorkspaceShortcutEligibility.Candidate(
                    isGroupAnchor: false,
                    isInCollapsedGroup: false,
                    attentionTaskStatus: attention
                ),
                WorkspaceShortcutEligibility.Candidate(
                    isGroupAnchor: false,
                    isInCollapsedGroup: false,
                    attentionTaskStatus: .working
                )
            ])
            let hasDigit = eligibility.position(forFlatIndex: 0) != nil
            return (attention, suppresses, hasDigit)
        }

        // 1. Auto with waiting agent under his list: quiet row (effective .todo) is elevated to .needsAttention.
        workspace.agentLifecycleStatesByPanelId[panelId] = ["agent": .needsInput]
        let autoWaiting = check(list: Self.hisList)
        #expect(autoWaiting.attention == .needsAttention)
        #expect(!autoWaiting.suppressesStrip, "strip should not be suppressed when waiting")
        #expect(autoWaiting.hasCommandDigit, "should carry command digit when waiting")

        // 2. Done with waiting agent under his list: effective .done is elevated to .needsAttention.
        workspace.setTaskStatusOverride(.done)
        let doneWaiting = check(list: Self.hisList)
        #expect(doneWaiting.attention == .needsAttention)
        #expect(!doneWaiting.suppressesStrip)
        #expect(doneWaiting.hasCommandDigit)

        // 3. Auto with running agent under his list: stays quiet (effective .todo).
        workspace.todoState.statusOverride = nil
        workspace.agentLifecycleStatesByPanelId[panelId] = ["agent": .running]
        let autoRunning = check(list: Self.hisList)
        #expect(autoRunning.attention == .todo)
        #expect(autoRunning.suppressesStrip, "running agent on Auto stays quiet")
        #expect(!autoRunning.hasCommandDigit, "running agent on Auto does not get a digit when another row is in play")

        // 4. No-list (.cmuxFive) keeps upstream behavior.
        // Under .cmuxFive with running agent: upstream detects .working, so attention is .working (strip shown).
        workspace.agentLifecycleStatesByPanelId[panelId] = ["agent": .running]
        let cmuxRunning = check(list: .cmuxFive)
        #expect(cmuxRunning.attention == .working)
        #expect(!cmuxRunning.suppressesStrip, "upstream cmuxFive gives strip to running agent on Auto")
        #expect(cmuxRunning.hasCommandDigit)

        // Under .cmuxFive with idle agent: upstream detects .todo, so attention is .todo (strip suppressed).
        workspace.agentLifecycleStatesByPanelId[panelId] = ["agent": .idle]
        let cmuxIdle = check(list: .cmuxFive)
        #expect(cmuxIdle.attention == .todo)
        #expect(cmuxIdle.suppressesStrip)
        #expect(!cmuxIdle.hasCommandDigit)
    }

    /// O5: Under his list with an open PR and a running agent, setting Done records inferredAtOverride == .review, Done in effect.
    @Test func doneSetWithOpenPrAndRunningAgentRecordsReviewAndStaysInEffect() throws {
        try underHisList {
            let manager = TabManager(autoWelcomeIfNeeded: false)
            let workspace = try #require(manager.selectedWorkspace)
            let panelId = try #require(workspace.focusedPanelId)

            workspace.panelGitBranches[panelId] = SidebarGitBranchState(branch: "feature/pr", isDirty: false)
            workspace.panelPullRequests[panelId] = SidebarPullRequestState(
                number: 1,
                label: "PR #1",
                url: try #require(URL(string: "https://example.com/pr/1")),
                status: .open,
                branch: "feature/pr"
            )
            workspace.agentLifecycleStatesByPanelId[panelId] = ["agent": .running]

            // Setting Done:
            workspace.setTaskStatusOverride(.done)
            #expect(workspace.todoState.statusOverride?.inferredAtOverride == .review)
            #expect(workspace.effectiveTaskStatus == .done)
            guard case .cmuxInEffect(let entry, _) = workspace.statusResolution(list: Self.hisList) else {
                Issue.record("Done override should be in effect")
                return
            }
            #expect(entry.id == "done")

            // Stop the agent: Done remains in effect under his list with open PR
            workspace.agentLifecycleStatesByPanelId[panelId] = ["agent": .idle]
            #expect(workspace.effectiveTaskStatus == .done)
            guard case .cmuxInEffect(let entryAfterStop, _) = workspace.statusResolution(list: Self.hisList) else {
                Issue.record("Done override should still be in effect after agent stops")
                return
            }
            #expect(entryAfterStop.id == "done")
        }
    }

    /// O5: A waiting Auto workspace with an open PR reads Review in all three places under his list.
    @Test func waitingAutoWorkspaceWithOpenPullRequestReadsReviewInAllThreePlaces() throws {
        try underHisList {
            let manager = TabManager(autoWelcomeIfNeeded: false)
            let workspace = try #require(manager.selectedWorkspace)
            let panelId = try #require(workspace.focusedPanelId)

            workspace.panelGitBranches[panelId] = SidebarGitBranchState(branch: "feature/pr", isDirty: false)
            workspace.panelPullRequests[panelId] = SidebarPullRequestState(
                number: 1,
                label: "PR #1",
                url: try #require(URL(string: "https://example.com/pr/1")),
                status: .open,
                branch: "feature/pr"
            )
            workspace.agentLifecycleStatesByPanelId[panelId] = ["agent": .needsInput]

            // 1. Workspace inference: detection without states yields .review with his list;
            // .cmuxFive yields upstream's live inference .needsAttention.
            #expect(workspace.inferredTaskStatus(list: Self.hisList) == .review)
            #expect(workspace.inferredTaskStatus(list: .cmuxFive) == .needsAttention)
            #expect(workspace.inferredTaskStatus == .review)

            // 2. Sidebar snapshot capture yields .review for his list, .needsAttention for .cmuxFive.
            let sidebarHis = SidebarWorkspaceTaskStatusSnapshot.capture(
                workspace: workspace,
                orderedPanelIds: [panelId],
                list: Self.hisList
            )
            #expect(sidebarHis.inferred == .review)
            let sidebarCmux = SidebarWorkspaceTaskStatusSnapshot.capture(
                workspace: workspace,
                orderedPanelIds: [panelId],
                list: .cmuxFive
            )
            #expect(sidebarCmux.inferred == .needsAttention)

            // 3. Control socket snapshot read reports .review for inferred under his list.
            let delegate = try #require(AppDelegate.shared)
            let windowId = delegate.registerMainWindowContextForTesting(tabManager: manager)
            defer { delegate.unregisterMainWindowContextForTesting(windowId: windowId) }
            let routing = ControlRoutingSelectors(
                hasWindowIDParam: false,
                windowID: nil,
                groupID: nil,
                workspaceID: nil,
                surfaceID: nil,
                paneID: nil
            )
            let resolution = TerminalController.shared.controlWorkspaceTaskStatus(
                routing: routing,
                workspaceID: workspace.id
            )
            guard case .resolved(_, let status) = resolution else {
                Issue.record("controlWorkspaceTaskStatus did not resolve")
                return
            }
            #expect(status.inferred == WorkspaceTaskStatus.review.rawValue)
        }
    }

    /// O1: Under his list, Done recorded at .working with detection .todo gives snapshot.todoStatusMenuModel?.activeOverride == .done.
    @Test func doneRecordedAtWorkingWithDetectionTodoGivesActiveOverrideInMenuModel() throws {
        let (settings, cleanUp) = settings()
        defer { cleanUp() }
        let workspace = Workspace()
        workspace.todoState.statusHidden = false
        workspace.todoState.statusOverride = WorkspaceTaskStatusOverride(
            status: .done,
            inferredAtOverride: .working
        )
        let snapshot = factory(workspace, list: Self.hisList, settings: settings).makeSnapshot()
        #expect(snapshot.todoStatusMenuModel?.activeOverride == .done)
    }

    /// Piece 4 (#cm-109.4, review #6): In SidebarWorkspaceTaskStatusSnapshot.capture, a pre-release
    /// Done record naming a state (.working) under a status list where live detection is .todo
    /// maintains activeOverride agreeing with held (.done).
    @Test func preReleaseDoneRecordWithWorkingStateMaintainsActiveOverrideMatchingHeld() throws {
        let workspace = Workspace()
        workspace.todoState.statusHidden = false
        workspace.todoState.statusOverride = WorkspaceTaskStatusOverride(
            status: .done,
            inferredAtOverride: .working
        )
        let taskSnapshot = SidebarWorkspaceTaskStatusSnapshot.capture(
            workspace: workspace,
            orderedPanelIds: [],
            list: Self.hisList
        )
        #expect(taskSnapshot.activeOverride == .done)
    }


    /// cm-128.1 (changed on purpose, was `slotResolutionPicksHandOverSpinnerAndBadgeAndRespectsCloseButton`): nothing hides
    /// another mark. The badge keeps the leading slot alone; a spinner set left draws in the agent-mark group after the
    /// glyph and the hand; with both set right the badge sits at the edge and the spinner beside it; the close button
    /// replaces both trailing marks.
    @Test func slotResolutionShowsEveryPresentMarkAndRespectsCloseButton() {
        func resolve(hand: Bool = false, spinner: Bool = false, unread: Int = 0,
                     spinnerAt: SidebarIndicatorPosition = .leading, badgeAt: SidebarIndicatorPosition = .leading,
                     close: Bool = false) -> SidebarWorkspaceSlotResolution {
            SidebarWorkspaceSlotResolution.resolve(
                showsHand: hand, showsSpinner: spinner, unreadCount: unread,
                loadingSpinnerPosition: spinnerAt, notificationBadgePosition: badgeAt, showsCloseButton: close
            )
        }
        func marks(_ r: SidebarWorkspaceSlotResolution) -> String {
            "leading=\(r.leading) trailing=\(r.trailing) inner=\(r.trailingInner) markSpinner=\(r.markSpinner) hand=\(r.showsHand)"
        }
        // 1. Nothing present.
        #expect(resolve() == SidebarWorkspaceSlotResolution(leading: .none, trailing: .none, showsHand: false))
        // 2. A leading badge holds the leading slot.
        #expect(resolve(unread: 3) == SidebarWorkspaceSlotResolution(leading: .badge, trailing: .none, showsHand: false))
        // 3. A left spinner leaves the leading slot for the agent-mark group.
        let spinnerLeft = resolve(spinner: true, unread: 3)
        #expect(spinnerLeft == SidebarWorkspaceSlotResolution(leading: .badge, trailing: .none, markSpinner: true, showsHand: false), "\(marks(spinnerLeft))")
        let spinnerLeftNoBadge = resolve(spinner: true)
        #expect(spinnerLeftNoBadge == SidebarWorkspaceSlotResolution(leading: .none, trailing: .none, markSpinner: true, showsHand: false), "\(marks(spinnerLeftNoBadge))")
        // 4. The hand hides neither the badge nor the spinner, on any side.
        let handLeft = resolve(hand: true, spinner: true, unread: 3)
        #expect(handLeft == SidebarWorkspaceSlotResolution(leading: .badge, trailing: .none, markSpinner: true, showsHand: true), "\(marks(handLeft))")
        let handRight = resolve(hand: true, spinner: true, unread: 3, spinnerAt: .trailing, badgeAt: .trailing)
        #expect(handRight == SidebarWorkspaceSlotResolution(leading: .none, trailing: .badge, trailingInner: .spinner, showsHand: true), "\(marks(handRight))")
        // 5. Both right, no hand: badge at the edge, spinner beside it. Either alone takes the edge.
        let bothRight = resolve(spinner: true, unread: 3, spinnerAt: .trailing, badgeAt: .trailing)
        #expect(bothRight == SidebarWorkspaceSlotResolution(leading: .none, trailing: .badge, trailingInner: .spinner, showsHand: false), "\(marks(bothRight))")
        #expect(resolve(spinner: true, spinnerAt: .trailing) == SidebarWorkspaceSlotResolution(leading: .none, trailing: .spinner, showsHand: false))
        #expect(resolve(unread: 3, badgeAt: .trailing) == SidebarWorkspaceSlotResolution(leading: .none, trailing: .badge, showsHand: false))
        // 6. The close button replaces both trailing marks, hand or not; left-side marks stay.
        let closeBothRight = resolve(hand: true, spinner: true, unread: 3, spinnerAt: .trailing, badgeAt: .trailing, close: true)
        #expect(closeBothRight == SidebarWorkspaceSlotResolution(leading: .none, trailing: .none, showsHand: true), "\(marks(closeBothRight))")
        let closeLeft = resolve(hand: true, spinner: true, unread: 3, close: true)
        #expect(closeLeft == SidebarWorkspaceSlotResolution(leading: .badge, trailing: .none, markSpinner: true, showsHand: true), "\(marks(closeLeft))")
        // 7. Opposite sides keep each mark on its own side.
        let spinnerRightBadgeLeft = resolve(hand: true, spinner: true, unread: 3, spinnerAt: .trailing, badgeAt: .leading)
        #expect(spinnerRightBadgeLeft == SidebarWorkspaceSlotResolution(leading: .badge, trailing: .spinner, showsHand: true), "\(marks(spinnerRightBadgeLeft))")
        let spinnerLeftBadgeRight = resolve(hand: true, spinner: true, unread: 3, spinnerAt: .leading, badgeAt: .trailing)
        #expect(spinnerLeftBadgeRight == SidebarWorkspaceSlotResolution(leading: .none, trailing: .badge, markSpinner: true, showsHand: true), "\(marks(spinnerLeftBadgeRight))")
    }

    /// cm-128.1: the title reserves badge + gap + spinner at the trailing edge when both show there, and never less than
    /// the close button that replaces them on hover.
    @Test func trailingReserveCoversBothMarksAndTheCloseButton() {
        func reserve(_ trailing: SidebarWorkspaceSlotResolution.SlotContent,
                     _ inner: SidebarWorkspaceSlotResolution.SlotContent,
                     close: CGFloat = 16) -> CGFloat {
            SidebarWorkspaceSlotResolution.trailingReserve(
                trailing: trailing, trailingInner: inner, badgeSide: 16, spinnerSide: 12, closeButtonWidth: close
            )
        }
        #expect(reserve(.badge, .spinner) == 16 + SidebarWorkspaceSlotResolution.trailingMarkGap + 12)
        #expect(reserve(.badge, .spinner, close: 40) == 40)
        #expect(reserve(.badge, .none) == 16)
        #expect(reserve(.spinner, .none) == 16)
        #expect(reserve(.none, .none) == 16)
        #expect(SidebarWorkspaceSlotResolution.trailingMarkGap == 6)
    }

    /// Piece 4 (#cm-109.4): Snapshot and ContextMenuImmediateFields capture showsRaisedHand.
    @Test func snapshotAndContextMenuImmediateFieldsCaptureShowsRaisedHand() throws {
        let (settings, cleanUp) = settings()
        defer { cleanUp() }
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)

        // Case A: Waiting agent with his list and showsAgentActivity on -> showsRaisedHand == true
        workspace.agentLifecycleStatesByPanelId[panelId] = ["agent": .needsInput]
        let taskSnapshot = SidebarWorkspaceTaskStatusSnapshot.capture(
            workspace: workspace,
            orderedPanelIds: [panelId],
            list: Self.hisList
        )
        #expect(taskSnapshot.isAgentWaiting == true)

        let snapshotWithList = factory(workspace, list: Self.hisList, settings: settings, showsAgentActivity: true).makeSnapshot()
        #expect(snapshotWithList.showsRaisedHand == true)
        #expect(snapshotWithList.contextMenuImmediateFields.showsRaisedHand == true)

        // Case B: Waiting agent with default list (.cmuxFive) -> showsRaisedHand == false
        let snapshotDefaultList = factory(workspace, list: .cmuxFive, settings: settings, showsAgentActivity: true).makeSnapshot()
        #expect(snapshotDefaultList.showsRaisedHand == false)
        #expect(snapshotDefaultList.contextMenuImmediateFields.showsRaisedHand == false)

        // Case C: Running (not waiting) agent with his list -> showsRaisedHand == false
        workspace.agentLifecycleStatesByPanelId[panelId] = ["agent": .running]
        let runningSnapshot = factory(workspace, list: Self.hisList, settings: settings, showsAgentActivity: true).makeSnapshot()
        #expect(runningSnapshot.showsRaisedHand == false)
        #expect(runningSnapshot.contextMenuImmediateFields.showsRaisedHand == false)

        // Case D: Waiting agent with his list, but showAgentActivity setting is false -> showsRaisedHand == false
        let (settingsOff, cleanUpOff) = self.settings(showAgentActivity: false)
        defer { cleanUpOff() }
        workspace.agentLifecycleStatesByPanelId[panelId] = ["agent": .needsInput]
        let activityOffSnapshot = factory(workspace, list: Self.hisList, settings: settingsOff, showsAgentActivity: false).makeSnapshot()
        #expect(activityOffSnapshot.showsRaisedHand == false)
        #expect(activityOffSnapshot.contextMenuImmediateFields.showsRaisedHand == false)
    }

    /// Piece 4 (#cm-109.4): Factory test: with a list in use, an agent waiting, settings.details.showAgentActivity == true
    /// and showsAgentActivity == false (experiment flag off), showsRaisedHand must be true.
    @Test func factoryShowsRaisedHandWhenAgentWaitingAndSettingEnabledEvenIfSpinnerFlagDisabled() throws {
        let (settings, cleanUp) = settings()
        defer { cleanUp() }
        #expect(settings.details.showAgentActivity == true)

        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.agentLifecycleStatesByPanelId[panelId] = ["agent": .needsInput]

        let snapshot = factory(
            workspace,
            list: Self.hisList,
            settings: settings,
            showsAgentActivity: false
        ).makeSnapshot()

        #expect(snapshot.showsRaisedHand == true)
        #expect(snapshot.contextMenuImmediateFields.showsRaisedHand == true)
    }

    /// Piece 4 (#cm-109.4): Factory test: with a list in use, an agent waiting, and settings.details.showAgentActivity == false,
    /// showsRaisedHand must be false.
    @Test func factoryHidesRaisedHandWhenAgentWaitingAndSettingDisabled() throws {
        let (settings, cleanUp) = settings(showAgentActivity: false)
        defer { cleanUp() }
        #expect(settings.details.showAgentActivity == false)

        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.agentLifecycleStatesByPanelId[panelId] = ["agent": .needsInput]

        let snapshot = factory(
            workspace,
            list: Self.hisList,
            settings: settings,
            showsAgentActivity: false
        ).makeSnapshot()

        #expect(snapshot.showsRaisedHand == false)
        #expect(snapshot.contextMenuImmediateFields.showsRaisedHand == false)
    }

    /// Piece 4 (#cm-109.4): AppKit sidebar row renders hand.raised.fill when agent is waiting under a status list,
    /// winning over the spinner and badge.
    @Test func appKitSidebarRowShowsRaisedHandDuringWaitAndWinsOverSpinnerAndBadge() throws {
        let (settings, cleanUp) = settings()
        defer { cleanUp() }
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.agentLifecycleStatesByPanelId[panelId] = [
            "runner": .running,
            "waiter": .needsInput
        ]

        // 1. Without a status list (.cmuxFive), the spinner shows and the hand does not.
        let defaultListSnapshot = factory(
            workspace,
            list: .cmuxFive,
            settings: settings,
            showsAgentActivity: true
        ).makeSnapshot()
        #expect(defaultListSnapshot.activeCodingAgentCount == 1)
        #expect(defaultListSnapshot.showsRaisedHand == false)

        let initialModel = SidebarWorkspaceRowModel(
            workspaceId: workspace.id,
            index: 0,
            snapshot: defaultListSnapshot,
            settings: settings,
            isActive: false,
            isMultiSelected: false,
            hasUserCustomTitle: false,
            canCloseWorkspace: false,
            accessibilityWorkspaceCount: 1,
            unreadCount: 5,
            latestNotificationText: nil,
            showsAgentActivity: true,
            rowSpacing: 8,
            isBeingDragged: false,
            topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false,
            isGrouped: false,
            isColorSectionMember: false,
            isFirstRow: true,
            shortcutHintText: nil,
            showsShortcutHints: false,
            colorSchemeIsDark: true,
            globalFontMagnificationPercent: 100,
            isChecklistExpanded: false,
            checklistAddFieldActivationToken: 0,
            isChecklistPopoverPresented: false,
            editingChecklistItemId: nil,
            todoControlsEnabled: true,
            isMetadataExpanded: false,
            isMarkdownExpanded: false
        )

        let cell = SidebarWorkspaceRowTableCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
        cell.configurePresentation(model: initialModel)
        #expect(cell.markSpinnerForTesting?.isHidden == false)
        #expect(cell.handForTesting?.isHidden != false) // (#cm-109.3)

        // 2. Under his list, hand becomes active, winning over the existing spinner and badge.
        let hisListSnapshot = factory(
            workspace,
            list: Self.hisList,
            settings: settings,
            showsAgentActivity: true
        ).makeSnapshot()
        #expect(hisListSnapshot.activeCodingAgentCount == 1)
        #expect(hisListSnapshot.showsRaisedHand == true)

        let waitingModel = SidebarWorkspaceRowModel(
            workspaceId: workspace.id,
            index: 0,
            snapshot: hisListSnapshot,
            settings: settings,
            isActive: false,
            isMultiSelected: false,
            hasUserCustomTitle: false,
            canCloseWorkspace: false,
            accessibilityWorkspaceCount: 1,
            unreadCount: 5,
            latestNotificationText: nil,
            showsAgentActivity: true,
            rowSpacing: 8,
            isBeingDragged: false,
            topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false,
            isGrouped: false,
            isColorSectionMember: false,
            isFirstRow: true,
            shortcutHintText: nil,
            showsShortcutHints: false,
            colorSchemeIsDark: true,
            globalFontMagnificationPercent: 100,
            isChecklistExpanded: false,
            checklistAddFieldActivationToken: 0,
            isChecklistPopoverPresented: false,
            editingChecklistItemId: nil,
            todoControlsEnabled: true,
            isMetadataExpanded: false,
            isMarkdownExpanded: false
        )

        cell.configurePresentation(model: waitingModel)
        cell.layout()

        let hand = try #require(cell.handForTesting) // (#cm-109.3)
        #expect(hand.isHidden == false)
        // cm-128.1: the hand hides neither mark. The badge keeps the leading slot; the left spinner draws after the hand.
        let markSpinner = try #require(cell.markSpinnerForTesting)
        #expect(markSpinner.isHidden == false)
        #expect(cell.leadingBadgeForTesting.isHidden == false)
        #expect(cell.leadingBadgeForTesting.frame.maxX <= hand.frame.minX)
        #expect(abs(markSpinner.frame.minX - (hand.frame.maxX + 8)) < 0.001, "spinner minX \(markSpinner.frame.minX), hand maxX \(hand.frame.maxX)")
        #expect(cell.titleFrameForTesting.minX >= markSpinner.frame.maxX)
        let standardSpinnerSide = max(10, 12 * waitingModel.fontScale)
        #expect(abs(hand.frame.size.width - standardSpinnerSide) < 0.001)
        #expect(abs(hand.frame.size.height - standardSpinnerSide) < 0.001)

        let expectedTooltip = String(localized: "sidebar.agentWaiting.tooltip", defaultValue: "An agent is waiting for your answer")
        #expect(hand.toolTip == expectedTooltip)
        #expect(hand.accessibilityLabel() == expectedTooltip)
        #expect(hand.image?.accessibilityDescription == expectedTooltip)

        // 3. Test at scaled font scale (sidebarFontSize: 18 pt -> fontScale: 1.44 -> spinnerSide: 17.28 pt)
        let suite = "WorkspaceStatusEntrancesTests.scaled.\(UUID().uuidString)"
        let scaledDefaults = UserDefaults(suiteName: suite)!
        defer { scaledDefaults.removePersistentDomain(forName: suite) }
        let scaledSettings = SidebarTabItemSettingsSnapshot(defaults: scaledDefaults, sidebarFontSize: 18)
        let scaledSnapshot = factory(
            workspace,
            list: Self.hisList,
            settings: scaledSettings,
            showsAgentActivity: true
        ).makeSnapshot()
        let scaledModel = SidebarWorkspaceRowModel(
            workspaceId: workspace.id,
            index: 0,
            snapshot: scaledSnapshot,
            settings: scaledSettings,
            isActive: false,
            isMultiSelected: false,
            hasUserCustomTitle: false,
            canCloseWorkspace: false,
            accessibilityWorkspaceCount: 1,
            unreadCount: 5,
            latestNotificationText: nil,
            showsAgentActivity: true,
            rowSpacing: 8,
            isBeingDragged: false,
            topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false,
            isGrouped: false,
            isColorSectionMember: false,
            isFirstRow: true,
            shortcutHintText: nil,
            showsShortcutHints: false,
            colorSchemeIsDark: true,
            globalFontMagnificationPercent: 100,
            isChecklistExpanded: false,
            checklistAddFieldActivationToken: 0,
            isChecklistPopoverPresented: false,
            editingChecklistItemId: nil,
            todoControlsEnabled: true,
            isMetadataExpanded: false,
            isMarkdownExpanded: false
        )
        cell.configurePresentation(model: scaledModel)
        cell.layout()
        let scaledHand = try #require(cell.handForTesting) // (#cm-109.3)
        #expect(scaledHand.isHidden == false)
        let scaledSpinnerSide = max(10, 12 * scaledModel.fontScale)
        #expect(abs(scaledHand.frame.size.width - scaledSpinnerSide) < 0.001)
        #expect(abs(scaledHand.frame.size.height - scaledSpinnerSide) < 0.001)
    }

    /// Change A (#cm-109.3): The raised hand draws right after the status glyph, before the title,
    /// in both spinner settings. With no glyph (Auto), the hand still sits before the title.
    @Test func appKitSidebarRowDrawsRaisedHandImmediatelyAfterStatusGlyphBeforeTitle() throws { // (#cm-109.3)
        let (settings, cleanUp) = settings() // (#cm-109.3)
        defer { cleanUp() } // (#cm-109.3)
        let workspace = Workspace() // (#cm-109.3)
        let panelId = try #require(workspace.focusedPanelId) // (#cm-109.3)
        workspace.agentLifecycleStatesByPanelId[panelId] = [ // (#cm-109.3)
            "waiter": .needsInput // (#cm-109.3)
        ] // (#cm-109.3)
        workspace.setTaskStatusOverride(.review) // (#cm-109.3)

        for spinnerPos in [SidebarIndicatorPosition.leading, SidebarIndicatorPosition.trailing] { // (#cm-109.3)
            let suite = "WorkspaceStatusEntrancesTests.layout.\(UUID().uuidString)" // (#cm-109.3)
            let defaults = UserDefaults(suiteName: suite)! // (#cm-109.3)
            defer { defaults.removePersistentDomain(forName: suite) } // (#cm-109.3)
            defaults.set(spinnerPos.rawValue, forKey: "sidebarLoadingSpinnerPosition") // (#cm-109.3)
            let rowSettings = SidebarTabItemSettingsSnapshot(defaults: defaults) // (#cm-109.3)
            #expect(rowSettings.loadingSpinnerPosition == spinnerPos) // (#cm-109.3)
            let snapshot = factory( // (#cm-109.3)
                workspace, // (#cm-109.3)
                list: Self.hisList, // (#cm-109.3)
                settings: rowSettings, // (#cm-109.3)
                showsAgentActivity: true // (#cm-109.3)
            ).makeSnapshot() // (#cm-109.3)
            #expect(snapshot.showsRaisedHand == true) // (#cm-109.3)

            let model = SidebarWorkspaceRowModel( // (#cm-109.3)
                workspaceId: workspace.id, // (#cm-109.3)
                index: 0, // (#cm-109.3)
                snapshot: snapshot, // (#cm-109.3)
                settings: rowSettings, // (#cm-109.3)
                isActive: false, // (#cm-109.3)
                isMultiSelected: false, // (#cm-109.3)
                hasUserCustomTitle: false, // (#cm-109.3)
                canCloseWorkspace: false, // (#cm-109.3)
                accessibilityWorkspaceCount: 1, // (#cm-109.3)
                unreadCount: 0, // (#cm-109.3)
                latestNotificationText: nil, // (#cm-109.3)
                showsAgentActivity: true, // (#cm-109.3)
                rowSpacing: 8, // (#cm-109.3)
                isBeingDragged: false, // (#cm-109.3)
                topDropIndicatorVisible: false, // (#cm-109.3)
                bottomDropIndicatorVisible: false, // (#cm-109.3)
                isGrouped: false, // (#cm-109.3)
                isColorSectionMember: false, // (#cm-109.3)
                isFirstRow: true, // (#cm-109.3)
                shortcutHintText: nil, // (#cm-109.3)
                showsShortcutHints: false, // (#cm-109.3)
                colorSchemeIsDark: true, // (#cm-109.3)
                globalFontMagnificationPercent: 100, // (#cm-109.3)
                isChecklistExpanded: false, // (#cm-109.3)
                checklistAddFieldActivationToken: 0, // (#cm-109.3)
                isChecklistPopoverPresented: false, // (#cm-109.3)
                editingChecklistItemId: nil, // (#cm-109.3)
                todoControlsEnabled: true, // (#cm-109.3)
                isMetadataExpanded: false, // (#cm-109.3)
                isMarkdownExpanded: false // (#cm-109.3)
            ) // (#cm-109.3)

            let cell = SidebarWorkspaceRowTableCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 40)) // (#cm-109.3)
            cell.configurePresentation(model: model) // (#cm-109.3)
            cell.layout() // (#cm-109.3)

            let glyph = cell.statusGlyphButtonForTesting // (#cm-109.3)
            #expect(!glyph.isHidden, "glyph is showing for .review") // (#cm-109.3)
            let hand = try #require(cell.handForTesting) // (#cm-109.3)
            #expect(!hand.isHidden, "hand is showing") // (#cm-109.3)
            let titleFrame = cell.titleFrameForTesting // (#cm-109.3)

            #expect(hand.frame.minX >= glyph.frame.maxX, "spinnerPos \(spinnerPos): hand minX (\(hand.frame.minX)) >= glyph maxX (\(glyph.frame.maxX))") // (#cm-109.3)
            #expect(titleFrame.minX >= hand.frame.maxX, "spinnerPos \(spinnerPos): title minX (\(titleFrame.minX)) >= hand maxX (\(hand.frame.maxX))") // (#cm-109.3)
        } // (#cm-109.3)

        // With no glyph (Auto), the hand still sits before the title.
        workspace.clearTaskStatusOverride() // (#cm-109.3)
        let autoSnapshot = factory( // (#cm-109.3)
            workspace, // (#cm-109.3)
            list: Self.hisList, // (#cm-109.3)
            settings: settings, // (#cm-109.3)
            showsAgentActivity: true // (#cm-109.3)
        ).makeSnapshot() // (#cm-109.3)
        #expect(autoSnapshot.showsRaisedHand == true) // (#cm-109.3)
        let autoModel = SidebarWorkspaceRowModel( // (#cm-109.3)
            workspaceId: workspace.id, // (#cm-109.3)
            index: 0, // (#cm-109.3)
            snapshot: autoSnapshot, // (#cm-109.3)
            settings: settings, // (#cm-109.3)
            isActive: false, // (#cm-109.3)
            isMultiSelected: false, // (#cm-109.3)
            hasUserCustomTitle: false, // (#cm-109.3)
            canCloseWorkspace: false, // (#cm-109.3)
            accessibilityWorkspaceCount: 1, // (#cm-109.3)
            unreadCount: 0, // (#cm-109.3)
            latestNotificationText: nil, // (#cm-109.3)
            showsAgentActivity: true, // (#cm-109.3)
            rowSpacing: 8, // (#cm-109.3)
            isBeingDragged: false, // (#cm-109.3)
            topDropIndicatorVisible: false, // (#cm-109.3)
            bottomDropIndicatorVisible: false, // (#cm-109.3)
            isGrouped: false, // (#cm-109.3)
            isColorSectionMember: false, // (#cm-109.3)
            isFirstRow: true, // (#cm-109.3)
            shortcutHintText: nil, // (#cm-109.3)
            showsShortcutHints: false, // (#cm-109.3)
            colorSchemeIsDark: true, // (#cm-109.3)
            globalFontMagnificationPercent: 100, // (#cm-109.3)
            isChecklistExpanded: false, // (#cm-109.3)
            checklistAddFieldActivationToken: 0, // (#cm-109.3)
            isChecklistPopoverPresented: false, // (#cm-109.3)
            editingChecklistItemId: nil, // (#cm-109.3)
            todoControlsEnabled: true, // (#cm-109.3)
            isMetadataExpanded: false, // (#cm-109.3)
            isMarkdownExpanded: false // (#cm-109.3)
        ) // (#cm-109.3)
        let autoCell = SidebarWorkspaceRowTableCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 40)) // (#cm-109.3)
        autoCell.configurePresentation(model: autoModel) // (#cm-109.3)
        autoCell.layout() // (#cm-109.3)
        let autoGlyph = autoCell.statusGlyphButtonForTesting // (#cm-109.3)
        #expect(autoGlyph.isHidden, "glyph is hidden on Auto") // (#cm-109.3)
        let autoHand = try #require(autoCell.handForTesting) // (#cm-109.3)
        #expect(!autoHand.isHidden, "hand is showing on Auto") // (#cm-109.3)
        let autoTitleFrame = autoCell.titleFrameForTesting // (#cm-109.3)
        #expect(autoTitleFrame.minX >= autoHand.frame.maxX, "title minX (\(autoTitleFrame.minX)) >= hand maxX (\(autoHand.frame.maxX))") // (#cm-109.3)
    } // (#cm-109.3)

    private static func descendants<T: NSView>(ofType type: T.Type, in root: NSView) -> [T] {
        var matches: [T] = []
        if let match = root as? T {
            matches.append(match)
        }
        for subview in root.subviews {
            matches.append(contentsOf: descendants(ofType: type, in: subview))
        }
        return matches
    }

    private static func renderedHandSize(in host: NSView) throws -> CGSize {
        let iconViews = descendants(ofType: CmuxResolvedIconImageView.self, in: host)
        guard let iconView = iconViews.first else {
            Issue.record("CmuxResolvedIconImageView not found in hosted view hierarchy")
            struct MissingIconViewError: Error {}
            throw MissingIconViewError()
        }
        return iconView.frame.size
    }

    @Test func swiftUISidebarSlotsShowRaisedHandNoLargerThanSpinnerSide() throws { // (#cm-109.3)
        for fontSize in stride(from: 10.0, through: 20.0, by: 0.5) { // (#cm-109.3)
            let fontScale = fontSize / 12.5 // (#cm-109.3)
            let spinnerSide = max(10, 12 * fontScale) // (#cm-109.3)
            let handView = CmuxSystemSymbolImage( // (#cm-109.3)
                systemName: "hand.raised.fill", // (#cm-109.3)
                pointSize: SidebarWorkspaceSlotResolution.handRaisedSymbolPointSize(spinnerSide: spinnerSide), // (#cm-109.3)
                tint: .secondary // (#cm-109.3)
            ) // (#cm-109.3)
            .frame(width: spinnerSide, height: spinnerSide) // (#cm-109.3)
            let host = NSHostingView(rootView: handView) // (#cm-109.3)
            host.frame = NSRect(x: 0, y: 0, width: 100, height: 100) // (#cm-109.3)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false) // (#cm-109.3)
            window.contentView = host // (#cm-109.3)
            host.layoutSubtreeIfNeeded() // (#cm-109.3)
            window.displayIfNeeded() // (#cm-109.3)
 // (#cm-109.3)
            let handSize = try Self.renderedHandSize(in: host) // (#cm-109.3)
            #expect(handSize.width <= spinnerSide + 0.001, "hand width \(handSize.width) exceeds spinnerSide \(spinnerSide) at font \(fontSize)") // (#cm-109.3)
            #expect(handSize.height <= spinnerSide + 0.001, "hand height \(handSize.height) exceeds spinnerSide \(spinnerSide) at font \(fontSize)") // (#cm-109.3)
            #expect(handSize.width >= spinnerSide * 0.75, "hand width \(handSize.width) is smaller than 75% of spinnerSide \(spinnerSide) at font \(fontSize)") // (#cm-109.3)
            #expect(handSize.height >= spinnerSide * 0.75, "hand height \(handSize.height) is smaller than 75% of spinnerSide \(spinnerSide) at font \(fontSize)") // (#cm-109.3)
        } // (#cm-109.3)
    } // (#cm-109.3)

    /// Piece 4 (#cm-109.4): the leading slot holds the unread badge alone, at upstream's 16·fs width, with the
    /// spinner set left or not, so the title never shifts as agents start and stop.
    @Test func swiftUISlotWidthKeepsTheBadgeWidthWhenTheSpinnerIsSetLeft() throws {
        for fontSize in stride(from: 10.0, through: 20.0, by: 0.5) {
            let fontScale = fontSize / 12.5
            let scaledUnreadBadgeSize = 16 * fontScale
            let resolution = SidebarWorkspaceSlotResolution.resolve(
                showsHand: false,
                showsSpinner: true,
                unreadCount: 3,
                loadingSpinnerPosition: .leading,
                notificationBadgePosition: .leading,
                showsCloseButton: false
            )
            // cm-128.1 (grill Q28): the left spinner moved after the glyph; this asserted leading == .spinner
            #expect(resolution.leading == .badge)
            #expect(resolution.markSpinner)

            let leadingSlot = SidebarWorkspaceLeadingStatusSlot( // (#cm-109.3)
                unreadCount: 3,
                side: scaledUnreadBadgeSize,
                badgeFont: .system(size: 9 * fontScale),
                badgeFillColor: .blue,
                badgeTextColor: .white
            )
            let host = NSHostingView(rootView: leadingSlot)
            host.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            #expect(abs(host.fittingSize.width - scaledUnreadBadgeSize) < 0.5, "hosted slot width \(host.fittingSize.width) must equal badge size \(scaledUnreadBadgeSize)")
        }
    }

    // MARK: - The waiting hand (#cm-109.7)

    private func resolvedSystemYellow(dark: Bool) -> NSColor { // (#cm-109.7)
        var out = NSColor.systemYellow // (#cm-109.7)
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance { // (#cm-109.7)
            out = NSColor.systemYellow.usingColorSpace(.sRGB)! // (#cm-109.7)
        } // (#cm-109.7)
        return out // (#cm-109.7)
    } // (#cm-109.7)

    private func resolvedTint(_ color: NSColor?, dark: Bool) -> NSColor? { // (#cm-109.7)
        guard let color else { return nil } // (#cm-109.7)
        var out: NSColor? // (#cm-109.7)
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance { // (#cm-109.7)
            out = color.usingColorSpace(.sRGB) // (#cm-109.7)
        } // (#cm-109.7)
        return out // (#cm-109.7)
    } // (#cm-109.7)

    private func isSameColor(_ a: NSColor?, _ b: NSColor) -> Bool { // (#cm-109.7)
        guard let a = a?.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false } // (#cm-109.7)
        return abs(a.redComponent - b.redComponent) < 0.01 // (#cm-109.7)
            && abs(a.greenComponent - b.greenComponent) < 0.01 // (#cm-109.7)
            && abs(a.blueComponent - b.blueComponent) < 0.01 // (#cm-109.7)
    } // (#cm-109.7)

    /// A built waiting row (his list, an agent waiting) with the sidebar stand-in `standIn`; `isActive` makes it the
    /// selected row, which has no workspace color so the accent fill is its background.
    private func waitingHandModel(dark: Bool, isActive: Bool, standIn: String, status: String? = nil, waiting: Bool = true) throws -> SidebarWorkspaceRowModel { // (#cm-109.7)
        let (settings, cleanUp) = settings() // (#cm-109.7)
        defer { cleanUp() } // (#cm-109.7)
        let workspace = Workspace() // (#cm-109.7)
        let panelId = try #require(workspace.focusedPanelId) // (#cm-109.7)
        workspace.agentLifecycleStatesByPanelId[panelId] = waiting ? ["waiter": .needsInput] : ["runner": .running] // (#cm-109.7)
        if let status { workspace.setOwnStatus(try #require(Self.hisList.entry(id: status))) } // (#cm-109.7)
        let snapshot = factory(workspace, list: Self.hisList, settings: settings, showsAgentActivity: true).makeSnapshot() // (#cm-109.7)
        #expect(snapshot.showsRaisedHand == waiting) // (#cm-109.7)
        return SidebarWorkspaceRowModel( // (#cm-109.7)
            workspaceId: workspace.id, // (#cm-109.7)
            index: 0, // (#cm-109.7)
            snapshot: snapshot, // (#cm-109.7)
            settings: settings, // (#cm-109.7)
            isActive: isActive, // (#cm-109.7)
            isMultiSelected: false, // (#cm-109.7)
            hasUserCustomTitle: false, // (#cm-109.7)
            canCloseWorkspace: false, // (#cm-109.7)
            accessibilityWorkspaceCount: 1, // (#cm-109.7)
            unreadCount: 0, // (#cm-109.7)
            latestNotificationText: nil, // (#cm-109.7)
            showsAgentActivity: true, // (#cm-109.7)
            rowSpacing: 8, // (#cm-109.7)
            isBeingDragged: false, // (#cm-109.7)
            topDropIndicatorVisible: false, // (#cm-109.7)
            bottomDropIndicatorVisible: false, // (#cm-109.7)
            isGrouped: false, // (#cm-109.7)
            isColorSectionMember: false, // (#cm-109.7)
            isFirstRow: true, // (#cm-109.7)
            shortcutHintText: nil, // (#cm-109.7)
            showsShortcutHints: false, // (#cm-109.7)
            colorSchemeIsDark: dark, // (#cm-109.7)
            contrastBackgroundHex: standIn, // (#cm-109.7)
            globalFontMagnificationPercent: 100, // (#cm-109.7)
            isChecklistExpanded: false, // (#cm-109.7)
            checklistAddFieldActivationToken: 0, // (#cm-109.7)
            isChecklistPopoverPresented: false, // (#cm-109.7)
            editingChecklistItemId: nil, // (#cm-109.7)
            todoControlsEnabled: true, // (#cm-109.7)
            isMetadataExpanded: false, // (#cm-109.7)
            isMarkdownExpanded: false // (#cm-109.7)
        ) // (#cm-109.7)
    } // (#cm-109.7)

    private func waitingHandCell(dark: Bool, isActive: Bool, standIn: String, status: String? = nil) throws -> SidebarWorkspaceRowTableCellView { // (#cm-109.7)
        let model = try waitingHandModel(dark: dark, isActive: isActive, standIn: standIn, status: status) // (#cm-109.7)
        let cell = SidebarWorkspaceRowTableCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 40)) // (#cm-109.7)
        cell.configurePresentation(model: model) // (#cm-109.7)
        cell.layout() // (#cm-109.7)
        return cell // (#cm-109.7)
    } // (#cm-109.7)

    /// Scenario 81 (#cm-109.7): in Light, a resting waiting row draws the hand in systemYellow with its outline visible.
    @Test func theHandIsYellowWithAnOutlineOnALightRestingRow() throws { // (#cm-109.7)
        let cell = try waitingHandCell(dark: false, isActive: false, standIn: "#C2C0CB") // (#cm-109.7)
        let hand = try #require(cell.handForTesting) // (#cm-109.7)
        #expect(hand.isHidden == false) // (#cm-109.7)
        #expect(isSameColor(resolvedTint(hand.contentTintColor, dark: false), resolvedSystemYellow(dark: false))) // (#cm-109.7)
        let outline = try #require(cell.handOutlineForTesting) // (#cm-109.7)
        #expect(outline.isHidden == false) // (#cm-109.7)
        #expect(outline.frame == hand.frame) // (#cm-109.7)
    } // (#cm-109.7)

    /// The outline is Tom's Amber #7D6608 (decision of 2026-10-17): every AppKit copy is tinted with it on a light resting row,
    /// and the SwiftUI hand reads the same constant, so both renderers draw one ink.
    @Test func theOutlineInkIsAmberInBothRenderers() throws { // (#cm-109.7)
        let amber = NSColor(srgbRed: 0x7D / 255, green: 0x66 / 255, blue: 0x08 / 255, alpha: 1) // (#cm-109.7)
        let cell = try waitingHandCell(dark: false, isActive: false, standIn: "#C2C0CB") // (#cm-109.7)
        let outline = try #require(cell.handOutlineForTesting) // (#cm-109.7)
        #expect(outline.isHidden == false) // (#cm-109.7)
        let copies = outline.subviews.compactMap { $0 as? NSImageView } // (#cm-109.7)
        #expect(copies.count == waitingHandOutlineOffsets.count) // (#cm-109.7)
        for copy in copies { // (#cm-109.7)
            #expect(isSameColor(copy.contentTintColor, amber), "copy tinted \(String(describing: copy.contentTintColor))") // (#cm-109.7)
        } // (#cm-109.7)
        #expect(isSameColor(waitingHandOutlineInk, amber), "shared ink is \(waitingHandOutlineInk)") // (#cm-109.7)
    } // (#cm-109.7)

    /// Scenario 81 (#cm-109.7): in Dark, a resting waiting row draws the hand in systemYellow with the outline hidden.
    @Test func theHandIsPlainYellowOnADarkRestingRow() throws { // (#cm-109.7)
        let cell = try waitingHandCell(dark: true, isActive: false, standIn: "#333846") // (#cm-109.7)
        let hand = try #require(cell.handForTesting) // (#cm-109.7)
        #expect(hand.isHidden == false) // (#cm-109.7)
        #expect(isSameColor(resolvedTint(hand.contentTintColor, dark: true), resolvedSystemYellow(dark: true))) // (#cm-109.7)
        #expect(cell.handOutlineForTesting?.isHidden != false) // (#cm-109.7)
    } // (#cm-109.7)

    /// Scenario 81 (#cm-109.7): a selected row with no workspace color in Dark sits on the accent fill, where the
    /// yellow alone is under 3:1, so the outline draws. The dark sidebar stand-in alone would say it does not: the
    /// row's own background decides.
    @Test func theHandIsOutlinedOnTheDarkAccentSelectionFill() throws { // (#cm-109.7)
        let cell = try waitingHandCell(dark: true, isActive: true, standIn: "#333846") // (#cm-109.7)
        let hand = try #require(cell.handForTesting) // (#cm-109.7)
        #expect(hand.isHidden == false) // (#cm-109.7)
        #expect(isSameColor(resolvedTint(hand.contentTintColor, dark: true), resolvedSystemYellow(dark: true))) // (#cm-109.7)
        #expect(cell.handOutlineForTesting?.isHidden == false) // (#cm-109.7)
    } // (#cm-109.7)

    /// Scenario 81 (#cm-109.7): a Done row dims its content to 0.6, and the hand is judged as drawn. On `#606068` in Dark
    /// the plain yellow clears 3:1 (4.4) but dimmed does not (2.6), so the outline draws.
    @Test func theHandIsOutlinedOnADimmedDoneRowWherePlainYellowWouldClear() throws { // (#cm-109.7)
        let cell = try waitingHandCell(dark: true, isActive: false, standIn: "#606068", status: "shipped") // (#cm-109.7)
        #expect(cell.statusGlyphModelForTesting?.drawnAlpha == 0.6) // (#cm-109.7)
        let hand = try #require(cell.handForTesting) // (#cm-109.7)
        #expect(hand.isHidden == false) // (#cm-109.7)
        #expect(cell.handOutlineForTesting?.isHidden == false) // (#cm-109.7)
    } // (#cm-109.7)

    /// The same row, resting and not Done, draws plain: the dim is what tips it.
    @Test func theHandIsPlainOnTheSameRowWhenItIsNotDone() throws { // (#cm-109.7)
        let cell = try waitingHandCell(dark: true, isActive: false, standIn: "#606068") // (#cm-109.7)
        #expect(cell.handForTesting?.isHidden == false) // (#cm-109.7)
        #expect(cell.handOutlineForTesting?.isHidden != false) // (#cm-109.7)
    } // (#cm-109.7)

    /// Scenario 81 (#cm-109.7): the spinner keeps its grey, `palette.secondary(0.55)`, on a row with an agent running.
    @Test func theSpinnerKeepsItsGreyWhileTheHandIsYellow() throws { // (#cm-109.7)
        for dark in [false, true] { // (#cm-109.7)
            let model = try waitingHandModel(dark: dark, isActive: false, standIn: dark ? "#333846" : "#C2C0CB", waiting: false) // (#cm-109.7)
            let cell = SidebarWorkspaceRowTableCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 40)) // (#cm-109.7)
            cell.configurePresentation(model: model) // (#cm-109.7)
            let spinner = try #require(cell.markSpinnerForTesting) // (#cm-109.7)
            #expect(spinner.isHidden == false, "dark: \(dark)") // (#cm-109.7)
            let expected = SidebarRowPalette(model: model).secondary(0.55) // (#cm-109.7)
            #expect(isSameColor(spinner.color, expected), "dark: \(dark)") // (#cm-109.7)
            #expect(abs(spinner.color.alphaComponent - expected.alphaComponent) < 0.01, "dark: \(dark)") // (#cm-109.7)
            #expect(!isSameColor(spinner.color, resolvedSystemYellow(dark: dark)), "dark: \(dark)") // (#cm-109.7)
        } // (#cm-109.7)
    } // (#cm-109.7)

    /// cm-128.1: a laid-out AppKit row for an agent mark scenario. `waiting` raises the hand, `running` starts the spinner,
    /// `status` shows the status glyph; the two positions are the sidebar settings under test.
    private func markRowCell(
        spinnerAt: SidebarIndicatorPosition, badgeAt: SidebarIndicatorPosition, unread: Int,
        waiting: Bool, running: Bool, status: WorkspaceTaskStatus? = nil
    ) throws -> SidebarWorkspaceRowTableCellView {
        let suite = "WorkspaceStatusEntrancesTests.marks.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(spinnerAt.rawValue, forKey: "sidebarLoadingSpinnerPosition")
        defaults.set(badgeAt.rawValue, forKey: "sidebarNotificationBadgePosition")
        let rowSettings = SidebarTabItemSettingsSnapshot(defaults: defaults)
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        var states: [String: AgentHibernationLifecycleState] = [:]
        if waiting { states["waiter"] = .needsInput }
        if running { states["runner"] = .running }
        workspace.agentLifecycleStatesByPanelId[panelId] = states
        if let status { workspace.setTaskStatusOverride(status) }
        let snapshot = factory(workspace, list: Self.hisList, settings: rowSettings, showsAgentActivity: true).makeSnapshot()
        #expect(snapshot.showsRaisedHand == waiting)
        #expect((snapshot.activeCodingAgentCount > 0) == running)
        let model = SidebarWorkspaceRowModel(
            workspaceId: workspace.id, index: 0, snapshot: snapshot, settings: rowSettings, isActive: false,
            isMultiSelected: false, hasUserCustomTitle: false, canCloseWorkspace: true, accessibilityWorkspaceCount: 1,
            unreadCount: unread, latestNotificationText: nil, showsAgentActivity: true, rowSpacing: 8, isBeingDragged: false,
            topDropIndicatorVisible: false, bottomDropIndicatorVisible: false, isGrouped: false, isColorSectionMember: false,
            isFirstRow: true, shortcutHintText: nil, showsShortcutHints: false, colorSchemeIsDark: true,
            globalFontMagnificationPercent: 100, isChecklistExpanded: false, checklistAddFieldActivationToken: 0,
            isChecklistPopoverPresented: false, editingChecklistItemId: nil, todoControlsEnabled: true,
            isMetadataExpanded: false, isMarkdownExpanded: false
        )
        let cell = SidebarWorkspaceRowTableCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
        cell.configurePresentation(model: model)
        cell.layout()
        return cell
    }

    /// cm-128.1 (Scenario 17, AppKit row): with the spinner set to the left it draws after the status glyph, beside the
    /// hand and after it; the badge keeps the leading slot alone, and the name starts after the last mark.
    @Test func appKitLeftSpinnerDrawsAfterTheGlyphBesideTheHandAndTheBadgeKeepsTheLeadingSlot() throws {
        let cell = try markRowCell(spinnerAt: .leading, badgeAt: .leading, unread: 3, waiting: true, running: true, status: .review)
        let badge = cell.leadingBadgeForTesting
        let glyph = cell.statusGlyphButtonForTesting
        let hand = try #require(cell.handForTesting)
        let spinner = try #require(cell.markSpinnerForTesting)
        #expect(!badge.isHidden && !glyph.isHidden && !hand.isHidden && !spinner.isHidden)
        #expect(badge.frame.maxX <= glyph.frame.minX, "badge \(badge.frame), glyph \(glyph.frame)")
        #expect(glyph.frame.maxX <= hand.frame.minX, "glyph \(glyph.frame), hand \(hand.frame)")
        #expect(abs(spinner.frame.minX - (hand.frame.maxX + 8)) < 0.001, "spinner \(spinner.frame), hand \(hand.frame)")
        #expect(cell.titleFrameForTesting.minX >= spinner.frame.maxX)
        #expect(cell.trailingSpinnerForTesting?.isHidden != false)

        let spinnerOnly = try markRowCell(spinnerAt: .leading, badgeAt: .leading, unread: 0, waiting: false, running: true, status: .review)
        let onlySpinner = try #require(spinnerOnly.markSpinnerForTesting)
        #expect(!onlySpinner.isHidden)
        #expect(onlySpinner.frame.minX >= spinnerOnly.statusGlyphButtonForTesting.frame.maxX, "the spinner follows the glyph, not the leading slot")
        #expect(spinnerOnly.titleFrameForTesting.minX >= onlySpinner.frame.maxX)
    }

    /// cm-128.1 (Scenario 17, AppKit row): both set to the right, the badge sits at the row's edge, the spinner beside it
    /// with the 6-pt gap, and the title stops before the spinner. Nothing leads.
    @Test func appKitRightBadgeAndSpinnerBothShowWithTheBadgeAtTheEdge() throws {
        let cell = try markRowCell(spinnerAt: .trailing, badgeAt: .trailing, unread: 3, waiting: true, running: true, status: .review)
        let badge = cell.trailingBadgeForTesting
        let spinner = try #require(cell.trailingSpinnerForTesting)
        #expect(!badge.isHidden && !spinner.isHidden)
        #expect(cell.leadingBadgeForTesting.isHidden)
        #expect(cell.markSpinnerForTesting?.isHidden != false)
        #expect(abs(spinner.frame.maxX + 6 - badge.frame.minX) < 0.001, "spinner \(spinner.frame), badge \(badge.frame)")
        #expect(cell.titleFrameForTesting.maxX <= spinner.frame.minX, "title \(cell.titleFrameForTesting), spinner \(spinner.frame)")
        let hand = try #require(cell.handForTesting)
        #expect(!hand.isHidden)
        #expect(cell.titleFrameForTesting.minX >= hand.frame.maxX)
    }

    /// cm-128.1: hovering the row swaps both trailing marks for the close button, and the title must not move: it reserves the
    /// marks' width at rest, not the width of what is visible. (Mutation proof: reserve from the visible marks and this fails.)
    @Test func hoveringTheRowDoesNotMoveTheTitleWhenBothTrailingMarksShow() throws {
        let cell = try markRowCell(spinnerAt: .trailing, badgeAt: .trailing, unread: 3, waiting: false, running: true)
        let resting = cell.titleFrameForTesting
        #expect(!cell.trailingBadgeForTesting.isHidden && cell.trailingSpinnerForTesting?.isHidden == false)
        cell.enforcePointerHovering(true)
        cell.layout()
        #expect(cell.trailingBadgeForTesting.isHidden && cell.trailingSpinnerForTesting?.isHidden != false, "the close button replaces both marks")
        #expect(cell.titleFrameForTesting == resting, "hovered title \(cell.titleFrameForTesting), resting \(resting)")
        cell.enforcePointerHovering(false)
        cell.layout()
        #expect(cell.titleFrameForTesting == resting)
    }

    /// The ink width of `view` as drawn, in points: the columns with alpha above `threshold`, at 8 px per point.
    private func inkWidth(of view: NSView, threshold: CGFloat) throws -> CGFloat { // (#cm-109.7)
        let scale = 8 // (#cm-109.7)
        let width = Int(view.bounds.width) * scale // (#cm-109.7)
        let height = Int(view.bounds.height) * scale // (#cm-109.7)
        let rep = try #require(NSBitmapImageRep( // (#cm-109.7)
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, // (#cm-109.7)
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0 // (#cm-109.7)
        )) // (#cm-109.7)
        rep.size = view.bounds.size // (#cm-109.7)
        view.cacheDisplay(in: view.bounds, to: rep) // (#cm-109.7)
        var minX = width // (#cm-109.7)
        var maxX = -1 // (#cm-109.7)
        for y in 0..<height { // (#cm-109.7)
            for x in 0..<width where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > threshold { // (#cm-109.7)
                minX = min(minX, x) // (#cm-109.7)
                maxX = max(maxX, x) // (#cm-109.7)
            } // (#cm-109.7)
        } // (#cm-109.7)
        return maxX < minX ? 0 : CGFloat(maxX - minX + 1) / CGFloat(scale) // (#cm-109.7)
    } // (#cm-109.7)

    /// The outlined hand is 1 pt wider than the yellow one: its copies sit 0.5 pt away on each side, as in the SwiftUI
    /// row. The copies are drawn by the same image view the hand is, so the measure compares like with like.
    @Test func theAppKitOutlineIsHalfAPointOffTheHand() throws { // (#cm-109.7)
        let cell = try waitingHandCell(dark: false, isActive: false, standIn: "#C2C0CB") // (#cm-109.7)
        let hand = try #require(cell.handForTesting) // (#cm-109.7)
        let outline = try #require(cell.handOutlineForTesting) // (#cm-109.7)
        #expect(outline.isHidden == false) // (#cm-109.7)
        outline.layoutSubtreeIfNeeded() // (#cm-109.7)
        let handInk = try inkWidth(of: hand, threshold: 0.9) // (#cm-109.7)
        let outlineInk = try inkWidth(of: outline, threshold: 0.9) // (#cm-109.7)
        #expect(handInk > 5, "the hand draws ink: \(handInk) pt") // (#cm-109.7)
        // 1 pt from the two 0.5 pt offsets; the layer-backed copies measure a quarter point more (1.25 here), so the band
        // is 1 to 1.5. Offsets of 0.25 or 1 pt, which is what a scaled or a doubled offset would give, fall outside it.
        let extra = outlineInk - handInk // (#cm-109.7)
        #expect(extra >= 1.0 && extra <= 1.5, "the outline is \(extra) pt wider than the hand (\(handInk)), expected about 1.0") // (#cm-109.7)
    } // (#cm-109.7)
}

@MainActor
@Suite("None workspace rows", .serialized)
struct WorkspaceNoneRowTests {
    static let list = WorkspaceStatusList(entries: [
        .init(id: "parked", name: "Parked", extends: .todo, color: "#112233"),
        .init(id: "next", name: "Next", extends: .working, color: "#334455", icon: .shape(.half)),
        .init(id: "done", name: "Done")
    ], source: .file)
    static let source = ##"{"workspaceStatuses":[{"id":"parked","name":"Parked","extends":"todo","color":"#112233"},{"id":"next","name":"Next","extends":"working","icon":"half","color":"#334455"},{"id":"done","name":"Done"}]}"##

    func model(_ workspace: Workspace, controls: Bool = true, dark: Bool = false) -> SidebarWorkspaceRowModel {
        let suite = "WorkspaceNoneRowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)
        let snapshot = SidebarWorkspaceSnapshotFactory(
            workspace: workspace, settings: settings, showsAgentActivity: false, todoControlsEnabled: controls,
            statusList: Self.list, statusColorHexes: ["next": "#334455", "parked": "#112233"]
        ).makeSnapshot()
        return SidebarWorkspaceRowModel(
            workspaceId: workspace.id, index: 0, snapshot: snapshot, settings: settings,
            isActive: false, isMultiSelected: false, hasUserCustomTitle: false, canCloseWorkspace: false,
            accessibilityWorkspaceCount: 1, unreadCount: 0, latestNotificationText: nil,
            showsAgentActivity: false, rowSpacing: 0, isBeingDragged: false,
            topDropIndicatorVisible: false, bottomDropIndicatorVisible: false, isGrouped: false,
            isColorSectionMember: false, isFirstRow: true, shortcutHintText: nil, showsShortcutHints: false,
            colorSchemeIsDark: dark, contrastBackgroundHex: dark ? "#202020" : "#FFFFFF",
            globalFontMagnificationPercent: 100, isChecklistExpanded: false,
            checklistAddFieldActivationToken: 0, isChecklistPopoverPresented: false, editingChecklistItemId: nil,
            todoControlsEnabled: controls, isMetadataExpanded: false, isMarkdownExpanded: false
        )
    }

    func cell(_ model: SidebarWorkspaceRowModel) -> SidebarWorkspaceRowTableCellView {
        let cell = SidebarWorkspaceRowTableCellView(frame: NSRect(x: 0, y: 0, width: 320, height: 40))
        cell.configurePresentation(model: model)
        cell.layout()
        return cell
    }

    func expectDot(_ cell: SidebarWorkspaceRowTableCellView) throws {
        #expect(!cell.statusGlyphButtonForTesting.isHidden, "None must show its glyph button")
        let glyph = try #require(cell.statusGlyphModelForTesting, "None must configure its glyph model")
        #expect(glyph.isNone, "None must draw the dot")
        let row = try #require(cell.currentModelForTesting)
        let shared = SidebarWorkspaceManualTaskStatusIndicatorModel(
            featureEnabled: row.todoControlsEnabled, taskStatus: row.snapshot.taskStatus,
            hasManualOverride: row.snapshot.hasManualTaskStatus, isHidden: row.snapshot.taskStatusInput.isHidden
        )
        #expect(shared.showsIndicator, "the shared SwiftUI row decision must admit None")
    }

    @Test func newWorkspaceOnNoneShowsDot() throws {
        let workspace = Workspace()
        #expect(workspace.todoState.statusHidden)
        let cell = cell(model(workspace))
        try expectDot(cell)
        let glyph = try #require(cell.statusGlyphModelForTesting)
        let context = try #require(CGContext(data: nil, width: 44, height: 36, bitsPerComponent: 8, bytesPerRow: 176,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: 4, y: 4)
        SidebarRowTaskStatusGlyphButton.drawGlyph(model: glyph, color: NSColor.black.cgColor,
            tickColor: NSColor.white.cgColor, in: context, bounds: CGRect(x: 0, y: 0, width: 11, height: 9))
        let image = try #require(context.makeImage())
        let ink = WorkspaceStatusIconDrawing.measureInkRect(image, imageSize: CGSize(width: 44, height: 36))
        #expect(abs(ink.width - 12) <= 1 && abs(ink.height - 12) <= 1,
                "the real factory row must draw a 3 pt dot, not a status glyph or dash")
        #expect(abs(ink.midX - 22) <= 0.5 && abs(ink.midY - 18) <= 0.5)
    }

    @Test func pickingNextReplacesDotWithItsGlyph() throws {
        let workspace = Workspace()
        workspace.setOwnStatus(try #require(Self.list.entry(id: "next")), list: Self.list)
        let cell = cell(model(workspace))
        #expect(!cell.statusGlyphButtonForTesting.isHidden)
        let glyph = try #require(cell.statusGlyphModelForTesting)
        #expect(!glyph.isNone && glyph.icon == .shape(.half) && glyph.name == "Next")
    }

    @Test func pickingAutoLeavesAnEmptySlot() {
        let workspace = Workspace(); workspace.clearTaskStatusOverride()
        let row = model(workspace)
        #expect(cell(row).statusGlyphButtonForTesting.isHidden)
        #expect(!SidebarWorkspaceManualTaskStatusIndicatorModel(
            featureEnabled: true, taskStatus: row.snapshot.taskStatus,
            hasManualOverride: row.snapshot.hasManualTaskStatus, isHidden: row.snapshot.taskStatusInput.isHidden
        ).showsIndicator)
    }

    @Test func pickingNoneAgainRestoresDot() throws {
        let workspace = Workspace()
        workspace.setOwnStatus(try #require(Self.list.entry(id: "next")), list: Self.list)
        workspace.hideTaskStatus()
        try expectDot(cell(model(workspace)))
    }

    @Test func controlsOffShowsNeitherDotNorStatusGlyph() throws {
        let workspace = Workspace()
        for choice in ["none", "next", "auto"] {
            if choice == "next" { workspace.setOwnStatus(try #require(Self.list.entry(id: "next")), list: Self.list) }
            if choice == "auto" { workspace.clearTaskStatusOverride() }
            let row = model(workspace, controls: false)
            #expect(cell(row).statusGlyphButtonForTesting.isHidden, "controls off: \(choice)")
            #expect(!SidebarWorkspaceManualTaskStatusIndicatorModel(
                featureEnabled: false, taskStatus: row.snapshot.taskStatus,
                hasManualOverride: row.snapshot.hasManualTaskStatus, isHidden: row.snapshot.taskStatusInput.isHidden
            ).showsIndicator)
        }
    }

    @Test func noneAndNextHaveTheSameTitlePositionAndGlyphGap() throws {
        let workspace = Workspace()
        let cell = cell(model(workspace))
        let noneX = cell.titleFrameForTesting.minX
        let noneGap = noneX - cell.statusGlyphButtonForTesting.frame.maxX
        workspace.setOwnStatus(try #require(Self.list.entry(id: "next")), list: Self.list)
        cell.configurePresentation(model: model(workspace)); cell.layout()
        #expect(noneX == cell.titleFrameForTesting.minX, "None and Next reserve the same glyph slot")
        #expect(noneGap == cell.titleFrameForTesting.minX - cell.statusGlyphButtonForTesting.frame.maxX,
                "None and Next have the same gap to the title")
    }

    @Test func noneHasItsNameAccessibleButtonAndContrastFloorInLightAndDark() throws {
        for dark in [false, true] {
            let cell = cell(model(Workspace(), dark: dark))
            let glyph = try #require(cell.statusGlyphModelForTesting, "None needs a configured glyph")
            #expect(glyph.name == "None")
            let background = try #require(glyph.contrastBackground, "None must use the row's contrast background")
            let color = SidebarRowTaskStatusGlyphButton.statusColor(
                model: glyph, monochromeColor: .secondaryLabelColor, neutralColor: .secondaryLabelColor
            )
            #expect(cmuxContrastRatio(foreground: color, background: background) >= 3 - 0.001)
            #expect(cell.statusGlyphButtonForTesting.accessibilityLabel() == "Status: None")
            #expect(cell.statusGlyphButtonForTesting.accessibilityRole() == .button)
        }
    }

    @Test func nonePopoverExistsAndChecksNone() throws {
        let workspace = Workspace(); workspace.hideTaskStatus()
        let popover = try #require(cell(model(workspace)).statusPopoverModelForTesting, "None must have a status popover")
        let lanes = WorkspaceTodoStatusLane.lanes(picker: popover.picker)
        #expect(lanes.last?.isNone == true && lanes.last?.isSelected == true)
        #expect(lanes.first?.isSelected == false)
    }

    @Test func noneWithDetectedDoneStaysUndimmedAndKeepsStripSuppression() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let panel = try #require(workspace.focusedPanelId)
        workspace.panelGitBranches[panel] = SidebarGitBranchState(branch: "done", isDirty: false)
        workspace.panelPullRequests[panel] = SidebarPullRequestState(
            number: 1, label: "PR #1", url: URL(string: "https://example.com/pr/1")!, status: .merged, branch: "done"
        )
        workspace.hideTaskStatus()
        let row = model(workspace)
        #expect(row.snapshot.taskStatusInput.inferred == .done, "fixture must detect Done")
        #expect(row.snapshot.taskStatus == nil && !row.snapshot.hasManualTaskStatus)
        #expect(SidebarWorkspaceRowVisualPalette.contentAlpha(taskStatus: row.snapshot.taskStatus) == 1)
        #expect(SidebarWorkspaceRowVisualPalette.suppressesAccentStrip(attentionTaskStatus: row.snapshot.attentionTaskStatus))
        try expectDot(cell(row))
    }

    private final class PopoverCloseWitness: NSObject {
        weak var popover: NSPopover?
        var requested = false
        @objc func willShow(_ notification: Notification) {
            if popover == nil { popover = notification.object as? NSPopover }
        }
        @objc func willClose(_ notification: Notification) { requested = true }
    }

    @Test func dotPressOpensPopoverAndRefreshKeepsItOpen() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let workspace = Workspace(); workspace.hideTaskStatus()
            let row = model(workspace)
            let actions = SidebarWorkspaceRowSuspensionTests.makeActions(model: row, workspace: workspace)
            let cell = SidebarWorkspaceRowTableCellView(frame: NSRect(x: 0, y: 0, width: 320, height: 40))
            cell.configure(model: row, actions: actions, isPointerHovering: false,
                           contextMenuDidOpen: {}, contextMenuDidClose: {})
            cell.layout()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = cell
            defer { window.contentView = nil; window.close() }
            window.orderFront(nil)
            let close = PopoverCloseWitness()
            NotificationCenter.default.addObserver(close, selector: #selector(PopoverCloseWitness.willShow(_:)),
                                                   name: NSPopover.willShowNotification, object: nil)
            defer { NotificationCenter.default.removeObserver(close) }
            #expect(cell.statusGlyphButtonForTesting.accessibilityPerformPress())
            #expect(cell.isStatusPopoverShownForTesting, "the dot must open the real status popover")
            let popover = try #require(close.popover, "capture the popover this dot opened")
            NotificationCenter.default.addObserver(close, selector: #selector(PopoverCloseWitness.willClose(_:)),
                                                   name: NSPopover.willCloseNotification, object: popover)
            let previous = try #require(cell.currentModelForTesting)
            var refreshed = previous
            refreshed.isActive.toggle()
            #expect(refreshed != previous, "refresh must exercise applyModel instead of the equality fast path")
            // The live table refresh calls this path: SidebarWorkspaceTableController.swift:2512 -> :2540.
            cell.configure(model: refreshed, actions: actions, isPointerHovering: false,
                           contextMenuDidOpen: {}, contextMenuDidClose: {})
            #expect(cell.isStatusPopoverShownForTesting && !close.requested,
                    "refresh must retain the None anchor and popover model without requesting an animated close")
        }
    }

    enum Placement { case workspaces, pinned, plainGroup, statusGroup, retainedColor }

    private func mounted(_ placement: Placement, checkHeader: Bool = false, click: Bool = false) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let restore = try SidebarNestedRootStatusTests.installStatusList(source: Self.source, controls: true)
            defer { restore() }
            let manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false)
            let active = Workspace(), target = Workspace()
            _ = active.setCustomTitle("active"); _ = target.setCustomTitle("none-target")
            active.clearTaskStatusOverride(); target.hideTaskStatus()
            manager.tabs = [active, target]; manager.selectedTabId = active.id
            var group: UUID?
            switch placement {
            case .workspaces: break
            case .pinned: manager.setPinned(target, pinned: true)
            case .plainGroup, .statusGroup:
                group = try #require(manager.createWorkspaceGroup(name: "None group", childWorkspaceIds: [target.id]))
                if placement == .statusGroup {
                    #expect(WorkspaceGroupStatusUIActions.app(tabManager: manager, controlsEnabled: true)
                        .applyGroup(.status(id: "parked"), groupId: group!))
                }
            case .retainedColor:
                target.setOwnStatus(try #require(Self.list.entry(id: "next")), list: Self.list)
                target.hideTaskStatus()
                manager.applyWorkspaceColor("#334455", to: [target])
            }
            let harness = SidebarNestedRootStatusTests()
            let mounted = try await harness.mountWindow(manager)
            defer { harness.closeWindow(mounted) }
            if click {
                mounted.window.orderFront(nil)
                await harness.drain(mounted.window, iterations: 4)
            }
            let cells = harness.descendants(of: SidebarWorkspaceRowTableCellView.self, in: mounted.table)
            let cell = try #require(cells.first { $0.currentModelForTesting?.workspaceId == target.id },
                                    "the sidebar must configure the target's real row")
            if checkHeader {
                let header = try #require(harness.descendants(of: SidebarGroupHeaderTableCellView.self, in: mounted.table)
                    .first { $0.currentModelForTesting?.groupId == group })
                let model = try #require(header.currentModelForTesting)
                #expect(model.groupStatusGlyph == nil && model.statusGlyph == nil)
                #expect(model.iconSymbol == RenderableSystemSymbol.defaultWorkspaceGroupIcon && header.iconImageForTesting != nil,
                        "a group on None keeps its folder and no status glyph")
            } else {
                try expectDot(cell)
            }
            if placement == .statusGroup {
                let header = try #require(harness.descendants(of: SidebarGroupHeaderTableCellView.self, in: mounted.table)
                    .first { $0.currentModelForTesting?.groupId == group })
                #expect(header.currentModelForTesting?.groupStatusGlyph?.name == "Parked")
            }
            if placement == .retainedColor {
                #expect(target.customColor == "#334455")
                let headers = harness.descendants(of: SidebarGroupHeaderTableCellView.self, in: mounted.table)
                let row = mounted.table.row(for: cell)
                let preceding = headers.filter { mounted.table.row(for: $0) < row }.max {
                    mounted.table.row(for: $0) < mounted.table.row(for: $1)
                }
                #expect(preceding?.currentModelForTesting?.statusHeaderKind == .workspacesArea,
                        "None wearing Next color must stay in Workspaces, under no status group")
            }
            if click {
                let before = manager.selectedTabId
                let glyph = cell.statusGlyphButtonForTesting
                let point = glyph.convert(CGPoint(x: glyph.bounds.midX, y: glyph.bounds.midY), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                        timestamp: 0, windowNumber: mounted.window.windowNumber, context: nil,
                        eventNumber: 0, clickCount: 1, pressure: 1))
                    if type == .leftMouseDown { glyph.mouseDown(with: event) } else { glyph.mouseUp(with: event) }
                }
                #expect(manager.selectedTabId == before, "clicking the dot must not select its row")
                #expect(cell.isStatusPopoverShownForTesting)
            }
        }
    }

    @Test func noneInWorkspacesShowsDot() async throws { try await mounted(.workspaces) }
    @Test func noneInPinnedShowsDot() async throws { try await mounted(.pinned) }
    @Test func noneInAPlainWorkspaceGroupShowsDot() async throws { try await mounted(.plainGroup) }
    @Test func noneInAGroupUnderParkedShowsDot() async throws { try await mounted(.statusGroup) }
    @Test func noneWearingNextColorShowsDotInWorkspaces() async throws { try await mounted(.retainedColor) }
    @Test func groupHeaderOnNoneKeepsFolderAndNoGlyph() async throws { try await mounted(.plainGroup, checkHeader: true) }
    @Test func clickingTheDotDoesNotSelectItsRow() async throws { try await mounted(.workspaces, click: true) }

    /// H68.2: exercise the mounted row's real capabilities, rather than substituting a status writer in the fixture.
    @Test(arguments: ["popover", "menu", "palette"])
    func pickingNextThroughTheMountedEntranceWritesAndPersistsItsColor(_ entrance: String) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let restore = try SidebarNestedRootStatusTests.installStatusList(source: Self.source, controls: true)
            defer { restore() }
            let suite = "WorkspaceNoneRowTests.color-pick.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let customizations = WorkspaceCustomizationStore(defaults: defaults,
                storageKey: "customizations", legacyStorageKey: "legacy-customizations")
            let manager = TabManager(autoWelcomeIfNeeded: false, workspaceCustomizationStore: customizations)
            let workspace = try #require(manager.selectedWorkspace)
            workspace.hideTaskStatus()
            let delegate = try #require(AppDelegate.shared)
            let windowId = delegate.registerMainWindowContextForTesting(tabManager: manager)
            defer { delegate.unregisterMainWindowContextForTesting(windowId: windowId) }
            let harness = SidebarNestedRootStatusTests()
            let mounted = try await harness.mountWindow(manager)
            defer { harness.closeWindow(mounted) }
            let cell = try #require(harness.descendants(of: SidebarWorkspaceRowTableCellView.self, in: mounted.table)
                .first { $0.currentModelForTesting?.workspaceId == workspace.id })
            try #require(workspace.customColor == nil && workspace.todoState.statusHidden)
            switch entrance {
            case "popover":
                let popover = try #require(cell.statusPopoverForTesting)
                let next = try #require(popover.lanes.first { $0.id == "next" })
                popover.onSelectLane(try #require(next.action))
                popover.onClose()
            case "menu":
                let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero,
                    modifierFlags: [], timestamp: 0, windowNumber: mounted.window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                let menu = try #require(cell.menu(for: event))
                let statuses = try #require(menu.items.first { $0.title == String(localized: "contextMenu.workspaceStatus", defaultValue: "Status") }?.submenu)
                let index = try #require(statuses.items.firstIndex { $0.title == "Next" })
                statuses.performActionForItem(at: index)
            default:
                var registry = CommandPaletteHandlerRegistry()
                WorkspaceTodoPaletteCommands.registerHandlers(in: &registry, tabManager: manager)
                let pick = try #require(registry.handler(for: "palette.workspaceStatus.next"))
                pick()
            }
            #expect(workspace.todoState.ownStatus?.id == "next" && !workspace.todoState.statusHidden,
                    "\(entrance): Next must reach the live workspace")
            #expect(workspace.customColor == "#334455", "\(entrance): Next must write its resolved color")
            await harness.drain(mounted.window)
            #expect(workspace.customColor == "#334455", "\(entrance): row reconciliation must retain Next's color")
            if case .value(let color)? = customizations.customization(for: workspace.stableId)?.customColor {
                #expect(color == "#334455", "\(entrance): Workspace Color persistence must agree")
            } else {
                Issue.record("\(entrance): Next must persist its resolved color; actual customization \(String(describing: customizations.customization(for: workspace.stableId)?.customColor))")
            }
        }
    }
}

@MainActor
@Suite("None todo pane header", .serialized)
struct WorkspaceNonePaneHeaderTests {
    private func workingWorkspace() throws -> (TabManager, Workspace) {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let panel = try #require(workspace.focusedPanelId)
        workspace.agentLifecycleStatesByPanelId[panel] = ["agent": .running]
        workspace.hideTaskStatus()
        #expect(workspace.inferredTaskStatus(list: .cmuxFive) == .working, "fixture must detect Working")
        return (manager, workspace)
    }

    private func pane(_ workspace: Workspace, controls: Bool = true, list: WorkspaceStatusList = .cmuxFive)
        -> (WorkspaceStatusPaneState, WorkspaceStatusPaneState.Header) {
        let inferred = workspace.inferredTaskStatus(list: list)
        let resolution = workspace.statusResolution(list: list, inferred: inferred)
        let pane = WorkspaceStatusPaneState.make(
            resolution: resolution, inferred: inferred, list: list,
            controlsEnabled: controls, statusHidden: workspace.todoState.statusHidden
        )
        return (pane, pane.header(effective: resolution.effective,
                                 statusHidden: workspace.todoState.statusHidden, controlsEnabled: controls))
    }

    @Test func noneHeaderReplacesDetectedWorkingWithDotAndNoneLabel() throws {
        let (manager, workspace) = try workingWorkspace()
        defer { withExtendedLifetime(manager) {} }
        let (_, header) = pane(workspace)
        #expect(header.isNone, "None header must draw the dot")
        #expect(header.status != .working, "None header must not draw detected Working")
        #expect(header.label == "None", "None header must replace the detected status label")
    }

    @Test func noneHeaderPopoverChecksNoneInsteadOfAuto() throws {
        let (manager, workspace) = try workingWorkspace()
        defer { withExtendedLifetime(manager) {} }
        let (pane, _) = pane(workspace)
        let lanes = WorkspaceTodoStatusLane.lanes(picker: pane.picker)
        #expect(lanes.last?.isNone == true && lanes.last?.isSelected == true, "None header popover checks None")
        #expect(lanes.first?.isSelected == false, "None header popover must not check Auto")
    }

    @Test func noneHeaderWithControlsOffShowsNoDotGlyphOrLabel() throws {
        let (manager, workspace) = try workingWorkspace()
        defer { withExtendedLifetime(manager) {} }
        let (_, header) = pane(workspace, controls: false)
        #expect(header.status == nil && !header.isNone && header.label == nil)
    }

    @Test func pickingNextInThePaneRetainsNextsGlyphAndName() throws {
        let workspace = Workspace()
        workspace.setOwnStatus(try #require(WorkspaceNoneRowTests.list.entry(id: "next")), list: WorkspaceNoneRowTests.list)
        let (pane, header) = pane(workspace, list: WorkspaceNoneRowTests.list)
        #expect(header.status == .working && !header.isNone && header.label == "Next")
        #expect(pane.icon == .shape(.half))
    }
}

@MainActor
@Suite("None status strings", .serialized)
struct WorkspaceNoneStringsTests {
    private func expectNone(_ lanes: [WorkspaceTodoStatusLane]) throws {
        let none = try #require(lanes.last)
        #expect(none.isNone && none.title == "None", "the real surface must call the choice None")
        #expect(none.status == nil && none.icon == nil, "the menu's None choice has no icon")
    }

    @Test func workspaceStatusSubmenuCallsTheChoiceNone() throws {
        let workspace = Workspace(); workspace.hideTaskStatus()
        try expectNone(workspace.statusMenuLanes(list: WorkspaceNoneRowTests.list, colorHexes: [:]))
    }

    @Test func statusPopoverCallsTheChoiceNone() throws {
        let fixture = WorkspaceNoneRowTests()
        let workspace = Workspace(); workspace.hideTaskStatus()
        let model = try #require(fixture.cell(fixture.model(workspace)).statusPopoverModelForTesting)
        let popover = SidebarWorkspaceStatusPopover(model: model, onSelectLane: { _ in }, onSelectNone: {}, onClose: {})
        try expectNone(popover.lanes)
    }

    @Test func rowInputsStatusLanesCallTheChoiceNone() throws {
        let fixture = WorkspaceNoneRowTests(), entrances = WorkspaceStatusEntrancesTests()
        let workspace = Workspace(); workspace.hideTaskStatus()
        let model = fixture.model(workspace)
        let input = entrances.rowInput(model.snapshot, settings: model.settings)
        try expectNone(entrances.rowSnapshot(input).contextMenu.todoStatusLanes)
    }

    @Test func appKitDotTooltipAndAccessibleNameSayPlainNone() {
        let fixture = WorkspaceNoneRowTests()
        let cell = fixture.cell(fixture.model(Workspace()))
        #expect(cell.statusGlyphButtonForTesting.toolTip == "None", "the dot tooltip must omit inferred/manual suffixes")
        #expect(cell.statusGlyphButtonForTesting.accessibilityLabel() == "Status: None")
    }

    @Test func swiftUIRowAndHeaderDotTooltipsSayPlainNone() throws {
        let menu = try WorkspaceNoneSwiftUIRowTests().menu(Workspace())
        #expect(menu.tooltip == "None", "the row's outer button must not replace the dot's None tooltip")
        #expect(menu.statusGlyph.tooltip == "None", "SwiftUI row glyph tooltip must say None")
        let headerGlyph = SidebarWorkspaceTaskStatusGlyph(
            status: .working, hasOverride: false, usesMonochrome: false, monochromeColor: .primary,
            neutralColor: .secondary, fontScale: 13.0 / 9.0, contrastBackground: nil, isNone: true
        )
        #expect(headerGlyph.tooltip == "None", "the header's tooltip and accessibility name must say None")
    }

    @Test func builtNoneAndCompactLabelHaveAllTwentyLocales() throws {
        let expected = [
            "en": "None", "ar": "لا شيء", "bs": "Nijedan", "da": "Ingen", "de": "Kein Status",
            "es": "Ninguno", "fr": "Aucun", "it": "Nessuno", "ja": "なし", "km": "គ្មាន",
            "ko": "없음", "nb": "Ingen", "pl": "Brak", "pt-BR": "Nenhum", "ru": "Нет",
            "th": "ไม่มี", "tr": "Yok", "uk": "Немає", "zh-Hans": "无", "zh-Hant": "無"
        ]
        for (locale, none) in expected {
            let path = try #require(Bundle.main.path(forResource: locale, ofType: "lproj"), "built locale \(locale)")
            let bundle = try #require(Bundle(path: path))
            #expect(bundle.localizedString(forKey: "workspaceGroup.status.none", value: nil, table: nil) == none,
                    "None translation for \(locale)")
            let format = bundle.localizedString(forKey: "sidebar.status.compactLabel", value: nil, table: nil)
            #expect(format.contains("%@"), "built compact label for \(locale)")
            #expect(String(format: format, none).contains(none))
        }
        #expect(expected.count == 20)
    }
}
