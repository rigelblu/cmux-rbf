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
struct SidebarWorkspaceSectionHostingTests {
    enum Activation: Sendable { case chevron, ax }

    /// Native row click not synthesized: NSTableView tracking; human Scenario64 owns that reading.
    @Test(arguments: [Activation.chevron, .ax])
    func appKitClickChevronAndAXPressUseSharedSectionToggle(_ activation: Activation) async throws {
        try await mount(appKit: true, activation: activation)
    }
    /// Checks hosting and the supplied callback. The production parent tap/AX callback remains human Scenario64.
    @Test func swiftUIHeaderFactoryHostsSnapshotsAndForwardsProvidedToggle() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let state = SidebarState(statusGroups: .init(areaCollapsed: true, collapsedStatusIds: ["parked"],
                sectionOrder: .statusesFirst))
            func header() throws -> SidebarSectionSwiftUIHeader {
                VerticalTabsSidebar.sidebarWorkspacesAreaHeaderRow(folds: try #require(state.statusGroups),
                    memberIds: [], unreadSnapshot: .init(summaryByWorkspaceId: [:]),
                    onToggle: { state.toggleWorkspacesArea() })
            }
            let realHeader = try header()
            #expect(realHeader.identifier == "sidebarWorkspacesArea" && !realHeader.isCollapsed)
            let host = NSHostingView(rootView: realHeader.frame(width: 280))
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 280, height: 80),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            SidebarLazyLayoutScaleTests.turnMainRunLoopOnce(layingOut: window)
            await Task.yield()
            #expect(host.fittingSize.height > 0)
            realHeader.onToggle()
            #expect(state.statusGroups?.workspacesCollapsed == true)
            #expect(state.statusGroups?.areaCollapsed == true && state.statusGroups?.collapsedStatusIds == ["parked"])
            let folded = try header()
            #expect(folded.isCollapsed)
            host.rootView = folded.frame(width: 280)
            SidebarLazyLayoutScaleTests.turnMainRunLoopOnce(layingOut: window)
            folded.onToggle()
            #expect(state.statusGroups?.workspacesCollapsed == false)
        }
    }
    private func mount(appKit: Bool, activation: Activation) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            _ = NSApplication.shared
            let suite = "SidebarWorkspaceSectionHostingTests.\(UUID().uuidString)"
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
            let windowId = UUID()
            let previousPresence = MobileWorkspaceListObserver.subscriberPresenceOverrideForTesting
            delegate.registerMainWindowContextForTesting(windowId: windowId, tabManager: tabs)
            defer {
                delegate.unregisterMainWindowContextForTesting(windowId: windowId)
                delegate.forgetRecoverableMainWindowRoute(windowId: windowId)
                MobileWorkspaceListObserver.subscriberPresenceOverrideForTesting = previousPresence
            }
            let state = SidebarState(statusGroups: .init(sectionOrder: .workspacesFirst))
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
            let deadline = Date().addingTimeInterval(5)
            var header: SidebarGroupHeaderTableCellView?
            repeat {
                SidebarLazyLayoutScaleTests.turnMainRunLoopOnce(layingOut: window)
                await Task.yield()
                header = Self.findCell(window.contentView!)
            } while header == nil && Date() < deadline
            let actual = try #require(header, "The production renderer must expose its actual Workspaces header")
            #expect(state.statusGroups?.workspacesCollapsed == false)
            if activation == .ax {
                #expect(actual.accessibilityPerformPress())
            } else if activation == .chevron {
                let cell = try #require(Self.findCell(window.contentView!))
                let chevron = try #require(cell.subviews.compactMap { $0 as? SidebarHeaderGlyphButton }.first)
                chevron.performClick(nil)
            }
            let foldedDeadline = Date().addingTimeInterval(3)
            repeat {
                SidebarLazyLayoutScaleTests.turnMainRunLoopOnce(layingOut: window)
                await Task.yield()
            } while state.statusGroups?.workspacesCollapsed != true && Date() < foldedDeadline
            #expect(state.statusGroups?.workspacesCollapsed == true, "Visible header event must reach the shared state action")
            let rows = VerticalTabsSidebar.statusRenderItemsForSnapshot(tabManager: tabs, state: state).items.map(\.id)
            #expect(rows.contains(.workspacesArea()) && rows.contains(.statusesArea()))
            #expect(!tabs.tabs.contains { rows.contains(.workspace($0.id)) })
            #expect(registry.setCollapsed(false, header: .workspaces, windowId: windowId))
            #expect(state.statusGroups?.workspacesCollapsed == false)
        }
    }
    private static func findCell(_ view: NSView) -> SidebarGroupHeaderTableCellView? {
        if let cell = view as? SidebarGroupHeaderTableCellView, cell.accessibilityIdentifier() == "sidebarWorkspacesArea" { return cell }
        return view.subviews.lazy.compactMap { findCell($0) }.first
    }
}
#endif
