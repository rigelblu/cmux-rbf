import Foundation
import Testing
@testable import CmuxNotifications

// MARK: - Fakes

/// Scriptable notification store: an ordered snapshot list plus the unread-id
/// set and the two unread predicates, with a log of every `markRead`.
@MainActor
private final class FakeStore: NotificationNavigationStoreReading {
    var orderedNotifications: [NotificationNavSnapshot] = []
    var workspaceUnreadIndicatorIds: Set<UUID> = []
    var windowDockUnreadTargets: [WindowDockUnreadTarget] = []
    var manualUnreadTabs: Set<UUID> = []
    var restoredUnreadTabs: Set<UUID> = []
    private(set) var markedReadIds: [UUID] = []
    private(set) var clearedWindowDockTargets: [WindowDockUnreadTarget] = []

    func hasManualUnread(forTabId tabId: UUID) -> Bool { manualUnreadTabs.contains(tabId) }
    func hasRestoredUnreadIndicator(forTabId tabId: UUID) -> Bool { restoredUnreadTabs.contains(tabId) }
    func markRead(id: UUID) { markedReadIds.append(id) }
    func clearWindowDockUnread(_ target: WindowDockUnreadTarget) {
        clearedWindowDockTargets.append(target)
    }
}

/// Scriptable window resolver: an ordered target list for the unread jump.
@MainActor
private final class FakeWindows: MainWindowContextResolving {
    var orderedTargetsForUnreadJump: [MainWindowTarget] = []
    var activeWorkspaceIdsForUnreadJump: [UUID] = []
}

/// Scriptable unread targeting: a per-workspace preferred panel and flash
/// predicate, with a log of flash + clear calls.
@MainActor
private final class FakeUnreadTargeting: UnreadWorkspaceTargeting {
    var preferredPanelByWorkspace: [UUID: UUID] = [:]
    var shouldFlashByWorkspacePanel: Set<PanelKey> = []
    private(set) var flashedPanels: [PanelKey] = []
    private(set) var clearedJumps: [(UUID, UUID?)] = []
    /// Panes the fake reports as "the pane he's on" (focused pane of the key window, app frontmost).
    var frontmostFocusedPanes: [FocusedNotificationTarget] = []

    struct PanelKey: Hashable { let workspaceId: UUID; let panelId: UUID }

    func preferredUnreadPanelIdForJump(workspaceId: UUID) -> UUID? {
        preferredPanelByWorkspace[workspaceId]
    }

    func shouldTriggerManualUnreadJumpFlash(workspaceId: UUID, panelId: UUID) -> Bool {
        shouldFlashByWorkspacePanel.contains(PanelKey(workspaceId: workspaceId, panelId: panelId))
    }

    func triggerUnreadIndicatorDismissFlash(workspaceId: UUID, panelId: UUID) {
        flashedPanels.append(PanelKey(workspaceId: workspaceId, panelId: panelId))
    }

    func clearUnreadAfterJump(workspaceId: UUID, panelId: UUID?) {
        clearedJumps.append((workspaceId, panelId))
    }

    func frontmostFocusedPane() -> UnreadQueueTarget? {
        frontmostFocusedPanes.first
    }

    /// Surfaces whose owning panel differs from the surface id (a remote tmux pane in a container panel).
    var owningPanels: [UUID: UUID] = [:]

    func owningPanelId(workspaceId: UUID, surfaceId: UUID) -> UUID {
        owningPanels[surfaceId] ?? surfaceId
    }
}

/// Recording click router: scriptable success plus a log of performed actions.
@MainActor
private final class FakeClickRouting: NotificationClickRouting {
    var succeeds = true
    private(set) var performed: [NotificationNavClickAction] = []

    func perform(_ action: NotificationNavClickAction) -> Bool {
        performed.append(action)
        return succeeds
    }
}

@MainActor
private func makeCoordinator(
    store: FakeStore = FakeStore(),
    windows: FakeWindows = FakeWindows(),
    unreadTargeting: FakeUnreadTargeting = FakeUnreadTargeting(),
    openRouting: FakeOpenRouting = FakeOpenRouting(),
    clickRouting: FakeClickRouting = FakeClickRouting(),
    focusedResolving: FakeFocusedResolving = FakeFocusedResolving()
) -> NotificationNavigationCoordinator {
    NotificationNavigationCoordinator(
        store: store,
        windows: windows,
        unreadTargeting: unreadTargeting,
        openRouting: openRouting,
        clickRouting: clickRouting,
        focusedResolving: focusedResolving
    )
}

private func snapshot(
    tabId: UUID,
    surfaceId: UUID? = nil,
    panelId: UUID? = nil,
    retargetsToLiveSurfaceOwner: Bool = true,
    isRead: Bool = false,
    clickAction: NotificationNavClickAction? = nil,
    scrollRow: Int? = nil,
    scrollTotalRows: Int? = nil,
    scrollRowSpaceRevision: UInt64? = nil,
    queuedAt: Int = 0,
    id: UUID = UUID()
) -> NotificationNavSnapshot {
    NotificationNavSnapshot(
        id: id,
        tabId: tabId,
        surfaceId: surfaceId,
        panelId: panelId,
        retargetsToLiveSurfaceOwner: retargetsToLiveSurfaceOwner,
        isRead: isRead,
        queuedAt: Date(timeIntervalSince1970: Double(queuedAt)),
        clickAction: clickAction,
        scrollRow: scrollRow,
        scrollTotalRows: scrollTotalRows,
        scrollRowSpaceRevision: scrollRowSpaceRevision
    )
}

// MARK: - Jump selection

@Suite(.serialized)
@MainActor
struct NotificationNavigationCoordinatorTests {
    @Test("jumpToOldestUnread opens the only openable unread, skipping a read one")
    func picksTheOpenableUnread() {
        let store = FakeStore()
        let openRouting = FakeOpenRouting()
        let tabA = UUID(), tabB = UUID()
        // First (latest) is read, second is the latest *openable* unread.
        let read = snapshot(tabId: tabA, isRead: true)
        let openable = snapshot(tabId: tabB)
        store.orderedNotifications = [read, openable]
        let coordinator = makeCoordinator(store: store, openRouting: openRouting)

        let openedId = coordinator.jumpToOldestUnread()

        #expect(openedId == openable.id)
        // Only the openable one was routed (the read one is skipped); it routes
        // through the full app-side `openNotification` (openRouted) with the
        // notification id, which marks read on success app-side.
        #expect(openRouting.log == ["routed(tab=\(short(tabB)),surf=nil,notif=\(short(openable.id)),row=nil,total=nil)"])
    }

    @Test("jumpToOldestUnread skips notifications with a click action in the scan")
    func skipsClickActionInScan() {
        let store = FakeStore()
        let openRouting = FakeOpenRouting()
        let tab = UUID()
        // A click-action notification is not openable-for-jump; with no other
        // unread and no unread-workspace fallback, the jump opens nothing.
        store.orderedNotifications = [snapshot(tabId: tab, clickAction: .revealInFinder(path: "/tmp/x"))]
        let coordinator = makeCoordinator(store: store, openRouting: openRouting)

        let openedId = coordinator.jumpToOldestUnread()

        #expect(openedId == nil)
        #expect(openRouting.log.isEmpty)
    }

    // (cm-128.11) Changed on purpose: the exclusion is the pane, not one notification id, so two
    // notifications on the excluded pane are both skipped and the walk opens another pane.
    @Test("jumpToOldestUnread skips every notification on the excluded pane")
    func honorsExcludedPane() {
        let store = FakeStore()
        let tab = UUID(), surface = UUID()
        let excluded = snapshot(tabId: tab, surfaceId: surface, queuedAt: 1)
        let alsoExcluded = snapshot(tabId: tab, surfaceId: surface, queuedAt: 2)
        let next = snapshot(tabId: UUID(), surfaceId: UUID(), queuedAt: 3)
        store.orderedNotifications = [next, alsoExcluded, excluded]
        let coordinator = makeCoordinator(store: store)

        let openedId = coordinator.jumpToOldestUnread(excludingPane: .workspace(tabId: tab, surfaceId: surface))

        #expect(openedId == next.id)
    }

    // MARK: - Window Dock unread fallback

    @Test("window Dock unread opens before workspace fallback and clears only its surface")
    func windowDockUnreadOpensBeforeWorkspaceFallback() {
        let store = FakeStore()
        let windows = FakeWindows()
        let unread = FakeUnreadTargeting()
        let openRouting = FakeOpenRouting()
        let target = WindowDockUnreadTarget(windowId: UUID(), surfaceId: UUID())
        let workspaceID = UUID()
        store.windowDockUnreadTargets = [target]
        store.workspaceUnreadIndicatorIds = [workspaceID]
        windows.orderedTargetsForUnreadJump = [
            MainWindowTarget(windowId: UUID(), workspaceIds: [workspaceID]),
        ]
        let coordinator = makeCoordinator(
            store: store,
            windows: windows,
            unreadTargeting: unread,
            openRouting: openRouting
        )

        let openedID = coordinator.jumpToOldestUnread()

        #expect(openedID == nil)
        #expect(store.clearedWindowDockTargets == [target])
        #expect(unread.clearedJumps.isEmpty)
        #expect(openRouting.log == [
            "windowDock(window=\(short(target.windowId)),surf=\(short(target.surfaceId)))",
        ])
    }

    // (cm-128.11) Changed on purpose: the Dock target is the one exclusion; the workspace parameter is gone.
    @Test("a Dock surface exclusion does not suppress a sibling window Dock surface")
    func dockExclusionDoesNotSuppressSiblingWindowDockSurface() {
        let store = FakeStore()
        let openRouting = FakeOpenRouting()
        let windowID = UUID()
        let focusedTarget = WindowDockUnreadTarget(
            windowId: windowID,
            surfaceId: UUID()
        )
        let siblingTarget = WindowDockUnreadTarget(
            windowId: windowID,
            surfaceId: UUID()
        )
        store.windowDockUnreadTargets = [focusedTarget, siblingTarget]
        let coordinator = makeCoordinator(store: store, openRouting: openRouting)

        _ = coordinator.jumpToOldestUnread(excludingPane: .windowDock(focusedTarget))

        #expect(store.clearedWindowDockTargets == [siblingTarget])
        #expect(openRouting.log == [
            "windowDock(window=\(short(windowID)),surf=\(short(siblingTarget.surfaceId)))",
        ])
    }

    @Test("mark-oldest skips both unread forms on the focused Dock surface")
    func markOldestSkipsNotificationAndManualUnreadForFocusedDockSurface() {
        let store = FakeStore()
        let openRouting = FakeOpenRouting()
        let focusedResolving = FakeFocusedResolving()
        let windowID = UUID()
        let focusedTarget = WindowDockUnreadTarget(
            windowId: windowID,
            surfaceId: UUID()
        )
        let siblingTarget = WindowDockUnreadTarget(
            windowId: windowID,
            surfaceId: UUID()
        )
        let focusedNotification = snapshot(
            tabId: windowID,
            surfaceId: focusedTarget.surfaceId
        )
        store.orderedNotifications = [focusedNotification]
        store.windowDockUnreadTargets = [focusedTarget, siblingTarget]
        focusedResolving.focusedTargetValue = .windowDock(focusedTarget)
        focusedResolving.targetsWithNotifications = [.windowDock(focusedTarget)]
        let coordinator = makeCoordinator(
            store: store,
            openRouting: openRouting,
            focusedResolving: focusedResolving
        )

        _ = coordinator.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread()

        #expect(store.markedReadIds.isEmpty)
        #expect(store.clearedWindowDockTargets == [siblingTarget])
        #expect(openRouting.log == [
            "windowDock(window=\(short(windowID)),surf=\(short(siblingTarget.surfaceId)))",
        ])
    }

    @Test("failed window Dock unread open falls through without clearing it")
    func failedWindowDockUnreadFallsThrough() {
        let store = FakeStore()
        let windows = FakeWindows()
        let unread = FakeUnreadTargeting()
        let openRouting = FakeOpenRouting()
        let target = WindowDockUnreadTarget(windowId: UUID(), surfaceId: UUID())
        let workspaceID = UUID()
        let workspacePanelID = UUID()
        let workspaceWindowID = UUID()
        store.windowDockUnreadTargets = [target]
        store.workspaceUnreadIndicatorIds = [workspaceID]
        windows.orderedTargetsForUnreadJump = [
            MainWindowTarget(
                windowId: workspaceWindowID,
                workspaceIds: [workspaceID]
            ),
        ]
        unread.preferredPanelByWorkspace[workspaceID] = workspacePanelID
        openRouting.windowDockSucceeds = false
        let coordinator = makeCoordinator(
            store: store,
            windows: windows,
            unreadTargeting: unread,
            openRouting: openRouting
        )

        _ = coordinator.jumpToOldestUnread()

        #expect(store.clearedWindowDockTargets.isEmpty)
        #expect(openRouting.log == [
            "windowDock(window=\(short(target.windowId)),surf=\(short(target.surfaceId)))",
            "window(\(short(workspaceWindowID)),tab=\(short(workspaceID)),surf=\(short(workspacePanelID)),notif=nil,row=nil,total=nil)",
        ])
    }

    // MARK: - Workspace-unread fallback + flash/clear

    @Test("falls back to unread-workspace jump and clears unread, flashing when manual")
    func fallbackJumpFlashesAndClears() {
        let store = FakeStore()
        let windows = FakeWindows()
        let unread = FakeUnreadTargeting()
        let openRouting = FakeOpenRouting()
        let tab = UUID(), panel = UUID(), windowId = UUID()
        // No openable notifications, but the workspace carries an unread indicator.
        store.workspaceUnreadIndicatorIds = [tab]
        windows.orderedTargetsForUnreadJump = [MainWindowTarget(windowId: windowId, workspaceIds: [tab])]
        unread.preferredPanelByWorkspace[tab] = panel
        unread.shouldFlashByWorkspacePanel = [.init(workspaceId: tab, panelId: panel)]
        let coordinator = makeCoordinator(
            store: store, windows: windows, unreadTargeting: unread, openRouting: openRouting
        )

        let openedId = coordinator.jumpToOldestUnread()

        #expect(openedId == nil) // workspace-unread fallback returns nil notification id
        #expect(openRouting.log == ["window(\(short(windowId)),tab=\(short(tab)),surf=\(short(panel)),notif=nil,row=nil,total=nil)"])
        #expect(unread.flashedPanels == [.init(workspaceId: tab, panelId: panel)])
        #expect(unread.clearedJumps.count == 1)
        #expect(unread.clearedJumps.first?.0 == tab)
        #expect(unread.clearedJumps.first?.1 == panel)
    }

    @Test("workspace-unread jump does NOT flash when not manual, but still clears")
    func fallbackJumpClearsWithoutFlashWhenNotManual() {
        let store = FakeStore()
        let windows = FakeWindows()
        let unread = FakeUnreadTargeting()
        let tab = UUID(), panel = UUID(), windowId = UUID()
        store.workspaceUnreadIndicatorIds = [tab]
        windows.orderedTargetsForUnreadJump = [MainWindowTarget(windowId: windowId, workspaceIds: [tab])]
        unread.preferredPanelByWorkspace[tab] = panel
        // shouldFlash is empty → no flash.
        let coordinator = makeCoordinator(store: store, windows: windows, unreadTargeting: unread)

        _ = coordinator.jumpToOldestUnread()

        #expect(unread.flashedPanels.isEmpty)
        #expect(unread.clearedJumps.count == 1)
    }

    @Test("workspace-unread jump that fails to open does not clear or flash")
    func failedWorkspaceJumpDoesNotClear() {
        let store = FakeStore()
        let windows = FakeWindows()
        let unread = FakeUnreadTargeting()
        let openRouting = FakeOpenRouting()
        openRouting.windowSucceeds = false
        openRouting.fallbackSucceeds = false
        let tab = UUID()
        store.workspaceUnreadIndicatorIds = [tab]
        windows.orderedTargetsForUnreadJump = [MainWindowTarget(windowId: UUID(), workspaceIds: [tab])]
        unread.preferredPanelByWorkspace[tab] = UUID()
        let coordinator = makeCoordinator(
            store: store, windows: windows, unreadTargeting: unread, openRouting: openRouting
        )

        _ = coordinator.jumpToOldestUnread()

        #expect(unread.clearedJumps.isEmpty)
        #expect(unread.flashedPanels.isEmpty)
    }

    @Test("workspace-unread jump falls back to the active tab manager when the window-context registry is empty (early-startup/VM timing)")
    func workspaceUnreadFallsBackToActiveManagerWhenRegistryEmpty() {
        let store = FakeStore()
        let windows = FakeWindows()
        let unread = FakeUnreadTargeting()
        let openRouting = FakeOpenRouting()
        let tab = UUID(), panel = UUID()
        store.workspaceUnreadIndicatorIds = [tab]
        // Registry lags during early startup: no targets...
        windows.orderedTargetsForUnreadJump = []
        // ...but the active tab manager already owns the unread workspace.
        windows.activeWorkspaceIdsForUnreadJump = [tab]
        unread.preferredPanelByWorkspace[tab] = panel
        let coordinator = makeCoordinator(
            store: store, windows: windows, unreadTargeting: unread, openRouting: openRouting
        )

        _ = coordinator.jumpToOldestUnread()

        // The active-window fallback opened it (the registry loop had nothing).
        #expect(openRouting.log.contains { $0.hasPrefix("fallback(tab=\(String(tab.uuidString.prefix(4)))") })
        #expect(unread.clearedJumps.count == 1)
        #expect(unread.clearedJumps.first?.0 == tab)
    }

    // MARK: - Click action

    @Test("openNotification performs the click action and marks read on success")
    func clickActionMarksReadOnSuccess() {
        let store = FakeStore()
        let click = FakeClickRouting()
        let openRouting = FakeOpenRouting()
        let notif = snapshot(tabId: UUID(), clickAction: .revealInFinder(path: "/tmp/file"))
        let coordinator = makeCoordinator(store: store, openRouting: openRouting, clickRouting: click)

        let opened = coordinator.openNotification(notif)

        #expect(opened)
        #expect(click.performed == [.revealInFinder(path: "/tmp/file")])
        #expect(store.markedReadIds == [notif.id])
        // No window routing for a click-action notification.
        #expect(openRouting.log.isEmpty)
    }

    @Test("openNotification does NOT mark read when the click action fails")
    func clickActionNotMarkedReadOnFailure() {
        let store = FakeStore()
        let click = FakeClickRouting()
        click.succeeds = false
        let notif = snapshot(tabId: UUID(), clickAction: .revealInFinder(path: "/tmp/file"))
        let coordinator = makeCoordinator(store: store, clickRouting: click)

        let opened = coordinator.openNotification(notif)

        #expect(!opened)
        #expect(store.markedReadIds.isEmpty)
    }

    // MARK: - Open routing

    @Test("open delegates to the app-side routed open (which owns window/fallback choice)")
    func openDelegatesToRoutedOpen() {
        let openRouting = FakeOpenRouting()
        let tab = UUID(), surface = UUID(), notifId = UUID()
        let coordinator = makeCoordinator(openRouting: openRouting)

        let opened = coordinator.open(tabId: tab, surfaceId: surface, notificationId: notifId)

        #expect(opened)
        #expect(openRouting.log == ["routed(tab=\(short(tab)),surf=\(short(surface)),notif=\(short(notifId)),row=nil,total=nil)"])
    }

    @Test("openNotification without a click action routes through the app-side routed open")
    func openNotificationWithoutClickActionRoutes() {
        let openRouting = FakeOpenRouting()
        let click = FakeClickRouting()
        let notif = snapshot(tabId: UUID(), surfaceId: UUID())
        let coordinator = makeCoordinator(openRouting: openRouting, clickRouting: click)

        let opened = coordinator.openNotification(notif)

        #expect(opened)
        #expect(click.performed.isEmpty)
        #expect(openRouting.log == ["routed(tab=\(short(notif.tabId)),surf=\(short(notif.surfaceId)),notif=\(short(notif.id)),row=nil,total=nil)"])
    }

    @Test("openNotification routes captured scroll row for terminal notifications")
    func openNotificationRoutesCapturedScrollRow() {
        let openRouting = FakeOpenRouting()
        let panelId = UUID()
        let notif = snapshot(tabId: UUID(), surfaceId: UUID(), panelId: panelId, scrollRow: 42, scrollTotalRows: 100)
        let coordinator = makeCoordinator(openRouting: openRouting)

        let opened = coordinator.openNotification(notif)

        #expect(opened)
        #expect(openRouting.log == ["routed(tab=\(short(notif.tabId)),surf=\(short(notif.surfaceId)),panel=\(short(panelId)),notif=\(short(notif.id)),row=42,total=100)"])
    }

    @Test("openNotification preserves captured row-space revision")
    func openNotificationPreservesCapturedRowSpaceRevision() {
        let openRouting = FakeOpenRouting()
        let notif = snapshot(
            tabId: UUID(),
            surfaceId: UUID(),
            scrollRow: 42,
            scrollTotalRows: 100,
            scrollRowSpaceRevision: 7
        )
        let coordinator = makeCoordinator(openRouting: openRouting)

        #expect(coordinator.openNotification(notif))
        #expect(openRouting.receivedRowSpaceRevisions == [7])
    }

    @Test("source-confined notification navigation preserves its workspace boundary")
    func sourceConfinedNotificationDoesNotEnableLiveRetargeting() {
        let openRouting = FakeOpenRouting()
        let notification = snapshot(
            tabId: UUID(),
            surfaceId: UUID(),
            retargetsToLiveSurfaceOwner: false
        )
        let coordinator = makeCoordinator(openRouting: openRouting)

        #expect(coordinator.openNotification(notification))
        #expect(openRouting.routedRetargetingValues == [false])
    }

    @Test("openNotification by id preserves stored panel and scroll context")
    func openNotificationByIdPreservesStoredContext() {
        let store = FakeStore()
        let openRouting = FakeOpenRouting()
        let fallbackTabId = UUID()
        let fallbackSurfaceId = UUID()
        let panelId = UUID()
        let notif = snapshot(tabId: UUID(), surfaceId: UUID(), panelId: panelId, scrollRow: 42, scrollTotalRows: 100)
        store.orderedNotifications = [notif]
        let coordinator = makeCoordinator(store: store, openRouting: openRouting)

        let opened = coordinator.openNotification(
            id: notif.id,
            fallbackTabId: fallbackTabId,
            fallbackSurfaceId: fallbackSurfaceId
        )

        #expect(opened)
        #expect(openRouting.log == ["routed(tab=\(short(notif.tabId)),surf=\(short(notif.surfaceId)),panel=\(short(panelId)),notif=\(short(notif.id)),row=42,total=100)"])
    }

    @Test("openNotification by id falls back when stored notification is missing")
    func openNotificationByIdFallsBackToUserInfoTarget() {
        let store = FakeStore()
        let openRouting = FakeOpenRouting()
        let fallbackTabId = UUID()
        let fallbackSurfaceId = UUID()
        let notificationId = UUID()
        let coordinator = makeCoordinator(store: store, openRouting: openRouting)

        let opened = coordinator.openNotification(
            id: notificationId,
            fallbackTabId: fallbackTabId,
            fallbackSurfaceId: fallbackSurfaceId,
            fallbackRetargetsToLiveSurfaceOwner: false
        )

        #expect(opened)
        #expect(openRouting.log == ["routed(tab=\(short(fallbackTabId)),surf=\(short(fallbackSurfaceId)),notif=\(short(notificationId)),row=nil,total=nil)"])
        #expect(openRouting.routedRetargetingValues == [false])
    }

    // MARK: - Focus signal (the #if DEBUG recorder hook)

    @Test("a successful workspace-unread jump signals onDidFocusForJumpUnread")
    func successfulJumpSignalsFocus() {
        let store = FakeStore()
        let windows = FakeWindows()
        let unread = FakeUnreadTargeting()
        let tab = UUID(), panel = UUID(), windowId = UUID()
        store.workspaceUnreadIndicatorIds = [tab]
        windows.orderedTargetsForUnreadJump = [MainWindowTarget(windowId: windowId, workspaceIds: [tab])]
        unread.preferredPanelByWorkspace[tab] = panel
        let coordinator = makeCoordinator(store: store, windows: windows, unreadTargeting: unread)
        var signalled: [(UUID, UUID?)] = []
        coordinator.onDidFocusForJumpUnread = { signalled.append(($0, $1)) }

        _ = coordinator.jumpToOldestUnread()

        #expect(signalled.count == 1)
        #expect(signalled.first?.0 == tab)
        #expect(signalled.first?.1 == panel)
    }

    // MARK: - tabTitle

    @Test("tabTitle forwards to the open router")
    func tabTitleForwards() {
        let openRouting = FakeOpenRouting()
        let tab = UUID()
        openRouting.titles[tab] = "My Workspace"
        let coordinator = makeCoordinator(openRouting: openRouting)

        #expect(coordinator.tabTitle(forTabId: tab) == "My Workspace")
    }

    private func short(_ id: UUID?) -> String { id.map { String($0.uuidString.prefix(4)) } ?? "nil" }
}

// MARK: - The unread queue (cm-128.11)

private func queued(
    _ tab: UUID,
    _ surface: UUID?,
    at t: Int,
    read: Bool = false,
    clickAction: NotificationNavClickAction? = nil,
    id: UUID = UUID()
) -> NotificationNavSnapshot {
    snapshot(
        tabId: tab,
        surfaceId: surface,
        isRead: read,
        clickAction: clickAction,
        queuedAt: t,
        id: id
    )
}

private func asRead(_ s: NotificationNavSnapshot) -> NotificationNavSnapshot {
    queued(s.tabId, s.surfaceId, at: 0, read: true, id: s.id)
}

@Suite(.serialized)
@MainActor
struct UnreadQueueWalkTests {
    private func routedPrefix(_ s: NotificationNavSnapshot) -> String {
        "routed(tab=\(String(s.tabId.uuidString.prefix(4))),surf=\(s.surfaceId.map { String($0.uuidString.prefix(4)) } ?? "nil"),notif=\(String(s.id.uuidString.prefix(4)))"
    }

    // Scenario 150
    @Test("walk opens the pane unread longest first, then the next as each is read")
    func walkOpensOldestQueuedPaneFirst() {
        let store = FakeStore()
        let a = queued(UUID(), UUID(), at: 1)
        let b = queued(UUID(), UUID(), at: 2)
        let c = queued(UUID(), UUID(), at: 3)
        store.orderedNotifications = [c, b, a] // the store is newest first
        let coordinator = makeCoordinator(store: store)

        #expect(coordinator.jumpToOldestUnread() == a.id)
        store.orderedNotifications = [c, b, asRead(a)]
        #expect(coordinator.jumpToOldestUnread() == b.id)
        store.orderedNotifications = [c, asRead(b), asRead(a)]
        #expect(coordinator.jumpToOldestUnread() == c.id)
    }

    // Scenario 151
    @Test("a pane that goes unread meanwhile waits behind every one already unread")
    func newArrivalJoinsTheBack() {
        let store = FakeStore()
        let a = queued(UUID(), UUID(), at: 1)
        let b = queued(UUID(), UUID(), at: 2)
        let d = queued(UUID(), UUID(), at: 4)
        store.orderedNotifications = [d, b, a]
        let coordinator = makeCoordinator(store: store)

        #expect(coordinator.jumpToOldestUnread() == a.id)
        store.orderedNotifications = [d, b, asRead(a)]
        #expect(coordinator.jumpToOldestUnread() == b.id)
        store.orderedNotifications = [d, asRead(b), asRead(a)]
        #expect(coordinator.jumpToOldestUnread() == d.id)
    }

    // Scenario 152 (walk half): a pane that notifies again keeps its place and opens at its newest text
    @Test("a pane that notified again keeps its place and opens its newest notification")
    func paneThatNotifiedAgainKeepsPlaceAndOpensNewestText() {
        let store = FakeStore()
        let tabA = UUID(), surfaceA = UUID()
        let b = queued(UUID(), UUID(), at: 2)
        let c = queued(UUID(), UUID(), at: 3)
        // t=4: A's new notification replaced its t=1 one and inherited t=1.
        let aNew = queued(tabA, surfaceA, at: 1)
        store.orderedNotifications = [aNew, c, b]
        let coordinator = makeCoordinator(store: store)

        #expect(coordinator.jumpToOldestUnread() == aNew.id)
        store.orderedNotifications = [asRead(aNew), c, b]
        #expect(coordinator.jumpToOldestUnread() == b.id)
        store.orderedNotifications = [asRead(aNew), c, asRead(b)]
        #expect(coordinator.jumpToOldestUnread() == c.id)
    }

    // Scenario 153
    @Test("a pane with two unread turns is one stop, opened at its newest")
    func paneWithTwoUnreadTurnsIsOneStop() {
        let store = FakeStore()
        let tabA = UUID(), surfaceA = UUID()
        let aOld = queued(tabA, surfaceA, at: 1)
        let b = queued(UUID(), UUID(), at: 2)
        let aNew = queued(tabA, surfaceA, at: 3)
        store.orderedNotifications = [aNew, b, aOld]
        let openRouting = FakeOpenRouting()
        let coordinator = makeCoordinator(store: store, openRouting: openRouting)

        #expect(coordinator.jumpToOldestUnread() == aNew.id)
        // The visit reads the whole pane (app side); the next press goes to B.
        store.orderedNotifications = [asRead(aNew), b, asRead(aOld)]
        #expect(coordinator.jumpToOldestUnread() == b.id)
    }

    @Test("two panes of one workspace are two stops")
    func twoPanesOfOneWorkspaceAreTwoStops() {
        let store = FakeStore()
        let tab = UUID()
        let first = queued(tab, UUID(), at: 1)
        let second = queued(tab, UUID(), at: 2)
        store.orderedNotifications = [second, first]
        let coordinator = makeCoordinator(store: store)

        #expect(coordinator.jumpToOldestUnread() == first.id)
        store.orderedNotifications = [second, asRead(first)]
        #expect(coordinator.jumpToOldestUnread() == second.id)
    }

    // Scenario 154
    @Test("the pane he's on is read and passed; the press opens the next stop")
    func focusedPaneIsReadAndPassed() {
        let store = FakeStore()
        let openRouting = FakeOpenRouting()
        let unread = FakeUnreadTargeting()
        let tabA = UUID(), surfaceA = UUID()
        let a = queued(tabA, surfaceA, at: 1)
        let b = queued(UUID(), UUID(), at: 2)
        store.orderedNotifications = [b, a]
        unread.frontmostFocusedPanes = [.workspace(tabId: tabA, surfaceId: surfaceA)]
        // A real open moves focus: after B opens, B is the pane he's on, and the press must still end there.
        openRouting.onRoutedOpen = { tab, surface in unread.frontmostFocusedPanes = [.workspace(tabId: tab, surfaceId: surface)] }
        let coordinator = makeCoordinator(store: store, unreadTargeting: unread, openRouting: openRouting)

        #expect(coordinator.jumpToOldestUnread() == b.id)
        // His pane was opened (which reads it), then B.
        #expect(openRouting.log.count == 2)
        #expect(openRouting.log.first?.hasPrefix(routedPrefix(a)) == true)
        #expect(openRouting.log.last?.hasPrefix(routedPrefix(b)) == true)
    }

    @Test("with only marks left after his pane, the press opens the first mark")
    func focusedPaneThenFirstMark() {
        let store = FakeStore()
        let windows = FakeWindows()
        let unread = FakeUnreadTargeting()
        let openRouting = FakeOpenRouting()
        let tabA = UUID(), surfaceA = UUID()
        let markedTab = UUID(), markedPanel = UUID(), windowId = UUID()
        store.orderedNotifications = [queued(tabA, surfaceA, at: 1)]
        store.workspaceUnreadIndicatorIds = [markedTab]
        windows.orderedTargetsForUnreadJump = [MainWindowTarget(windowId: windowId, workspaceIds: [markedTab])]
        unread.preferredPanelByWorkspace[markedTab] = markedPanel
        unread.frontmostFocusedPanes = [.workspace(tabId: tabA, surfaceId: surfaceA)]
        let coordinator = makeCoordinator(store: store, windows: windows, unreadTargeting: unread, openRouting: openRouting)

        #expect(coordinator.jumpToOldestUnread() == nil)
        #expect(unread.clearedJumps.count == 1)
        #expect(unread.clearedJumps.first?.0 == markedTab)
    }

    @Test("when the next stop is his own pane's mark, the press clears it and opens the next mark")
    func ownPaneMarkIsClearedThenNextMark() {
        let windows = FakeWindows()
        let unread = FakeUnreadTargeting()
        let openRouting = FakeOpenRouting()
        let store = FakeStore()
        let ownTab = UUID(), ownPanel = UUID(), otherTab = UUID(), otherPanel = UUID(), windowId = UUID()
        store.workspaceUnreadIndicatorIds = [ownTab, otherTab]
        windows.orderedTargetsForUnreadJump = [MainWindowTarget(windowId: windowId, workspaceIds: [ownTab, otherTab])]
        unread.preferredPanelByWorkspace[ownTab] = ownPanel
        unread.preferredPanelByWorkspace[otherTab] = otherPanel
        unread.frontmostFocusedPanes = [.workspace(tabId: ownTab, surfaceId: ownPanel)]
        let coordinator = makeCoordinator(store: store, windows: windows, unreadTargeting: unread, openRouting: openRouting)

        #expect(coordinator.jumpToOldestUnread() == nil)
        #expect(unread.clearedJumps.map(\.0) == [ownTab, otherTab])
    }

    @Test("with nothing else unread, the press reads his pane and stays")
    func focusedPaneAloneReadsAndStays() {
        let store = FakeStore()
        let openRouting = FakeOpenRouting()
        let unread = FakeUnreadTargeting()
        let tabA = UUID(), surfaceA = UUID()
        let a = queued(tabA, surfaceA, at: 1)
        store.orderedNotifications = [a]
        unread.frontmostFocusedPanes = [.workspace(tabId: tabA, surfaceId: surfaceA)]
        let coordinator = makeCoordinator(store: store, unreadTargeting: unread, openRouting: openRouting)

        #expect(coordinator.jumpToOldestUnread() == a.id)
        #expect(openRouting.log.count == 1)
    }

    // Scenario 155
    @Test("a click-action notification is skipped; a read one is skipped")
    func clickActionAndReadAreSkipped() {
        let store = FakeStore()
        let click = queued(UUID(), UUID(), at: 1, clickAction: .revealInFinder(path: "/tmp/x"))
        let read = queued(UUID(), UUID(), at: 2, read: true)
        let ok = queued(UUID(), UUID(), at: 3)
        store.orderedNotifications = [ok, read, click]
        let coordinator = makeCoordinator(store: store)

        #expect(coordinator.jumpToOldestUnread() == ok.id)
    }

    @Test("news comes before every mark, whatever the marks' age")
    func newsBeforeMarks() {
        let store = FakeStore()
        let windows = FakeWindows()
        let unread = FakeUnreadTargeting()
        let openRouting = FakeOpenRouting()
        let news = queued(UUID(), UUID(), at: 9)
        let dock = WindowDockUnreadTarget(windowId: UUID(), surfaceId: UUID())
        let markedTab = UUID()
        store.orderedNotifications = [news]
        store.windowDockUnreadTargets = [dock]
        store.workspaceUnreadIndicatorIds = [markedTab]
        windows.orderedTargetsForUnreadJump = [MainWindowTarget(windowId: UUID(), workspaceIds: [markedTab])]
        let coordinator = makeCoordinator(store: store, windows: windows, unreadTargeting: unread, openRouting: openRouting)

        #expect(coordinator.jumpToOldestUnread() == news.id)
        #expect(openRouting.log.count == 1)
    }

    @Test("Dock marks are taken in the order the store lists them, first mark first")
    func dockMarksTakeTheStoreListFromTheFront() {
        let store = FakeStore()
        let openRouting = FakeOpenRouting()
        let windowId = UUID()
        let x = WindowDockUnreadTarget(windowId: windowId, surfaceId: UUID())
        let y = WindowDockUnreadTarget(windowId: windowId, surfaceId: UUID())
        store.windowDockUnreadTargets = [x, y]
        let coordinator = makeCoordinator(store: store, openRouting: openRouting)

        _ = coordinator.jumpToOldestUnread()

        #expect(store.clearedWindowDockTargets == [x])
    }

    // The one pane exclusion (⌘⌃U)
    @Test("the excluded pane's notifications are skipped, all of them")
    func excludedPaneSkipsEveryNotificationOnIt() {
        let store = FakeStore()
        let tabA = UUID(), surfaceA = UUID()
        let a1 = queued(tabA, surfaceA, at: 1)
        let a2 = queued(tabA, surfaceA, at: 2)
        let b = queued(UUID(), UUID(), at: 3)
        store.orderedNotifications = [b, a2, a1]
        let coordinator = makeCoordinator(store: store)

        #expect(coordinator.jumpToOldestUnread(excludingPane: .workspace(tabId: tabA, surfaceId: surfaceA)) == b.id)
    }

    // Review R1 (cm-128.11): the tie-break
    @Test("two panes queued at the same time: the lower notification id goes first")
    func tieIsBrokenByNotificationId() {
        let store = FakeStore()
        let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let high = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFE")!
        let first = queued(UUID(), UUID(), at: 5, id: high)
        let second = queued(UUID(), UUID(), at: 5, id: low)
        store.orderedNotifications = [first, second] // the higher id is ahead in store order
        let coordinator = makeCoordinator(store: store)

        #expect(coordinator.jumpToOldestUnread() == low)
    }

    // Review R2 (cm-128.11): Scenario 154 and Q97 for a Dock surface
    @Test("a mark on the Dock surface he's on is cleared and passed; the press opens the next Dock mark")
    func ownDockMarkIsClearedThenNextDockMark() {
        let store = FakeStore()
        let unread = FakeUnreadTargeting()
        let openRouting = FakeOpenRouting()
        let windowId = UUID()
        let own = WindowDockUnreadTarget(windowId: windowId, surfaceId: UUID())
        let next = WindowDockUnreadTarget(windowId: windowId, surfaceId: UUID())
        store.windowDockUnreadTargets = [own, next]
        unread.frontmostFocusedPanes = [.windowDock(own)]
        let coordinator = makeCoordinator(store: store, unreadTargeting: unread, openRouting: openRouting)

        #expect(coordinator.jumpToOldestUnread() == nil)
        #expect(store.clearedWindowDockTargets == [own, next])
    }

    // Review R3 (cm-128.11): the sent-back pane's mark is not opened again
    @Test("the sent-back pane's workspace mark is skipped; another pane's mark in that workspace is not")
    func sentBackPaneWorkspaceMarkIsExcluded() {
        let store = FakeStore()
        let windows = FakeWindows()
        let unread = FakeUnreadTargeting()
        let openRouting = FakeOpenRouting()
        let tab = UUID(), panel = UUID(), otherPanel = UUID()
        store.workspaceUnreadIndicatorIds = [tab]
        windows.orderedTargetsForUnreadJump = [MainWindowTarget(windowId: UUID(), workspaceIds: [tab])]
        unread.preferredPanelByWorkspace[tab] = panel
        let coordinator = makeCoordinator(store: store, windows: windows, unreadTargeting: unread, openRouting: openRouting)

        #expect(coordinator.jumpToOldestUnread(excludingPane: .workspace(tabId: tab, surfaceId: panel)) == nil)
        #expect(unread.clearedJumps.isEmpty)
        #expect(openRouting.log.isEmpty)

        // With no pane named, the whole workspace's mark is the sent-back one.
        #expect(coordinator.jumpToOldestUnread(excludingPane: .workspace(tabId: tab, surfaceId: nil)) == nil)
        #expect(unread.clearedJumps.isEmpty)

        // The mark belongs to another pane of that workspace: it still opens.
        #expect(coordinator.jumpToOldestUnread(excludingPane: .workspace(tabId: tab, surfaceId: otherPanel)) == nil)
        #expect(unread.clearedJumps.map(\.0) == [tab])
    }

    // Review R6 (cm-128.11, Tom's Q77/Q97, the lead's reading of Q6)
    @Test("a summary older than the pane he's on opens first and leaves that pane unread")
    func summaryOlderThanHisPaneOpensAndHisPaneStaysUnread() {
        let store = FakeStore()
        let unread = FakeUnreadTargeting()
        let openRouting = FakeOpenRouting()
        let tabA = UUID(), surfaceA = UUID()
        store.orderedNotifications = [queued(tabA, surfaceA, at: 100)]
        unread.frontmostFocusedPanes = [.workspace(tabId: tabA, surfaceId: surfaceA)]
        let summaryAt = Date(timeIntervalSince1970: 50)
        var asked: [Date?] = []
        let coordinator = makeCoordinator(store: store, unreadTargeting: unread, openRouting: openRouting)

        let opened = coordinator.jumpToOldestUnread(openRestartSummary: { before in
            asked.append(before)
            return before.map { summaryAt <= $0 } ?? true
        })

        #expect(opened == nil)
        #expect(openRouting.log.isEmpty, "his pane was not the next stop: not opened, so not read")
        #expect(asked == [Date(timeIntervalSince1970: 100)])
    }

    @Test("a summary between the pane he's on and the next pane opens after his pane is read")
    func summaryAfterHisPaneOpensAfterHisPaneIsRead() {
        let store = FakeStore()
        let unread = FakeUnreadTargeting()
        let openRouting = FakeOpenRouting()
        let tabA = UUID(), surfaceA = UUID()
        store.orderedNotifications = [queued(UUID(), UUID(), at: 200), queued(tabA, surfaceA, at: 100)]
        unread.frontmostFocusedPanes = [.workspace(tabId: tabA, surfaceId: surfaceA)]
        let summaryAt = Date(timeIntervalSince1970: 150)
        var asked: [Date?] = []
        let coordinator = makeCoordinator(store: store, unreadTargeting: unread, openRouting: openRouting)

        let opened = coordinator.jumpToOldestUnread(openRestartSummary: { before in
            asked.append(before)
            return before.map { summaryAt <= $0 } ?? true
        })

        #expect(opened == nil)
        #expect(openRouting.log.count == 1, "his pane opened, which reads it; the next pane did not")
        #expect(asked == [Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 200)])
    }

    // Review carry-over (b), cm-128.11: opening a workspace-level notification focuses the workspace's
    // focused pane, which is the pane ⌘⌃U just sent back, and the open reads it.
    @Test("a workspace-level notification in the sent-back pane's workspace is skipped; another workspace's is not")
    func workspaceLevelNotificationInTheSentBackPanesWorkspaceIsExcluded() {
        let store = FakeStore()
        let openRouting = FakeOpenRouting()
        let tab = UUID(), sentBack = UUID(), otherTab = UUID()
        let inSameWorkspace = queued(tab, nil, at: 1)
        let elsewhere = queued(otherTab, nil, at: 2)
        store.orderedNotifications = [elsewhere, inSameWorkspace]
        let coordinator = makeCoordinator(store: store, openRouting: openRouting)

        #expect(coordinator.jumpToOldestUnread(excludingPane: .workspace(tabId: tab, surfaceId: sentBack)) == elsewhere.id)
        #expect(openRouting.log.count == 1, "the sent-back pane's workspace was not opened, so its pane was not read")
    }

    // Review finding 3 (cm-128.11, decision 02): a remote tmux pane is a surface X inside a container panel P.
    @Test("a mark on the container panel of the sent-back remote tmux pane is excluded, and the pane stays unread")
    func sentBackRemoteTmuxPaneMarkOnItsContainerIsExcluded() {
        let store = FakeStore()
        let windows = FakeWindows()
        let unread = FakeUnreadTargeting()
        let openRouting = FakeOpenRouting()
        let tab = UUID(), surfaceX = UUID(), containerP = UUID()
        store.workspaceUnreadIndicatorIds = [tab]
        windows.orderedTargetsForUnreadJump = [MainWindowTarget(windowId: UUID(), workspaceIds: [tab])]
        unread.preferredPanelByWorkspace[tab] = containerP
        unread.owningPanels[surfaceX] = containerP
        let coordinator = makeCoordinator(store: store, windows: windows, unreadTargeting: unread, openRouting: openRouting)

        #expect(coordinator.jumpToOldestUnread(excludingPane: .workspace(tabId: tab, surfaceId: surfaceX)) == nil)
        #expect(unread.clearedJumps.isEmpty, "the mark on the container panel was read back")
        #expect(openRouting.log.isEmpty)
    }

    @Test("plain unread jump passes the mark on the container panel of the remote tmux pane he is on")
    func remoteTmuxPaneHeIsOnIsPassedWhenTheMarkIsOnItsContainer() {
        let store = FakeStore()
        let windows = FakeWindows()
        let unread = FakeUnreadTargeting()
        let openRouting = FakeOpenRouting()
        let tab = UUID(), surfaceX = UUID(), containerP = UUID()
        let otherTab = UUID(), otherPanel = UUID()
        store.workspaceUnreadIndicatorIds = [tab, otherTab]
        windows.orderedTargetsForUnreadJump = [MainWindowTarget(windowId: UUID(), workspaceIds: [tab, otherTab])]
        unread.preferredPanelByWorkspace[tab] = containerP
        unread.preferredPanelByWorkspace[otherTab] = otherPanel
        unread.owningPanels[surfaceX] = containerP
        unread.frontmostFocusedPanes = [.workspace(tabId: tab, surfaceId: surfaceX)]
        let coordinator = makeCoordinator(store: store, windows: windows, unreadTargeting: unread, openRouting: openRouting)

        #expect(coordinator.jumpToOldestUnread() == nil)
        #expect(unread.clearedJumps.map(\.0) == [tab, otherTab], "his own mark is cleared and passed; the next opens")
    }

    // Narrow check of the finding-3 round (cm-128.11): notifications from remote tmux panes are stored per pane,
    // so two panes in one container are two stops; only the container's own mark belongs to the pane he's on.
    @Test("a sibling remote tmux pane in the same container is its own stop, not the pane he is on")
    func siblingRemoteTmuxPaneInTheSameContainerIsItsOwnStop() {
        let store = FakeStore()
        let openRouting = FakeOpenRouting()
        let unread = FakeUnreadTargeting()
        let tab = UUID(), paneX1 = UUID(), paneX2 = UUID(), containerP = UUID()
        let onX1 = queued(tab, paneX1, at: 1)
        let elsewhere = queued(UUID(), UUID(), at: 2)
        store.orderedNotifications = [elsewhere, onX1]
        unread.owningPanels[paneX1] = containerP
        unread.owningPanels[paneX2] = containerP
        unread.frontmostFocusedPanes = [.workspace(tabId: tab, surfaceId: paneX2)]
        let coordinator = makeCoordinator(store: store, unreadTargeting: unread, openRouting: openRouting)

        #expect(coordinator.jumpToOldestUnread() == onX1.id, "he is on X2; X1's news is another pane, so it is the stop")
        #expect(openRouting.log.count == 1, "only X1 opens; X1 is not read and passed as his own pane")
    }

    // The stop's side of the mapping (cm-128.11): a stop whose surface is owned by the panel he's on
    // (a tab id inside it, as the app's step-3 mapping read) is his pane, so it is read and passed.
    @Test("a stop whose surface is owned by the panel he is on is his pane, read and passed")
    func stopOwnedByThePanelHeIsOnIsHisPane() {
        let store = FakeStore()
        let openRouting = FakeOpenRouting()
        let unread = FakeUnreadTargeting()
        let tab = UUID(), innerSurface = UUID(), focusedPanel = UUID()
        let onHisPane = queued(tab, innerSurface, at: 1)
        let elsewhere = queued(UUID(), UUID(), at: 2)
        store.orderedNotifications = [elsewhere, onHisPane]
        unread.owningPanels[innerSurface] = focusedPanel
        unread.frontmostFocusedPanes = [.workspace(tabId: tab, surfaceId: focusedPanel)]
        let coordinator = makeCoordinator(store: store, unreadTargeting: unread, openRouting: openRouting)

        #expect(coordinator.jumpToOldestUnread() == elsewhere.id, "his own pane is read and passed; the next stop opens")
    }
}
