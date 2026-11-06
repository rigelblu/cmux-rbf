public import Foundation

/// The focused-notification mark state machine: toggling the focused
/// notification's unread state, and sending its pane to the back of the unread
/// queue before jumping to the next oldest unread (cm-128.11). Lifted verbatim from `AppDelegate`'s focused-mark
/// cluster (`toggleFocusedNotificationUnread`,
/// `markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread`, the
/// `markFocusedNotificationAsOldestUnread` overloads), with every app-target
/// collaborator (`TerminalNotificationStore`, `Workspace`, the first-responder
/// `focusedTerminalShortcutContext`, the window contexts) reached through
/// ``FocusedNotificationResolving``.
///
/// A Coordinator-adjacent flow helper (CONVENTIONS §2): it sequences the
/// focused-mark flows and owns no state. The jump step is delegated back to the
/// owning ``NotificationNavigationCoordinator`` through an injected closure so
/// this type carries no jump logic of its own. `@MainActor` for parity with the
/// resolver and the legacy main-actor path.
@MainActor
public final class FocusedNotificationMarker {
    private let resolver: any FocusedNotificationResolving
    /// Delegates to `NotificationNavigationCoordinator.jumpToOldestUnread`,
    /// returning the opened notification id (or `nil`). Injected so the marker
    /// does not depend on the coordinator's other seams. (cm-128.11) One pane
    /// exclusion in place of the notification, workspace and Dock parameters.
    private let jumpToOldestUnread: (_ excludingPane: UnreadQueueTarget?) -> UUID?

    /// Creates a focused-notification marker driven by the injected resolver
    /// and jump closure.
    public init(
        resolver: any FocusedNotificationResolving,
        jumpToOldestUnread: @escaping (_ excludingPane: UnreadQueueTarget?) -> UUID?
    ) {
        self.resolver = resolver
        self.jumpToOldestUnread = jumpToOldestUnread
    }

    /// Toggles the focused notification's unread state, returning whether
    /// anything was toggled. Mirrors `toggleFocusedNotificationUnread`.
    @discardableResult
    public func toggleFocusedNotificationUnread(preferredWindowToken: AnyObject? = nil) -> Bool {
        // Mirrors `guard let notificationStore, let target = focusedNotificationTarget(...)`.
        guard resolver.hasNotificationStore,
              let target = resolver.focusedTarget(preferredWindowToken: preferredWindowToken) else {
            return false
        }
        switch target {
        case .windowDock(let dockTarget):
            if resolver.windowDockSurfaceIsUnread(dockTarget) {
                resolver.clearWindowDockSurfaceUnread(dockTarget)
            } else {
                resolver.markWindowDockSurfaceUnread(dockTarget)
            }
            return true
        case .workspace(let tabId, let surfaceId):
            return toggleWorkspaceNotificationUnread(tabId: tabId, surfaceId: surfaceId)
        }
    }

    private func toggleWorkspaceNotificationUnread(tabId: UUID, surfaceId: UUID?) -> Bool {
        if let panel = resolver.focusedPanel(forTabId: tabId, surfaceId: surfaceId) {
            let focusedPanelHasRestoredUnread = resolver.panelHasRestoredUnread(panel)
            let hasWorkspaceOnlyRestoredUnread =
                resolver.storeHasRestoredUnread(forTabId: tabId) &&
                !focusedPanelHasRestoredUnread &&
                !resolver.workspaceHasContributingRestoredUnread(panel)
            if resolver.hasVisibleNotificationIndicator(forTabId: tabId, surfaceId: nil) ||
                hasWorkspaceOnlyRestoredUnread {
                resolver.storeMarkRead(forTabId: tabId)
                return true
            }
            let hasWorkspaceManualUnreadOnPanel =
                resolver.storeHasManualUnread(forTabId: tabId) &&
                resolver.panelIsRepresentativeForWorkspaceManualUnread(panel)
            let isPanelUnread =
                resolver.panelIsManualUnread(panel) ||
                focusedPanelHasRestoredUnread ||
                resolver.hasVisibleNotificationIndicator(forTabId: tabId, surfaceId: panel.panelId) ||
                hasWorkspaceManualUnreadOnPanel
            if isPanelUnread {
                resolver.markPanelRead(panel)
                if hasWorkspaceManualUnreadOnPanel {
                    resolver.storeClearManualUnread(forTabId: tabId)
                }
                return true
            }
            resolver.markPanelUnread(panel)
            return true
        }
        if resolver.workspaceIsUnread(forTabId: tabId) {
            resolver.storeMarkRead(forTabId: tabId)
            return true
        }
        resolver.storeMarkUnread(forTabId: tabId)
        return true
    }

    /// Sends the focused pane to the back of the unread queue (Send to Back), then jumps to the next
    /// unread pane, oldest first, excluding the pane just sent back (cm-128.11, Tom grill Q74, Q95),
    /// returning the opened notification id. Mirrors
    /// `markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread`.
    @discardableResult
    public func markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread(
        preferredWindowToken: AnyObject? = nil
    ) -> UUID? {
        // (cm-128.11) The focused target is resolved here, once; `sendToBack(_:)` takes it as an argument.
        guard resolver.hasNotificationStore,
              let target = resolver.focusedTarget(preferredWindowToken: preferredWindowToken) else {
            return nil
        }
        return jumpToOldestUnread(sendToBack(target))
    }

    /// Sends one explicit target to the back of the unread queue (cm-128.11): the step ⌘⌃U runs on the
    /// target it resolved, split out of the focused-target lookup so another caller can pass its own.
    /// - Returns: the pane the follow-on walk must skip: the one just sent back.
    func sendToBack(_ target: UnreadQueueTarget) -> UnreadQueueTarget {
        switch target {
        case .windowDock:
            // The store marks a Dock surface with no notification itself, and moves an existing mark to the end.
            _ = resolver.sendToBack(target)
            return target
        case .workspace(let tabId, let surfaceId):
            if resolver.sendToBack(target) { return target }
            return markPaneOrWorkspaceUnread(tabId: tabId, surfaceId: surfaceId)
        }
    }

    /// The pane had no notification: it gets his mark, behind all news (cm-128.11: unchanged logic).
    /// - Returns: the pane to exclude from the follow-on walk: the marked panel, by the id its mark is
    ///   kept under, which can differ from the focused surface id.
    private func markPaneOrWorkspaceUnread(tabId: UUID, surfaceId: UUID?) -> UnreadQueueTarget {
        if let panel = resolver.focusedPanel(forTabId: tabId, surfaceId: surfaceId) {
            let panelAlreadyUnread =
                resolver.panelIsManualUnread(panel) ||
                resolver.panelHasRestoredUnread(panel) ||
                resolver.hasVisibleNotificationIndicator(forTabId: tabId, surfaceId: panel.panelId)
            let hasWorkspaceOnlyRestoredUnread =
                resolver.storeHasRestoredUnread(forTabId: tabId) &&
                !resolver.workspaceHasContributingRestoredUnread(panel)
            if !panelAlreadyUnread &&
                !resolver.storeHasManualUnread(forTabId: tabId) &&
                !hasWorkspaceOnlyRestoredUnread {
                resolver.markPanelUnread(panel)
            }
            return .workspace(tabId: tabId, surfaceId: panel.panelId)
        } else if !resolver.workspaceIsUnread(forTabId: tabId) {
            resolver.storeMarkUnread(forTabId: tabId)
        }
        return .workspace(tabId: tabId, surfaceId: nil)
    }
}
