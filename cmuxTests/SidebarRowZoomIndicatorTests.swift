import AppKit
import CmuxFoundation
import CmuxSettings
import CmuxSidebar
import CmuxWorkspaces
import SwiftUI
import Testing
@testable import cmux_DEV

/// Unit and regression tests for Everything Zoom row mark scaling (cm-128.16).
/// Covers Scenarios 200–206, 211, 212.
@Suite(.serialized)
@MainActor
struct SidebarRowZoomIndicatorTests {

    // MARK: - Fixture Helpers

    static func makeSnapshot(
        title: String = "Workspace",
        unreadCount: Int = 0,
        markedUnread: Bool = false,
        showsAgentActivity: Bool = true,
        monitoringCount: Int = 0,
        waitingCount: Int = 0,
        runningCount: Int = 0,
        errorCount: Int = 0,
        hasTaskStatus: Bool = false,
        taskStatus: WorkspaceTaskStatus? = nil,
        isPinned: Bool = false,
        progress: Double? = nil,
        pullRequestStatus: SidebarPullRequestStatus? = nil
    ) -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        var agentLists = SidebarAgentStateLists()
        if waitingCount > 0 {
            agentLists.waiting = [SidebarAgentStateEntry(statusKey: "claude", displayName: "Claude Code", paneCount: waitingCount, usageLimit: false)]
        }
        if runningCount > 0 {
            agentLists.running = [SidebarAgentStateEntry(statusKey: "claude", displayName: "Claude Code", paneCount: runningCount, usageLimit: false)]
        }
        if monitoringCount > 0 {
            agentLists.monitoring = [SidebarAgentStateEntry(statusKey: "claude", displayName: "Claude Code", paneCount: monitoringCount, usageLimit: false)]
        }
        if errorCount > 0 {
            agentLists.error = [SidebarAgentStateEntry(statusKey: "claude", displayName: "Claude Code", paneCount: errorCount, usageLimit: false)]
        }

        var prRows: [SidebarWorkspaceSnapshotBuilder.PullRequestDisplay] = []
        if let prStatus = pullRequestStatus {
            prRows = [SidebarWorkspaceSnapshotBuilder.PullRequestDisplay(
                id: "PR-1",
                number: 128,
                label: "feat",
                url: URL(string: "https://github.com/manaflow-ai/cmux/pull/128")!,
                status: prStatus,
                isStale: false
            )]
        }

        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)

        let effectiveStatus = taskStatus ?? (hasTaskStatus ? .todo : nil)
        var snapshot = SidebarWorkspaceSnapshotBuilder.Snapshot(
            presentationKey: SidebarWorkspaceSnapshotFactory.presentationKey(
                settings: settings,
                showsAgentActivity: showsAgentActivity
            ),
            title: title,
            customDescription: nil,
            isPinned: isPinned,
            isMuted: false,
            customColorHex: nil,
            cloudWorkspaceLabel: nil,
            remoteWorkspaceSidebarText: nil,
            remoteConnectionStatusText: "",
            remoteStateHelpText: "",
            showsRemoteReconnectAffordance: false,
            copyableSidebarSSHError: nil,
            latestConversationMessage: nil,
            metadataEntries: [],
            metadataBlocks: [],
            latestLog: nil,
            progress: progress.map { SidebarProgressState(value: $0, label: nil) },
            compactGitBranchSummaryText: nil,
            compactDirectoryCandidates: [],
            compactBranchDirectoryCandidates: [],
            branchDirectoryLines: [],
            branchLinesContainBranch: false,
            pullRequestRows: prRows,
            listeningPorts: [],
            finderDirectoryPath: nil,
            mediaActivity: BrowserMediaActivity(),
            taskStatus: effectiveStatus,
            todoStatusMenuModel: nil,
            hasManualTaskStatus: effectiveStatus != nil,
            attentionTaskStatus: effectiveStatus,
            checklistItems: [],
            checklistCompletedCount: 0,
            checklistTotalCount: 0,
            checklistFirstUncheckedText: nil
        )
        snapshot.agentLists = agentLists
        return snapshot
    }

    static func makeModel(
        snapshot: SidebarWorkspaceSnapshotBuilder.Snapshot? = nil,
        unreadCount: Int = 0,
        markedUnread: Bool = false,
        showsAgentActivity: Bool = true,
        loadingSpinnerPosition: SidebarIndicatorPosition = .leading,
        notificationBadgePosition: SidebarIndicatorPosition = .leading,
        globalFontMagnificationPercent: Int = 100,
        sidebarFontSize: CGFloat = GhosttyConfig.defaultSidebarFontSize,
        isPinned: Bool = false,
        canClose: Bool = true,
        showsPullRequests: Bool = true
    ) -> SidebarWorkspaceRowModel {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(loadingSpinnerPosition.rawValue, forKey: "sidebarLoadingSpinnerPosition")
        defaults.set(notificationBadgePosition.rawValue, forKey: "sidebarNotificationBadgePosition")
        defaults.set(showsPullRequests, forKey: "sidebarShowPullRequest")

        let settings = SidebarTabItemSettingsSnapshot(
            defaults: defaults,
            sidebarFontSize: sidebarFontSize
        )

        let resolvedSnapshot = snapshot ?? Self.makeSnapshot(
            unreadCount: unreadCount,
            markedUnread: markedUnread,
            showsAgentActivity: showsAgentActivity,
            isPinned: isPinned
        )

        return SidebarWorkspaceRowModel(
            workspaceId: UUID(),
            index: 0,
            snapshot: resolvedSnapshot,
            settings: settings,
            isActive: false,
            isMultiSelected: false,
            hasUserCustomTitle: false,
            canCloseWorkspace: canClose,
            accessibilityWorkspaceCount: 1,
            unreadCount: unreadCount,
            markedUnread: markedUnread,
            latestNotificationText: nil,
            showsAgentActivity: showsAgentActivity,
            rowSpacing: 8,
            isBeingDragged: false,
            topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false,
            isGrouped: false,
            isColorSectionMember: false,
            isFirstRow: true,
            shortcutHintText: nil,
            showsShortcutHints: false,
            colorSchemeIsDark: true,
            globalFontMagnificationPercent: globalFontMagnificationPercent,
            isChecklistExpanded: false,
            checklistAddFieldActivationToken: 0,
            isChecklistPopoverPresented: false,
            editingChecklistItemId: nil,
            todoControlsEnabled: true,
            isMetadataExpanded: false,
            isMarkdownExpanded: false
        )
    }

    static func configuredCell(
        model: SidebarWorkspaceRowModel,
        isHovered: Bool = false
    ) -> SidebarWorkspaceRowTableCellView {
        let cell = SidebarWorkspaceRowTableCellView()
        cell.configure(
            model: model,
            actions: SidebarAppKitRowCellTests.makeActions(model: model),
            isPointerHovering: isHovered,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )
        _ = cell.layoutContent(model: model, width: 215, apply: true)
        cell.layoutSubtreeIfNeeded()
        return cell
    }

    private static func makeGroupHeaderModel(
        groupId: UUID = UUID(),
        name: String = "Group",
        fontScale: CGFloat = 1.0,
        globalFontMagnificationPercent: Int = 100,
        hasOwnWorkspace: Bool = true,
        isPinned: Bool = false,
        anchorMarkedUnread: Bool = false,
        groupStatusGlyph: SidebarWorkspaceGroupStatusGlyph? = nil
    ) -> SidebarGroupHeaderRowModel {
        var model = SidebarGroupHeaderRowModel(
            groupId: groupId,
            anchorWorkspaceId: groupId,
            name: name,
            iconSymbol: "folder",
            tintHex: "#3B82F6",
            customColorHex: nil,
            isCollapsed: false,
            isPinned: isPinned,
            isAnchorActive: false,
            isMultiSelected: false,
            multiSelectionBackgroundStyle: .clear,
            memberCount: 2,
            anchorUnreadCount: 0,
            anchorMarkedUnread: anchorMarkedUnread,
            canMarkRead: false,
            canMarkUnread: false,
            hasLatestNotifications: false,
            canMarkAllRead: false,
            canMarkAllUnread: false,
            shortcutHintText: nil,
            shortcutHintXOffset: 0,
            shortcutHintYOffset: 0,
            fontScale: fontScale,
            globalFontMagnificationPercent: globalFontMagnificationPercent,
            cwdContextMenuItems: [],
            rowSpacing: 0,
            isFirstRow: false,
            isBeingDragged: false,
            topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false,
            colorSchemeIsDark: false,
            contrastBackgroundHex: nil,
            depth: 0,
            hasOwnWorkspace: hasOwnWorkspace,
            isFoldedOverSelection: false,
            holdsGroups: false
        )
        model.groupStatusGlyph = groupStatusGlyph
        return model
    }

    // MARK: - Scenario 200: Mark Line Marks Grow With Zoom

    /// Scenario 200: at 150%, every mark-line mark grows (badge 24, glyph slot 20.5x17.5 on title line,
    /// hand/triangle/spinner/waveform 18 on mark line, glyph model fontScale 1.5). At 100%: 16, 15x13, 12, fontScale 1.
    @Test
    func markLineMarksGrowWithZoom() throws {
        // At 150%: badgeSide = 24, spinnerSide = 18, statusGlyph occupiedSize = 20.5 x 17.5
        let snapshot150 = Self.makeSnapshot(
            unreadCount: 3,
            showsAgentActivity: true,
            monitoringCount: 1,
            waitingCount: 1,
            runningCount: 1,
            errorCount: 1,
            hasTaskStatus: true
        )
        let model150 = Self.makeModel(
            snapshot: snapshot150,
            unreadCount: 3,
            globalFontMagnificationPercent: 150
        )
        let cell150 = Self.configuredCell(model: model150)

        // Leading badge: 24 x 24
        #expect(!cell150.leadingBadgeForTesting.isHidden)
        #expect(Double(cell150.leadingBadgeForTesting.frame.width) == 24.0)
        #expect(Double(cell150.leadingBadgeForTesting.frame.height) == 24.0)

        // Status glyph slot at 150%: 20.5 x 17.5
        #expect(abs(Double(cell150.statusGlyphButtonForTesting.frame.width) - 20.5) < 0.01)
        #expect(abs(Double(cell150.statusGlyphButtonForTesting.frame.height) - 17.5) < 0.01)

        // Status glyph model fontScale: 1.5
        let glyphModel150 = try #require(cell150.statusGlyphModelForTesting)
        #expect(abs(Double(glyphModel150.fontScale) - 1.5) < 0.01)

        // Hand at 150%: 18 x 18
        let hand150 = try #require(cell150.handForTesting)
        #expect(!hand150.isHidden)
        #expect(Double(hand150.frame.width) == 18.0)
        #expect(Double(hand150.frame.height) == 18.0)

        // Triangle at 150%: 18 x 18
        let triangle150 = try #require(cell150.errorTriangleForTesting)
        #expect(!triangle150.isHidden)
        #expect(Double(triangle150.frame.width) == 18.0)
        #expect(Double(triangle150.frame.height) == 18.0)

        // Mark Spinner at 150%: 18 x 18
        let spinner150 = try #require(cell150.markSpinnerForTesting)
        #expect(!spinner150.isHidden)
        #expect(Double(spinner150.frame.width) == 18.0)
        #expect(Double(spinner150.frame.height) == 18.0)

        // Waveform at 150%: 18 x 18
        let waveform150 = try #require(cell150.monitoringImageViewForTesting)
        #expect(!waveform150.isHidden)
        #expect(Double(waveform150.frame.width) == 18.0)
        #expect(Double(waveform150.frame.height) == 18.0)

        // cmux-rbf: changed on purpose (#cm-128.9)
        // Badge and marks are on the line under the title line, centered on the line within 0.5 pt
        let titleFrame150 = cell150.titleFrameForTesting
        let markLineCenterY150 = titleFrame150.maxY + 4 + 24.0 / 2 // title maxY + spacing + badgeSide/2
        #expect(abs(Double(cell150.leadingBadgeForTesting.frame.midY - markLineCenterY150)) <= 0.5)
        #expect(abs(Double(hand150.frame.midY - markLineCenterY150)) <= 0.5)

        // Controls at 100%: 16 badge, 15x13 slot, 12 symbols
        let snapshot100 = Self.makeSnapshot(
            unreadCount: 3,
            showsAgentActivity: true,
            monitoringCount: 1,
            waitingCount: 1,
            runningCount: 1,
            errorCount: 1,
            hasTaskStatus: true
        )
        let model100 = Self.makeModel(
            snapshot: snapshot100,
            unreadCount: 3,
            globalFontMagnificationPercent: 100
        )
        let cell100 = Self.configuredCell(model: model100)
        #expect(Double(cell100.leadingBadgeForTesting.frame.width) == 16.0)
        #expect(Double(cell100.leadingBadgeForTesting.frame.height) == 16.0)

        let expectedGlyphSize100 = SidebarRowTaskStatusGlyphButton.occupiedSize(fontScale: 1.0)
        #expect(abs(Double(cell100.statusGlyphButtonForTesting.frame.width - expectedGlyphSize100.width)) < 0.01)
        #expect(abs(Double(cell100.statusGlyphButtonForTesting.frame.height - expectedGlyphSize100.height)) < 0.01)

        let glyphModel100 = try #require(cell100.statusGlyphModelForTesting)
        #expect(abs(Double(glyphModel100.fontScale) - 1.0) < 0.01)

        let hand100 = try #require(cell100.handForTesting)
        #expect(Double(hand100.frame.width) == 12.0)
        let triangle100 = try #require(cell100.errorTriangleForTesting)
        #expect(Double(triangle100.frame.width) == 12.0)
        let spinner100 = try #require(cell100.markSpinnerForTesting)
        #expect(Double(spinner100.frame.width) == 12.0)
        let waveform100 = try #require(cell100.monitoringImageViewForTesting)
        #expect(Double(waveform100.frame.width) == 12.0)
    }

    // MARK: - Scenario 201: Close Button And Trailing Slot Grow

    /// Scenario 201: close button and trailing slot grow with zoom (close button 24x24,
    /// trailing badge 24, trailing spinner 18 at 150%). Title stops at trailing reserve.
    @Test
    func closeButtonAndTrailingSlotGrowWithZoom() throws {
        let snapshot150 = Self.makeSnapshot(
            unreadCount: 2,
            showsAgentActivity: true,
            runningCount: 1
        )
        let model150 = Self.makeModel(
            snapshot: snapshot150,
            unreadCount: 2,
            loadingSpinnerPosition: .trailing,
            notificationBadgePosition: .trailing,
            globalFontMagnificationPercent: 150,
            canClose: true
        )

        // Unhovered: trailing badge and trailing spinner show
        let unhoveredCell = Self.configuredCell(model: model150, isHovered: false)
        #expect(!unhoveredCell.trailingBadgeForTesting.isHidden)
        #expect(Double(unhoveredCell.trailingBadgeForTesting.frame.width) == 24.0)
        #expect(Double(unhoveredCell.trailingBadgeForTesting.frame.height) == 24.0)

        let trailingSpinner = try #require(unhoveredCell.trailingSpinnerForTesting)
        #expect(!trailingSpinner.isHidden)
        #expect(Double(trailingSpinner.frame.width) == 18.0)
        #expect(Double(trailingSpinner.frame.height) == 18.0)

        // Title stops at trailing reserve
        let titleMaxX = unhoveredCell.titleFrameForTesting.maxX
        #expect(titleMaxX <= 215.0 - 24.0)

        // Hovered: close button shows and replaces trailing marks
        let hoveredCell = Self.configuredCell(model: model150, isHovered: true)
        let closeBtn = hoveredCell.closeButtonForTesting
        #expect(!closeBtn.isHidden)
        #expect(Double(closeBtn.frame.width) == 24.0)
        #expect(Double(closeBtn.frame.height) == 24.0)

        // Center Y alignment within 0.5 pt
        let titleCenterY = hoveredCell.titleFrameForTesting.midY
        #expect(abs(Double(closeBtn.frame.midY - titleCenterY)) <= 0.5)
        #expect(abs(Double(unhoveredCell.trailingBadgeForTesting.frame.midY - unhoveredCell.titleFrameForTesting.midY)) <= 0.5)
    }

    // MARK: - Scenario 202: Mark Dot Grows

    /// Scenario 202: his dot grows (dot is 9 pt across inside 24-pt badge slot at 150% in leading and trailing slots).
    @Test
    func markDotGrowsWithZoom() {
        let model150 = Self.makeModel(
            unreadCount: 0,
            markedUnread: true,
            globalFontMagnificationPercent: 150
        )
        let cell = Self.configuredCell(model: model150)
        #expect(!cell.leadingBadgeForTesting.isHidden)
        #expect(Double(cell.leadingBadgeForTesting.frame.width) == 24.0)
        #expect(Double(cell.leadingBadgeForTesting.frame.height) == 24.0)
        #expect(abs(Double(cell.leadingBadgeForTesting.markDiameterForTesting) - 9.0) < 0.01)

        // Trailing dot grows too
        let modelTrailing150 = Self.makeModel(
            unreadCount: 0,
            markedUnread: true,
            notificationBadgePosition: .trailing,
            globalFontMagnificationPercent: 150
        )
        let cellTrailing = Self.configuredCell(model: modelTrailing150)
        #expect(!cellTrailing.trailingBadgeForTesting.isHidden)
        #expect(Double(cellTrailing.trailingBadgeForTesting.frame.width) == 24.0)
        #expect(Double(cellTrailing.trailingBadgeForTesting.frame.height) == 24.0)
        #expect(abs(Double(cellTrailing.trailingBadgeForTesting.markDiameterForTesting) - 9.0) < 0.01)
    }

    // MARK: - Scenario 203: Agent Symbols Grow

    /// Scenario 203: hand, triangle and waveform symbols grow, and hand configuration equals regular.
    @Test
    func agentSymbolsGrowWithZoom() throws {
        // At font 12.5 and 100%: hand is 16x16, configuration is 13 pt regular
        let model100 = Self.makeModel(
            snapshot: Self.makeSnapshot(showsAgentActivity: true, waitingCount: 1),
            globalFontMagnificationPercent: 100,
            sidebarFontSize: 12.5
        )
        let cell100 = Self.configuredCell(model: model100)
        let hand100 = try #require(cell100.handForTesting)
        let image100 = try #require(hand100.image)
        #expect(Double(image100.size.width) == 16.0)
        #expect(Double(image100.size.height) == 16.0)
        let expectedConfig100 = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        #expect(image100.symbolConfiguration == expectedConfig100)

        // At 150%: spinnerSide is 18. Hand symbol is 13 * 18 / 12 = 19.5 pt regular.
        let model150 = Self.makeModel(
            snapshot: Self.makeSnapshot(showsAgentActivity: true, monitoringCount: 1, waitingCount: 1, errorCount: 1),
            globalFontMagnificationPercent: 150,
            sidebarFontSize: 12.5
        )
        let cell150 = Self.configuredCell(model: model150)
        let hand150 = try #require(cell150.handForTesting)
        let image150 = try #require(hand150.image)
        let expectedConfig150 = NSImage.SymbolConfiguration(pointSize: 19.5, weight: .regular)
        #expect(image150.symbolConfiguration == expectedConfig150)
        #expect(abs(Double(hand150.frame.width) - 18.0) <= 0.5)

        // Triangle symbol at 150%: 18 pt semibold
        let triangle150 = try #require(cell150.errorTriangleForTesting)
        let triangleImg150 = try #require(triangle150.image)
        let expectedTriangleConfig = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        #expect(triangleImg150.symbolConfiguration == expectedTriangleConfig)

        // Waveform symbol at 150%: 18 pt semibold
        let waveform150 = try #require(cell150.monitoringImageViewForTesting)
        let waveformImg150 = try #require(waveform150.image)
        let expectedWaveformConfig = NSImage.SymbolConfiguration(pointSize: 18, weight: SidebarWorkspaceMonitoringWaveform.symbolWeight)
        #expect(waveformImg150.symbolConfiguration == expectedWaveformConfig)

        // At font 20 (scale 1.6) and 100%: spinnerSide is 19.2 pt, pointSize is 20.8 pt
        let modelFont20 = Self.makeModel(
            snapshot: Self.makeSnapshot(showsAgentActivity: true, waitingCount: 1),
            globalFontMagnificationPercent: 100,
            sidebarFontSize: 20.0
        )
        let cellFont20 = Self.configuredCell(model: modelFont20)
        let handFont20 = try #require(cellFont20.handForTesting)
        let imageFont20 = try #require(handFont20.image)
        let expectedConfig20 = NSImage.SymbolConfiguration(pointSize: 20.8, weight: .regular)
        #expect(imageFont20.symbolConfiguration == expectedConfig20)
    }

    // MARK: - Scenario 204: Lower Line Marks Grow

    /// Scenario 204: PR icons and progress bar grow with zoom in drawing and layout.
    @Test
    func lowerLineMarksGrowWithZoom() throws {
        // Open PR at 150%: 19.5 x 19.5, configure fontScale 1.5
        let snapshotOpenPR = Self.makeSnapshot(pullRequestStatus: .open)
        let modelOpenPR = Self.makeModel(snapshot: snapshotOpenPR, globalFontMagnificationPercent: 150, showsPullRequests: true)
        let cellOpenPR = Self.configuredCell(model: modelOpenPR)
        let prLineOpen = try #require(cellOpenPR.pullRequestLinesForTesting.first)
        #expect(abs(Double(prLineOpen.iconViewForTesting.frame.width) - 19.5) < 0.1)
        #expect(abs(Double(prLineOpen.iconViewForTesting.frame.height) - 19.5) < 0.1)
        #expect(abs(Double(prLineOpen.iconViewForTesting.fontScaleForTesting) - 1.5) < 0.01)

        // Closed PR at 150%: 18 x 18, configure fontScale 1.5
        let snapshotClosedPR = Self.makeSnapshot(pullRequestStatus: .closed)
        let modelClosedPR = Self.makeModel(snapshot: snapshotClosedPR, globalFontMagnificationPercent: 150, showsPullRequests: true)
        let cellClosedPR = Self.configuredCell(model: modelClosedPR)
        let prLineClosed = try #require(cellClosedPR.pullRequestLinesForTesting.first)
        #expect(abs(Double(prLineClosed.iconViewForTesting.frame.width) - 18.0) < 0.1)
        #expect(abs(Double(prLineClosed.iconViewForTesting.frame.height) - 18.0) < 0.1)
        #expect(abs(Double(prLineClosed.iconViewForTesting.fontScaleForTesting) - 1.5) < 0.01)

        // Progress bar at 150%: height is 4.5 pt, configured barHeight is 4.5 pt, difference with/without progress bar is 9 pt
        let snapshotWithProgress = Self.makeSnapshot(progress: 0.5)
        let modelWithProgress = Self.makeModel(snapshot: snapshotWithProgress, globalFontMagnificationPercent: 150)
        let cellWithProgress = Self.configuredCell(model: modelWithProgress)
        #expect(abs(Double(cellWithProgress.progressBarForTesting.frame.height) - 4.5) < 0.01)
        #expect(abs(Double(cellWithProgress.progressBarForTesting.barHeightForTesting) - 4.5) < 0.01)

        let snapshotWithoutProgress = Self.makeSnapshot(progress: nil)
        let modelWithoutProgress = Self.makeModel(snapshot: snapshotWithoutProgress, globalFontMagnificationPercent: 150)
        let cellWithoutProgress = Self.configuredCell(model: modelWithoutProgress)

        let heightWith = cellWithProgress.layoutContent(model: modelWithProgress, width: 215, apply: false)
        let heightWithout = cellWithoutProgress.layoutContent(model: modelWithoutProgress, width: 215, apply: false)
        // ceil(y) turns 4 + 4.5 pt into 9 pt height difference (was 7 pt on base)
        #expect(abs(Double(heightWith - heightWithout) - 9.0) < 0.01)
    }

    // MARK: - Scenario 205: Combined Scale And Floors

    /// Scenario 205: indicatorScale pure function and mark floors verified on live cell.
    @Test
    func combinedScaleAndFloors() throws {
        let scaleMax = SidebarWorkspaceSlotResolution.indicatorScale(fontScale: 1.6, magnificationPercent: 200)
        #expect(abs(Double(scaleMax) - 3.2) < 0.001)

        let scaleMin = SidebarWorkspaceSlotResolution.indicatorScale(fontScale: 0.8, magnificationPercent: 50)
        #expect(abs(Double(scaleMin) - 0.4) < 0.001)

        let scaleBase = SidebarWorkspaceSlotResolution.indicatorScale(fontScale: 1.0, magnificationPercent: 100)
        #expect(abs(Double(scaleBase) - 1.0) < 0.001)

        // Production cell floors at scale < 1.0 (font 10, 50% zoom -> indicatorScale ~0.4166):
        let modelSmall = Self.makeModel(
            snapshot: Self.makeSnapshot(showsAgentActivity: true, waitingCount: 1, progress: 0.5),
            globalFontMagnificationPercent: 50,
            sidebarFontSize: 10
        )
        let cellSmall = Self.configuredCell(model: modelSmall)
        let handSmall = try #require(cellSmall.handForTesting)
        #expect(Double(handSmall.frame.width) == 10.0) // floor max(10, 12 * 0.4166) = 10
        let imageSmall = try #require(handSmall.image)
        let expectedHandConfigSmall = NSImage.SymbolConfiguration(pointSize: 13.0 * 10.0 / 12.0, weight: .regular)
        #expect(imageSmall.symbolConfiguration == expectedHandConfigSmall)

        #expect(Double(cellSmall.closeButtonForTesting.frame.height) == 16.0) // floor max(16, 16 * 0.4166) = 16
        #expect(Double(cellSmall.progressBarForTesting.frame.height) == 3.0) // layout floor max(3, 3 * 0.4166) = 3
        #expect(Double(cellSmall.progressBarForTesting.barHeightForTesting) == 3.0) // configure floor max(3, 3 * 0.4166) = 3
    }

    // MARK: - Scenario 206: Row Height Follows Zoomed Badge

    /// Scenario 206: row height follows zoomed badge, models differing only in zoom are not height-equivalent.
    @Test
    func rowHeightFollowsZoomedBadge() {
        let model100 = Self.makeModel(unreadCount: 3, globalFontMagnificationPercent: 100)
        let model150 = Self.makeModel(unreadCount: 3, globalFontMagnificationPercent: 150)

        #expect(!model100.hasHeightEquivalentContent(to: model150))

        let cell = Self.configuredCell(model: model150)
        // At 150%, badgeSide is 24, so leading badge height is 24
        #expect(Double(cell.leadingBadgeForTesting.frame.height) == 24.0)

        // cmux-rbf: changed on purpose (#cm-128.9)
        // Measured row height: a row with leading badge at 150% is taller than a row with trailing badge
        // because the left badge adds the mark line (4 pt spacing + 24 pt badgeSide = 28 pt), while the
        // right badge stays on the title line and adds no mark line.
        let modelLeftBadge = Self.makeModel(unreadCount: 3, notificationBadgePosition: .leading, globalFontMagnificationPercent: 150)
        let modelRightBadge = Self.makeModel(unreadCount: 3, notificationBadgePosition: .trailing, globalFontMagnificationPercent: 150)
        let cellLeft = Self.configuredCell(model: modelLeftBadge)
        let cellRight = Self.configuredCell(model: modelRightBadge)
        let heightLeft = cellLeft.layoutContent(model: modelLeftBadge, width: 215, apply: false)
        let heightRight = cellRight.layoutContent(model: modelRightBadge, width: 215, apply: false)
        #expect(heightLeft - heightRight == 28.0)
    }

    // MARK: - Scenario 211: Sites That Already Zoom Stay Once

    /// Scenario 211: sites that already zoom stay once (pin icon, badge count font, close glyph, title).
    @Test
    func sitesThatAlreadyZoomStayOnce() throws {
        let model150 = Self.makeModel(
            unreadCount: 15,
            globalFontMagnificationPercent: 150,
            isPinned: true
        )
        let cell150 = Self.configuredCell(model: model150)

        // Pin slot frame: scaled(9) + 4 = 17.5 pt (zoomed once)
        #expect(abs(Double(cell150.pinImageViewForTesting.frame.width) - 17.5) < 0.01)
        #expect(abs(Double(cell150.pinImageViewForTesting.frame.height) - 17.5) < 0.01)

        // Badge count font: scaled(9) = 13.5 pt
        let badgeFont = try #require(cell150.leadingBadgeForTesting.fontForTesting)
        #expect(abs(Double(badgeFont.pointSize) - 13.5) < 0.01)

        // Title font: scaled(12.5) = 18.75 pt
        let titleFont = try #require(cell150.titleViewForTesting.font)
        #expect(abs(Double(titleFont.pointSize) - 18.75) < 0.01)

        // Close glyph image is unmagnified (pointSize 10)
        let glyphImage = try #require(cell150.closeButtonForTesting.glyphImage)
        #expect(glyphImage.size.width <= 14.0)
    }

    // MARK: - Scenario 212: Done Rows Keep Dim And Colours

    /// Scenario 212: Done rows keep their dim and colours under zoom.
    @Test
    func doneDimAndColoursHoldUnderZoom() throws {
        let snapshot = Self.makeSnapshot(
            unreadCount: 2,
            showsAgentActivity: true,
            waitingCount: 1,
            errorCount: 1,
            hasTaskStatus: true,
            taskStatus: .done
        )

        let model100 = Self.makeModel(snapshot: snapshot, unreadCount: 2, globalFontMagnificationPercent: 100)
        let model150 = Self.makeModel(snapshot: snapshot, unreadCount: 2, globalFontMagnificationPercent: 150)

        let cell100 = Self.configuredCell(model: model100)
        let cell150 = Self.configuredCell(model: model150)

        // Dimmed alpha values hold across zoom
        let doneAlpha = SidebarWorkspaceRowVisualPalette.contentAlpha(taskStatus: .done)
        #expect(abs(Double(cell100.contentAlphaForTesting) - Double(doneAlpha)) < 0.01)
        #expect(abs(Double(cell150.contentAlphaForTesting) - Double(doneAlpha)) < 0.01)
        #expect(cell100.contentAlphaForTesting == cell150.contentAlphaForTesting)

        #expect(abs(Double(cell100.leadingBadgeForTesting.alphaValue) - Double(doneAlpha)) < 0.01)
        #expect(abs(Double(cell150.leadingBadgeForTesting.alphaValue) - Double(doneAlpha)) < 0.01)
        #expect(cell100.leadingBadgeForTesting.alphaValue == cell150.leadingBadgeForTesting.alphaValue)

        let hand100 = try #require(cell100.handForTesting)
        let hand150 = try #require(cell150.handForTesting)
        #expect(hand100.contentTintColor == hand150.contentTintColor)

        let triangle100 = try #require(cell100.errorTriangleForTesting)
        let triangle150 = try #require(cell150.errorTriangleForTesting)
        #expect(triangle100.contentTintColor == triangle150.contentTintColor)
    }

    // MARK: - Scenario 207: Status Header Zooms Once

    /// Scenario 207: built through `statusHeaderModel` at 150%, sidebar font 12.5 (`sidebarFontScale: 1`):
    /// the header model's `fontScale` is 1, the name's font 16.5 pt, the icon frame 21, and its glyph image 21 × 21.
    /// At `sidebarFontScale: 1.6` (font 20) and 100%: `fontScale` 1.6, and the glyph image 22.4 × 22.4.
    @Test
    func statusHeaderZoomsOnce() throws {
        let presentation = SidebarStatusGroupPresentation(
            name: "Parked",
            tintHex: "#6B7280",
            glyph: .symbol("archivebox"),
            behavesAs: .todo
        )

        // Case 1: 150% zoom, sidebar font 12.5 (sidebarFontScale: 1.0)
        let env150 = SidebarWorkspaceTableEnvironmentSnapshot(
            colorScheme: .light,
            globalFontMagnificationPercent: 150,
            lazyContractProbe: .init()
        )
        var model150 = VerticalTabsSidebar.statusHeaderModel(
            kind: .statusGroup("parked"),
            presentation: presentation,
            memberCount: 2,
            unreadCount: 0,
            isCollapsed: true,
            environment: env150,
            sidebarFontScale: 1.0
        )
        model150.anchorMarkedUnread = true

        // Model fontScale must be 1.0 (sidebarFontScale), not 1.5 (zoom)
        #expect(model150.fontScale == 1.0)

        let cell150 = SidebarGroupHeaderTableCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        cell150.configurePresentation(model: model150)
        cell150.layout()

        // Name font: scaled(11.0, percent: 150) = 16.5 pt
        let nameFont150 = try #require(cell150.nameFontForTesting)
        #expect(nameFont150.pointSize == 16.5)

        // Icon frame: 14 * 1.5 = 21.0
        #expect(cell150.iconImageView.frame.width == 21.0)
        #expect(cell150.iconImageView.frame.height == 21.0)

        // Glyph image: 14 * 1.5 = 21.0 × 21.0
        let image150 = try #require(cell150.iconImageForTesting)
        #expect(image150.size.width == 21.0)
        #expect(image150.size.height == 21.0)

        // Status header unread mark dot (9.0) and mark-only badge (24.0) at 150%
        #expect(cell150.unreadBadgeViewForTesting.markDiameterForTesting == 9.0)
        #expect(cell150.unreadBadgeViewForTesting.frame.width == 24.0)
        #expect(cell150.unreadBadgeViewForTesting.frame.height == 24.0)

        // Case 2: 100% zoom, sidebar font 20 (sidebarFontScale: 1.6)
        let env100 = SidebarWorkspaceTableEnvironmentSnapshot(
            colorScheme: .light,
            globalFontMagnificationPercent: 100,
            lazyContractProbe: .init()
        )
        let modelFont20 = VerticalTabsSidebar.statusHeaderModel(
            kind: .statusGroup("parked"),
            presentation: presentation,
            memberCount: 2,
            unreadCount: 0,
            isCollapsed: false,
            environment: env100,
            sidebarFontScale: 1.6
        )

        #expect(modelFont20.fontScale == 1.6)

        let cellFont20 = SidebarGroupHeaderTableCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        cellFont20.configurePresentation(model: modelFont20)
        cellFont20.layout()

        // Glyph image at font 20: 14 * 1.6 = 22.4 × 22.4
        let imageFont20 = try #require(cellFont20.iconImageForTesting)
        #expect((imageFont20.size.width * 10).rounded() / 10 == 22.4)
        #expect((imageFont20.size.height * 10).rounded() / 10 == 22.4)
    }

    // MARK: - Scenario 208: Group Header Frames Zoom

    /// Scenario 208: at 150%: chevron and icon frames 21, plus 24, mark-only badge 24, dot 9;
    /// `preferredHeight` matches layout content.
    @Test
    func groupHeaderFramesZoom() throws {
        let model150 = Self.makeGroupHeaderModel(
            name: "Workspaces",
            fontScale: 1.0,
            globalFontMagnificationPercent: 150,
            hasOwnWorkspace: true,
            isPinned: true,
            anchorMarkedUnread: true
        )

        let cell = SidebarGroupHeaderTableCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        cell.configurePresentation(model: model150)
        cell.layout()

        // Pin frame: 14 * 1.5 = 21.0
        #expect(cell.pinImageViewForTesting.frame.width == 21.0)
        #expect(cell.pinImageViewForTesting.frame.height == 21.0)

        // Chevron frame: 14 * 1.5 = 21.0
        #expect(cell.chevronButtonForTesting.frame.width == 21.0)
        #expect(cell.chevronButtonForTesting.frame.height == 21.0)

        // Icon frame: 14 * 1.5 = 21.0
        #expect(cell.iconImageView.frame.width == 21.0)
        #expect(cell.iconImageView.frame.height == 21.0)

        // Plus button frame: 16 * 1.5 = 24.0
        #expect(cell.plusButtonForTesting.frame.width == 24.0)
        #expect(cell.plusButtonForTesting.frame.height == 24.0)

        // Mark-only badge: 16 * 1.5 = 24.0
        #expect(cell.unreadBadgeViewForTesting.frame.width == 24.0)
        #expect(cell.unreadBadgeViewForTesting.frame.height == 24.0)

        // Dot inside mark-only badge: 6 * 1.5 = 9.0
        #expect(cell.unreadBadgeViewForTesting.markDiameterForTesting == 9.0)

        // Preferred height equals laid-out content height: max(21, 21, 24, nameLineHeight) + 10 = 34
        let preferred150 = SidebarGroupHeaderTableCellView.preferredHeight(model: model150)
        #expect(preferred150 == 34.0)

        // Control at 100%
        let model100 = Self.makeGroupHeaderModel(
            name: "Workspaces",
            fontScale: 1.0,
            globalFontMagnificationPercent: 100,
            hasOwnWorkspace: true,
            isPinned: true,
            anchorMarkedUnread: true
        )
        let cell100 = SidebarGroupHeaderTableCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        cell100.configurePresentation(model: model100)
        cell100.layout()
        #expect(cell100.pinImageViewForTesting.frame.width == 14.0)
        #expect(cell100.pinImageViewForTesting.frame.height == 14.0)
        let preferred100 = SidebarGroupHeaderTableCellView.preferredHeight(model: model100)
        #expect(preferred100 == 26.0)
    }

    // MARK: - Scenario 213: Group Status Glyph Zooms

    /// Scenario 213: at 150%, sidebar font 12.5, a workspace-group header whose group carries a status:
    /// the icon's image is 21 × 21. At 100%: 14 × 14.
    @Test
    func groupStatusGlyphZooms() throws {
        let glyph = SidebarWorkspaceGroupStatusGlyph(
            status: .working,
            name: "Working",
            glyph: .symbol("arrow.triangle.2.circlepath"),
            colorHex: "#3B82F6"
        )
        let model150 = Self.makeGroupHeaderModel(
            name: "Project Group",
            fontScale: 1.0,
            globalFontMagnificationPercent: 150,
            hasOwnWorkspace: true,
            groupStatusGlyph: glyph
        )

        let cell150 = SidebarGroupHeaderTableCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        cell150.configurePresentation(model: model150)
        cell150.layout()

        let image150 = try #require(cell150.iconImageForTesting)
        #expect(image150.size.width == 21.0)
        #expect(image150.size.height == 21.0)

        // At 100%:
        let model100 = Self.makeGroupHeaderModel(
            name: "Project Group",
            fontScale: 1.0,
            globalFontMagnificationPercent: 100,
            hasOwnWorkspace: true,
            groupStatusGlyph: glyph
        )
        let cell100 = SidebarGroupHeaderTableCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        cell100.configurePresentation(model: model100)
        cell100.layout()

        let image100 = try #require(cell100.iconImageForTesting)
        #expect(image100.size.width == 14.0)
        #expect(image100.size.height == 14.0)
    }

    // MARK: - Scenario 214: Section Header Zooms Once

    /// Scenario 214: the Workspaces section header, built through `statusHeaderConfiguration` at 150%
    /// and sidebar font 12.5 (`sidebarFontScale: 1`): model `fontScale` 1, name font 16.5 pt, chevron frame 21.
    /// At `sidebarFontScale: 1.6` (font 20) and 100%: `fontScale` 1.6, name font 17.6 pt.
    @Test
    func sectionHeaderZoomsOnce() throws {
        let env150 = SidebarWorkspaceTableEnvironmentSnapshot(
            colorScheme: .light,
            globalFontMagnificationPercent: 150,
            lazyContractProbe: .init()
        )
        let config150 = VerticalTabsSidebar.statusHeaderConfiguration(
            kind: .workspacesArea,
            presentation: nil,
            memberCount: 3,
            memberIds: [UUID(), UUID(), UUID()],
            folds: .init(),
            environment: env150,
            sidebarFontScale: 1.0,
            onToggle: {}
        )
        let model150 = try #require(config150.appKitGroupHeaderModel)
        #expect(model150.fontScale == 1.0)

        let cell150 = SidebarGroupHeaderTableCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        cell150.configurePresentation(model: model150)
        cell150.layout()

        let nameFont150 = try #require(cell150.nameFontForTesting)
        #expect(nameFont150.pointSize == 16.5)

        #expect(cell150.chevronButtonForTesting.frame.width == 21.0)
        #expect(cell150.chevronButtonForTesting.frame.height == 21.0)

        // Case 2: font 20 (scale 1.6) and 100%
        let env100 = SidebarWorkspaceTableEnvironmentSnapshot(
            colorScheme: .light,
            globalFontMagnificationPercent: 100,
            lazyContractProbe: .init()
        )
        let configFont20 = VerticalTabsSidebar.statusHeaderConfiguration(
            kind: .workspacesArea,
            presentation: nil,
            memberCount: 3,
            memberIds: [UUID(), UUID(), UUID()],
            folds: .init(),
            environment: env100,
            sidebarFontScale: 1.6,
            onToggle: {}
        )
        let modelFont20 = try #require(configFont20.appKitGroupHeaderModel)
        #expect(modelFont20.fontScale == 1.6)

        let cellFont20 = SidebarGroupHeaderTableCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        cellFont20.configurePresentation(model: modelFont20)
        cellFont20.layout()

        let nameFont20 = try #require(cellFont20.nameFontForTesting)
        #expect((nameFont20.pointSize * 10).rounded() / 10 == 17.6)
    }

    // MARK: - Scenario 218: Header-Only Dot Zooms

    /// Scenario 218 (Header-only dot half): a header-only workspace-group header at 150% (font 12.5)
    /// draws its dot image at 12 × 12, and at font 20 and 100% at 12.8 × 12.8.
    /// On the base it reads 8 × 8 at both.
    @Test
    func headerOnlyDotGrowsWithZoom() throws {
        // Case 1: 150% zoom, sidebar font 12.5 (fontScale 1.0, magnification 150%)
        let model150 = Self.makeGroupHeaderModel(
            name: "Loose Group",
            fontScale: 1.0,
            globalFontMagnificationPercent: 150,
            hasOwnWorkspace: false
        )

        let cell150 = SidebarGroupHeaderTableCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        cell150.configurePresentation(model: model150)
        cell150.layout()

        let image150 = try #require(cell150.iconImageForTesting)
        #expect(image150.size.width == 12.0)
        #expect(image150.size.height == 12.0)

        // Case 2: 100% zoom, sidebar font 20 (fontScale 1.6, magnification 100%)
        let modelFont20 = Self.makeGroupHeaderModel(
            name: "Loose Group",
            fontScale: 1.6,
            globalFontMagnificationPercent: 100,
            hasOwnWorkspace: false
        )

        let cellFont20 = SidebarGroupHeaderTableCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        cellFont20.configurePresentation(model: modelFont20)
        cellFont20.layout()

        let imageFont20 = try #require(cellFont20.iconImageForTesting)
        #expect((imageFont20.size.width * 10).rounded() / 10 == 12.8)
        #expect((imageFont20.size.height * 10).rounded() / 10 == 12.8)
    }

    // MARK: - Scenario 209: SwiftUI Status Header & Badge Zoom

    /// Scenario 209: SwiftUI status header glyph at indicatorScale, chevron frame 10 * indicatorScale,
    /// band height matches AppKit preferredHeight; shared badge dot and slot on indicatorScale;
    /// sidebarStatusGroupHeaderRow forwards sidebarFontScale.
    @Test
    func swiftUIHeaderAndBadgeMarksGrowWithZoom() throws {
        let presentation = SidebarStatusGroupPresentation(
            name: "Doing",
            tintHex: "#3B82F6",
            glyph: .symbol("hammer"),
            behavesAs: .working
        )

        // Case 1: 150% zoom, sidebar font 12.5 (fontScale 1.0)
        let header150 = SidebarStatusGroupSwiftUIHeader(
            statusId: "doing",
            presentation: presentation,
            memberCount: 2,
            isCollapsed: false,
            listWidth: 320,
            colorScheme: .light,
            fontScale: 1.0,
            globalFontMagnificationPercent: 150
        )

        // Glyph image: 14 * 1.5 = 21.0 × 21.0
        #expect(header150.glyphImage.size == NSSize(width: 21.0, height: 21.0))

        // Chevron frame: 10 * 1.5 = 15.0
        #expect(header150.chevronFrameWidth == 15.0)

        // Band height: max(chevron, icon, plus, name) + 10 = 34.0 (matching AppKit preferredHeight)
        #expect(header150.calculatedBandHeight == 34.0)
        #expect(header150.calculatedBandHeight == SidebarGroupHeaderTableCellView.preferredHeight(fontScale: 1.0, globalFontMagnificationPercent: 150))

        // Case 2: 100% zoom, sidebar font 20 (fontScale 1.6)
        let headerFont20 = SidebarStatusGroupSwiftUIHeader(
            statusId: "doing",
            presentation: presentation,
            memberCount: 2,
            isCollapsed: false,
            listWidth: 320,
            colorScheme: .light,
            fontScale: 1.6,
            globalFontMagnificationPercent: 100
        )

        // Glyph image at font 20: 14 * 1.6 = 22.4 × 22.4
        #expect((headerFont20.glyphImage.size.width * 10).rounded() / 10 == 22.4)
        #expect((headerFont20.glyphImage.size.height * 10).rounded() / 10 == 22.4)

        // Chevron frame at font 20: 10 * 1.6 = 16.0
        #expect(headerFont20.chevronFrameWidth == 16.0)

        // Band height at font 20: 36.0 (matching AppKit preferredHeight)
        #expect(headerFont20.calculatedBandHeight == 36.0)
        #expect(headerFont20.calculatedBandHeight == SidebarGroupHeaderTableCellView.preferredHeight(fontScale: 1.6, globalFontMagnificationPercent: 100))

        // Case 3: sidebarStatusGroupHeaderRow forwards sidebarFontScale (Scenario 209)
        let environment = SidebarWorkspaceTableEnvironmentSnapshot(
            colorScheme: .light,
            globalFontMagnificationPercent: 100,
            lazyContractProbe: SidebarLazyContractProbe()
        )
        let projection = WorkspaceStatusGroupProjection(groups: [
            WorkspaceStatusGroup(statusId: "doing", memberWorkspaceIds: [UUID()])
        ])
        let groupHeaderRow = try #require(VerticalTabsSidebar.sidebarStatusGroupHeaderRow(
            statusId: "doing",
            projection: projection,
            presentations: ["doing": presentation],
            listWidth: 320,
            environment: environment,
            sidebarFontScale: 1.6
        ))
        #expect(groupHeaderRow.fontScale == 1.6)

        // Shared unread badge at 150%: mark dot 9.0, slot 24.0
        let badge150 = SidebarStatusUnreadBadge(
            count: 0,
            markedUnread: true,
            fontScale: 1.0,
            globalFontMagnificationPercent: 150
        )
        #expect(badge150.markDiameterForTesting == 9.0)
        #expect(badge150.slotSizeForTesting == 24.0)
    }

    // MARK: - Scenario 218: Checklist Marks Grow With Zoom

    /// Scenario 218 (Checklist half): at 150% and sidebar font 12.5: the AppKit paperclip's point size is 13.5 (9 × 1.5)
    /// and its chevron's 8.775 (13.5 * 0.65), and the remove slot is 21.5 (9 × 1.5 + 8).
    /// At 100%: paperclip 9.0, remove slot 17.0.
    @Test
    func checklistMarksGrowWithZoom() throws {
        let item = WorkspaceChecklistItem(
            id: UUID(),
            text: "Implement zoom on checklist marks",
            state: .pending,
            attachments: [
                WorkspaceChecklistAttachment(displayName: "shot.png", filePath: "/tmp/shot.png")
            ]
        )

        // Case 1: 150% zoom, sidebar font 12.5 (fontScale 1.0, percent 150%)
        let snapshot150 = Self.makeSnapshot(title: "Checklist Workspace")
        let model150 = Self.makeModel(snapshot: snapshot150, globalFontMagnificationPercent: 150)
        let actions150 = SidebarAppKitRowCellTests.makeActions(model: model150)

        let line150 = SidebarRowChecklistItemLine(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        line150.configure(
            item,
            model: model150,
            primary: .labelColor,
            secondary: .secondaryLabelColor,
            isEditing: false,
            actions: actions150
        )

        // Paperclip point size: 9 * 1.5 = 13.5
        #expect(line150.attachmentButtonForTesting.iconPointSizeForTesting == 13.5)

        // Chevron point size: 13.5 * 0.65 = 8.775
        #expect(abs(line150.attachmentButtonForTesting.chevronPointSizeForTesting - 8.775) < 0.001)

        // Remove slot: 9 * 1.5 + 8 = 21.5
        #expect(line150.removeSlotForTesting == 21.5)

        // Case 2: 100% zoom (control)
        let snapshot100 = Self.makeSnapshot(title: "Checklist Workspace")
        let model100 = Self.makeModel(snapshot: snapshot100, globalFontMagnificationPercent: 100)
        let actions100 = SidebarAppKitRowCellTests.makeActions(model: model100)

        let line100 = SidebarRowChecklistItemLine(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        line100.configure(
            item,
            model: model100,
            primary: .labelColor,
            secondary: .secondaryLabelColor,
            isEditing: false,
            actions: actions100
        )

        #expect(line100.attachmentButtonForTesting.iconPointSizeForTesting == 9.0)
        #expect(abs(line100.attachmentButtonForTesting.chevronPointSizeForTesting - 5.85) < 0.001)
        #expect(line100.removeSlotForTesting == 17.0)
    }
}
