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

/// Exercises inference through the mounted AppKit sidebar, including the parent membership projection.
@MainActor
@Suite(.serialized)
struct SidebarStatusGroupRefreshTests {
    @Test(arguments: [SidebarPullRequestStatus.merged, .open])
    func anAutomaticPullRequestStatusMovesAnUnselectedWorkspaceIntoItsStatusGroup(
        _ status: SidebarPullRequestStatus
    ) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            _ = NSApplication.shared
            let previousPortalMode = WindowTerminalPortal.usesCoalescedAnchorFailsafe
            defer { WindowTerminalPortal.usesCoalescedAnchorFailsafe = previousPortalMode }
            let suite = "SidebarStatusGroupRefreshTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: directory)
            }
            let file = directory.appendingPathComponent("cmux.json")
            try ##"{"workspaceStatuses":[{"id":"done","name":"Done","color":"#112233"},{"id":"review","name":"Review","color":"#445566"}]}"##
                .write(to: file, atomically: true, encoding: .utf8)
            let store = WorkspaceStatusListStore(
                fileURL: file, defaults: defaults,
                resolveColor: { $0 }, paletteFingerprint: { "fixed" }, clock: ContinuousClock()
            )
            store.load()
            let oldDelegate = AppDelegate.shared
            let delegate = AppDelegate()
            delegate.workspaceStatusListStore = store
            AppDelegate.shared = delegate
            defer { AppDelegate.shared = oldDelegate }
            let controlsKey = BetaFeaturesCatalogSection().workspaceTodoControls.userDefaultsKey
            let previousControls = UserDefaults.standard.object(forKey: controlsKey)
            UserDefaults.standard.set(true, forKey: controlsKey)
            defer { UserDefaults.standard.set(previousControls, forKey: controlsKey) }
            let flags = CmuxFeatureFlags(defaults: defaults, remoteFlagValueProvider: { _ in nil })
            flags.setOverride(true, for: CmuxFeatureFlags.appKitSidebarListFlag)
            defaults.set(CmuxExtensionSidebarSelection.defaultProviderId, forKey: CmuxExtensionSidebarSelection.defaultsKey)
            let tabs = TabManager(autoWelcomeIfNeeded: false)
            let workspace = tabs.addWorkspace(
                title: "Auto PR", select: false, autoWelcomeIfNeeded: false, autoRefreshMetadata: false
            )
            workspace.customColor = "#2C81D9"
            workspace.clearTaskStatusOverride()
            #expect(!workspace.todoState.statusHidden)
            let panelId = try #require(workspace.focusedPanelId)
            let windowId = UUID()
            let previousMobilePresence = MobileWorkspaceListObserver.subscriberPresenceOverrideForTesting
            delegate.registerMainWindowContextForTesting(windowId: windowId, tabManager: tabs)
            defer {
                delegate.unregisterMainWindowContextForTesting(windowId: windowId)
                delegate.forgetRecoverableMainWindowRoute(windowId: windowId)
                MobileWorkspaceListObserver.subscriberPresenceOverrideForTesting = previousMobilePresence
            }
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
            .environmentObject(SidebarState())
            .environmentObject(SidebarSelectionState())
            .defaultAppStorage(defaults)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 280, height: 640),
                styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: root)
            defer { window.contentView = nil; window.close() }
            await Self.waitFor(window: window) { SidebarDebugRowSnapshots.items(windowId: windowId) != nil }
            let initial = try #require(SidebarDebugRowSnapshots.items(windowId: windowId))
            #expect(initial.contains { if case .colorSectionHeader(let section) = $0 { return section.memberWorkspaceIds.contains(workspace.id) }; return false })
            #expect(workspace.statusResolution(list: store.list) == .detected(.todo))
            #expect(!workspace.todoState.statusHidden)
            // A different mounted sidebar must not evict this still-live fixture's built snapshot.
            SidebarDebugRowSnapshots.record(windowId: UUID(), items: [.statusesHeader])
            let retainedSnapshot = SidebarDebugRowSnapshots.items(windowId: windowId)
            #expect(retainedSnapshot?.map(\.id) == initial.map(\.id), "A live mounted sidebar retains its snapshot after another caller records")
            workspace.updatePanelPullRequest(
                panelId: panelId, number: 99013, label: "PR", url: try #require(URL(string: "https://example.invalid/cm110/test")),
                status: status
            )
            let expectedId = status == .open ? "review" : "done"
            #expect(workspace.statusResolution(list: store.list) == .detected(status == .open ? .review : .done))
            await Self.waitFor(window: window) {
                Self.header(containing: workspace.id, windowId: windowId) == expectedId
            }
            #expect(Self.header(containing: workspace.id, windowId: windowId) == expectedId)
            #expect(workspace.customColor == "#2C81D9")
            #expect(workspace.todoState.statusOverride == nil)
        }
    }

    // MARK: The debug helper reads the rows the sidebar built

    @Test func theDebugRowsAreReadOffTheBuiltItems() throws {
        typealias Sidebar = VerticalTabsSidebar
        let palette: [WorkspaceColorPaletteEntry] = [
            WorkspaceColorPaletteEntry(name: "Blue", hex: "#3B82F6"),
            WorkspaceColorPaletteEntry(name: "Yellow", hex: "#EAB308"),
            WorkspaceColorPaletteEntry(name: "Teal", hex: "#14B8A6")
        ]
        func snapshot(_ id: UUID, color: String?, pinned: Bool = false) -> SidebarWorkspaceColorSectionWorkspaceSnapshot {
            SidebarWorkspaceColorSectionWorkspaceSnapshot(id: id, groupId: nil, isPinned: pinned, customColor: color)
        }
        let anchor = UUID()
        let member = UUID()
        let groupId = UUID()
        let colorA = UUID()
        let colorB = UUID()
        let sNext = UUID()
        let anchor2 = UUID()
        let groupId2 = UUID()
        let colorProjection = Sidebar.colorSectionProjection(
            workspaces: [snapshot(colorA, color: "#14B8A6"), snapshot(colorB, color: "#14B8A6")],
            collapsedHexes: [],
            statusGroupProjection: nil,
            colorHexes: [:],
            paletteEntries: palette
        )
        let section = try #require(colorProjection.sections.first)
        let items: [SidebarWorkspaceRenderItem] = [
            .groupHeader(groupId: groupId, anchorWorkspaceId: anchor),
            .workspace(workspaceId: anchor),
            .workspace(workspaceId: member),
            .colorSectionHeader(section: section),
            .workspace(workspaceId: colorA),
            .workspace(workspaceId: colorB),
            .statusesHeader,
            .statusGroupHeader(statusId: "next"),
            .workspace(workspaceId: sNext),
            .statusGroupHeader(statusId: "parked"),
            .groupHeader(groupId: groupId2, anchorWorkspaceId: anchor2),
            .workspace(workspaceId: anchor2),
        ]
        let rows = SidebarDebugRow.rows(
            from: items,
            workspaceTitle: { "ws-\($0.uuidString.prefix(4))" },
            groupName: { _ in "Backend" },
            groupIsFolded: { _ in false },
            groupIdOfWorkspace: { [anchor: groupId, member: groupId, anchor2: groupId2][$0] },
            statusName: { $0.capitalized }
        )
        #expect(rows.map(\.kind) == [
            "groupHeader", "workspace", "workspace", "colorSectionHeader", "workspace", "workspace",
            "statusesHeader", "statusGroupHeader", "workspace", "statusGroupHeader", "groupHeader", "workspace",
        ])
        #expect(rows[1].header == groupId.uuidString)
        #expect(rows[2].header == groupId.uuidString)
        #expect(rows[4].header == "#14B8A6")
        #expect(rows[5].header == "#14B8A6")
        #expect(rows[7].header == "statusesArea")
        #expect(rows[7].title == "Next")
        #expect(rows[8].header == "next")
        #expect(rows[9].id == "parked")
        // A group after the area (Piece 3 can put the area anywhere): its rows are the group's, not a status group's.
        #expect(rows[11].header == groupId2.uuidString)
        // A closed window's rows are forgotten.
        let windowA = UUID()
        let windowB = UUID()
        SidebarDebugRowSnapshots.store(windowId: windowA, items: [.statusesHeader])
        SidebarDebugRowSnapshots.store(windowId: windowB, items: [.statusesHeader])
        SidebarDebugRowSnapshots.prune(keepingWindowIds: [windowA])
        #expect(SidebarDebugRowSnapshots.items(windowId: windowA) != nil)
        #expect(SidebarDebugRowSnapshots.items(windowId: windowB) == nil)
        SidebarDebugRowSnapshots.prune(keepingWindowIds: [])
        // Nothing built, nothing listed: the helper does not compute a model of its own.
        #expect(SidebarDebugRow.rows(from: [], workspaceTitle: { _ in "" }, groupName: { _ in "" }, groupIsFolded: { _ in false }, groupIdOfWorkspace: { _ in nil }, statusName: { $0 }).isEmpty)
    }

    private static func header(containing workspaceId: UUID, windowId: UUID) -> String? {
        var current: String?
        for item in SidebarDebugRowSnapshots.items(windowId: windowId) ?? [] {
            switch item {
            case .statusGroupHeader(let statusId): current = statusId
            case .workspace(let id): if id == workspaceId { return current }
            default: current = nil
            }
        }
        return nil
    }

    private static func waitFor(window: NSWindow, condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            SidebarLazyLayoutScaleTests.turnMainRunLoopOnce(layingOut: window)
            await Task.yield()
        }
    }
}
