import Foundation
import Testing
@testable import CmuxNotifications

/// The one copy of the unread queue's grouping and order (cm-128.13, F2): the walk and the store's
/// Send to Back both call `UnreadQueue.stops`. The walk's own behaviour stays in
/// `NotificationNavigationCoordinatorTests`; this suite pins the function directly.
@Suite("UnreadQueue")
struct UnreadQueueTests {
    private func snapshot(
        _ tab: UUID,
        _ surface: UUID?,
        at seconds: TimeInterval,
        id: UUID = UUID(),
        isRead: Bool = false,
        clickAction: NotificationNavClickAction? = nil
    ) -> NotificationNavSnapshot {
        NotificationNavSnapshot(
            id: id, tabId: tab, surfaceId: surface, isRead: isRead,
            queuedAt: Date(timeIntervalSince1970: seconds), clickAction: clickAction
        )
    }

    @Test("panes are grouped by workspace and surface, oldest earliest-queuedAt first")
    func groupsByPaneAndOrdersByEarliestQueuedAt() {
        let tab = UUID(), s1 = UUID(), s2 = UUID()
        let a1 = snapshot(tab, s1, at: 10)
        let a2 = snapshot(tab, s1, at: 40)
        let b = snapshot(tab, s2, at: 20)
        let w = snapshot(tab, nil, at: 30)

        let stops = UnreadQueue.stops(in: [a2, w, b, a1])

        #expect(stops.map(\.target) == [
            .workspace(tabId: tab, surfaceId: s1),
            .workspace(tabId: tab, surfaceId: s2),
            .workspace(tabId: tab, surfaceId: nil)
        ])
        #expect(stops[0].queuedAt == a1.queuedAt, "a pane's place is its earliest unread notification")
        #expect(stops[0].newest.id == a2.id, "the stop opens the newest one: store order is newest first")
        #expect(stops[0].memberIds == [a2.id, a1.id])
    }

    @Test("two panes queued at the same time: the lower notification id goes first")
    func tieIsBrokenByNotificationId() {
        let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let high = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFE")!
        let first = snapshot(UUID(), UUID(), at: 5, id: high)
        let second = snapshot(UUID(), UUID(), at: 5, id: low)

        #expect(UnreadQueue.stops(in: [first, second]).map(\.tieBreakId) == [low, high])
    }

    @Test("read notifications and click-action notifications make no stop")
    func readAndClickActionNotificationsMakeNoStop() {
        let tab = UUID()
        let read = snapshot(tab, UUID(), at: 1, isRead: true)
        let click = snapshot(tab, UUID(), at: 2, clickAction: .revealInFinder(path: "/tmp"))
        let plain = snapshot(tab, UUID(), at: 3)

        #expect(UnreadQueue.stops(in: [read, click, plain]).map(\.newest.id) == [plain.id])
    }

    @Test("the excluded pane's stop is left out, workspace-level notifications of its workspace with it")
    func excludedPaneLeavesItsStopOut() {
        let tab = UUID(), pane = UUID()
        let own = snapshot(tab, pane, at: 1)
        let workspaceLevel = snapshot(tab, nil, at: 2)
        let other = snapshot(UUID(), UUID(), at: 3)

        let stops = UnreadQueue.stops(in: [other, workspaceLevel, own], excludingPane: .workspace(tabId: tab, surfaceId: pane))

        #expect(stops.map(\.newest.id) == [other.id])
    }
}
