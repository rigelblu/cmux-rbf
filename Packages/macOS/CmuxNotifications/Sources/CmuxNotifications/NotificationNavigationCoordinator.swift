public import Foundation
import Observation

/// Orchestrates notification jump/open navigation: which unread notification to
/// open, in which window, with what unread state cleared and what marked read.
/// Lifted verbatim from `AppDelegate`'s jump/open cluster
/// (`jumpToLatestUnread`, `openLatestWorkspaceUnread`, `openWorkspaceUnread`,
/// `clearWorkspaceUnreadAfterJump`, `openTerminalNotification`,
/// `openNotification`, `tabTitle`), with every app-target collaborator replaced
/// by an injected protocol seam.
///
/// A Coordinator (CONVENTIONS §2): it sequences a user flow and owns no I/O.
/// `@MainActor` because every navigation entry point is a MainActor UI path and
/// the seams it drives are themselves `@MainActor`. `@Observable` for parity
/// with the package's other navigation model and to allow future observable
/// navigation state, though this wave exposes none.
///
/// The focused-mark cluster (`toggleFocusedNotificationUnread`,
/// `markFocusedNotificationAsOldestUnread*`) now lives in
/// ``FocusedNotificationMarker``, owned by this coordinator and driven through
/// the ``FocusedNotificationResolving`` seam; the coordinator exposes the two
/// public focused-mark entry points and forwards to the marker, which delegates
/// its jump step back to
/// ``jumpToOldestUnread(excludingPane:openRestartSummary:)``.
@MainActor
@Observable
public final class NotificationNavigationCoordinator: NotificationDeliveryTerminalNavigating {
    private let store: any NotificationNavigationStoreReading
    private let windows: any MainWindowContextResolving
    private let unreadTargeting: any UnreadWorkspaceTargeting
    private let openRouting: any NotificationOpenRouting
    private let clickRouting: any NotificationClickRouting
    private let focusedResolving: any FocusedNotificationResolving
    private let explicitFocusedJump: ((UnreadQueueTarget?) -> UUID?)?
    /// The focused-mark state machine. Lazy so its default jump closure can
    /// capture `self` (allowed only after all stored properties are initialized);
    /// the closure is invoked later, on the main actor. `@ObservationIgnored`
    /// because this is a private internal collaborator that must not participate
    /// in `@Observable` observation; the enclosing type is `@MainActor`, so the
    /// lazy initialization is concurrency-safe.
    @ObservationIgnored
    private lazy var focusedMarker: FocusedNotificationMarker = FocusedNotificationMarker(
        resolver: focusedResolving,
        jumpToOldestUnread: explicitFocusedJump ?? {
            // (cm-128.11) one pane exclusion in place of the notification, workspace and Dock parameters
            [unowned self] excludedPane in
            self.jumpToOldestUnread(excludingPane: excludedPane)
        }
    )

    /// Signalled after a jump/open focuses a workspace/surface, so the app-target
    /// `#if DEBUG` jump-unread UI-test recorders (which observe Combine and
    /// first-responder events the package must not import) can arm/record. Carries
    /// the focused `(tabId, surfaceId?)`. No-op in production builds.
    public var onDidFocusForJumpUnread: ((UUID, UUID?) -> Void)?

    /// - Parameter focusedJump: (cm-128.11) the jump the focused-mark flow performs after
    ///   sending the focused pane to the back, returning the opened notification id
    ///   (`nil` when a restart summary or a mark opened). Injected so the app target
    ///   can route it through its own recorder-wrapped, summary-aware
    ///   `jumpToOldestUnread` (which fires the `#if DEBUG` `jumpUnreadInvoked`
    ///   UI-test recorder and applies the nil-store guard). Defaults to this
    ///   coordinator's plain ``jumpToOldestUnread(excludingPane:openRestartSummary:)``.
    public init(
        store: any NotificationNavigationStoreReading,
        windows: any MainWindowContextResolving,
        unreadTargeting: any UnreadWorkspaceTargeting,
        openRouting: any NotificationOpenRouting,
        clickRouting: any NotificationClickRouting,
        focusedResolving: any FocusedNotificationResolving,
        focusedJump: ((_ excludingPane: UnreadQueueTarget?) -> UUID?)? = nil
    ) {
        self.store = store
        self.windows = windows
        self.unreadTargeting = unreadTargeting
        self.openRouting = openRouting
        self.clickRouting = clickRouting
        self.focusedResolving = focusedResolving
        self.explicitFocusedJump = focusedJump
    }

    // MARK: Focused-mark

    /// Toggles the focused notification's unread state, returning whether
    /// anything was toggled. Forwards to ``FocusedNotificationMarker``. Mirrors
    /// `AppDelegate.toggleFocusedNotificationUnread`.
    @discardableResult
    public func toggleFocusedNotificationUnread(preferredWindowToken: AnyObject? = nil) -> Bool {
        focusedMarker.toggleFocusedNotificationUnread(preferredWindowToken: preferredWindowToken)
    }

    /// Sends the focused pane to the back of the unread queue, then jumps to the next
    /// oldest unread (cm-128.11), returning the opened notification id. Forwards to
    /// ``FocusedNotificationMarker``. Mirrors
    /// `AppDelegate.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread`.
    @discardableResult
    public func markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread(
        preferredWindowToken: AnyObject? = nil
    ) -> UUID? {
        focusedMarker.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread(
            preferredWindowToken: preferredWindowToken
        )
    }

    // MARK: Jump

    /// One pane in the unread queue: its place and the notification the press opens (cm-128.11).
    private struct QueueStop {
        let target: UnreadQueueTarget
        let queuedAt: Date
        /// The id of the earliest member, the tie-break between two panes queued at the same time.
        let tieBreakId: UUID
        /// The pane's newest unread notification: store order is newest first.
        let newest: NotificationNavSnapshot
    }

    /// The queue: unread, openable notifications grouped by pane, oldest `queuedAt` first, ties by
    /// notification id (cm-128.11). The stop is the pane, not the workspace (Tom, grill Q92). A
    /// notification with no surface groups by its workspace.
    private func unreadQueue(excludingPane excludedPane: UnreadQueueTarget?) -> [QueueStop] {
        struct Key: Hashable { let tabId: UUID; let surfaceId: UUID? }
        var order: [Key] = []
        var members: [Key: [NotificationNavSnapshot]] = [:]
        for notification in store.orderedNotifications
        where notification.isOpenableForJump(excludingNotificationId: nil, excludingWorkspaceId: nil)
            && !notification.isOnPane(excludedPane) {
            let key = Key(tabId: notification.tabId, surfaceId: notification.surfaceId)
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(notification)
        }
        return order.compactMap { key -> QueueStop? in
            guard let group = members[key],
                  let newest = group.first,
                  let earliest = group.min(by: { lhs, rhs in
                      lhs.queuedAt != rhs.queuedAt
                          ? lhs.queuedAt < rhs.queuedAt
                          : lhs.id.uuidString < rhs.id.uuidString
                  }) else { return nil }
            return QueueStop(
                target: .workspace(tabId: key.tabId, surfaceId: key.surfaceId),
                queuedAt: earliest.queuedAt,
                tieBreakId: earliest.id,
                newest: newest
            )
        }
        .sorted { lhs, rhs in
            lhs.queuedAt != rhs.queuedAt
                ? lhs.queuedAt < rhs.queuedAt
                : lhs.tieBreakId.uuidString < rhs.tieBreakId.uuidString
        }
    }

    /// Opens the pane that has been unread longest, returning the opened notification's id, or `nil`
    /// when nothing could be opened or a mark or restart summary opened instead (cm-128.11).
    ///
    /// Order: the queue of panes with unread news, oldest first; then Dock-surface marks in the
    /// order the store lists them (oldest first); then workspace marks, as before. When the next stop
    /// is the pane he's on, the press reads it and goes to the one after; with nothing else, it
    /// reads it and stays. `excludedPane` is the pane ⌘⌃U just sent back: its notifications and
    /// mark are skipped and never read. `openRestartSummary` is asked at each stop with that stop's
    /// `queuedAt` (`nil` when no news stop is left): when an unread summary is as old, it opens it
    /// and the walk ends.
    @discardableResult
    public func jumpToOldestUnread(
        excludingPane excludedPane: UnreadQueueTarget? = nil,
        openRestartSummary: ((_ before: Date?) -> Bool)? = nil
    ) -> UUID? {
        var staying: UUID?
        for stop in unreadQueue(excludingPane: excludedPane) {
            if openRestartSummary?(stop.queuedAt) == true { return nil }
            // Asked before the open: opening moves focus, and the pane he lands on is not the one he was on.
            let hesHere = isFrontmostFocusedPane(stop.target)
            guard openNotification(stop.newest) else { continue }
            if hesHere {
                // He is already here: opening it read the pane. Go on to the next stop.
                staying = staying ?? stop.newest.id
                continue
            }
            return stop.newest.id
        }
        if openRestartSummary?(nil) == true { return nil }
        if openOldestWindowDockUnread(excludingPane: excludedPane) { return nil }
        if openOldestWorkspaceUnread(excludingPane: excludedPane) { return nil }
        // Nothing else opened: he is on the only stop left, and the press has read it.
        return staying
    }

    /// Workspaces whose mark belongs to the excluded pane (cm-128.11): the whole workspace when the
    /// target names no pane, else the workspace when its preferred panel is the excluded pane.
    private func excludedWorkspaceMarks(_ excludedPane: UnreadQueueTarget?) -> Set<UUID> {
        guard case .workspace(let tabId, let surfaceId)? = excludedPane else { return [] }
        guard let surfaceId else { return [tabId] }
        // (cm-128.11) The preferred panel may be the container of the excluded surface (a remote tmux pane).
        guard let preferred = unreadTargeting.preferredUnreadPanelIdForJump(workspaceId: tabId) else { return [] }
        let owner = unreadTargeting.owningPanelId(workspaceId: tabId, surfaceId: surfaceId)
        return preferred == surfaceId || preferred == owner ? [tabId] : []
    }

    /// Whether `target` is the pane he's on (cm-128.11). One side at a time is mapped to its owning panel,
    /// never both: a mark on a remote tmux pane's container belongs to that pane, but two panes in one
    /// container keep their own notifications, so they stay two panes.
    private func isFrontmostFocusedPane(_ target: UnreadQueueTarget) -> Bool {
        guard let focused = unreadTargeting.frontmostFocusedPane() else { return false }
        switch (target, focused) {
        case (.windowDock(let wanted), .windowDock(let current)):
            return wanted == current
        case (.workspace(let tabId, let surfaceId), .workspace(let focusedTabId, let focusedSurfaceId)):
            guard tabId == focusedTabId else { return false }
            guard let surfaceId else { return true }
            guard let focusedSurfaceId else { return false }
            return surfaceId == focusedSurfaceId
                || surfaceId == unreadTargeting.owningPanelId(workspaceId: tabId, surfaceId: focusedSurfaceId)
                || unreadTargeting.owningPanelId(workspaceId: tabId, surfaceId: surfaceId) == focusedSurfaceId
        default:
            return false
        }
    }

    /// Opens the oldest Dock-surface mark; a mark on the Dock surface he's on is cleared and passed (cm-128.11).
    private func openOldestWindowDockUnread(excludingPane excludedPane: UnreadQueueTarget?) -> Bool {
        for target in store.windowDockUnreadTargets
        where excludedPane != .windowDock(target) {
            let hesHere = isFrontmostFocusedPane(.windowDock(target))
            guard openRouting.openWindowDockUnread(target) else { continue }
            signalDidFocusForJumpUnread(
                tabId: target.windowId,
                surfaceId: target.surfaceId
            )
            store.clearWindowDockUnread(target)
            if hesHere {
                // His own Dock surface's mark: cleared; the press goes to the next mark.
                continue
            }
            return true
        }
        return false
    }

    private func openOldestWorkspaceUnread(excludingPane excludedPane: UnreadQueueTarget?) -> Bool {
        var unreadWorkspaceIds = store.workspaceUnreadIndicatorIds
        unreadWorkspaceIds.subtract(excludedWorkspaceMarks(excludedPane))
        guard !unreadWorkspaceIds.isEmpty else { return false }

        // (cm-128.11) A mark on the pane he's on is cleared and passed: the press goes to the next mark.
        var passedOwnMarks = Set<UUID>()
        for target in windows.orderedTargetsForUnreadJump {
            for workspaceId in target.workspaceIds where unreadWorkspaceIds.contains(workspaceId) {
                switch openWorkspaceUnread(workspaceId: workspaceId, in: target) {
                case .stopped: return true
                case .passedOwnPane: passedOwnMarks.insert(workspaceId)
                case .failed: break
                }
            }
        }
        unreadWorkspaceIds.subtract(passedOwnMarks)

        // The legacy fallback used the active tab manager's first unread
        // workspace, which is NOT necessarily in the window-context registry:
        // during early startup / VM timing the registry lags behind model init,
        // so `orderedTargetsForUnreadJump` can be empty while the active manager
        // already owns the unread workspace. Resolve it from the active manager
        // directly, mirroring the legacy `self.tabManager.tabs.first(where:)`.
        guard let workspaceId = windows.activeWorkspaceIdsForUnreadJump
            .first(where: { unreadWorkspaceIds.contains($0) }) else {
            return false
        }
        let panelId = unreadTargeting.preferredUnreadPanelIdForJump(workspaceId: workspaceId)
        let didOpen = openRouting.openInActiveWindowFallback(
            tabId: workspaceId,
            surfaceId: panelId,
            panelId: nil,
            notificationId: nil,
            scrollRow: nil,
            scrollTotalRows: nil,
            scrollRowSpaceRevision: nil
        )
        if didOpen {
            signalDidFocusForJumpUnread(tabId: workspaceId, surfaceId: panelId)
            clearWorkspaceUnreadAfterJump(workspaceId: workspaceId, panelId: panelId)
        }
        return didOpen
    }

    /// How a workspace-mark stop ended (cm-128.11).
    private enum WorkspaceMarkOutcome { case stopped, passedOwnPane, failed }

    /// Opens one workspace mark; reports whether it was the pane he's on, which the walk passes (cm-128.11).
    private func openWorkspaceUnread(workspaceId: UUID, in target: MainWindowTarget) -> WorkspaceMarkOutcome {
        let panelId = unreadTargeting.preferredUnreadPanelIdForJump(workspaceId: workspaceId)
        let hesHere = panelId.map { isFrontmostFocusedPane(.workspace(tabId: workspaceId, surfaceId: $0)) } ?? false
        let didOpen = openRouting.openInWindow(
            windowId: target.windowId,
            tabId: workspaceId,
            surfaceId: panelId,
            panelId: nil,
            notificationId: nil,
            scrollRow: nil,
            scrollTotalRows: nil,
            scrollRowSpaceRevision: nil
        )
        if didOpen {
            signalDidFocusForJumpUnread(tabId: workspaceId, surfaceId: panelId)
            clearWorkspaceUnreadAfterJump(workspaceId: workspaceId, panelId: panelId)
        }
        guard didOpen else { return .failed }
        if hesHere { return .passedOwnPane }
        return .stopped
    }

    private func clearWorkspaceUnreadAfterJump(workspaceId: UUID, panelId: UUID?) {
        if let panelId,
           unreadTargeting.shouldTriggerManualUnreadJumpFlash(workspaceId: workspaceId, panelId: panelId) {
            unreadTargeting.triggerUnreadIndicatorDismissFlash(workspaceId: workspaceId, panelId: panelId)
        }
        unreadTargeting.clearUnreadAfterJump(workspaceId: workspaceId, panelId: panelId)
    }

    // MARK: Open

    /// Opens a single notification, returning whether it opened. Click-action
    /// notifications run their side effect; the rest focus their surface.
    /// Mirrors `AppDelegate.openTerminalNotification`.
    @discardableResult
    public func openNotification(_ notification: NotificationNavSnapshot) -> Bool {
        if notification.hasClickAction {
            // A click action exists; resolve and perform it via the router.
            // The router returns `false` when the action cannot be resolved or
            // performed, matching the legacy `performTerminalNotificationClickAction`.
            return openNotificationViaClickRouting(notification)
        }
        return open(
            tabId: notification.tabId,
            surfaceId: notification.surfaceId,
            panelId: notification.panelId,
            retargetsToLiveSurfaceOwner: notification.retargetsToLiveSurfaceOwner,
            notificationId: notification.id,
            scrollRow: notification.scrollRow,
            scrollTotalRows: notification.scrollTotalRows,
            scrollRowSpaceRevision: notification.scrollRowSpaceRevision
        )
    }

    /// Opens a notification response from the OS notification center by first
    /// resolving the stored notification snapshot. This preserves panel and
    /// scroll context that is app-local and not serialized into `userInfo`.
    ///
    /// - Parameters:
    ///   - id: Stable notification id used to find the stored snapshot.
    ///   - fallbackTabId: Workspace id from the delivered OS notification.
    ///   - fallbackSurfaceId: Surface id from the delivered OS notification.
    ///   - fallbackRetargetsToLiveSurfaceOwner: Whether a missing stored
    ///     notification may follow its surface into another workspace.
    @discardableResult
    public func openNotification(
        id: UUID,
        fallbackTabId: UUID,
        fallbackSurfaceId: UUID?,
        fallbackRetargetsToLiveSurfaceOwner: Bool = true
    ) -> Bool {
        if let notification = store.orderedNotifications.first(where: { $0.id == id }) {
            return openNotification(notification)
        }
        return open(
            tabId: fallbackTabId,
            surfaceId: fallbackSurfaceId,
            panelId: nil,
            retargetsToLiveSurfaceOwner: fallbackRetargetsToLiveSurfaceOwner,
            notificationId: id,
            scrollRow: nil,
            scrollTotalRows: nil
        )
    }

    private func openNotificationViaClickRouting(_ notification: NotificationNavSnapshot) -> Bool {
        guard let action = notification.clickAction else { return false }
        let didPerform = clickRouting.perform(action)
        if didPerform {
            store.markRead(id: notification.id)
        }
        return didPerform
    }

    /// Focuses `tabId`/`surfaceId`, marking `notificationId` read on success.
    /// Routes to the owning registered window, falling back to the active window
    /// when no context owns the tab. Mirrors `AppDelegate.openNotification`
    /// (the routing decision and its `#if DEBUG` recorders live behind the seam).
    @discardableResult
    public func open(tabId: UUID, surfaceId: UUID?, notificationId: UUID?) -> Bool {
        open(
            tabId: tabId,
            surfaceId: surfaceId,
            panelId: nil,
            notificationId: notificationId,
            scrollRow: nil,
            scrollTotalRows: nil,
            scrollRowSpaceRevision: nil
        )
    }

    /// Focuses `tabId`/`surfaceId`, marks `notificationId` read on success, and
    /// optionally restores terminal scrollback context.
    ///
    /// - Parameters:
    ///   - tabId: Workspace id that owns the notification.
    ///   - surfaceId: Surface id to focus when the notification is surface-scoped.
    ///   - panelId: App-target terminal panel id used only to restore scroll
    ///     context when it differs from, or is more precise than, `surfaceId`.
    ///   - retargetsToLiveSurfaceOwner: Whether the app-side route may follow a
    ///     moved surface into its current owning workspace.
    ///   - notificationId: Notification id to mark read after focus succeeds.
    ///   - scrollRow: Bottom-relative terminal scrollback row captured when the
    ///     notification was recorded.
    ///   - scrollTotalRows: Total terminal scrollback rows at capture time. The
    ///     app-side router uses this to adjust `scrollRow` for output appended
    ///     after the notification was recorded.
    @discardableResult
    public func open(
        tabId: UUID,
        surfaceId: UUID?,
        panelId: UUID?,
        retargetsToLiveSurfaceOwner: Bool = true,
        notificationId: UUID?,
        scrollRow: Int?,
        scrollTotalRows: Int?,
        scrollRowSpaceRevision: UInt64? = nil
    ) -> Bool {
        openRouting.openRouted(
            tabId: tabId,
            surfaceId: surfaceId,
            panelId: panelId,
            retargetsToLiveSurfaceOwner: retargetsToLiveSurfaceOwner,
            notificationId: notificationId,
            scrollRow: scrollRow,
            scrollTotalRows: scrollTotalRows,
            scrollRowSpaceRevision: scrollRowSpaceRevision
        )
    }

    /// Performs a terminal notification click action through the injected click
    /// routing seam. Used by ``NotificationDeliveryCoordinator`` for tapped OS
    /// notifications that carry click-action userInfo.
    @discardableResult
    public func performClickAction(_ action: NotificationNavClickAction) -> Bool {
        clickRouting.perform(action)
    }

    /// Marks a terminal notification read through the injected store seam. Used
    /// by ``NotificationDeliveryCoordinator`` for dismissed OS notifications and
    /// successfully performed click actions.
    public func markNotificationRead(id: UUID) {
        store.markRead(id: id)
    }

    // MARK: Titles

    /// The workspace's title. Mirrors `AppDelegate.tabTitle(for:)`.
    public func tabTitle(forTabId tabId: UUID) -> String? {
        openRouting.tabTitle(forTabId: tabId)
    }

    // MARK: Helpers

    private func signalDidFocusForJumpUnread(tabId: UUID, surfaceId: UUID?) {
        onDidFocusForJumpUnread?(tabId, surfaceId)
    }
}
