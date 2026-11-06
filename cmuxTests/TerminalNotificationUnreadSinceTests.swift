import CmuxNotifications
import CmuxSettings
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The store's half of ⌘⇧U's unread queue (cm-128.11): the time each notification went unread
/// (`queuedAt`, "unread since"), what a newer notification on a pane inherits, and what reading and
/// Mark as Unread leave alone. The walk itself is tested in `CmuxNotificationsTests` and
/// `NotificationJumpOldestFirstTests`.
@MainActor
final class TerminalNotificationUnreadSinceTests: XCTestCase {
    private let store = TerminalNotificationStore.shared

    override func setUp() {
        super.setUp()
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
    }

    override func tearDown() {
        store.resetNotificationDeliveryHandlerForTesting()
        store.replaceNotificationsForTesting([])
        super.tearDown()
    }

    private func notification(
        tab: UUID = UUID(),
        surface: UUID? = UUID(),
        queuedAt: TimeInterval,
        createdAt: TimeInterval? = nil,
        isRead: Bool = false,
        correlationKey: String? = nil
    ) -> TerminalNotification {
        TerminalNotification(
            id: UUID(),
            tabId: tab,
            surfaceId: surface,
            correlationKey: correlationKey,
            title: "t",
            subtitle: "",
            body: "",
            createdAt: Date(timeIntervalSince1970: createdAt ?? queuedAt),
            queuedAt: Date(timeIntervalSince1970: queuedAt),
            isRead: isRead
        )
    }

    /// Records through the store's real path and returns the notification it stored, or nil when it kept none.
    @discardableResult
    private func record(tab: UUID, surface: UUID, key: String? = nil) -> TerminalNotification? {
        let before = Set(store.notifications.map(\.id))
        store.addNotification(
            tabId: tab, surfaceId: surface, title: "t", subtitle: "", body: "",
            retargetsToLiveSurfaceOwner: false, correlationKey: key
        )
        return store.notifications.first(where: { !before.contains($0.id) })
    }

    private func queuedAt(_ id: UUID) -> Date? {
        store.notifications.first(where: { $0.id == id })?.queuedAt
    }

    // MARK: Scenario 152: a pane that notifies again keeps its place

    func testKeyedRenotifyInheritsTheEarlierUnreadQueuedAt() throws {
        let tab = UUID(), surface = UUID()
        let first = try XCTUnwrap(record(tab: tab, surface: surface, key: "turn-1"))
        Thread.sleep(forTimeInterval: 0.02)
        let again = try XCTUnwrap(record(tab: tab, surface: surface, key: "turn-1"))

        XCTAssertNil(queuedAt(first.id), "the first entry was replaced")
        XCTAssertEqual(again.queuedAt, first.queuedAt, "a re-sent reminder keeps its pane's place")
        XCTAssertLessThan(again.queuedAt, again.createdAt, "while its own time is later: he lands on the newest text")
    }

    func testKeylessRenotifyInheritsTheEarliestUnreadQueuedAtOfEveryEntryItReplaces() throws {
        let tab = UUID(), surface = UUID()
        let early = notification(tab: tab, surface: surface, queuedAt: 100)
        let later = notification(tab: tab, surface: surface, queuedAt: 300)
        store.replaceNotificationsForTesting([later, early])

        let again = try XCTUnwrap(record(tab: tab, surface: surface))

        XCTAssertEqual(store.notifications.map(\.id), [again.id], "a keyless notification replaces every one on its pane")
        XCTAssertEqual(again.queuedAt, Date(timeIntervalSince1970: 100))
    }

    func testRenotifyIgnoresReadEntriesAndTakesItsOwnTime() throws {
        let tab = UUID(), surface = UUID()
        let read = notification(tab: tab, surface: surface, queuedAt: 100, isRead: true)
        store.replaceNotificationsForTesting([read])

        let again = try XCTUnwrap(record(tab: tab, surface: surface))

        XCTAssertEqual(again.queuedAt, again.createdAt, "a read entry's time is not the pane's place: it left the queue")
    }

    func testANotificationOnAnotherPaneKeepsItsOwnTime() throws {
        let tab = UUID()
        let other = notification(tab: tab, surface: UUID(), queuedAt: 100)
        store.replaceNotificationsForTesting([other])

        let new = try XCTUnwrap(record(tab: tab, surface: UUID()))

        XCTAssertEqual(queuedAt(other.id), Date(timeIntervalSince1970: 100))
        XCTAssertEqual(new.queuedAt, new.createdAt)
    }

    // MARK: Scenario 163: reading and Mark as Unread leave the place

    func testMarkUnreadByIdPutsANotificationBackAtItsOldPlace() throws {
        // createdAt differs from queuedAt (as after a supersede), so "back to createdAt" would be visible
        let c = notification(queuedAt: 0, createdAt: 500)
        store.replaceNotificationsForTesting([c])
        store.markRead(id: c.id)
        XCTAssertEqual(queuedAt(c.id), Date(timeIntervalSince1970: 0), "reading leaves the place")

        store.markUnread(id: c.id)

        XCTAssertEqual(store.notifications.first?.isRead, false)
        XCTAssertEqual(queuedAt(c.id), Date(timeIntervalSince1970: 0), "Mark as Unread puts it back where it was")
    }

    func testMarkNotificationFeedUnreadPutsItBackAtItsOldPlaceToo() throws {
        let c = notification(queuedAt: 0, createdAt: 500, isRead: true)
        store.replaceNotificationsForTesting([c])

        XCTAssertGreaterThanOrEqual(store.markNotificationFeedUnread(ids: [c.id]), 0)

        XCTAssertEqual(store.notifications.first?.isRead, false)
        XCTAssertEqual(queuedAt(c.id), Date(timeIntervalSince1970: 0), "the iPhone's path keeps the place as the popover's does")
    }

    // MARK: Scenario 157: Send to Back

    private let sentAt = Date(timeIntervalSince1970: 1_000)

    func testSendToBackSetsQueuedAtToNowOnEveryUnreadNotificationOfThePaneOnly() {
        let tab = UUID(), surface = UUID()
        let first = notification(tab: tab, surface: surface, queuedAt: 10)
        let second = notification(tab: tab, surface: surface, queuedAt: 20)
        let otherPane = notification(tab: tab, surface: UUID(), queuedAt: 15)
        store.replaceNotificationsForTesting([second, otherPane, first])

        XCTAssertTrue(store.sendToBack(.workspace(tabId: tab, surfaceId: surface), now: sentAt))

        XCTAssertEqual(queuedAt(first.id), sentAt)
        XCTAssertEqual(queuedAt(second.id), sentAt)
        XCTAssertEqual(queuedAt(otherPane.id), Date(timeIntervalSince1970: 15), "another pane keeps its place")
        XCTAssertEqual(store.notifications.map(\.id), [second.id, otherPane.id, first.id], "nothing moves in the array")
    }

    func testSendToBackOfAReadPaneMakesItsNewestNotificationUnreadAtTheBack() {
        let tab = UUID(), surface = UUID()
        let older = notification(tab: tab, surface: surface, queuedAt: 10, isRead: true)
        let newest = notification(tab: tab, surface: surface, queuedAt: 20, isRead: true)
        store.replaceNotificationsForTesting([newest, older])

        XCTAssertTrue(store.sendToBack(.workspace(tabId: tab, surfaceId: surface), now: sentAt))

        XCTAssertEqual(store.notifications.first(where: { $0.id == newest.id })?.isRead, false)
        XCTAssertEqual(queuedAt(newest.id), sentAt)
        XCTAssertEqual(store.notifications.first(where: { $0.id == older.id })?.isRead, true, "only the newest turn comes back")
        XCTAssertEqual(queuedAt(older.id), Date(timeIntervalSince1970: 10))
    }

    func testSendToBackClearsHisMarkOnThePaneAsTheOldMoveDid() {
        let tab = UUID(), surface = UUID()
        let n = notification(tab: tab, surface: surface, queuedAt: 10, isRead: true)
        store.replaceNotificationsForTesting([n])
        XCTAssertTrue(store.markWindowDockSurfaceUnread(windowId: tab, surfaceId: surface))

        XCTAssertTrue(store.sendToBack(.workspace(tabId: tab, surfaceId: surface), now: sentAt))

        XCTAssertFalse(store.hasManualUnread(forTabId: tab, surfaceId: surface), "the notification now provides the unread state")
    }

    // Step-2 review finding 3: when the newest notification is already unread, the unread path changes nothing,
    // so only sendToBack's own clears take his marks off the pane.
    func testSendToBackClearsHisMarksBesideAnAlreadyUnreadNewestNotification() {
        let tab = UUID(), surface = UUID()
        let n = notification(tab: tab, surface: surface, queuedAt: 10)
        store.replaceNotificationsForTesting([n])
        store.markUnread(forTabId: tab, surfaceId: surface)
        store.markUnread(forTabId: tab)
        defer { store.clearWindowDockSurfaceUnread(windowId: tab, surfaceId: surface) }
        XCTAssertTrue(store.hasManualUnread(forTabId: tab, surfaceId: surface))
        XCTAssertTrue(store.hasManualUnread(forTabId: tab))

        XCTAssertTrue(store.sendToBack(.workspace(tabId: tab, surfaceId: surface), now: sentAt))

        XCTAssertFalse(store.hasManualUnread(forTabId: tab, surfaceId: surface), "the notification provides the unread state")
        XCTAssertFalse(store.hasManualUnread(forTabId: tab))
        XCTAssertEqual(queuedAt(n.id), sentAt)
    }

    // Step-2 review finding 1 (the lead's call (3)): the workspace-level notifications of the pane's workspace go back with it.
    func testSendToBackAlsoSendsBackTheUnreadWorkspaceLevelNotificationsOfItsWorkspace() {
        let tab = UUID(), surface = UUID(), otherTab = UUID()
        let own = notification(tab: tab, surface: surface, queuedAt: 10)
        let w = notification(tab: tab, surface: nil, queuedAt: 5)
        let readW = notification(tab: tab, surface: nil, queuedAt: 6, isRead: true)
        let sibling = notification(tab: tab, surface: UUID(), queuedAt: 7)
        let otherWorkspaceW = notification(tab: otherTab, surface: nil, queuedAt: 8)
        store.replaceNotificationsForTesting([own, otherWorkspaceW, sibling, readW, w])

        XCTAssertTrue(store.sendToBack(.workspace(tabId: tab, surfaceId: surface), now: sentAt))

        XCTAssertEqual(queuedAt(w.id), sentAt)
        XCTAssertEqual(queuedAt(readW.id), Date(timeIntervalSince1970: 6), "a read one stays read, in place")
        XCTAssertEqual(store.notifications.first(where: { $0.id == readW.id })?.isRead, true)
        XCTAssertEqual(queuedAt(sibling.id), Date(timeIntervalSince1970: 7), "a sibling pane keeps its place")
        XCTAssertEqual(queuedAt(otherWorkspaceW.id), Date(timeIntervalSince1970: 8), "another workspace keeps its place")
    }

    func testSendToBackOfAPaneWithNoNotificationStillSendsBackItsWorkspacesWorkspaceLevelNotification() {
        let tab = UUID()
        let w = notification(tab: tab, surface: nil, queuedAt: 5)
        store.replaceNotificationsForTesting([w])

        XCTAssertFalse(store.sendToBack(.workspace(tabId: tab, surfaceId: UUID()), now: sentAt), "the pane has none of its own")

        XCTAssertEqual(queuedAt(w.id), sentAt)
    }

    // Step-2 review finding 6: the exact-surface rule of the old marker test, now the store's.
    func testSendToBackOfADockSurfaceLeavesASiblingSurfacesNotificationAlone() {
        let window = UUID()
        let x = WindowDockUnreadTarget(windowId: window, surfaceId: UUID())
        let sibling = notification(tab: window, surface: UUID(), queuedAt: 15)
        let windowLevel = notification(tab: window, surface: nil, queuedAt: 16)
        store.replaceNotificationsForTesting([windowLevel, sibling])
        defer { store.clearWindowDockSurfaceUnread(windowId: window, surfaceId: x.surfaceId) }

        XCTAssertFalse(store.sendToBack(.windowDock(x), now: sentAt), "x has no notification of its own")

        XCTAssertEqual(queuedAt(sibling.id), Date(timeIntervalSince1970: 15))
        XCTAssertEqual(queuedAt(windowLevel.id), Date(timeIntervalSince1970: 16))
        XCTAssertEqual(store.windowDockUnreadTargets, [x], "x is marked on its own")
    }

    func testSendToBackThenReadThenMarkUnreadKeepsTheBackPlace() {
        let tab = UUID(), surface = UUID()
        let d = notification(tab: tab, surface: surface, queuedAt: 0.5, createdAt: 0.5)
        store.replaceNotificationsForTesting([d])
        store.sendToBack(.workspace(tabId: tab, surfaceId: surface), now: sentAt)
        store.markRead(id: d.id)

        store.markUnread(id: d.id)

        XCTAssertEqual(queuedAt(d.id), sentAt, "Mark as Unread puts it back where Send to Back left it: at the back")
    }

    func testSendToBackWithNoNotificationReturnsFalseAndMarksOnlyAWorkspace() {
        let tab = UUID()
        XCTAssertFalse(store.sendToBack(.workspace(tabId: tab, surfaceId: UUID())))
        XCTAssertFalse(store.workspaceIsUnread(forTabId: tab), "a pane's mark is the caller's, not the store's")
        XCTAssertFalse(store.sendToBack(.workspace(tabId: tab, surfaceId: nil)))
        XCTAssertTrue(store.workspaceIsUnread(forTabId: tab), "the guard from .4: no pane, no notification, so the workspace is marked")
    }

    func testSendToBackMovesAnAlreadyMarkedDockSurfaceToTheEndOfTheDockMarks() {
        let window = UUID()
        let x = WindowDockUnreadTarget(windowId: window, surfaceId: UUID())
        let y = WindowDockUnreadTarget(windowId: window, surfaceId: UUID())
        XCTAssertTrue(store.markWindowDockSurfaceUnread(windowId: window, surfaceId: x.surfaceId))
        XCTAssertTrue(store.markWindowDockSurfaceUnread(windowId: window, surfaceId: y.surfaceId))
        defer {
            store.clearWindowDockSurfaceUnread(windowId: window, surfaceId: x.surfaceId)
            store.clearWindowDockSurfaceUnread(windowId: window, surfaceId: y.surfaceId)
        }

        XCTAssertFalse(store.sendToBack(.windowDock(x)))

        XCTAssertEqual(store.windowDockUnreadTargets, [y, x], "it used to keep its place")
    }

    func testSendToBackMarksAnUnmarkedDockSurfaceAtTheEnd() {
        let window = UUID()
        let x = WindowDockUnreadTarget(windowId: window, surfaceId: UUID())
        let y = WindowDockUnreadTarget(windowId: window, surfaceId: UUID())
        XCTAssertTrue(store.markWindowDockSurfaceUnread(windowId: window, surfaceId: x.surfaceId))
        defer {
            store.clearWindowDockSurfaceUnread(windowId: window, surfaceId: x.surfaceId)
            store.clearWindowDockSurfaceUnread(windowId: window, surfaceId: y.surfaceId)
        }

        XCTAssertFalse(store.sendToBack(.windowDock(y)))

        XCTAssertEqual(store.windowDockUnreadTargets, [x, y])
    }

    func testSendToBackOfADockSurfaceWithANotificationSendsThatBack() {
        let window = UUID(), surface = UUID()
        let n = notification(tab: window, surface: surface, queuedAt: 10)
        store.replaceNotificationsForTesting([n])

        XCTAssertTrue(store.sendToBack(.windowDock(WindowDockUnreadTarget(windowId: window, surfaceId: surface)), now: sentAt))

        XCTAssertEqual(queuedAt(n.id), sentAt)
        XCTAssertTrue(store.windowDockUnreadTargets.isEmpty, "no Dock mark beside a notification")
    }

    // MARK: Scenario 155: Dock marks are listed oldest first

    func testWindowDockMarksAreListedOldestFirst() {
        let window = UUID()
        let x = UUID(), y = UUID()
        XCTAssertTrue(store.markWindowDockSurfaceUnread(windowId: window, surfaceId: x))
        XCTAssertTrue(store.markWindowDockSurfaceUnread(windowId: window, surfaceId: y))
        defer {
            store.clearWindowDockSurfaceUnread(windowId: window, surfaceId: x)
            store.clearWindowDockSurfaceUnread(windowId: window, surfaceId: y)
        }

        XCTAssertEqual(
            store.windowDockUnreadTargets,
            [WindowDockUnreadTarget(windowId: window, surfaceId: x), WindowDockUnreadTarget(windowId: window, surfaceId: y)]
        )
    }

    // MARK: Scenario 158: the place survives a relaunch

    private func roundTrip(_ notification: TerminalNotification) throws -> TerminalNotification {
        let data = try JSONEncoder().encode(SessionNotificationSnapshot(notification: notification))
        let decoded = try JSONDecoder().decode(SessionNotificationSnapshot.self, from: data)
        return decoded.terminalNotification(
            tabId: notification.tabId, surfaceId: notification.surfaceId, panelId: notification.panelId
        )
    }

    func testSnapshotRoundTripKeepsQueuedAt() throws {
        let n = notification(queuedAt: 10, createdAt: 50)

        let restored = try roundTrip(n)

        XCTAssertEqual(restored.queuedAt, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(restored.createdAt, Date(timeIntervalSince1970: 50), "its own time is separate")
    }

    func testARestoredReadNotificationKeepsQueuedAtToo() throws {
        let n = notification(queuedAt: 10, createdAt: 50, isRead: true)

        XCTAssertEqual(try roundTrip(n).queuedAt, Date(timeIntervalSince1970: 10), "Mark as Unread after a relaunch finds the old place")
    }

    func testASnapshotSavedWithoutQueuedAtRestoresAtCreatedAt() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"t","subtitle":"","body":"","createdAt":50,"isRead":false}
        """
        let decoded = try JSONDecoder().decode(SessionNotificationSnapshot.self, from: Data(json.utf8))

        let restored = decoded.terminalNotification(tabId: UUID(), surfaceId: UUID(), panelId: nil)

        XCTAssertNil(decoded.queuedAt)
        XCTAssertEqual(restored.queuedAt, Date(timeIntervalSince1970: 50))
    }

    func testRestoreSessionNotificationsKeepsEachQueuedAtAndSoTheWalkOrder() throws {
        let tab = UUID()
        // Created in the reverse of the order they went unread, so createdAt would give the wrong order.
        let first = notification(tab: tab, surface: UUID(), queuedAt: 1, createdAt: 30)
        let second = notification(tab: tab, surface: UUID(), queuedAt: 2, createdAt: 20)
        let third = notification(tab: tab, surface: UUID(), queuedAt: 3, createdAt: 10)
        let saved = try [third, second, first].map(roundTrip)

        store.restoreSessionNotifications(saved, forTabId: tab)

        let order = store.notifications.sorted { $0.queuedAt < $1.queuedAt }.map(\.id)
        XCTAssertEqual(order, [first.id, second.id, third.id], "the order before saving")
        XCTAssertEqual(store.notifications.first(where: { $0.id == first.id })?.createdAt, Date(timeIntervalSince1970: 30))
    }

    func testRestoreIdCollisionCopyKeepsQueuedAt() {
        let collidingId = UUID()
        let otherTab = UUID(), tab = UUID(), surface = UUID()
        let existing = TerminalNotification(
            id: collidingId, tabId: otherTab, surfaceId: UUID(), title: "t", subtitle: "", body: "",
            createdAt: Date(timeIntervalSince1970: 5), isRead: false
        )
        let restoring = TerminalNotification(
            id: collidingId, tabId: tab, surfaceId: surface, title: "t", subtitle: "", body: "",
            createdAt: Date(timeIntervalSince1970: 50), queuedAt: Date(timeIntervalSince1970: 10), isRead: false
        )
        store.replaceNotificationsForTesting([existing])

        store.restoreSessionNotifications([restoring], forTabId: tab)

        let copy = store.notifications.first(where: { $0.tabId == tab })
        XCTAssertNotNil(copy)
        XCTAssertNotEqual(copy?.id, collidingId, "the id collided, so restore rebuilt the notification field by field")
        XCTAssertEqual(copy?.queuedAt, Date(timeIntervalSince1970: 10))
    }

    func testRebindSurfaceNotificationsKeepsQueuedAt() {
        let source = UUID(), destination = UUID(), surface = UUID()
        let n = notification(tab: source, surface: surface, queuedAt: 10, createdAt: 50)
        store.replaceNotificationsForTesting([n])

        store.rebindSurfaceNotifications(fromTabId: source, toTabId: destination, surfaceId: surface)

        let moved = store.notifications.first(where: { $0.id == n.id })
        XCTAssertEqual(moved?.tabId, destination)
        XCTAssertEqual(moved?.queuedAt, Date(timeIntervalSince1970: 10), "a pane that moves to another workspace keeps its place")
    }

    // MARK: Scenario 161: the two Settings rows read the localized keys

    func testTheTwoSettingsRowsReadTheLocalizedKeys() throws {
        let rows: [(ShortcutAction, String, String)] = [
            (.jumpToUnread, "shortcut.jumpToUnread.label", "Jump to Oldest Unread"),
            (.markOldestUnreadAndJumpNext, "shortcut.markOldestUnreadAndJumpNext.label", "Send to Back of Unread Queue and Jump to Next"),
        ]
        let germanPath = try XCTUnwrap(Bundle.main.path(forResource: "de", ofType: "lproj"))
        let german = try XCTUnwrap(Bundle(path: germanPath))
        for (action, key, english) in rows {
            XCTAssertEqual(action.displayName, english)
            // The row is the catalog's value, not a hard-coded string: a literal would not follow the catalog.
            XCTAssertEqual(action.displayName, Bundle.main.localizedString(forKey: key, value: "MISSING", table: nil), key)
            // And the catalog carries a translation, so a German Settings list does not read English.
            let translated = german.localizedString(forKey: key, value: "MISSING", table: nil)
            XCTAssertNotEqual(translated, "MISSING", key)
            XCTAssertNotEqual(translated, english, key)
        }
    }

    // MARK: Wiring: the field reaches the walk

    func testNavigationSnapshotCarriesQueuedAt() {
        let n = notification(queuedAt: 42, createdAt: 99)
        XCTAssertEqual(n.notificationNavigationSnapshot.queuedAt, Date(timeIntervalSince1970: 42))
    }
}
