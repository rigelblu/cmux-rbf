import AppKit
import CmuxNotifications
import CmuxControlSocket
import CmuxSettings
import CmuxWorkspaces
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct TerminalNotificationStoreBadgeTests {
    enum Mark: CaseIterable, Sendable { case workspace, dockSurface, pane, restored }

    @Test(arguments: Mark.allCases, [0, 2])
    func numbersCountNewsWhileMarksKeepUnreadActions(_ mark: Mark, _ news: Int) {
        let store = TerminalNotificationStore.shared
        let workspace = UUID()
        store.replaceNotificationsForTesting((0..<news).map { _ in Self.notification(workspace) })
        defer { store.replaceNotificationsForTesting([]) }
        Self.mark(mark, workspace: workspace, store: store)

        #expect(store.unreadCount(forTabId: workspace) == news + 1, "Legacy count includes one mark")
        #expect(store.workspaceIsUnread(forTabId: workspace))
        #expect(store.canMarkWorkspaceRead(forTabIds: [workspace]))
        #expect(!store.canMarkWorkspaceUnread(forTabIds: [workspace]))
        #expect(store.sidebarUnread.snapshot.workspaceIsUnread(forWorkspaceId: workspace), "Menus retain every mark")
        #expect(store.sidebarUnread.snapshot.summary(forWorkspaceId: workspace).markedUnread)
        #expect(store.sidebarUnread.snapshot.unreadCount(forWorkspaceId: workspace) == news, "Row number counts news only")
        #expect(store.unreadCount == news, "Dock total counts news only")
        #expect(store.sidebarUnread.snapshot.totalUnreadCount == news, "Titlebar total counts news only")
        #expect(store.notificationMenuSnapshot.unreadCount == news, "Popover and menu bar count news only")
        #expect(store.notificationMenuSnapshot.hasNotifications, "Marks keep today's view and Clear All available")
        #expect(TerminalNotificationStore.dockBadgeLabel(unreadCount: store.unreadCount, isEnabled: true) == (news == 0 ? nil : "\(news)"))
        if news == 0 {
            #expect(store.notificationMenuSnapshot.stateHintTitle == String(localized: "statusMenu.noUnread", defaultValue: "No unread notifications"))
        }
    }

    @Test(arguments: [SidebarStatusHeaderKind.statusGroup("parked"), .statusesArea, .workspacesArea, .pinnedArea])
    func foldedHeadersCountOnlyTheirMembersNews(_ kind: SidebarStatusHeaderKind) throws {
        let store = TerminalNotificationStore.shared
        let first = UUID(), second = UUID(), outside = UUID()
        store.replaceNotificationsForTesting([Self.notification(outside)])
        defer { store.replaceNotificationsForTesting([]) }
        store.setPanelDerivedUnread(true, forTabId: first)
        store.restoreUnreadIndicator(forTabId: second)
        let config = VerticalTabsSidebar.statusHeaderConfiguration(
            kind: kind, presentation: .init(name: "Parked", tintHex: nil, glyph: nil, behavesAs: .todo),
            memberCount: 2, memberIds: [first, second],
            folds: .init(areaCollapsed: true, collapsedStatusIds: ["parked"], workspacesCollapsed: true, pinnedCollapsed: true),
            environment: .init(colorScheme: .light, globalFontMagnificationPercent: 100, lazyContractProbe: .init()),
            onToggle: {}, onFocusAnchor: { _ in }
        )
        let rebuild = try #require(config.appKitGroupHeaderUnreadRebuild)
        let onlyMarks = rebuild(store.sidebarUnread.snapshot)
        #expect(onlyMarks.anchorUnreadCount == 0, "Two marks are no news; outside news is excluded")
        #expect(onlyMarks.anchorMarkedUnread, "A folded header retains its members' mark")

        store.replaceNotificationsForTesting([Self.notification(first), Self.notification(first), Self.notification(outside)])
        store.setPanelDerivedUnread(true, forTabId: first)
        store.restoreUnreadIndicator(forTabId: second)
        #expect(rebuild(store.sidebarUnread.snapshot).anchorUnreadCount == 2, "News takes precedence over members' marks")
    }

    @Test(arguments: [SidebarIndicatorPosition.leading, .trailing])
    func markKeepsTheNumbersSlotAndOtherAgentMarks(_ position: SidebarIndicatorPosition) {
        let dot = SidebarWorkspaceSlotResolution.resolve(showsHand: true, showsSpinner: true, unreadCount: 0,
            markedUnread: true, loadingSpinnerPosition: position, notificationBadgePosition: position)
        let number = SidebarWorkspaceSlotResolution.resolve(showsHand: true, showsSpinner: true, unreadCount: 2,
            loadingSpinnerPosition: position, notificationBadgePosition: position)
        #expect(dot == number)
        #expect(dot.showsHand)
        #expect(position == .leading ? dot.leading == .badge : dot.trailing == .badge)
    }

    @Test func foldedWorkspaceGroupDotUsesItsOwnProjectedBadgeMembers() throws {
        let store = TerminalNotificationStore.shared
        let marked = UUID()
        store.replaceNotificationsForTesting([])
        defer { store.replaceNotificationsForTesting([]) }
        store.setPanelDerivedUnread(true, forTabId: marked)
        let parent = WorkspaceGroup(id: UUID(), name: "Parent", isCollapsed: true, isPinned: false,
            anchorWorkspaceId: UUID(), customColor: nil, iconSymbol: nil)
        var child = WorkspaceGroup(id: UUID(), name: "Child", isCollapsed: true, isPinned: false,
            anchorWorkspaceId: marked, customColor: nil, iconSymbol: nil, parentGroupId: parent.id)
        child.statusId = "parked"
        let groups = WorkspaceGroupStatusProjection(groups: [parent, child],
            workspaces: [.init(id: marked, groupId: child.id, isPinned: false)],
            list: .init(entries: [.init(id: "parked", name: "Parked", extends: .todo)], source: .file))
        let projection = WorkspaceStatusGroupProjection(groups: [.init(statusId: "parked", memberWorkspaceIds: [])],
            workspaceGroups: groups)
        let snapshot = store.sidebarUnread.snapshot
        let ordinary = VerticalTabsSidebar.foldedGroupBadgeWorkspaceIds(group: parent,
            memberWorkspaceIds: [marked], projection: nil, tabs: [], groups: [parent, child])
        #expect(snapshot.badgeSummary(forWorkspaceIds: ordinary).markedUnread)
        let projected = VerticalTabsSidebar.foldedGroupBadgeWorkspaceIds(group: parent,
            memberWorkspaceIds: [marked], projection: projection, tabs: [], groups: [parent, child])
        #expect(!snapshot.badgeSummary(forWorkspaceIds: projected).markedUnread)
        let statusMembers = projection.displayMemberWorkspaceIds(for: "parked")
        let configuration = VerticalTabsSidebar.statusHeaderConfiguration(kind: .statusGroup("parked"),
            presentation: .init(name: "Parked", tintHex: nil, glyph: nil, behavesAs: .todo),
            memberCount: statusMembers.count, memberIds: statusMembers,
            folds: .init(collapsedStatusIds: ["parked"]),
            environment: .init(colorScheme: .light, globalFontMagnificationPercent: 100, lazyContractProbe: .init()),
            onToggle: {}, onFocusAnchor: { _ in })
        let rebuild = try #require(configuration.appKitGroupHeaderUnreadRebuild)
        #expect(rebuild(snapshot).anchorMarkedUnread)
    }

    @Test(arguments: [false, true], ["#FFFFFF", "#777777", "#555555", "#111111"])
    func dotContrastSurvivesPixelRounding(_ selected: Bool, _ hex: String) throws {
        let fill = try #require(NSColor(hex: hex))
        let palette = SidebarWorkspaceRowVisualPalette(isActive: selected, isMultiSelected: false,
            isHovered: false, isEditing: false, customColorHex: nil, colorScheme: hex == "#FFFFFF" ? .light : .dark,
            selectionColorHex: hex, notificationBadgeColorHex: nil, attentionTaskStatus: nil)
        let mark = palette.unreadMarkColor(sidebarStandIn: fill)
        let pixel = Self.pixel(cmuxCompositedNSColor(mark, over: fill))
        #expect(cmuxContrastRatio(foreground: pixel, background: Self.pixel(fill)) >= 3)
        if selected {
            let rgb = try #require(mark.usingColorSpace(.sRGB))
            let primary = try #require(palette.primaryTextColor.usingColorSpace(.sRGB))
            #expect(rgb.redComponent == primary.redComponent)
            #expect(rgb.greenComponent == primary.greenComponent)
            #expect(rgb.blueComponent == primary.blueComponent)
        }
    }

    @Test(arguments: [CGFloat(1), CGFloat(2)])
    func bothRenderersDrawTheScaledSixPointDot(_ scale: CGFloat) throws {
        let side = 16 * scale
        let badge = SidebarRowUnreadBadgeView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        badge.configure(count: 0, markedUnread: true, markColor: .white,
            markDiameter: SidebarWorkspaceSlotResolution.unreadMarkDiameter(fontScale: scale),
            fillColor: .red, textColor: .black, font: .systemFont(ofSize: 9))
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        badge.draw(badge.bounds)
        NSGraphicsContext.restoreGraphicsState()
        Self.expectDot(bitmap, diameter: Int(6 * scale))

        let renderer = ImageRenderer(content: SidebarWorkspaceUnreadBadge(unreadCount: 0, markedUnread: true,
            markColor: .white, side: side, font: .system(size: 9), fillColor: .red, textColor: .black))
        renderer.scale = 1
        let image = try #require(renderer.nsImage)
        let data = try #require(image.tiffRepresentation)
        Self.expectDot(try #require(NSBitmapImageRep(data: data)), diameter: Int(6 * scale))
    }

    @Test func appKitRowKeepsTheMarkAtFullStrengthOnDone() throws {
        let snapshot = SidebarWorkspaceSnapshotRefreshPolicyTests.snapshot(taskStatus: .done)
        var model = SidebarAppKitRowCellTests.makeModel(snapshot: snapshot)
        model.markedUnread = true
        let cell = SidebarAppKitRowCellTests.configuredCell(model: model)
        _ = cell.layoutContent(model: model, width: 420, apply: true)
        let badge = try #require([cell.leadingBadgeForTesting, cell.trailingBadgeForTesting].first { !$0.isHidden })
        #expect(badge.superview === cell)
        #expect(badge.alphaValue == 1)
        #expect(badge.frame.width == 16 * model.fontScale)
    }

    @Test func extensionSnapshotGetsTheStoreMarkWithoutChangingTheLegacyCount() throws {
        let store = TerminalNotificationStore.shared
        let controller = TerminalController.shared
        let previous = controller.tabManager
        let manager = TabManager(autoWelcomeIfNeeded: false)
        controller.tabManager = manager
        store.replaceNotificationsForTesting([])
        defer {
            controller.tabManager = previous
            store.replaceNotificationsForTesting([])
        }
        let workspace = try #require(manager.selectedWorkspace)
        store.markUnread(forTabId: workspace.id)
        let snapshot = try #require(controller.controlExtensionSidebarSnapshot(routing: .init(
            hasWindowIDParam: false, windowID: nil, groupID: nil, workspaceID: nil, surfaceID: nil, paneID: nil)))
        let row = try #require(snapshot.workspaces.first { $0.workspaceID == workspace.id })
        #expect(row.unreadCount == 0)
        #expect(row.markedUnread)
        #expect(store.unreadCount(forTabId: workspace.id) == 1)
    }

    @Test func markOnlyRowMenuKeepsReadEnabled() throws {
        let store = TerminalNotificationStore.shared
        let workspace = UUID()
        let suite = "cmux.badge.menu.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        store.replaceNotificationsForTesting([])
        defer {
            store.replaceNotificationsForTesting([])
            defaults.removePersistentDomain(forName: suite)
        }
        store.markUnread(forTabId: workspace)
        let summary = store.sidebarUnread.snapshot.summary(forWorkspaceId: workspace)
        var input = SidebarWorkspaceContextMenuTargetAggregateTests.rowInput(workspaceId: workspace, groupId: nil,
            unreadCount: summary.unreadCount, isMultiSelected: false, isRemote: false, remoteState: .connected,
            settings: SidebarTabItemSettingsSnapshot(defaults: defaults))
        input.markedUnread = summary.markedUnread
        let menu = SidebarWorkspaceContextMenuTargetAggregate(targetWorkspaceIds: [workspace],
            workspaceRowsById: [workspace: input], anchorWorkspaceIds: [],
            notificationIndex: SidebarWorkspaceNotificationIndex(notifications: []))
        #expect(menu.canMarkRead)
        #expect(!menu.canMarkUnread)
        #expect(input.unreadCount == 0)
    }

    @Test func phoneRefreshSignatureKeepsMarksEvenWithUnreadNews() throws {
        let store = TerminalNotificationStore.shared
        let workspace = Workspace()
        store.replaceNotificationsForTesting([Self.notification(workspace.id), Self.notification(workspace.id)])
        defer { store.replaceNotificationsForTesting([]) }
        let before = MobileWorkspaceListObserver.previewSignatures(for: [workspace], unreadSnapshot: store.sidebarUnread.snapshot)
        store.markUnread(forTabId: workspace.id)
        let after = MobileWorkspaceListObserver.previewSignatures(for: [workspace], unreadSnapshot: store.sidebarUnread.snapshot)
        #expect(before[workspace.id] != after[workspace.id])
        #expect(store.unreadCount(forTabId: workspace.id) == 3)
        #expect(store.sidebarUnread.snapshot.unreadCount(forWorkspaceId: workspace.id) == 2)
    }

    @Test func clearAllClearsMarksWithoutLeavingNews() {
        let store = TerminalNotificationStore.shared
        store.replaceNotificationsForTesting([])
        defer { store.replaceNotificationsForTesting([]) }
        let workspaces = Mark.allCases.map { _ in UUID() }
        for (mark, workspace) in zip(Mark.allCases, workspaces) {
            Self.mark(mark, workspace: workspace, store: store)
        }
        store.clearAll()
        #expect(store.unreadCount == 0)
        #expect(!store.notificationMenuSnapshot.hasNotifications)
        #expect(workspaces.allSatisfy { !store.workspaceIsUnread(forTabId: $0) })
    }

    private static func mark(_ mark: Mark, workspace: UUID, store: TerminalNotificationStore) {
        switch mark {
        case .workspace: store.markUnread(forTabId: workspace)
        case .dockSurface: store.markWindowDockSurfaceUnread(windowId: workspace, surfaceId: UUID())
        case .pane: store.setPanelDerivedUnread(true, forTabId: workspace)
        case .restored: store.restoreUnreadIndicator(forTabId: workspace)
        }
    }

    private static func notification(_ workspace: UUID) -> TerminalNotification {
        TerminalNotification(id: UUID(), tabId: workspace, surfaceId: nil, title: "Finished", subtitle: "cm-128",
            body: "News", createdAt: Date(timeIntervalSince1970: 100), isRead: false)
    }

    private static func pixel(_ color: NSColor) -> NSColor {
        let rgb = color.usingColorSpace(.sRGB)!
        return NSColor(srgbRed: (rgb.redComponent * 255).rounded() / 255,
            green: (rgb.greenComponent * 255).rounded() / 255,
            blue: (rgb.blueComponent * 255).rounded() / 255, alpha: 1)
    }

    private static func expectDot(_ bitmap: NSBitmapImageRep, diameter: Int) {
        var xs: [Int] = [], ys: [Int] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                xs.append(x)
                ys.append(y)
            }
        }
        #expect(!xs.isEmpty, "A mark actually rendered")
        #expect((xs.max() ?? -1) - (xs.min() ?? 0) + 1 == diameter)
        #expect((ys.max() ?? -1) - (ys.min() ?? 0) + 1 == diameter)
        #expect((xs.min() ?? 0) + (xs.max() ?? 0) == bitmap.pixelsWide - 1, "The dot stays centred")
        #expect((ys.min() ?? 0) + (ys.max() ?? 0) == bitmap.pixelsHigh - 1)
    }
}
