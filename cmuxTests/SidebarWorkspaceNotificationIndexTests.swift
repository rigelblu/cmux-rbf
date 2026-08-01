import Foundation
import CmuxCore
import CmuxWorkspaces
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct SidebarWorkspaceNotificationIndexTests {
    @Test
    func presenceUsesWorkspaceBuckets() {
        let firstWorkspaceId = UUID()
        let secondWorkspaceId = UUID()
        let missingWorkspaceId = UUID()
        let index = SidebarWorkspaceNotificationIndex(notifications: [
            Self.notification(workspaceId: firstWorkspaceId, timestamp: 1),
            Self.notification(workspaceId: secondWorkspaceId, timestamp: 2)
        ])

        #expect(index.hasNotification(workspaceId: firstWorkspaceId))
        #expect(index.hasNotification(workspaceId: secondWorkspaceId))
        #expect(!index.hasNotification(workspaceId: missingWorkspaceId))
        #expect(index.hasNotification(workspaceIds: [missingWorkspaceId, secondWorkspaceId]))
        #expect(!index.hasNotification(workspaceIds: [missingWorkspaceId]))
        #expect(!index.hasNotification(workspaceIds: []))
    }

    @Test
    func contextMenuMergeIsNewestFirstAcrossWorkspaceBuckets() {
        let firstWorkspaceId = UUID()
        let secondWorkspaceId = UUID()
        let unrelatedWorkspaceId = UUID()
        let selected = [
            Self.notification(workspaceId: firstWorkspaceId, timestamp: 100),
            Self.notification(workspaceId: secondWorkspaceId, timestamp: 400),
            Self.notification(workspaceId: firstWorkspaceId, timestamp: 300),
            Self.notification(workspaceId: secondWorkspaceId, timestamp: 200)
        ]
        let index = SidebarWorkspaceNotificationIndex(notifications: [
            selected[0],
            Self.notification(workspaceId: unrelatedWorkspaceId, timestamp: 500),
            selected[1],
            selected[2],
            selected[3]
        ])
        let expected = selected.sorted(by: TerminalNotificationStore.notificationSortPrecedes)

        let actual = index.contextMenuNotifications(
            workspaceIds: [firstWorkspaceId, secondWorkspaceId, firstWorkspaceId]
        )

        #expect(actual.map(\.id) == expected.map(\.id))
    }

    @Test
    func contextMenuMergeStopsAtLimitWithoutIncludingUnrelatedBuckets() {
        let firstWorkspaceId = UUID()
        let secondWorkspaceId = UUID()
        let unrelatedWorkspaceId = UUID()
        let selected = (0 ..< 80).map { index in
            Self.notification(
                workspaceId: index.isMultiple(of: 2) ? firstWorkspaceId : secondWorkspaceId,
                timestamp: TimeInterval(index)
            )
        }
        let unrelated = (0 ..< 200).map { index in
            Self.notification(
                workspaceId: unrelatedWorkspaceId,
                timestamp: TimeInterval(1_000 + index)
            )
        }
        let notificationIndex = SidebarWorkspaceNotificationIndex(
            notifications: Array((selected + unrelated).reversed())
        )
        let expected = Array(
            selected
                .sorted(by: TerminalNotificationStore.notificationSortPrecedes)
                .prefix(SidebarWorkspaceNotificationIndex.contextMenuNotificationLimit)
        )

        let actual = notificationIndex.contextMenuNotifications(
            workspaceIds: [firstWorkspaceId, secondWorkspaceId]
        )

        #expect(actual.count == SidebarWorkspaceNotificationIndex.contextMenuNotificationLimit)
        #expect(actual.map(\.id) == expected.map(\.id))
        #expect(actual.allSatisfy { $0.tabId != unrelatedWorkspaceId })
    }

    private static func notification(
        workspaceId: UUID,
        timestamp: TimeInterval
    ) -> TerminalNotification {
        TerminalNotification(
            id: UUID(),
            tabId: workspaceId,
            surfaceId: nil,
            title: "notification",
            subtitle: "",
            body: "",
            createdAt: Date(timeIntervalSince1970: timestamp),
            isRead: false
        )
    }
}

@MainActor
@Suite
struct SidebarWorkspaceContextMenuTargetAggregateTests {
    @Test
    func selectedRowsReuseCorrectParentAggregateAndSingleRowsStayScoped() throws {
        let groupId = UUID()
        let connectingWorkspaceId = UUID()
        let disconnectedWorkspaceId = UUID()
        let anchorWorkspaceId = disconnectedWorkspaceId
        let singleWorkspaceId = UUID()
        let suiteName = "SidebarWorkspaceContextMenuTargetAggregateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)
        let rows = [
            connectingWorkspaceId: Self.rowInput(
                workspaceId: connectingWorkspaceId,
                groupId: groupId,
                unreadCount: 2,
                isMultiSelected: true,
                isRemote: true,
                remoteState: .connecting,
                settings: settings
            ),
            disconnectedWorkspaceId: Self.rowInput(
                workspaceId: disconnectedWorkspaceId,
                groupId: groupId,
                unreadCount: 0,
                isMultiSelected: true,
                isRemote: true,
                remoteState: .disconnected,
                settings: settings
            ),
            singleWorkspaceId: Self.rowInput(
                workspaceId: singleWorkspaceId,
                groupId: nil,
                unreadCount: 0,
                isMultiSelected: false,
                isRemote: false,
                remoteState: .connected,
                settings: settings
            )
        ]
        let selectedNotification = Self.notification(
            workspaceId: connectingWorkspaceId,
            timestamp: 200
        )
        let singleNotification = Self.notification(
            workspaceId: singleWorkspaceId,
            timestamp: 300
        )
        let notificationIndex = SidebarWorkspaceNotificationIndex(
            notifications: [singleNotification, selectedNotification]
        )
        let list = SidebarWorkspaceRowsSnapshot(
            workspaceRowsById: rows,
            groupRowsById: [:],
            selectedContextTargetIds: [connectingWorkspaceId, disconnectedWorkspaceId],
            anchorWorkspaceIds: [anchorWorkspaceId],
            workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot(items: []),
            canCreateEmptyGroup: true,
            notificationIndex: notificationIndex
        )

        let selected = list.selectedContextMenuTargetAggregate
        #expect(selected.targetWorkspaceIds == [connectingWorkspaceId, disconnectedWorkspaceId])
        #expect(selected.remoteTargetWorkspaceIds == [connectingWorkspaceId, disconnectedWorkspaceId])
        #expect(!selected.allRemoteTargetsConnecting)
        #expect(!selected.allRemoteTargetsDisconnected)
        #expect(selected.eligibleGroupTargetIds == [connectingWorkspaceId])
        #expect(selected.allEligibleTargetsGroupId == groupId)
        #expect(selected.hasGroupedEligibleTarget)
        #expect(selected.canMarkRead)
        #expect(selected.canMarkUnread)
        #expect(selected.hasLatestNotification)
        #expect(selected.notifications.map(\.id) == [selectedNotification.id])

        let secondSelected = try #require(rows[disconnectedWorkspaceId])
        #expect(list.contextMenuTargetAggregate(for: secondSelected) == selected)

        let singleInput = try #require(rows[singleWorkspaceId])
        let single = list.contextMenuTargetAggregate(for: singleInput)
        #expect(single.targetWorkspaceIds == [singleWorkspaceId])
        #expect(single.remoteTargetWorkspaceIds.isEmpty)
        #expect(!single.canMarkRead)
        #expect(single.canMarkUnread)
        #expect(single.hasLatestNotification)
        #expect(single.notifications.map(\.id) == [singleNotification.id])
    }

    // MARK: - `cm-11.1` multi-target color snapshot

    /// The workspace color submenu can only draw a truthful checkmark if it knows every
    /// target's current color. Both builders previously gated on the clicked workspace
    /// while acting on the whole selection, so this aggregate is where that gap closes.
    @Test
    func aggregateCollectsEveryTargetColorInTargetOrder() throws {
        let teal = UUID()
        let red = UUID()
        let uncolored = UUID()
        let suiteName = "TargetColorAggregate.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)

        let rows = [
            teal: Self.rowInput(
                workspaceId: teal, groupId: nil, unreadCount: 0, isMultiSelected: true,
                isRemote: false, remoteState: .disconnected, settings: settings,
                customColorHex: "#006B6B"
            ),
            red: Self.rowInput(
                workspaceId: red, groupId: nil, unreadCount: 0, isMultiSelected: true,
                isRemote: false, remoteState: .disconnected, settings: settings,
                customColorHex: "#C0392B"
            ),
            uncolored: Self.rowInput(
                workspaceId: uncolored, groupId: nil, unreadCount: 0, isMultiSelected: true,
                isRemote: false, remoteState: .disconnected, settings: settings,
                customColorHex: nil
            ),
        ]

        let aggregate = SidebarWorkspaceContextMenuTargetAggregate(
            targetWorkspaceIds: [teal, red, uncolored],
            workspaceRowsById: rows,
            anchorWorkspaceIds: [],
            notificationIndex: SidebarWorkspaceNotificationIndex(notifications: [])
        )

        #expect(
            aggregate.targetColorHexes == ["#006B6B", "#C0392B", nil],
            "colors must line up with targetWorkspaceIds, with nil for an uncolored workspace"
        )
    }

    @Test
    func aggregateScopesColorsToItsOwnTargets() throws {
        let selected = UUID()
        let other = UUID()
        let suiteName = "TargetColorScope.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)

        let rows = [
            selected: Self.rowInput(
                workspaceId: selected, groupId: nil, unreadCount: 0, isMultiSelected: false,
                isRemote: false, remoteState: .disconnected, settings: settings,
                customColorHex: "#006B6B"
            ),
            other: Self.rowInput(
                workspaceId: other, groupId: nil, unreadCount: 0, isMultiSelected: false,
                isRemote: false, remoteState: .disconnected, settings: settings,
                customColorHex: "#C0392B"
            ),
        ]

        let aggregate = SidebarWorkspaceContextMenuTargetAggregate(
            targetWorkspaceIds: [selected],
            workspaceRowsById: rows,
            anchorWorkspaceIds: [],
            notificationIndex: SidebarWorkspaceNotificationIndex(notifications: [])
        )

        #expect(
            aggregate.targetColorHexes == ["#006B6B"],
            "a single-row menu must not inherit another workspace's color"
        )
    }

    @Test
    func aggregateOmitsTargetsWithNoKnownRow() throws {
        let known = UUID()
        let missing = UUID()
        let suiteName = "TargetColorMissing.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)

        let rows = [
            known: Self.rowInput(
                workspaceId: known, groupId: nil, unreadCount: 0, isMultiSelected: true,
                isRemote: false, remoteState: .disconnected, settings: settings,
                customColorHex: "#006B6B"
            ),
        ]

        let aggregate = SidebarWorkspaceContextMenuTargetAggregate(
            targetWorkspaceIds: [known, missing],
            workspaceRowsById: rows,
            anchorWorkspaceIds: [],
            notificationIndex: SidebarWorkspaceNotificationIndex(notifications: [])
        )

        // A workspace we cannot resolve is unknown, not uncolored. Emitting nil for it
        // would make No Color read as "mixed" for a selection that is fully colored.
        #expect(
            aggregate.targetColorHexes == ["#006B6B"],
            "an unresolvable target contributes nothing rather than a false nil"
        )
    }

    private static func rowInput(
        workspaceId: UUID,
        groupId: UUID?,
        unreadCount: Int,
        isMultiSelected: Bool,
        isRemote: Bool,
        remoteState: WorkspaceRemoteConnectionState,
        settings: SidebarTabItemSettingsSnapshot,
        customColorHex: String? = nil
    ) -> SidebarWorkspaceRowInput {
        SidebarWorkspaceRowInput(
            workspaceId: workspaceId,
            groupId: groupId,
            index: 0,
            workspaceCount: 3,
            workspace: SidebarWorkspaceSnapshotRefreshPolicyTests.snapshot(customColorHex: customColorHex),
            isActive: false,
            isMultiSelected: isMultiSelected,
            hasUserCustomTitle: false,
            hasCustomTitle: false,
            hasCustomDescription: false,
            customTitle: nil,
            workspaceShortcutDigit: nil,
            workspaceShortcutModifierSymbol: "⌘",
            canCloseWorkspace: true,
            unreadCount: unreadCount,
            latestNotificationText: nil,
            showsAgentActivity: false,
            rowSpacing: 0,
            showsModifierShortcutHints: false,
            isPointerHovering: false,
            isBeingDragged: false,
            topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false,
            isBonsplitWorkspaceDropActive: false,
            settings: settings,
            isChecklistExpanded: false,
            checklistAddFieldActivationToken: 0,
            isChecklistPopoverPresented: false,
            isRemoteContextMenuEligible: isRemote,
            remoteConnectionState: remoteState,
            contextMenuPinState: nil,
            inferredTaskStatus: .todo,
            activeTodoOverride: nil,
            isTodoStatusHidden: false
        )
    }

    private static func notification(
        workspaceId: UUID,
        timestamp: TimeInterval
    ) -> TerminalNotification {
        TerminalNotification(
            id: UUID(),
            tabId: workspaceId,
            surfaceId: nil,
            title: "notification",
            subtitle: "",
            body: "",
            createdAt: Date(timeIntervalSince1970: timestamp),
            isRead: false
        )
    }
}
