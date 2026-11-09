import AppKit
import CmuxWorkspaces
import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SidebarAgentMonitoringTests {
    @Test func waveformUsesTheSharedBoldWeight() {
        #expect(SidebarWorkspaceMonitoringWaveform.symbolWeight == .bold)
    }

    @Test(arguments: [false, true])
    func snapshotsCountMonitoringBesideRunningWithOrWithoutAStatusList(hasStatusList: Bool) throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        workspace.agentLifecycleStatesByPanelId[panel] = ["claude_code": .monitoring, "codex": .running]
        let suite = "cmux.monitoring.snapshot.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshot = SidebarWorkspaceSnapshotFactory(workspace: workspace,
            settings: SidebarTabItemSettingsSnapshot(defaults: defaults), showsAgentActivity: true,
            todoControlsEnabled: true, statusList: hasStatusList ? WorkspaceStatusEntrancesTests.hisList : .cmuxFive,
            statusColorHexes: [:]).makeSnapshot()
        #expect(snapshot.monitoringAgentCount == 1)
        #expect(snapshot.activeCodingAgentCount == 1)
    }

    @Test func hidingAgentActivityAlsoHidesMonitoring() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        workspace.agentLifecycleStatesByPanelId[panel] = ["claude_code": .monitoring]
        let suite = "cmux.monitoring.hidden.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshot = SidebarWorkspaceSnapshotFactory(workspace: workspace,
            settings: SidebarTabItemSettingsSnapshot(defaults: defaults), showsAgentActivity: false,
            todoControlsEnabled: true, statusList: .cmuxFive, statusColorHexes: [:]).makeSnapshot()
        #expect(snapshot.monitoringAgentCount == 0)
        #expect(snapshot.activeCodingAgentCount == 0)
    }

    @Test func aWaveformUpdatesWhileTheMenuKeepsOtherDetailsFrozen() {
        let current = SidebarWorkspaceSnapshotRefreshPolicyTests.snapshot(latestConversationMessage: "old")
        var next = SidebarWorkspaceSnapshotRefreshPolicyTests.snapshot(latestConversationMessage: "new")
        next.monitoringAgentCount = 1
        let decision = SidebarWorkspaceSnapshotRefreshPolicy().decision(current: current, next: next,
            force: false, contextMenuVisible: true)
        #expect(decision.workspaceSnapshotStorage?.monitoringAgentCount == 1)
        #expect(decision.workspaceSnapshotStorage?.latestConversationMessage == "old")
        #expect(decision.pendingWorkspaceSnapshot == next)
    }

    @Test func appKitShowsAStaticTwelvePointWaveformAndRemovesItWhenMonitoringEnds() throws {
        var snapshot = SidebarWorkspaceSnapshotRefreshPolicyTests.snapshot()
        snapshot.monitoringAgentCount = 1
        let model = SidebarAppKitRowCellTests.makeModel(snapshot: snapshot)
        #expect(model.showsAgentActivity, "control: agent activity is enabled for this renderer")
        let cell = SidebarAppKitRowCellTests.configuredCell(model: model)
        _ = cell.layoutContent(model: model, width: 420, apply: true)
        let tooltip = String(localized: "sidebar.agentMonitoring.tooltip", defaultValue: "Watching a background job")
        let waveform = try #require(SidebarAppKitRowCellTests.descendants(of: cell).compactMap { $0 as? NSImageView }
            .first { $0.toolTip == tooltip && !$0.isHidden })
        #expect(waveform.image != nil)
        #expect(waveform.frame.width == 12)
        #expect(waveform.frame.height == 12)
        #expect(waveform.layer?.animationKeys()?.isEmpty ?? true)
        #expect(cell.markSpinnerForTesting?.isHidden ?? true)
        #expect(cell.trailingSpinnerForTesting?.isHidden ?? true)

        snapshot.monitoringAgentCount = 0
        let quiet = SidebarAppKitRowCellTests.makeModel(snapshot: snapshot)
        cell.configure(model: quiet, actions: SidebarAppKitRowCellTests.makeActions(model: quiet),
            isPointerHovering: false, contextMenuDidOpen: {}, contextMenuDidClose: {})
        #expect(waveform.isHidden)
    }

    @Test(arguments: [false, true])
    func doneDimsNoAgentMarkEachKeepsItsContrastStrength(isDark: Bool) throws { // cm-128.5 (Tom, grill Q34): the hand no longer dims
        var snapshot = SidebarWorkspaceSnapshotRefreshPolicyTests.snapshot(customColorHex: "#777777",
            activeCodingAgentCount: 1, showsRaisedHand: true, taskStatus: .done)
        snapshot.monitoringAgentCount = 1
        let model = SidebarAppKitRowCellTests.makeModel(isActive: true, colorSchemeIsDark: isDark, snapshot: snapshot)
        let cell = SidebarAppKitRowCellTests.configuredCell(model: model)
        _ = cell.layoutContent(model: model, width: 420, apply: true)
        let tooltip = String(localized: "sidebar.agentMonitoring.tooltip", defaultValue: "Watching a background job")
        let waveform = try #require(SidebarAppKitRowCellTests.descendants(of: cell).compactMap { $0 as? NSImageView }
            .first { $0.toolTip == tooltip && !$0.isHidden })
        let spinner = try #require([cell.markSpinnerForTesting, cell.trailingSpinnerForTesting]
            .compactMap { $0 }.first { !$0.isHidden })
        let hand = try #require(cell.handForTesting)
        func effectiveAlpha(_ view: NSView) -> CGFloat {
            var alpha: CGFloat = 1
            var current: NSView? = view
            while let node = current {
                alpha *= node.alphaValue
                current = node.superview
            }
            return alpha
        }
        #expect(effectiveAlpha(hand) == 1)
        #expect(effectiveAlpha(spinner) == 1)
        #expect(effectiveAlpha(waveform) == 1)
        let palette = SidebarRowPalette(model: model)
        let background = try #require(palette.visual.backgroundStyle.color)
        let color = try #require(waveform.contentTintColor)
        #expect(cmuxContrastRatio(foreground: cmuxCompositedNSColor(color, over: background), background: background) >= 3)
        #expect(cmuxContrastRatio(foreground: cmuxCompositedNSColor(spinner.color, over: background), background: background) >= 3)
    }

    @Test func swiftUIWaveformFitsInsideItsTwelvePointSlot() throws {
        // Render the actual row component into a larger transparent canvas so overflow remains visible.
        let renderer = ImageRenderer(content: SidebarWorkspaceMonitoringWaveform(side: 12, color: .white)
            .frame(width: 40, height: 40))
        renderer.scale = 1
        let image = try #require(renderer.nsImage)
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        var minX = bitmap.pixelsWide
        var minY = bitmap.pixelsHigh
        var maxX = -1
        var maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        #expect(maxX >= minX && maxY >= minY, "the waveform actually rendered")
        #expect(maxX - minX + 1 <= 12, "waveform width is \(maxX - minX + 1) pixels")
        #expect(maxY - minY + 1 <= 12, "waveform height is \(maxY - minY + 1) pixels")
    }
}
