import AppKit
import CmuxSettings
import CmuxWorkspaces
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SidebarWorkspaceSectionMigrationTests {
    private func withList(_ body: (TabManager) throws -> Void) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let name = "SidebarWorkspaceSectionMigrationTests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: name))
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: dir) }
            let file = dir.appendingPathComponent("cmux.json")
            try ##"{"workspaceStatuses":[{"id":"parked","name":"Parked","extends":"todo","color":"#112233"}]}"##
                .write(to: file, atomically: true, encoding: .utf8)
            let store = WorkspaceStatusListStore(fileURL: file, defaults: defaults,
                resolveColor: { $0 }, paletteFingerprint: { "fixed" }, clock: ContinuousClock())
            store.load()
            let old = AppDelegate.shared, delegate = AppDelegate()
            delegate.workspaceStatusListStore = store; AppDelegate.shared = delegate
            let key = BetaFeaturesCatalogSection().workspaceTodoControls.userDefaultsKey
            let previous = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.set(true, forKey: key)
            defer { AppDelegate.shared = old; UserDefaults.standard.set(previous, forKey: key) }
            let manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false)
            _ = manager.addWorkspace(title: "A", workingDirectory: dir.path, select: false,
                eagerLoadTerminal: false, autoWelcomeIfNeeded: false, autoRefreshMetadata: false)
            _ = manager.addWorkspace(title: "B", workingDirectory: dir.path, select: false,
                eagerLoadTerminal: false, autoWelcomeIfNeeded: false, autoRefreshMetadata: false)
            try body(manager)
        }
    }

    private func migrate(_ record: WorkspaceStatusGroupsState?, manager: TabManager,
        expected: WorkspaceSectionOrder) throws {
        let saved = SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 280, statusGroups: record)
        let decoded = try JSONDecoder().decode(SessionSidebarSnapshot.self, from: JSONEncoder().encode(saved))
        let state = SidebarState(statusGroups: decoded.statusGroups)
        #expect(state.statusGroups?.sectionOrder == nil)
        let next = try #require(state.statusGroupsForSnapshot(tabManager: manager))
        #expect(next.sectionOrder == expected)
        #expect(next.workspacesCollapsed == false)
        #expect(next.aboveRow == "top" && next.belowRow == nil && next.last == (expected == .workspacesFirst))
        let first = VerticalTabsSidebar.statusRenderItemsForSnapshot(tabManager: manager, state: state).items.map(\.id)
        let statuses = try #require(first.firstIndex(of: .statusesArea()))
        let workspaces = try #require(first.firstIndex(of: .workspacesArea()))
        #expect((statuses < workspaces) == (expected == .statusesFirst))
        let second = SidebarState(statusGroups: try JSONDecoder().decode(WorkspaceStatusGroupsState.self, from: JSONEncoder().encode(next)))
        #expect(second.statusGroupsForSnapshot(tabManager: manager) == next)
        #expect(next.areaCollapsed == (record?.areaCollapsed ?? false))
        #expect(next.collapsedStatusIds == (record?.collapsedStatusIds ?? []))
    }
    @Test func legacyTopWithoutLastStartsStatusesFirst() async throws {
        try await withList { try migrate(.init(areaCollapsed: true, collapsedStatusIds: ["parked"], last: false, aboveRow: "top"), manager: $0, expected: .statusesFirst) }
    }
    @Test func staleAboveWithFirstUnpinnedBelowStartsStatusesFirst() async throws {
        try await withList { manager in
            try migrate(.init(last: false, aboveRow: "workspace:gone", belowRow: "workspace:\(manager.tabs[0].id)"), manager: manager, expected: .statusesFirst)
        }
    }
    @Test func legacyLiveAboveRowStartsStatusesSecond() async throws {
        try await withList { manager in
            try migrate(.init(last: false, aboveRow: "workspace:\(manager.tabs[0].id)", belowRow: "workspace:\(manager.tabs[1].id)"), manager: manager, expected: .workspacesFirst)
        }
    }
    @Test func legacyLastWinsOverTopAndEmptyWorkspaces() async throws {
        try await withList { manager in
            for workspace in manager.tabs { workspace.customColor = "#112233" }
            try migrate(.init(last: true, aboveRow: "top"), manager: manager, expected: .workspacesFirst)
        }
    }
    @Test func missingLegacyRecordStartsStatusesSecond() async throws {
        try await withList { try migrate(nil, manager: $0, expected: .workspacesFirst) }
    }
    @Test func snapshotCannotRewriteLegacyPlacementBeforeMigration() async throws {
        try await withList { manager in
            let record = WorkspaceStatusGroupsState(last: false, aboveRow: "workspace:\(manager.tabs[0].id)")
            for snapshotFirst in [false, true] {
                let state = SidebarState(statusGroups: record)
                if snapshotFirst { _ = state.statusGroupsForSnapshot(tabManager: manager) }
                let result = try #require(state.reanchorStatusAreaBeforeMove(tabManager: manager,
                    movingWorkspaceIds: [manager.tabs[0].id], movingGroupIds: []))
                #expect(result.sectionOrder == .workspacesFirst)
                #expect(result.last == true && result.aboveRow == "top" && result.belowRow == nil)
                #expect(state.statusGroupsForSnapshot(tabManager: manager) == result)
            }
        }
    }
    @Test func firstListArrivalRevealsSelectedStatusAfterSectionPreparation() async throws {
        try await withList { manager in
            let selected = manager.tabs[0]
            selected.setOwnStatus(try #require(AppDelegate.statusListInUse.entry(id: "parked")), list: AppDelegate.statusListInUse)
            let delegate = try #require(AppDelegate.shared)
            let previousPresence = MobileWorkspaceListObserver.subscriberPresenceOverrideForTesting
            let windowId = delegate.registerMainWindowContextForTesting(tabManager: manager)
            defer {
                delegate.unregisterMainWindowContextForTesting(windowId: windowId)
                delegate.forgetRecoverableMainWindowRoute(windowId: windowId)
                MobileWorkspaceListObserver.subscriberPresenceOverrideForTesting = previousPresence
            }
            let state = SidebarState(collapsedColorSectionHexes: ["#112233"], statusGroups: nil)
            try #require(state.statusGroups == nil)
            let seed = WorkspaceStatusGroupsState.seeded(list: AppDelegate.statusListInUse,
                resolvedHexByStatusId: delegate.workspaceStatusListStore.colorHexes,
                collapsedColorHexes: state.collapsedColorSectionHexes)
            try #require(seed.collapsedStatusIds.contains("parked"), "The first list must inherit a collapsed selected status")
            state.prepareStatusGroupsOnListArrival(selectedWorkspace: selected)
            #expect(state.statusGroups?.sectionOrder != nil)
            #expect(state.statusGroups?.collapsedStatusIds.contains("parked") == false)
            #expect(state.statusGroups?.areaCollapsed == false)
            state.toggleStatusGroup(id: "parked")
            state.prepareStatusGroupsOnListArrival(selectedWorkspace: selected)
            #expect(state.statusGroups?.collapsedStatusIds.contains("parked") == true,
                "Later list revisions preserve a deliberate selected-status fold")
        }
    }
    @Test func inactiveListPreservesPendingLegacyRecordUntilActivation() async throws {
        try await withList { manager in
            let key = BetaFeaturesCatalogSection().workspaceTodoControls.userDefaultsKey
            UserDefaults.standard.set(false, forKey: key)
            let record = WorkspaceStatusGroupsState(last: false, aboveRow: "workspace:gone", belowRow: "workspace:\(manager.tabs[0].id)")
            let state = SidebarState(statusGroups: record)
            #expect(!state.prepareWorkspaceSections(tabManager: manager))
            #expect(state.statusGroupsForSnapshot(tabManager: manager) == record)
            UserDefaults.standard.set(true, forKey: key)
            #expect(state.prepareWorkspaceSections(tabManager: manager))
            #expect(state.statusGroups?.sectionOrder == .statusesFirst)
        }
    }
    enum StartupSelection: CaseIterable, Sendable { case plain, status, groupMember }

    @Test(arguments: StartupSelection.allCases)
    func startupRestoresWorkspacesFoldWhileKeepingLegacyStatusesReveal(_ selection: StartupSelection) async throws {
        try await withList { manager in
            let selectedStatus = selection == .status
            _ = NSApplication.shared
            let delegate = try #require(AppDelegate.shared)
            let selectedId = manager.tabs[0].id
            if selection != .plain {
                manager.tabs[0].setOwnStatus(try #require(AppDelegate.statusListInUse.entry(id: "parked")),
                    list: AppDelegate.statusListInUse)
            }
            if selection == .groupMember {
                let anchor = manager.tabs[1]
                let group = WorkspaceGroup(id: UUID(), name: "Plain restore group", isCollapsed: false, isPinned: false,
                    anchorWorkspaceId: anchor.id, customColor: nil, iconSymbol: nil)
                manager.tabs[0].groupId = group.id; anchor.groupId = group.id
                manager.workspaceGroups = [group]
            }
            var tabs = manager.sessionSnapshot(includeScrollback: false)
            tabs.selectedWorkspaceIndex = try #require(tabs.workspaces.firstIndex { $0.workspaceId == selectedId })
            let snapshot = SessionWindowSnapshot(windowId: UUID(), frame: nil, display: nil, tabManager: tabs,
                sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 300,
                    statusGroups: .init(areaCollapsed: true, collapsedStatusIds: ["parked"],
                        sectionOrder: .workspacesFirst, workspacesCollapsed: true)))
            let windowId = delegate.createMainWindow(initialTerminalInput: "", sessionWindowSnapshot: snapshot,
                shouldActivate: false, remapClosedPanelHistoryFromSessionSnapshot: false)
            defer {
                let previous = delegate.debugCloseMainWindowConfirmationHandler
                delegate.debugCloseMainWindowConfirmationHandler = { _ in true }
                defer { delegate.debugCloseMainWindowConfirmationHandler = previous }
                if let window = delegate.mainWindow(for: windowId) {
                    window.animationBehavior = .none; window.orderOut(nil); window.close()
                }
                delegate.forgetRecoverableMainWindowRoute(windowId: windowId)
            }
            let restoredManager = try #require(delegate.tabManagerFor(windowId: windowId))
            if selection == .groupMember {
                let member = try #require(restoredManager.selectedTab)
                let groupId = try #require(member.groupId, "The restored fixture must still be grouped")
                let group = try #require(restoredManager.workspaceGroups.first { $0.id == groupId })
                try #require(group.statusId == nil && !group.isPinned)
                try #require(member.todoState.ownStatus?.id == "parked")
            }
            let state = try #require(delegate.mainWindowContext(for: restoredManager)?.sidebarState)
            #expect(state.statusGroups?.workspacesCollapsed == true,
                "Restoring the already-selected workspace must retain the saved Workspaces fold")
            #expect(state.statusGroups?.areaCollapsed == !selectedStatus,
                "Existing Statuses restore reveal remains unchanged")
            #expect(state.statusGroups?.collapsedStatusIds == (selectedStatus ? [] : ["parked"]))
            // A subsequent real selection still uses the normal shared reveal callback.
            restoredManager.revealSelectedWorkspaceInSidebar?(restoredManager.tabs[1])
            #expect(state.statusGroups?.workspacesCollapsed == false)
        }
    }


#if DEBUG
    @Test func sectionSwapAloneInvalidatesAutosaveAndWritesNewOrder() async throws {
        try await verifyIsolatedSectionAutosave(swap: true)
    }
    @Test func workspacesFoldAloneInvalidatesAutosaveAndWritesNewFold() async throws {
        try await verifyIsolatedSectionAutosave(swap: false)
    }
    private func verifyIsolatedSectionAutosave(swap: Bool) async throws {
        try await withList { manager in
            let app = try #require(AppDelegate.shared)
            let previousPresence = MobileWorkspaceListObserver.subscriberPresenceOverrideForTesting
            let windowId = app.registerMainWindowContextForTesting(tabManager: manager)
            defer {
                app.unregisterMainWindowContextForTesting(windowId: windowId)
                app.forgetRecoverableMainWindowRoute(windowId: windowId)
                MobileWorkspaceListObserver.subscriberPresenceOverrideForTesting = previousPresence
            }
            let context = try #require(app.mainWindowContexts.values.first { $0.windowId == windowId })
            let state = context.sidebarState
            state.setStatusGroups(.init(sectionOrder: .workspacesFirst, workspacesCollapsed: false))
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SectionAutosave.\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("session.json")
            let repository = SessionSnapshotRepository<AppSessionSnapshot>(schemaVersion: SessionSnapshotSchema.currentVersion,
                bundleIdentifier: "cmux.section-autosave-tests", appSupportDirectory: directory)
            let initial = try #require(app.debugBuildSessionSnapshotForTesting(includeScrollback: false))
            #expect(repository.save(initial, fileURL: file))
            let before = try #require(app.sessionAutosaveFingerprint(includeScrollback: false,
                restorableAgentIndex: .empty, surfaceResumeBindingIndex: .empty))
            #expect(app.sessionAutosaveFingerprint(includeScrollback: false,
                restorableAgentIndex: .empty, surfaceResumeBindingIndex: .empty) == before)
            let tabFingerprint = manager.sessionAutosaveFingerprint()
            let tabs = manager.tabs.map(\.id)
            if swap {
                #expect(state.commitStatusHeaderDrop(source: .statusesArea,
                    plan: .init(indicator: .init(tabId: SidebarStatusHeaderIdentity.workspacesAreaUUID, edge: .top),
                        action: .area(aboveRow: "top", belowRow: nil, last: false)),
                    list: AppDelegate.statusListInUse, controlsEnabled: true))
            } else { state.toggleWorkspacesArea() }
            #expect(manager.tabs.map(\.id) == tabs && manager.sessionAutosaveFingerprint() == tabFingerprint)
            let after = try #require(app.sessionAutosaveFingerprint(includeScrollback: false,
                restorableAgentIndex: .empty, surfaceResumeBindingIndex: .empty))
            #expect(after != before, "A section action alone must invalidate the actual app autosave fingerprint")
            let now = Date()
            let skip = AppDelegate.shouldSkipSessionAutosaveForUnchangedFingerprint(isTerminatingApp: false,
                includeScrollback: false, previousFingerprint: before, currentFingerprint: after,
                lastPersistedAt: now.addingTimeInterval(-SessionPersistencePolicy.autosaveInterval), now: now)
            #expect(!skip, "The next 8-second tick must save without the 60-second unchanged fallback")
            if !skip {
                let current = try #require(app.debugBuildSessionSnapshotForTesting(includeScrollback: false))
                #expect(repository.save(current, fileURL: file))
            }
            let saved = try #require(repository.load(fileURL: file))
            let window = try #require(saved.windows.first { $0.windowId == windowId })
            #expect(window.sidebar.statusGroups?.sectionOrder == (swap ? .statusesFirst : .workspacesFirst))
            #expect(window.sidebar.statusGroups?.workspacesCollapsed == !swap)
            #expect(window.sidebar.statusGroups?.last == !swap)
        }
    }

    @Test func pinnedFoldAutosaveInvalidatesFingerprint() async throws { // (#cm-110.5)
        try await AppContextSerialGate.withExclusiveAppContext {
            _ = NSApplication.shared
            let app = AppDelegate()
            let windowId = UUID()
            let manager = TabManager(autoWelcomeIfNeeded: false)
            let tab = manager.addWorkspace(title: "Pinned", select: false, autoWelcomeIfNeeded: false, autoRefreshMetadata: false)
            tab.isPinned = true
            let previousPresence = MobileWorkspaceListObserver.subscriberPresenceOverrideForTesting
            app.registerMainWindowContextForTesting(windowId: windowId, tabManager: manager)
            defer {
                app.unregisterMainWindowContextForTesting(windowId: windowId)
                app.forgetRecoverableMainWindowRoute(windowId: windowId)
                MobileWorkspaceListObserver.subscriberPresenceOverrideForTesting = previousPresence
            }
            let context = try #require(app.mainWindowContexts.values.first { $0.windowId == windowId })
            let state = context.sidebarState
            state.setStatusGroups(.init(sectionOrder: .workspacesFirst, workspacesCollapsed: false, pinnedCollapsed: false))
            let before = try #require(app.sessionAutosaveFingerprint(includeScrollback: false,
                restorableAgentIndex: .empty, surfaceResumeBindingIndex: .empty))
            state.togglePinnedArea()
            let after = try #require(app.sessionAutosaveFingerprint(includeScrollback: false,
                restorableAgentIndex: .empty, surfaceResumeBindingIndex: .empty))
            #expect(after != before, "A pinned fold action alone must invalidate the actual app autosave fingerprint")
        }
    }

    @Test func restoreWithPinnedWorkspaceSelected_retainsPinnedFold() async throws { // (#cm-110.5)
        try await withList { manager in
            let tab = manager.tabs[0]
            tab.isPinned = true
            let state = SidebarState(statusGroups: .init(sectionOrder: .workspacesFirst, workspacesCollapsed: false, pinnedCollapsed: true))
            #expect(state.statusGroups?.pinnedCollapsed == true)
            state.prepareStatusGroupsForSelection(selectedWorkspace: tab, revealWorkspaces: false)
            #expect(state.statusGroups?.pinnedCollapsed == true, "Restore with a pinned workspace selected must not unfold pinned rows")
        }
    }
#endif
}
