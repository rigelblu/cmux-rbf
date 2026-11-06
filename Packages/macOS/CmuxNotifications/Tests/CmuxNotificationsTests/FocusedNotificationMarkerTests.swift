import Foundation
import Testing
@testable import CmuxNotifications

@Suite(.serialized)
@MainActor
struct FocusedNotificationMarkerTests {
    /// Records every pane exclusion the marker asks to jump for (cm-128.11: one exclusion in place of
    /// the notification, workspace and Dock parameters), and returns a scriptable opened id.
    @MainActor
    final class JumpSpy {
        var openedId: UUID?
        private(set) var calls: [UnreadQueueTarget?] = []

        func jump(_ excludedPane: UnreadQueueTarget?) -> UUID? {
            calls.append(excludedPane)
            return openedId
        }
    }

    private func makeMarker(
        resolver: FakeFocusedResolving,
        jump: JumpSpy = JumpSpy()
    ) -> (FocusedNotificationMarker, JumpSpy) {
        let marker = FocusedNotificationMarker(
            resolver: resolver,
            jumpToOldestUnread: { jump.jump($0) }
        )
        return (marker, jump)
    }

    // MARK: toggle entry gate

    @Test("toggle is a no-op when no store is present")
    func toggleNoStore() {
        let resolver = FakeFocusedResolving()
        resolver.hasNotificationStore = false
        resolver.focusedTargetValue = .workspace(tabId: UUID(), surfaceId: UUID())
        let (marker, _) = makeMarker(resolver: resolver)

        #expect(marker.toggleFocusedNotificationUnread() == false)
        #expect(resolver.mutations.isEmpty)
    }

    @Test("toggle is a no-op when nothing is focused")
    func toggleNoTarget() {
        let resolver = FakeFocusedResolving()
        resolver.focusedTargetValue = nil
        let (marker, _) = makeMarker(resolver: resolver)

        #expect(marker.toggleFocusedNotificationUnread() == false)
        #expect(resolver.mutations.isEmpty)
    }

    @Test("toggle mutates only the exact focused window Dock surface")
    func toggleWindowDockSurface() {
        let target = WindowDockUnreadTarget(windowId: UUID(), surfaceId: UUID())
        let resolver = FakeFocusedResolving()
        resolver.focusedTargetValue = .windowDock(target)
        let (marker, _) = makeMarker(resolver: resolver)

        #expect(marker.toggleFocusedNotificationUnread())
        #expect(resolver.unreadWindowDockTargets == [target])
        #expect(resolver.mutations == [
            "markWindowDockSurfaceUnread(\(short(target.surfaceId)))",
        ])

        #expect(marker.toggleFocusedNotificationUnread())
        #expect(resolver.unreadWindowDockTargets.isEmpty)
        #expect(resolver.mutations == [
            "markWindowDockSurfaceUnread(\(short(target.surfaceId)))",
            "clearWindowDockSurfaceUnread(\(short(target.surfaceId)))",
        ])
    }

    // MARK: toggle, panel path

    @Test("toggle marks the workspace read when it shows a visible indicator")
    func togglePanelVisibleIndicatorMarksRead() {
        let tab = UUID(), surface = UUID()
        let panel = FocusedPanel(tabId: tab, panelId: surface)
        let resolver = FakeFocusedResolving()
        resolver.focusedTargetValue = .workspace(tabId: tab, surfaceId: surface)
        resolver.panelByTabSurface[.init(tabId: tab, surfaceId: surface)] = panel
        // Workspace-level visible indicator → first branch wins.
        resolver.visibleIndicatorSet = [.init(tabId: tab, surfaceId: nil)]
        let (marker, _) = makeMarker(resolver: resolver)

        #expect(marker.toggleFocusedNotificationUnread())
        #expect(resolver.mutations == ["storeMarkRead(\(short(tab)))"])
    }

    @Test("toggle marks an unread panel read and clears workspace manual unread when representative")
    func togglePanelUnreadClearsManual() {
        let tab = UUID(), surface = UUID()
        let panel = FocusedPanel(tabId: tab, panelId: surface)
        let resolver = FakeFocusedResolving()
        resolver.focusedTargetValue = .workspace(tabId: tab, surfaceId: surface)
        resolver.panelByTabSurface[.init(tabId: tab, surfaceId: surface)] = panel
        // Manual unread on the representative panel → mark read + clear manual.
        resolver.storeManualUnreadTabs = [tab]
        resolver.panelIsRepresentativeSet = [panel]
        let (marker, _) = makeMarker(resolver: resolver)

        #expect(marker.toggleFocusedNotificationUnread())
        #expect(resolver.mutations == ["markPanelRead(\(short(surface)))", "storeClearManualUnread(\(short(tab)))"])
    }

    @Test("toggle marks a clean panel unread")
    func togglePanelMarksUnread() {
        let tab = UUID(), surface = UUID()
        let panel = FocusedPanel(tabId: tab, panelId: surface)
        let resolver = FakeFocusedResolving()
        resolver.focusedTargetValue = .workspace(tabId: tab, surfaceId: surface)
        resolver.panelByTabSurface[.init(tabId: tab, surfaceId: surface)] = panel
        // Nothing unread anywhere → toggle ON.
        let (marker, _) = makeMarker(resolver: resolver)

        #expect(marker.toggleFocusedNotificationUnread())
        #expect(resolver.mutations == ["markPanelUnread(\(short(surface)))"])
    }

    // MARK: toggle, workspace (no panel) path

    @Test("toggle without a panel marks the unread workspace read")
    func toggleWorkspaceReadWhenUnread() {
        let tab = UUID()
        let resolver = FakeFocusedResolving()
        // No surface → no panel resolution → workspace branch.
        resolver.focusedTargetValue = .workspace(tabId: tab, surfaceId: nil)
        resolver.workspaceUnreadTabs = [tab]
        let (marker, _) = makeMarker(resolver: resolver)

        #expect(marker.toggleFocusedNotificationUnread())
        #expect(resolver.mutations == ["storeMarkRead(\(short(tab)))"])
    }

    @Test("toggle without a panel marks the read workspace unread")
    func toggleWorkspaceUnreadWhenRead() {
        let tab = UUID()
        let resolver = FakeFocusedResolving()
        resolver.focusedTargetValue = .workspace(tabId: tab, surfaceId: nil)
        let (marker, _) = makeMarker(resolver: resolver)

        #expect(marker.toggleFocusedNotificationUnread())
        #expect(resolver.mutations == ["storeMarkUnread(\(short(tab)))"])
    }

    // MARK: markOldest + jump

    // Scenario 157 (cm-128.11): ⌘⌃U sends the focused pane to the back, then walks without it.

    @Test("send to back: a Dock surface is handed to the store and is the one exclusion, whether or not it has a notification")
    func sendToBackDockSurface() {
        // The marker treats both cases the same: the store marks, moves or sends back; the fake's answer is ignored.
        for hasNotification in [false, true] {
            let target = WindowDockUnreadTarget(windowId: UUID(), surfaceId: UUID())
            let resolver = FakeFocusedResolving()
            resolver.focusedTargetValue = .windowDock(target)
            if hasNotification { resolver.targetsWithNotifications = [.windowDock(target)] }
            let (marker, spy) = makeMarker(resolver: resolver)

            _ = marker.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread()

            #expect(resolver.mutations == ["sendToBack(dock \(short(target.surfaceId)))"], "the store marks and moves a Dock mark itself")
            #expect(spy.calls == [.windowDock(target)])
        }
    }

    @Test("send to back: a pane with a notification is sent back; the walk excludes the pane, and nothing else is marked")
    func sendToBackPaneWithNotification() {
        let tab = UUID(), surface = UUID(), opened = UUID()
        let resolver = FakeFocusedResolving()
        resolver.focusedTargetValue = .workspace(tabId: tab, surfaceId: surface)
        resolver.targetsWithNotifications = [.workspace(tabId: tab, surfaceId: surface)]
        let jump = JumpSpy(); jump.openedId = opened
        let (marker, spy) = makeMarker(resolver: resolver, jump: jump)

        let result = marker.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread()

        #expect(result == opened)
        #expect(spy.calls == [.workspace(tabId: tab, surfaceId: surface)]) // the pane just sent back
        #expect(resolver.mutations == ["sendToBack(\(short(tab)),\(short(surface)))"], "no mark of his own beside it")
    }

    @Test("send to back: a pane with no notification gets his mark, then the walk excludes it")
    func sendToBackPaneWithNoNotificationMarksPanel() {
        let tab = UUID(), surface = UUID(), opened = UUID()
        let panel = FocusedPanel(tabId: tab, panelId: surface)
        let resolver = FakeFocusedResolving()
        resolver.focusedTargetValue = .workspace(tabId: tab, surfaceId: surface)
        resolver.panelByTabSurface[.init(tabId: tab, surfaceId: surface)] = panel
        let jump = JumpSpy(); jump.openedId = opened
        let (marker, spy) = makeMarker(resolver: resolver, jump: jump)

        let result = marker.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread()

        #expect(result == opened)
        #expect(resolver.mutations == ["sendToBack(\(short(tab)),\(short(surface)))", "markPanelUnread(\(short(surface)))"])
        #expect(spy.calls == [.workspace(tabId: tab, surfaceId: surface)]) // the marked pane
    }

    // Review carry-over (a): the focused surface id is not the panel id the mark is kept under.
    @Test("send to back: the exclusion carries the id the pane's mark is kept under, not the focused surface id")
    func sendToBackExcludesThePanelIdItMarked() {
        let tab = UUID(), surface = UUID(), panelId = UUID()
        let resolver = FakeFocusedResolving()
        resolver.focusedTargetValue = .workspace(tabId: tab, surfaceId: surface)
        resolver.panelByTabSurface[.init(tabId: tab, surfaceId: surface)] = FocusedPanel(tabId: tab, panelId: panelId)
        let (marker, spy) = makeMarker(resolver: resolver)

        _ = marker.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread()

        #expect(resolver.mutations.last == "markPanelUnread(\(short(panelId)))")
        #expect(spy.calls == [.workspace(tabId: tab, surfaceId: panelId)], "the walk compares it with the workspace mark's panel")
    }

    @Test("send to back: an already-unread panel is not marked again, but is still excluded")
    func sendToBackSkipsAlreadyUnreadPanel() {
        let tab = UUID(), surface = UUID()
        let panel = FocusedPanel(tabId: tab, panelId: surface)
        let resolver = FakeFocusedResolving()
        resolver.focusedTargetValue = .workspace(tabId: tab, surfaceId: surface)
        resolver.panelByTabSurface[.init(tabId: tab, surfaceId: surface)] = panel
        resolver.panelIsManualUnreadSet = [panel] // already unread → no mark
        let (marker, spy) = makeMarker(resolver: resolver)

        _ = marker.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread()

        #expect(resolver.mutations == ["sendToBack(\(short(tab)),\(short(surface)))"])
        #expect(spy.calls == [.workspace(tabId: tab, surfaceId: surface)])
    }

    @Test("send to back: with no panel, a read workspace is marked unread and the walk excludes the workspace")
    func sendToBackMarksWorkspaceUnread() {
        let tab = UUID()
        let resolver = FakeFocusedResolving()
        resolver.focusedTargetValue = .workspace(tabId: tab, surfaceId: nil)
        let (marker, spy) = makeMarker(resolver: resolver)

        _ = marker.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread()

        #expect(resolver.mutations == ["sendToBack(\(short(tab)),nil)", "storeMarkUnread(\(short(tab)))"])
        #expect(spy.calls == [.workspace(tabId: tab, surfaceId: nil)]) // no pane: its workspace
    }

    // Step-2 review finding 2 (MX1): when the surface id resolves to no panel, the mark is a workspace mark.
    @Test("send to back: a surface id that resolves to no panel marks the workspace, and the walk excludes the workspace, not the surface id")
    func sendToBackWithASurfaceIdAndNoPanelExcludesTheWorkspace() {
        let tab = UUID(), surface = UUID()
        let resolver = FakeFocusedResolving()
        resolver.focusedTargetValue = .workspace(tabId: tab, surfaceId: surface) // no panelByTabSurface entry
        let (marker, spy) = makeMarker(resolver: resolver)

        _ = marker.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread()

        #expect(resolver.mutations == ["sendToBack(\(short(tab)),\(short(surface)))", "storeMarkUnread(\(short(tab)))"])
        #expect(spy.calls == [.workspace(tabId: tab, surfaceId: nil)], "the mark was set under the workspace")
    }

    // The seam split: the marker resolves the focused target once and hands it to `sendToBack`.
    @Test("send to back: the focused target is resolved once, and sendToBack takes it as an argument")
    func sendToBackTakesTheResolvedTargetAsAnArgument() {
        let tab = UUID(), surface = UUID()
        let resolver = FakeFocusedResolving()
        resolver.focusedTargetValue = .workspace(tabId: tab, surfaceId: surface)
        resolver.targetsWithNotifications = [.workspace(tabId: tab, surfaceId: surface)]
        let (marker, _) = makeMarker(resolver: resolver)

        _ = marker.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread()
        #expect(resolver.focusedTargetCalls == 1)

        // Another caller passes its own target: no lookup of the focused one.
        let other = UnreadQueueTarget.workspace(tabId: UUID(), surfaceId: UUID())
        resolver.targetsWithNotifications.insert(other)
        #expect(marker.sendToBack(other) == other)
        #expect(resolver.focusedTargetCalls == 1)
    }

    @Test("send to back is a no-op when no store is present")
    func markOldestNoStore() {
        let resolver = FakeFocusedResolving()
        resolver.hasNotificationStore = false
        resolver.focusedTargetValue = .workspace(tabId: UUID(), surfaceId: nil)
        let (marker, spy) = makeMarker(resolver: resolver)

        #expect(marker.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread() == nil)
        #expect(resolver.mutations.isEmpty)
        #expect(spy.calls.isEmpty)
    }

    private func short(_ id: UUID) -> String { String(id.uuidString.prefix(4)) }
}
