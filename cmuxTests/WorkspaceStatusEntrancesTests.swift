import AppKit
import CmuxCommandPalette
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
        Entry(id: "review", name: "Reviewing"),
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

    private func settings() -> (SidebarTabItemSettingsSnapshot, () -> Void) {
        let suite = "WorkspaceStatusEntrancesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (SidebarTabItemSettingsSnapshot(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }

    private func factory(
        _ workspace: Workspace,
        list: WorkspaceStatusList,
        hexes: [String: String] = [:],
        settings: SidebarTabItemSettingsSnapshot
    ) -> SidebarWorkspaceSnapshotFactory {
        SidebarWorkspaceSnapshotFactory(
            workspace: workspace, settings: settings, showsAgentActivity: false, todoControlsEnabled: true,
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

    private func rowInput(_ snapshot: SidebarWorkspaceSnapshotBuilder.Snapshot, settings: SidebarTabItemSettingsSnapshot) -> SidebarWorkspaceRowInput {
        SidebarWorkspaceRowInput(
            workspaceId: UUID(), groupId: nil, isColorSectionMember: false, index: 0, workspaceCount: 1,
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

    private func rowSnapshot(_ input: SidebarWorkspaceRowInput) -> SidebarWorkspaceRowSnapshot {
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
        workspace.setOwnStatus(try #require(Self.hisList.entry(id: "parked")))
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .needsInput)
        #expect(workspace.inferredTaskStatus == .needsAttention, "no wait was detected, so the test proves nothing")
        let snapshot = factory(workspace, list: Self.hisList, settings: settings).makeSnapshot()
        #expect(snapshot.hasManualTaskStatus, "his status is held through the wait but the glyph is not drawn")
        #expect(snapshot.taskStatus == .todo, "the glyph shows \(String(describing: snapshot.taskStatus)), not the status he holds")
        #expect(snapshot.attentionTaskStatus == .needsAttention, "the row is no longer in play during the wait")
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
    /// the glyph's tooltip and the header, and the rows. His word is only for a status in effect: a status of his that
    /// waits behind a waiting agent is held, not shown (the tooltip must not name it).
    @Test func thePaneStateOverTheSixResolutions() {
        let expected: [(hasOverride: Bool, cmux: WorkspaceTaskStatus?, word: String?)] = [
            (false, nil, nil), (true, .review, "Reviewing"), (true, .working, nil), (false, nil, nil),
            (true, nil, "Doing"), (false, nil, nil), (false, nil, nil),
        ]
        for ((name, resolution), want) in zip(sixResolutions(), expected) {
            let inferred = resolution.effective
            let pane = WorkspaceStatusPaneState.make(resolution: resolution, inferred: inferred, list: Self.hisList, controlsEnabled: true)
            #expect(pane.hasOverride == want.hasOverride, "\(name): hasOverride")
            #expect(pane.cmuxOverride == want.cmux, "\(name): cmuxOverride")
            #expect(pane.hisWord == want.word, "\(name): hisWord")
            let off = WorkspaceStatusPaneState.make(resolution: resolution, inferred: inferred, list: Self.hisList, controlsEnabled: false)
            #expect(!off.hasOverride && off.hisWord == nil, "\(name): the controls are off")
        }
    }

    /// The pane builds its rows with `isHidden: false`, as the release's popover hosts did: on a workspace that starts
    /// on None, with cmux's five, Auto is the checked row and None is not.
    @Test func thePanesRowsForAWorkspaceOnNoneHaveAutoChecked() {
        let pane = WorkspaceStatusPaneState.make(
            resolution: .resolve(override: nil, own: nil, inferred: .todo, list: .cmuxFive),
            inferred: .todo, list: .cmuxFive, controlsEnabled: true
        )
        let lanes = WorkspaceTodoStatusLane.lanes(picker: pane.picker)
        #expect(lanes.first?.isSelected == true)
        #expect(lanes.last?.isNone == true && lanes.last?.isSelected == false)
        #expect(lanes == WorkspaceTodoStatusLane.lanes(inferred: .todo, activeOverride: nil, isHidden: false))
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
}
