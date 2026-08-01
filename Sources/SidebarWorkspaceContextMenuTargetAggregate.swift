import CmuxCore
import Foundation

/// Shared context-menu facts derived from a target workspace selection.
///
/// The sidebar computes the selected-set aggregate once above `LazyVStack`.
/// Selected rows reuse this immutable value instead of repeating remote,
/// grouping, unread, and notification aggregation during row realization.
struct SidebarWorkspaceContextMenuTargetAggregate: Equatable {
    let targetWorkspaceIds: [UUID]
    let remoteTargetWorkspaceIds: [UUID]
    let allRemoteTargetsConnecting: Bool
    let allRemoteTargetsDisconnected: Bool
    let eligibleGroupTargetIds: [UUID]
    let allEligibleTargetsGroupId: UUID?
    let hasGroupedEligibleTarget: Bool
    let canMarkRead: Bool
    let canMarkUnread: Bool
    let hasLatestNotification: Bool
    let notifications: [TerminalNotification]
    /// Each target workspace's assigned color, `nil` where a workspace has none.
    ///
    /// The workspace color submenu derives on/off/mixed from this. Both menu builders
    /// previously gated on the *clicked* workspace while acting on `targetWorkspaceIds`,
    /// so no multi-target color snapshot existed and a checkmark could not be truthful
    /// for a multi-selection.
    ///
    /// Aggregated here, above the `LazyVStack`, so rows never read a store to draw state.
    let targetColorHexes: [String?]

    @MainActor
    init(
        targetWorkspaceIds: [UUID],
        workspaceRowsById: [UUID: SidebarWorkspaceRowInput],
        anchorWorkspaceIds: Set<UUID>,
        notificationIndex: SidebarWorkspaceNotificationIndex
    ) {
        self.targetWorkspaceIds = targetWorkspaceIds
        remoteTargetWorkspaceIds = targetWorkspaceIds.filter {
            workspaceRowsById[$0]?.isRemoteContextMenuEligible == true
        }
        allRemoteTargetsConnecting = !remoteTargetWorkspaceIds.isEmpty
            && remoteTargetWorkspaceIds.allSatisfy {
                guard let state = workspaceRowsById[$0]?.remoteConnectionState else { return false }
                return state == .connecting || state == .reconnecting
            }
        allRemoteTargetsDisconnected = !remoteTargetWorkspaceIds.isEmpty
            && remoteTargetWorkspaceIds.allSatisfy {
                workspaceRowsById[$0]?.remoteConnectionState == .disconnected
            }
        eligibleGroupTargetIds = targetWorkspaceIds.filter {
            !anchorWorkspaceIds.contains($0) && workspaceRowsById[$0] != nil
        }
        let eligibleGroupIds = eligibleGroupTargetIds.map { workspaceRowsById[$0]?.groupId }
        allEligibleTargetsGroupId = Self.commonGroupId(eligibleGroupIds)
        hasGroupedEligibleTarget = eligibleGroupTargetIds.contains {
            workspaceRowsById[$0]?.groupId != nil
        }
        canMarkRead = targetWorkspaceIds.contains {
            (workspaceRowsById[$0]?.unreadCount ?? 0) > 0
        }
        canMarkUnread = targetWorkspaceIds.contains {
            (workspaceRowsById[$0]?.unreadCount ?? 0) == 0
        }
        hasLatestNotification = notificationIndex.hasNotification(
            workspaceIds: targetWorkspaceIds
        )
        notifications = notificationIndex.contextMenuNotifications(
            workspaceIds: targetWorkspaceIds
        )
        // `compactMap` on the row, then `map` the color: a target we cannot resolve
        // contributes nothing, while a resolved-but-uncolored one contributes `nil`.
        // Flattening those two cases together would make a fully-coloured selection
        // report No Color as mixed.
        targetColorHexes = targetWorkspaceIds.compactMap { id in
            workspaceRowsById[id].map(\.workspace.customColorHex)
        }
    }

    private static func commonGroupId(_ groupIds: [UUID?]) -> UUID? {
        guard let first = groupIds.first,
              groupIds.allSatisfy({ $0 == first }) else {
            return nil
        }
        return first
    }
}
