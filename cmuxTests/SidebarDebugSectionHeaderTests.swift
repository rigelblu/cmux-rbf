import AppKit
import CmuxNotifications
import CmuxSettings
import CmuxSidebar
import CmuxUpdater
import CmuxWorkspaces
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
@MainActor
@Suite(.serialized)
struct SidebarDebugSectionHeaderTests {
    @Test func namedHeadersHaveDistinctStableDebugIdentitiesAndKinds() {
        let statuses = SidebarDebugActions.Header.statuses
        let workspaces = SidebarDebugActions.Header.workspaces
        let pinned = SidebarDebugActions.Header.pinned
        #expect(statuses.id == SidebarStatusHeaderIdentity.statusesAreaUUID)
        #expect(workspaces.id == SidebarStatusHeaderIdentity.workspacesAreaUUID)
        #expect(pinned.id == SidebarStatusHeaderIdentity.pinnedAreaUUID)
        #expect(pinned.id != statuses.id)
        #expect(pinned.id != workspaces.id)
        #expect(workspaces.id != statuses.id)
        #expect(workspaces.id == SidebarDebugActions.Header(rawValue: "workspaces")?.id)
        #expect(pinned.id == SidebarDebugActions.Header(rawValue: "pinned")?.id)
        #expect(workspaces.rowKind == "workspacesHeader")
        #expect(statuses.rowKind == "statusesHeader")
        #expect(pinned.rowKind == "pinnedHeader")
    }

    @Test func aMissingHeaderRefusesWithoutManufacturingRows() {
        let registry = SidebarDebugActions()
        let windowId = UUID()
        #expect(!registry.setCollapsed(true, header: .pinned, windowId: windowId))
        #expect(!registry.setCollapsed(true, header: .workspaces, windowId: windowId))
        #expect(registry.rows([], windowId: windowId).isEmpty)
        #expect(SidebarDebugActions.identity("pinned", items: [.statusesHeader]) == nil)
        #expect(SidebarDebugActions.identity("workspaces", items: [.statusesHeader]) == nil)
        #expect(SidebarDebugActions.identity("statuses", items: [.statusesHeader]) == SidebarStatusHeaderIdentity.statusesAreaUUID)
        #expect(SidebarDebugActions.identity("statuses", items: []) == nil)
    }

    @Test func foldAndUnfoldAreIdempotentAndWindowLocal() {
        let registry = SidebarDebugActions()
        let windowId = UUID(), otherWindowId = UUID()
        let owner = NSView()
        let state = SidebarState()
        var toggles = 0
        registry.update(windowId: windowId, owner: owner, actions: [
            .init(header: .statuses, isCollapsed: { state.statusGroups?.areaCollapsed ?? false }, toggle: {
                toggles += 1
                state.toggleStatusesArea()
            })
        ])
        defer { registry.remove(windowId: windowId, owner: owner) }
        #expect(registry.setCollapsed(true, header: .statuses, windowId: windowId))
        #expect(registry.setCollapsed(true, header: .statuses, windowId: windowId))
        #expect(toggles == 1)
        #expect(!registry.setCollapsed(false, header: .statuses, windowId: otherWindowId))
        #expect(state.statusGroups?.areaCollapsed == true)
        #expect(registry.setCollapsed(false, header: .statuses, windowId: windowId))
        #expect(toggles == 2)
        #expect(state.statusGroups?.areaCollapsed == false)
    }

    @Test func aRetiredHostCannotRemoveItsReplacement() {
        let registry = SidebarDebugActions()
        let windowId = UUID(), old = NSView(), current = NSView()
        var folded = false
        let action = SidebarDebugActions.Action(header: .statuses,
            isCollapsed: { folded }, toggle: { folded.toggle() })
        registry.update(windowId: windowId, owner: old, actions: [action])
        registry.update(windowId: windowId, owner: current, actions: [action])
        defer { registry.remove(windowId: windowId, owner: current) }
        registry.remove(windowId: windowId, owner: old)
        #expect(registry.setCollapsed(true, header: .statuses, windowId: windowId))
        registry.remove(windowId: windowId, owner: current)
        #expect(!registry.setCollapsed(false, header: .statuses, windowId: windowId))
    }

    @Test func rowReadingsUseTheLiveActionStateAndNeverInventAHeader() {
        let registry = SidebarDebugActions()
        let windowId = UUID(), owner = NSView()
        var folded = false
        registry.update(windowId: windowId, owner: owner, actions: [
            .init(header: .workspaces, isCollapsed: { folded }, toggle: { folded.toggle() })
        ])
        defer { registry.remove(windowId: windowId, owner: owner) }
        let row = SidebarDebugRow(kind: "old-kind", id: SidebarDebugActions.Header.workspaces.id.uuidString,
            title: "Workspaces", header: nil, folded: false)
        #expect(registry.rows([], windowId: windowId).isEmpty)
        #expect(registry.setCollapsed(true, header: .workspaces, windowId: windowId))
        let actual = registry.rows([row], windowId: windowId)
        #expect(actual.count == 1)
        #expect(actual.first?.kind == "workspacesHeader")
        #expect(actual.first?.folded == true)
        #expect(actual.first?.title == row.title)
    }

    @Test(arguments: [false, true])
    func theMountedProductionSidebarRegistersItsSharedFoldAction(_ appKit: Bool) async throws {
        try await mount(appKit)
    }

    @Test(arguments: [false, true])
    func bothMountedRenderersRouteSectionDragPlanCommitAndPaint(_ appKit: Bool) async throws {
        try await mount(appKit, verifyDrops: true)
    }

    @Test(arguments: [false, true])
    func workspaceOnWorkspacesHeaderRefusesWithoutIndicator(_ appKit: Bool) async throws {
        try await mount(appKit, verifyRefusal: true)
    }

    @Test(arguments: [false, true])
    func sectionHeaderCommitMigratesPendingRecordBeforeSaving(_ appKit: Bool) async throws {
        try await mount(appKit, verifyPending: true)
    }

    private func mount(_ appKit: Bool, verifyDrops: Bool = false, verifyRefusal: Bool = false, verifyPending: Bool = false) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            _ = NSApplication.shared
            let suite = "SidebarDebugSectionHeaderTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: directory)
            }
            let file = directory.appendingPathComponent("cmux.json")
            try ##"{"workspaceStatuses":[{"id":"parked","name":"Parked","extends":"todo","color":"#112233"}]}"##
                .write(to: file, atomically: true, encoding: .utf8)
            let store = WorkspaceStatusListStore(fileURL: file, defaults: defaults,
                resolveColor: { $0 }, paletteFingerprint: { "fixed" }, clock: ContinuousClock())
            store.load()
            #expect(store.list.source != .cmux)
            let oldDelegate = AppDelegate.shared
            let delegate = AppDelegate()
            let registry = delegate.sidebarDebugActions
            delegate.workspaceStatusListStore = store
            AppDelegate.shared = delegate
            defer { AppDelegate.shared = oldDelegate }
            let key = BetaFeaturesCatalogSection().workspaceTodoControls.userDefaultsKey
            let previous = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.set(true, forKey: key)
            defer { UserDefaults.standard.set(previous, forKey: key) }
            let flags = CmuxFeatureFlags(defaults: defaults, remoteFlagValueProvider: { _ in nil })
            flags.setOverride(appKit, for: CmuxFeatureFlags.appKitSidebarListFlag)
            #expect(flags.isAppKitSidebarListEnabled == appKit)
            defaults.set(CmuxExtensionSidebarSelection.defaultProviderId, forKey: CmuxExtensionSidebarSelection.defaultsKey)
            let tabs = TabManager(autoWelcomeIfNeeded: false)
            _ = tabs.addWorkspace(title: "Loose", select: false, autoWelcomeIfNeeded: false, autoRefreshMetadata: false)
            var refusalGroups: [UUID] = []
            if verifyRefusal {
                let pinned = tabs.addWorkspace(title: "Pinned", select: false, autoWelcomeIfNeeded: false, autoRefreshMetadata: false)
                pinned.isPinned = true
                let rootMember = tabs.addWorkspace(title: "Root member", select: false, autoWelcomeIfNeeded: false, autoRefreshMetadata: false)
                let root = try #require(tabs.createWorkspaceGroup(name: "Root", childWorkspaceIds: [rootMember.id]))
                let nestedMember = tabs.addWorkspace(title: "Nested member", select: false, autoWelcomeIfNeeded: false, autoRefreshMetadata: false)
                let nested = try #require(tabs.createWorkspaceGroup(name: "Nested", childWorkspaceIds: [nestedMember.id]))
                let nestedIndex = try #require(tabs.workspaceGroups.firstIndex { $0.id == nested })
                tabs.workspaceGroups[nestedIndex].parentGroupId = root
                refusalGroups = [root, nested]
            }
            let windowId = UUID()
            let previousPresence = MobileWorkspaceListObserver.subscriberPresenceOverrideForTesting
            delegate.registerMainWindowContextForTesting(windowId: windowId, tabManager: tabs)
            defer {
                delegate.unregisterMainWindowContextForTesting(windowId: windowId)
                delegate.forgetRecoverableMainWindowRoute(windowId: windowId)
                MobileWorkspaceListObserver.subscriberPresenceOverrideForTesting = previousPresence
            }
            let state = SidebarState()
            #expect(WorkspaceTodoFeature.isEnabled)
            #expect(VerticalTabsSidebar.currentStatusGroupProjection(tabs: tabs.tabs, groups: tabs.workspaceGroups) != nil)
            let root = VerticalTabsSidebar(
                updateViewModel: UpdateStateModel(), fileExplorerState: FileExplorerState(), featureFlags: flags,
                sidebarUnread: SidebarUnreadModel(), titlebarControlsLayoutModel: TitlebarControlsLayoutModel(),
                windowId: windowId, onSendFeedback: {}, onToggleSidebar: {}, onNewTab: {},
                observedWindowReference: WeakWindowReference(), chromeBackgroundColor: .black,
                selection: .constant(.tabs), selectedTabIds: .constant([]), lastSidebarSelectionIndex: .constant(nil),
                sidebarRenderWorkerClient: .constant(nil)
            )
            .frame(width: 280, height: 640)
            .environmentObject(tabs)
            .environmentObject(CmuxConfigStore())
            .environmentObject(state)
            .environmentObject(SidebarSelectionState())
            .defaultAppStorage(defaults)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 640),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: root)
            defer { window.contentView = nil; window.close() }
            let deadline = Date().addingTimeInterval(3)
            var accepted = false
            repeat {
                SidebarLazyLayoutScaleTests.turnMainRunLoopOnce(layingOut: window)
                await Task.yield()
                accepted = registry.setCollapsed(true, header: .statuses, windowId: windowId)
            } while !accepted && Date() < deadline
            #expect(accepted, "The production sidebar parent must mount the DEBUG section action host")
            #expect(state.statusGroups?.areaCollapsed == true)
            #expect(registry.setCollapsed(false, header: .statuses, windowId: windowId))
            #expect(state.statusGroups?.areaCollapsed == false)
            #expect(registry.setCollapsed(true, header: .workspaces, windowId: windowId))
            #expect(state.statusGroups?.workspacesCollapsed == true)
            #expect(registry.setCollapsed(false, header: .workspaces, windowId: windowId))
            #expect(state.statusGroups?.workspacesCollapsed == false)
            if verifyDrops || verifyRefusal || verifyPending {
                @MainActor func settle() async {
                    for _ in 0..<12 {
                        SidebarLazyLayoutScaleTests.turnMainRunLoopOnce(layingOut: window)
                        await Task.yield()
                    }
                }
                @MainActor func drop(_ source: String, _ target: String, _ zone: String) throws -> SidebarDebugDropResult {
                    let request = try #require(SidebarDebugDropRequest(params: ["drag": source,
                        "target": target, "zone": zone, "side": "right"]))
                    let result: SidebarDebugDropResult?
                    if appKit {
                        let content = try #require(window.contentView)
                        let table = try #require(Self.findTable(content))
                        result = try #require(table.workspaceController).debugPerformSidebarDrop(request)
                    } else {
                        result = registry.perform(windowId: windowId, request: request)
                    }
                    return try #require(result,
                        "Production parent must forward its real measured targets and plan/commit callbacks")
                }
                await settle()
                if verifyDrops {
                    let originalTabs = tabs.tabs.map(\.id), originalGroups = tabs.workspaceGroups
                    let first = try drop("statuses", "workspaces", "upper")
                    #expect(first.performed && first.plan != nil)
                    #expect(first.plan?.indicator == .init(tabId: SidebarStatusHeaderIdentity.workspacesAreaUUID, edge: .top))
                    #expect(first.paint?.level == 0 && first.paint?.rowIds.contains(SidebarStatusHeaderIdentity.workspacesAreaUUID) == true)
                    #expect(state.statusGroups?.sectionOrder == .statusesFirst)
                    await settle()
                    let second = try drop("workspaces", "statuses", "upper")
                    #expect(second.performed && second.plan != nil)
                    #expect(second.plan?.indicator == .init(tabId: SidebarStatusHeaderIdentity.statusesAreaUUID, edge: .top))
                    #expect(second.paint?.level == 0)
                    #expect(state.statusGroups?.sectionOrder == .workspacesFirst)
                    #expect(tabs.tabs.map(\.id) == originalTabs && tabs.workspaceGroups == originalGroups)
                    await settle()
                    let refused = try drop("workspaces", "workspaces", "upper")
                    #expect(!refused.performed && refused.plan == nil)
                }
                if verifyPending {
                    state.setStatusGroups(.init(last: false, aboveRow: "top"))
                    await settle()
                    let result = try drop("workspaces", "statuses", "upper")
                    #expect(result.performed && result.plan != nil)
                    #expect(state.statusGroups?.sectionOrder == .workspacesFirst)
                    #expect(state.statusGroups?.last == true && state.statusGroups?.aboveRow == "top")
                    return
                }
                if verifyRefusal {
                    let originalTabs = tabs.tabs.map(\.id), originalGroups = tabs.workspaceGroups
                    let originalState = state.statusGroups
                    for id in refusalGroups {
                        for target in ["workspaces", "statuses", "pinned"] {
                            for zone in ["upper", "lower"] {
                                let result = try drop("group:" + id.uuidString, target, zone)
                                #expect(!result.performed && result.plan == nil && result.paint == nil,
                                    "Both root and nested group headers must be refused on all section headers")
                                #expect(tabs.tabs.map(\.id) == originalTabs && tabs.workspaceGroups == originalGroups)
                                #expect(state.statusGroups == originalState)
                            }
                        }
                    }
                    let workspace = try #require(tabs.tabs.first(where: { !$0.isPinned }))
                    for target in ["workspaces", "pinned"] {
                        for zone in ["upper", "lower"] {
                            let workspaceRefused = try drop("workspace:" + workspace.id.uuidString, target, zone)
                            #expect(!workspaceRefused.performed && workspaceRefused.plan == nil)
                            #expect(tabs.tabs.map(\.id) == originalTabs && tabs.workspaceGroups == originalGroups)
                        }
                    }
                }
            }
        }
    }
    private static func findTable(_ view: NSView) -> SidebarWorkspaceTableViewImpl? {
        if let table = view as? SidebarWorkspaceTableViewImpl { return table }
        return view.subviews.lazy.compactMap { findTable($0) }.first
    }
}
#endif
