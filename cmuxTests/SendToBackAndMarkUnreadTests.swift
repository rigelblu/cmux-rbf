import Bonsplit // (cm-128.13) step 10 (TabID, PaneID)
import Combine
import CmuxCommandPalette // cmux-rbf: step 4b R2 (CommandPaletteHandlerRegistry)
import CmuxNotifications
import CmuxUpdater // cmux-rbf: step 4b R2 (UpdateStateModel)
import CmuxWorkspaces
import SwiftUI
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Send to Back over several targets, and Mark as Unread that puts a notification back where it was
/// (cm-128.13). The store's half (the order several panes keep, the stamps they take, the row a menu sends, the put-back mark), the four
/// dismissal checks, every Mark as Unread entrance, the Send to Back menu items (AppKit row, SwiftUI row, workspace tab, Dock tab) and the
/// popover row's dot.
///
/// NOT driven by any test (reverting any of them passes every test here):
/// - the one line in `ContentView.registerCommandPaletteHandlers` that calls `registerMarkWorkspaceUnreadPaletteHandler` (the handler itself
///   is driven), and the menu bar Button's forwarder `cmuxApp.markSelectedWorkspaceUnread(in:)` (the static it calls is driven): live checks in
///   Scenario 189's human steps;
/// - the SwiftUI menu's Button action (`actions.sendToBack`): no live check covers it (Scenario 182 runs the AppKit sidebar, the default, and the
///   SwiftUI row only shows with the `sidebar-appkit-list-experiment` flag off);
/// - `AppDelegate.jumpToOldestUnread`'s `derivedPutBackExclusion` flag (`AppDelegate.swift`, `let derivedPutBackExclusion = excludedPane == nil`, passed as
///   `mapsExclusionThroughOwningPanel:`): the package tests pass the flag explicitly, and a test through the app needs a remote tmux workspace whose
///   inner surface and container have different ids (`RemoteTmuxMirrorRenameHarness`); ⌘⌃U always passes a non-nil exclusion, so it never sets the flag;
/// - the Dock's surface-creating session restore (the restore tests drive `adoptManualUnreadState`, one call below it).
@MainActor
final class SendToBackAndMarkUnreadTests: XCTestCase {
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

    // MARK: Fixtures

    /// A fixed id so a tie between two notifications is decided by a known id, never by chance.
    private func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    private func notification(
        id: UUID = UUID(),
        tab: UUID,
        surface: UUID?,
        queuedAt: TimeInterval,
        isRead: Bool = false,
        isPutBack: Bool = false,
        correlationKey: String? = nil
    ) -> TerminalNotification {
        TerminalNotification(
            id: id,
            tabId: tab,
            surfaceId: surface,
            correlationKey: correlationKey,
            title: "t",
            subtitle: "",
            body: "",
            createdAt: Date(timeIntervalSince1970: queuedAt),
            queuedAt: Date(timeIntervalSince1970: queuedAt),
            isRead: isRead,
            isPutBack: isPutBack
        )
    }

    private func queuedAt(_ id: UUID) -> Date? {
        store.notifications.first(where: { $0.id == id })?.queuedAt
    }

    /// The order a ⌘⇧U walk takes the panes in: the newest notification of each stop, oldest stop first.
    /// This is the function the walk itself calls (`UnreadQueue.stops`), over the store's own snapshots.
    private func walkOrder() -> [UUID] {
        UnreadQueue.stops(in: store.notifications.map(\.notificationNavigationSnapshot)).map(\.newest.id)
    }

    private func pane(_ tab: UUID, _ surface: UUID?) -> UnreadQueueTarget {
        .workspace(tabId: tab, surfaceId: surface)
    }

    private func ms(_ milliseconds: Double) -> TimeInterval { milliseconds / 1000 }

    // MARK: Scenario 170, store half: the pane he isn't on goes to the back

    func testSendToBackPaneHeIsNotOnMovesToBack() {
        let a = notification(tab: UUID(), surface: UUID(), queuedAt: 10)
        let b = notification(tab: UUID(), surface: UUID(), queuedAt: 20)
        let c = notification(tab: UUID(), surface: UUID(), queuedAt: 30)
        store.replaceNotificationsForTesting([c, b, a])
        let sentAt = Date()

        let answers = store.sendToBack([pane(a.tabId, a.surfaceId)], now: sentAt)

        XCTAssertEqual(answers, [true])
        XCTAssertEqual(walkOrder(), [b.id, c.id, a.id], "A was first; it is now last")
        XCTAssertEqual(queuedAt(a.id), sentAt)
        XCTAssertEqual(queuedAt(b.id), Date(timeIntervalSince1970: 20), "another pane keeps its place")
        XCTAssertEqual(queuedAt(c.id), Date(timeIntervalSince1970: 30))
    }

    // MARK: Scenario 172, 173 (store halves): several targets keep the order they had

    func testSeveralTargetsOfOneRowKeepTheirOrderAtTheBack() {
        let tab = UUID()
        // The lower id belongs to the later pane: a shared `now` would hand their order to the id.
        let x1 = notification(id: id(900), tab: tab, surface: UUID(), queuedAt: 10)
        let x2 = notification(id: id(100), tab: tab, surface: UUID(), queuedAt: 20)
        let y = notification(tab: UUID(), surface: UUID(), queuedAt: 15)
        store.replaceNotificationsForTesting([y, x2, x1])
        let sentAt = Date()

        // Passed back to front on purpose: the menus pass their targets in any order.
        let answers = store.sendToBack([pane(tab, x2.surfaceId), pane(tab, x1.surfaceId)], now: sentAt)

        XCTAssertEqual(answers, [true, true], "one answer per target, in the order given")
        XCTAssertEqual(walkOrder(), [y.id, x1.id, x2.id], "Y waits at 15; X1 then X2, the order they had")
        XCTAssertEqual(queuedAt(x1.id), sentAt.addingTimeInterval(-ms(1)))
        XCTAssertEqual(queuedAt(x2.id), sentAt, "the last stop sits exactly at now")
    }

    // F1: a workspace-level notification is a stop of its own, in the order the queue gives it
    func testRowWithWorkspaceLevelNotificationAndPanesKeepsQueueOrder() {
        let tab = UUID()
        // Ids chosen so that, with one shared `now`, P1 would sort ahead of W.
        let w = notification(id: id(900), tab: tab, surface: nil, queuedAt: 1)
        let p1 = notification(id: id(100), tab: tab, surface: UUID(), queuedAt: 2)
        let p2 = notification(id: id(500), tab: tab, surface: UUID(), queuedAt: 3)
        let b = notification(tab: UUID(), surface: UUID(), queuedAt: 1.5)
        store.replaceNotificationsForTesting([p2, p1, b, w])
        let sentAt = Date()

        _ = store.sendToBack([pane(tab, p1.surfaceId), pane(tab, p2.surfaceId)], now: sentAt)

        XCTAssertEqual(walkOrder(), [b.id, w.id, p1.id, p2.id], "B waits; then W, P1, P2 as they were queued")
        XCTAssertEqual(queuedAt(w.id), sentAt.addingTimeInterval(-ms(2)))
        XCTAssertEqual(queuedAt(p1.id), sentAt.addingTimeInterval(-ms(1)))
        XCTAssertEqual(queuedAt(p2.id), sentAt)
        XCTAssertEqual(queuedAt(b.id), Date(timeIntervalSince1970: 1.5), "a pane not sent keeps its place")
    }

    func testSeveralRowsSelectedKeepTheirRelativeOrder() {
        let tab1 = UUID(), tab2 = UUID()
        let c = notification(tab: UUID(), surface: UUID(), queuedAt: 25)
        let a1 = notification(id: id(900), tab: tab1, surface: UUID(), queuedAt: 10)
        let b1 = notification(id: id(500), tab: tab2, surface: UUID(), queuedAt: 20)
        let a2 = notification(id: id(100), tab: tab1, surface: UUID(), queuedAt: 30)
        store.replaceNotificationsForTesting([a2, b1, a1, c])

        store.sendToBack(store.rowTargetsToSendBack(forWorkspaceIds: [tab2, tab1]), now: Date())

        XCTAssertEqual(walkOrder(), [c.id, a1.id, b1.id, a2.id], "C waits; the rows' panes keep their relative order across rows")
    }

    // The order is the queue's, whatever order the targets come in, and a read target sorts by its old place.
    func testReadTargetSortsByItsOldPlaceAmongTheOthers() {
        let readTab = UUID(), unreadTab = UUID()
        let read = notification(tab: readTab, surface: UUID(), queuedAt: 10, isRead: true)
        let unread = notification(tab: unreadTab, surface: UUID(), queuedAt: 30)
        store.replaceNotificationsForTesting([unread, read])
        let sentAt = Date()

        let answers = store.sendToBack([pane(unreadTab, unread.surfaceId), pane(readTab, read.surfaceId)], now: sentAt)

        XCTAssertEqual(answers, [true, true])
        XCTAssertEqual(store.notifications.first(where: { $0.id == read.id })?.isRead, false, "the read target came back unread")
        XCTAssertEqual(walkOrder(), [read.id, unread.id], "the read one's old place (10) is earlier than 30")
        XCTAssertEqual(queuedAt(read.id), sentAt.addingTimeInterval(-ms(1)))
        XCTAssertEqual(queuedAt(unread.id), sentAt)
    }

    // One copy of the queue order: the store's tie-break is the walk's, so breaking it once breaks both suites.
    func testStoreQueueOrderTieBreakIsTheLowerNotificationId() {
        let high = notification(id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFE")!, tab: UUID(), surface: UUID(), queuedAt: 5)
        let low = notification(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, tab: UUID(), surface: UUID(), queuedAt: 5)
        store.replaceNotificationsForTesting([high, low])
        let sentAt = Date()

        _ = store.sendToBack([pane(high.tabId, high.surfaceId), pane(low.tabId, low.surfaceId)], now: sentAt)

        XCTAssertEqual(walkOrder(), [low.id, high.id])
        XCTAssertEqual(queuedAt(low.id), sentAt.addingTimeInterval(-ms(1)), "the lower id was ahead, so it is the earlier stamp")
        XCTAssertEqual(queuedAt(high.id), sentAt)
    }

    // A target with no notification answers false and moves nothing; the others still go.
    func testEachTargetAnswersWhetherItHadANotification() {
        let tab = UUID()
        let held = notification(tab: tab, surface: UUID(), queuedAt: 10)
        let other = notification(tab: UUID(), surface: UUID(), queuedAt: 5)
        store.replaceNotificationsForTesting([held, other])

        let answers = store.sendToBack([pane(tab, UUID()), pane(tab, held.surfaceId)], now: Date())

        XCTAssertEqual(answers, [false, true])
        XCTAssertEqual(walkOrder(), [other.id, held.id])
    }

    // MARK: Scenario 174, 175, 190: what arrives after, and the lone pane

    func testALaterFinishGoesBehindTheSkippedPane() throws {
        let a = notification(tab: UUID(), surface: UUID(), queuedAt: 10)
        let b = notification(tab: UUID(), surface: UUID(), queuedAt: 20)
        store.replaceNotificationsForTesting([b, a])
        store.sendToBack([pane(a.tabId, a.surfaceId)], now: Date())

        let later = UUID()
        store.addNotification(tabId: later, surfaceId: UUID(), title: "t", subtitle: "", body: "",
                              retargetsToLiveSurfaceOwner: false, correlationKey: nil)
        let c = try XCTUnwrap(store.notifications.first(where: { $0.tabId == later }), "C was recorded")

        XCTAssertEqual(walkOrder(), [b.id, a.id, c.id], "C finished after the skip, so it is behind A")
    }

    func testSendToBackWithNothingElseWaitingKeepsItNextAndLaterArrivalsBehindIt() throws {
        let a = notification(tab: UUID(), surface: UUID(), queuedAt: 10)
        store.replaceNotificationsForTesting([a])
        store.sendToBack([pane(a.tabId, a.surfaceId)], now: Date())
        XCTAssertEqual(walkOrder(), [a.id], "the lone pane is still the next stop")

        let later = UUID()
        store.addNotification(tabId: later, surfaceId: UUID(), title: "t", subtitle: "", body: "",
                              retargetsToLiveSurfaceOwner: false, correlationKey: nil)
        let y = try XCTUnwrap(store.notifications.first(where: { $0.tabId == later }), "Y was recorded")

        XCTAssertEqual(walkOrder(), [a.id, y.id], "Y arrived after the skip, so it opens after A")
    }

    func testASkippedPaneThatNotifiesAgainStaysAtTheBack() {
        let a = notification(tab: UUID(), surface: UUID(), queuedAt: 10)
        let b = notification(tab: UUID(), surface: UUID(), queuedAt: 20)
        store.replaceNotificationsForTesting([b, a])
        let sentAt = Date()
        store.sendToBack([pane(a.tabId, a.surfaceId)], now: sentAt)

        store.addNotification(tabId: a.tabId, surfaceId: a.surfaceId, title: "t", subtitle: "", body: "",
                              retargetsToLiveSurfaceOwner: false, correlationKey: nil)
        let renotified = store.notifications.first(where: { $0.tabId == a.tabId && $0.id != a.id })

        XCTAssertEqual(renotified?.queuedAt, sentAt, "it inherits the place it was sent back to")
        XCTAssertEqual(walkOrder().last, renotified?.id, "A is still behind B")
        XCTAssertEqual(walkOrder().count, 2)
    }

    // MARK: Rows: what a row sends, and when the item is on

    func testAnUnreadRowSendsEveryPaneThatHoldsAnUnreadNotification() {
        let tab = UUID(), p1 = UUID(), p2 = UUID(), p3 = UUID()
        let n1 = notification(tab: tab, surface: p1, queuedAt: 10)
        let n2 = notification(tab: tab, surface: p2, queuedAt: 20)
        let readOnly = notification(tab: tab, surface: p3, queuedAt: 30, isRead: true)
        let w = notification(tab: tab, surface: nil, queuedAt: 5)
        store.replaceNotificationsForTesting([readOnly, n2, n1, w])

        let targets = Set(store.rowTargetsToSendBack(forWorkspaceIds: [tab]))

        XCTAssertEqual(targets, [pane(tab, p1), pane(tab, p2), pane(tab, nil)],
                       "the unread panes and the workspace-level notification as its own pane; a read pane waits")
    }

    func testAReadRowSendsThePaneOfItsNewestNotification() {
        let tab = UUID(), older = UUID(), newest = UUID()
        let n1 = notification(tab: tab, surface: older, queuedAt: 10, isRead: true)
        let n2 = notification(tab: tab, surface: newest, queuedAt: 20, isRead: true)
        store.replaceNotificationsForTesting([n2, n1])

        XCTAssertEqual(store.rowTargetsToSendBack(forWorkspaceIds: [tab]), [pane(tab, newest)])
    }

    func testCanSendToBackIsOnWhenAnyRowHoldsANotificationAndNotForMarksAlone() {
        let unreadTab = UUID(), readTab = UUID(), markTab = UUID(), emptyTab = UUID()
        store.replaceNotificationsForTesting([
            notification(tab: unreadTab, surface: UUID(), queuedAt: 10),
            notification(tab: readTab, surface: UUID(), queuedAt: 20, isRead: true)
        ])
        store.markUnread(forTabId: markTab)
        defer { store.markRead(forTabId: markTab) }
        XCTAssertTrue(store.hasManualUnread(forTabId: markTab), "setup: the row carries his mark")

        XCTAssertTrue(store.canSendToBack(forWorkspaceIds: [unreadTab]))
        XCTAssertTrue(store.canSendToBack(forWorkspaceIds: [readTab]), "a read target is on: it comes back unread")
        XCTAssertFalse(store.canSendToBack(forWorkspaceIds: [markTab]), "his mark alone is neither an unread nor a read target")
        XCTAssertFalse(store.canSendToBack(forWorkspaceIds: [emptyTab]))
        XCTAssertTrue(store.canSendToBack(forWorkspaceIds: [emptyTab, markTab, readTab]), "any one row is enough")
        XCTAssertEqual(store.rowTargetsToSendBack(forWorkspaceIds: [markTab]), [], "a mark-only row sends nothing")
    }

    // MARK: Step 2: the put-back mark in the store

    private func stored(_ id: UUID) -> TerminalNotification? {
        store.notifications.first(where: { $0.id == id })
    }

    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    // Scenario 187, store half: Mark as Unread puts the newest notification back at its old place, as his mark
    func testMarkUnreadAtFormerPlaceTurnsTheNewestNotificationBackAtItsOldPlaceAsHisMark() {
        let tab = UUID(), surface = UUID()
        let older = notification(tab: tab, surface: surface, queuedAt: 5, isRead: true)
        let newest = notification(tab: tab, surface: surface, queuedAt: 10, isRead: true)
        let other = notification(tab: UUID(), surface: UUID(), queuedAt: 20)
        store.replaceNotificationsForTesting([other, newest, older])

        let answers = store.markUnreadAtFormerPlace([pane(tab, surface)])

        XCTAssertEqual(answers, [true])
        XCTAssertEqual(stored(newest.id)?.isRead, false)
        XCTAssertEqual(stored(newest.id)?.isPutBack, true, "his mark")
        XCTAssertEqual(queuedAt(newest.id), at(10), "its old place, not now")
        XCTAssertEqual(stored(older.id)?.isRead, true, "only the newest turn comes back")
        XCTAssertEqual(stored(older.id)?.isPutBack, false)
        XCTAssertEqual(walkOrder(), [newest.id, other.id], "it was ahead of the other pane, and is again")
    }

    func testMarkUnreadAtFormerPlaceOnAWorkspaceTakesThePaneOfItsNewestNotification() {
        let tab = UUID(), p1 = UUID(), p2 = UUID()
        let old = notification(tab: tab, surface: p1, queuedAt: 10, isRead: true)
        let newest = notification(tab: tab, surface: p2, queuedAt: 20, isRead: true)
        store.replaceNotificationsForTesting([newest, old])

        let answers = store.markUnreadAtFormerPlace([pane(tab, nil)])

        XCTAssertEqual(answers, [true])
        XCTAssertEqual(stored(newest.id)?.isPutBack, true)
        XCTAssertEqual(stored(newest.id)?.isRead, false)
        XCTAssertEqual(stored(old.id)?.isRead, true, "the other pane is left alone")
    }

    func testMarkUnreadAtFormerPlaceOnAWorkspaceWithNoNotificationLeavesTheWorkspaceMark() {
        let tab = UUID()
        defer { store.markRead(forTabId: tab) }

        let answers = store.markUnreadAtFormerPlace([pane(tab, nil)])

        XCTAssertEqual(answers, [false])
        XCTAssertTrue(store.hasManualUnread(forTabId: tab), "a mark, as today")
    }

    func testMarkUnreadAtFormerPlaceOnAPaneWithNoNotificationLeavesItsMarkToTheCaller() {
        let tab = UUID()
        store.replaceNotificationsForTesting([notification(tab: tab, surface: UUID(), queuedAt: 10, isRead: true)])

        let answers = store.markUnreadAtFormerPlace([pane(tab, UUID())])

        XCTAssertEqual(answers, [false], "a pane's mark lives in Workspace, outside the store")
        XCTAssertFalse(store.workspaceIsUnread(forTabId: tab))
    }

    func testMarkUnreadAtFormerPlaceOnADockSurfaceTakesItsNewestNotificationElseADockMark() {
        let window = UUID()
        let withNotification = WindowDockUnreadTarget(windowId: window, surfaceId: UUID())
        let bare = WindowDockUnreadTarget(windowId: window, surfaceId: UUID())
        let n = notification(tab: window, surface: withNotification.surfaceId, queuedAt: 10, isRead: true)
        store.replaceNotificationsForTesting([n])
        defer { store.clearWindowDockSurfaceUnread(windowId: window, surfaceId: bare.surfaceId) }

        let answers = store.markUnreadAtFormerPlace([.windowDock(withNotification), .windowDock(bare)])

        XCTAssertEqual(answers, [true, false])
        XCTAssertEqual(stored(n.id)?.isPutBack, true)
        XCTAssertEqual(queuedAt(n.id), at(10))
        XCTAssertEqual(store.windowDockUnreadTargets, [bare], "a surface with no notification gets a Dock mark")
    }

    func testMarkUnreadAtFormerPlaceOnSeveralTargetsPutsEachBackAtItsOwnOldPlace() {
        let a = notification(tab: UUID(), surface: UUID(), queuedAt: 10, isRead: true)
        let b = notification(tab: UUID(), surface: UUID(), queuedAt: 30, isRead: true)
        let between = notification(tab: UUID(), surface: UUID(), queuedAt: 20)
        store.replaceNotificationsForTesting([b, between, a])

        let answers = store.markUnreadAtFormerPlace([pane(b.tabId, b.surfaceId), pane(a.tabId, a.surfaceId)])

        XCTAssertEqual(answers, [true, true])
        XCTAssertEqual(walkOrder(), [a.id, between.id, b.id], "each is back where it was, not stacked at the back")
    }

    // The popover's and the phone's Mark as Unread reach the same unread path, so they leave a put-back notification too.
    func testThePopoversMarkAsUnreadLeavesAPutBackNotification() {
        let n = notification(tab: UUID(), surface: UUID(), queuedAt: 10, isRead: true)
        store.replaceNotificationsForTesting([n])

        store.markUnread(id: n.id)

        XCTAssertEqual(stored(n.id)?.isRead, false)
        XCTAssertEqual(stored(n.id)?.isPutBack, true)
        XCTAssertEqual(queuedAt(n.id), at(10))
    }

    func testThePhonesFeedMarkAsUnreadLeavesAPutBackNotification() {
        let n = notification(tab: UUID(), surface: UUID(), queuedAt: 10, isRead: true)
        store.replaceNotificationsForTesting([n])

        store.markNotificationFeedUnread(ids: [n.id])

        XCTAssertEqual(stored(n.id)?.isPutBack, true)
        XCTAssertEqual(stored(n.id)?.isRead, false)
    }

    // MARK: Scenario 194, store half: the mark lasts until read or removed

    private func putBackOnAPane(_ tab: UUID = UUID(), _ surface: UUID = UUID(), queuedAt seconds: TimeInterval = 10) -> TerminalNotification {
        let n = notification(tab: tab, surface: surface, queuedAt: seconds, isPutBack: true)
        store.replaceNotificationsForTesting([n])
        return n
    }

    private func assertReadAndNoLongerPutBack(_ n: TerminalNotification, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(stored(n.id)?.isRead, true, message, file: file, line: line)
        XCTAssertEqual(stored(n.id)?.isPutBack, false, message, file: file, line: line)
    }

    func testReadingByIdClearsThePutBackMark() {
        let n = putBackOnAPane()
        store.markRead(id: n.id)
        assertReadAndNoLongerPutBack(n, "markRead(id:), the popover's and the jump's read")
    }

    func testTheFeedReadClearsThePutBackMark() {
        let n = putBackOnAPane()
        store.markNotificationFeedRead(ids: [n.id])
        assertReadAndNoLongerPutBack(n, "markNotificationFeedRead(ids:), the phone's read")
    }

    func testMarkAsReadOfAWorkspaceClearsThePutBackMark() {
        let n = putBackOnAPane()
        store.markRead(forTabId: n.tabId)
        assertReadAndNoLongerPutBack(n, "markRead(forTabId:), Mark as Read")
    }

    func testReadingAPaneClearsThePutBackMark() {
        let n = putBackOnAPane()
        store.markRead(forTabId: n.tabId, surfaceId: n.surfaceId)
        assertReadAndNoLongerPutBack(n, "markRead(forTabId:surfaceId:), a visit's and the socket's read")
    }

    func testMarkAllReadClearsThePutBackMark() {
        let n = putBackOnAPane()
        store.markAllRead()
        assertReadAndNoLongerPutBack(n, "markAllRead()")
    }

    func testARemovalTakesThePutBackMarkWithTheNotification() {
        let n = putBackOnAPane()
        XCTAssertTrue(store.hasUnreadMark(forTabId: n.tabId), "setup")

        store.remove(id: n.id)

        XCTAssertNil(stored(n.id))
        XCTAssertFalse(store.hasUnreadMark(forTabId: n.tabId))
    }

    func testANewNotificationOnThePaneReplacesThePutBackOneAndIsPlainNews() throws {
        let n = putBackOnAPane()

        store.addNotification(tabId: n.tabId, surfaceId: n.surfaceId, title: "t", subtitle: "", body: "",
                              retargetsToLiveSurfaceOwner: false, correlationKey: nil)
        let fresh = try XCTUnwrap(store.notifications.first, "the new notification was recorded")

        XCTAssertNotEqual(fresh.id, n.id)
        XCTAssertFalse(fresh.isPutBack, "the new one is news")
        XCTAssertEqual(fresh.queuedAt, at(10), "the pane keeps the put-back notification's place in the queue (Q75): the replacement inherits it")
        XCTAssertNil(stored(n.id), "the supersede took the old one, mark and all")
    }

    func testAPaneMoveKeepsThePutBackMark() {
        let source = UUID(), destination = UUID(), surface = UUID()
        let n = putBackOnAPane(source, surface)

        store.rebindSurfaceNotifications(fromTabId: source, toTabId: destination, surfaceId: surface)

        XCTAssertEqual(stored(n.id)?.tabId, destination, "setup: it moved with the pane")
        XCTAssertEqual(stored(n.id)?.isPutBack, true)
        XCTAssertEqual(stored(n.id)?.isRead, false)
    }

    func testClearAgentStateKeepsAPutBackNotificationAndReadsTheRest() {
        let tab = UUID()
        let mine = notification(tab: tab, surface: UUID(), queuedAt: 10, isPutBack: true)
        let news = notification(tab: tab, surface: UUID(), queuedAt: 20)
        store.replaceNotificationsForTesting([news, mine])
        store.notificationFeedHistory.reconcileActiveNotifications(store.notifications)

        store.markRead(forTabId: tab, keepingOwnUnreadMarks: true)

        XCTAssertEqual(stored(mine.id)?.isRead, false, "his mark stays, as his dot does")
        XCTAssertEqual(stored(mine.id)?.isPutBack, true)
        XCTAssertEqual(stored(news.id)?.isRead, true)
        let history = store.notificationFeedHistory.snapshot.notifications
        XCTAssertEqual(history.first(where: { $0.id == mine.id })?.isRead, false, "the phone's list agrees")
        XCTAssertEqual(history.first(where: { $0.id == news.id })?.isRead, true)
    }

    func testTheSurfaceReadWithTheKeepLeavesAPutBackNotificationUnread() {
        let tab = UUID(), surface = UUID()
        let mine = notification(tab: tab, surface: surface, queuedAt: 10, isPutBack: true)
        let news = notification(tab: tab, surface: surface, queuedAt: 20)
        store.replaceNotificationsForTesting([news, mine])
        store.notificationFeedHistory.reconcileActiveNotifications(store.notifications)

        store.markRead(forTabId: tab, surfaceId: surface, keepingPutBack: true)

        XCTAssertEqual(stored(mine.id)?.isRead, false)
        XCTAssertEqual(stored(mine.id)?.isPutBack, true)
        XCTAssertEqual(stored(news.id)?.isRead, true, "any other unread notification on the pane is read")
        let history = store.notificationFeedHistory.snapshot.notifications
        XCTAssertEqual(history.first(where: { $0.id == mine.id })?.isRead, false, "the phone's list agrees")
        XCTAssertEqual(history.first(where: { $0.id == news.id })?.isRead, true)
    }

    // MARK: Scenario 194: it is saved and comes back

    private func decodedSnapshot(_ json: String) throws -> SessionNotificationSnapshot {
        try JSONDecoder().decode(SessionNotificationSnapshot.self, from: Data(json.utf8))
    }

    private func snapshotJSON(putBackKey: String) -> String {
        """
        {"id":"\(UUID().uuidString)","title":"t","subtitle":"","body":"","createdAt":10,"queuedAt":10,"isRead":false\(putBackKey)}
        """
    }

    func testTheSnapshotWritesThePutBackKey() throws {
        let mine = notification(tab: UUID(), surface: UUID(), queuedAt: 10, isPutBack: true)
        let plain = notification(tab: UUID(), surface: UUID(), queuedAt: 10)

        let written = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(SessionNotificationSnapshot(notification: mine))
        ) as? [String: Any]
        let writtenPlain = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(SessionNotificationSnapshot(notification: plain))
        ) as? [String: Any]

        XCTAssertEqual(written?["isPutBack"] as? Bool, true)
        XCTAssertNil(writtenPlain?["isPutBack"], "a plain notification writes no key: an older build sees the file it always saw")
    }

    func testASnapshotWithThePutBackKeyRestoresAPutBackNotification() throws {
        let snapshot = try decodedSnapshot(snapshotJSON(putBackKey: ",\"isPutBack\":true"))

        let restored = snapshot.terminalNotification(tabId: UUID(), surfaceId: UUID(), panelId: nil)

        XCTAssertTrue(restored.isPutBack)
        XCTAssertFalse(restored.isRead)
    }

    func testASnapshotWithoutThePutBackKeyRestoresPlainUnread() throws {
        let snapshot = try decodedSnapshot(snapshotJSON(putBackKey: ""))

        let restored = snapshot.terminalNotification(tabId: UUID(), surfaceId: UUID(), panelId: nil)

        XCTAssertFalse(restored.isPutBack, "a file saved before the key restores plain unread")
        XCTAssertFalse(restored.isRead)
    }

    func testRestoringSessionNotificationsKeepsAPutBackNotification() {
        let tab = UUID()
        let mine = notification(tab: tab, surface: UUID(), queuedAt: 10, isPutBack: true)

        store.restoreSessionNotifications([mine], forTabId: tab)

        XCTAssertEqual(stored(mine.id)?.isPutBack, true)
        XCTAssertTrue(store.hasUnreadMark(forTabId: tab))
    }

    func testTheRestoreIdCollisionCopyKeepsThePutBackMark() {
        let tab = UUID()
        let shared = UUID()
        let first = notification(id: shared, tab: tab, surface: UUID(), queuedAt: 10, isPutBack: true)
        let second = notification(id: shared, tab: tab, surface: UUID(), queuedAt: 10, isPutBack: true)

        store.restoreSessionNotifications([first, second], forTabId: tab)

        XCTAssertEqual(store.notifications.count, 2, "setup: the second took a fresh id")
        XCTAssertEqual(store.notifications.map(\.isPutBack), [true, true], "the copy keeps the mark too")
    }

    // MARK: Scenario 195: it sits on .4's mark side

    func testAPutBackNotificationCountsAsHisMarkOnItsWorkspace() {
        let n = putBackOnAPane()
        let plainTab = UUID()
        store.replaceNotificationsForTesting([n, notification(tab: plainTab, surface: UUID(), queuedAt: 30)])

        XCTAssertTrue(store.hasUnreadMark(forTabId: n.tabId))
        XCTAssertFalse(store.hasUnreadMark(forTabId: plainTab), "ordinary news is not a mark")
        XCTAssertTrue(store.workspaceIsUnread(forTabId: n.tabId))
        XCTAssertTrue(store.hasUnreadNotification(forTabId: n.tabId, surfaceId: n.surfaceId), "the tab still offers Mark Tab as Read")
    }

    func testAPutBackNotificationIsOutOfTheNewsOnlyCountsAndInTheOldMeaningOnes() {
        let tab = UUID()
        let mine = notification(tab: tab, surface: UUID(), queuedAt: 10, isPutBack: true)
        store.replaceNotificationsForTesting([mine])

        XCTAssertEqual(store.unreadNotificationCount(forTabId: tab), 0, "no displayed number counts it")
        XCTAssertEqual(store.unreadCount(forTabId: tab), 1, "the old meaning counts it once, as his mark")

        let news = notification(tab: tab, surface: UUID(), queuedAt: 20)
        store.replaceNotificationsForTesting([news, mine])
        XCTAssertEqual(store.unreadNotificationCount(forTabId: tab), 1, "only the news counts")
        XCTAssertEqual(store.unreadCount(forTabId: tab), 2)
    }

    func testThePhonesAppIconCountLeavesAPutBackNotificationOut() {
        let mine = notification(tab: UUID(), surface: UUID(), queuedAt: 10, isPutBack: true)
        store.replaceNotificationsForTesting([mine])
        XCTAssertEqual(store.unreadCount, 0, "the global count the phone's app icon shows")

        store.replaceNotificationsForTesting([notification(tab: UUID(), surface: UUID(), queuedAt: 20), mine])
        XCTAssertEqual(store.unreadCount, 1, "news still counts")
    }

    func testTheMenuSnapshotLeavesAPutBackNotificationOutOfItsCount() {
        let mine = notification(tab: UUID(), surface: UUID(), queuedAt: 10, isPutBack: true)
        let news = notification(tab: UUID(), surface: UUID(), queuedAt: 20)

        let onlyMine = NotificationMenuSnapshotBuilder.make(notifications: [mine])
        let both = NotificationMenuSnapshotBuilder.make(notifications: [news, mine])

        XCTAssertEqual(onlyMine.unreadCount, 0, "the menu bar icon, the popover header and the app menu count news only")
        XCTAssertTrue(onlyMine.hasNotifications, "Clear All is still on offer")
        XCTAssertEqual(both.unreadCount, 1)
    }

    func testAWorkspaceWhoseOnlyUnreadIsAPutBackNotificationStillHasStateToDismiss() {
        let mine = putBackOnAPane()

        XCTAssertTrue(store.hasDismissibleState(forTabId: mine.tabId), "typing in the pane reads it, as typing reads his dot")
        XCTAssertFalse(store.hasDismissibleState(forTabId: UUID()))
    }

    func testThePanelIdHalfOfTheNewsIndexLeavesAPutBackNotificationOut() {
        let tab = UUID(), surface = UUID(), panelId = UUID()
        let mine = TerminalNotification(
            id: UUID(), tabId: tab, surfaceId: surface, panelId: panelId, title: "t", subtitle: "", body: "",
            createdAt: at(10), isRead: false, isPutBack: true
        )
        store.replaceNotificationsForTesting([mine])

        XCTAssertTrue(store.hasUnreadNotification(forTabId: tab, surfaceId: panelId), "the plain read counts it by its panel id too")
        XCTAssertFalse(store.hasUnreadNewsNotification(forTabId: tab, surfaceId: panelId), "the news read does not, by panel id")
        XCTAssertFalse(store.hasUnreadNewsNotification(forTabId: tab, surfaceId: surface), "nor by surface id")
    }

    // MARK: MISS2: Send to Back is not this mark

    func testSendToBackClearsThePutBackMarkOfEveryNotificationItSendsBack() {
        let tab = UUID(), surface = UUID()
        let mine = notification(tab: tab, surface: surface, queuedAt: 10, isPutBack: true)
        let elsewhere = notification(tab: UUID(), surface: UUID(), queuedAt: 20, isPutBack: true)
        store.replaceNotificationsForTesting([elsewhere, mine])

        store.sendToBack([pane(tab, surface)], now: Date())

        XCTAssertEqual(stored(mine.id)?.isPutBack, false, "a skipped pane is read like any other when he reaches it")
        XCTAssertEqual(stored(mine.id)?.isRead, false)
        XCTAssertEqual(stored(elsewhere.id)?.isPutBack, true, "a pane that was not sent keeps its mark")
    }

    func testSendToBackOnASiblingPaneClearsThePutBackMarkOfTheWorkspaceLevelNotification() {
        let tab = UUID(), pane1 = UUID()
        let workspaceLevel = notification(tab: tab, surface: nil, queuedAt: 5, isPutBack: true)
        let sibling = notification(tab: tab, surface: pane1, queuedAt: 10)
        store.replaceNotificationsForTesting([sibling, workspaceLevel])

        store.sendToBack([pane(tab, pane1)], now: Date())

        XCTAssertEqual(stored(workspaceLevel.id)?.isPutBack, false, "it goes back with the pane, so it loses the mark too")
        XCTAssertEqual(stored(workspaceLevel.id)?.isRead, false)
    }

    func testSendToBackOfAReadTargetBringsItBackUnreadAndNotAsAMark() {
        let n = notification(tab: UUID(), surface: UUID(), queuedAt: 10, isRead: true)
        store.replaceNotificationsForTesting([n])

        store.sendToBack([pane(n.tabId, n.surfaceId)], now: Date())

        XCTAssertEqual(stored(n.id)?.isRead, false)
        XCTAssertEqual(stored(n.id)?.isPutBack, false, "Send to Back is the other of his two meanings")
    }

    // MARK: One step, one publication (the Dock badge must never flicker to 0)

    func testSendToBackOverSeveralTargetsPublishesNotificationsOnceAndNeverPutBack() {
        let read = notification(tab: UUID(), surface: UUID(), queuedAt: 10, isRead: true)
        let unread = notification(tab: UUID(), surface: UUID(), queuedAt: 20)
        let mine = notification(tab: unread.tabId, surface: UUID(), queuedAt: 30, isPutBack: true)
        store.replaceNotificationsForTesting([mine, unread, read])
        var published: [[TerminalNotification]] = []
        let subscription = store.$notifications.dropFirst().sink { published.append($0) }
        defer { subscription.cancel() }

        store.sendToBack([pane(unread.tabId, unread.surfaceId), pane(read.tabId, read.surfaceId), pane(mine.tabId, mine.surfaceId)], now: Date())

        XCTAssertEqual(published.count, 1, "one sendToBack, one publication of notifications")
        let sentBack = Set([read.id, unread.id, mine.id])
        XCTAssertTrue(
            published.flatMap { $0 }.filter { sentBack.contains($0.id) }.allSatisfy { !$0.isPutBack && !$0.isRead },
            "no publication shows a sent-back notification as put back"
        )
    }

    // MARK: Step 2 review fixes

    // R1: nothing to turn unread, so nothing changes and his mark stays; sidebarUnread agrees with hasUnreadMark.
    func testMarkAsUnreadOnAnAlreadyUnreadTargetChangesNothingAndHisMarkStays() {
        let tab = UUID()
        let unread = notification(tab: tab, surface: UUID(), queuedAt: 10)
        store.replaceNotificationsForTesting([unread])
        store.markUnread(forTabId: tab)
        defer { store.markRead(forTabId: tab) }
        XCTAssertTrue(store.hasManualUnread(forTabId: tab), "setup: his workspace mark")

        let answers = store.markUnreadAtFormerPlace([pane(tab, nil)])

        XCTAssertEqual(answers, [true], "the target holds a notification")
        XCTAssertTrue(store.hasManualUnread(forTabId: tab), "nothing was turned unread, so his mark is not deleted")
        XCTAssertEqual(store.sidebarUnread.summary(forWorkspaceId: tab).markedUnread, store.hasUnreadMark(forTabId: tab),
                       "the sidebar's mark and the store's agree")
        XCTAssertEqual(stored(unread.id)?.isPutBack, false, "an already unread notification does not become a mark")
    }

    // R2: a bulk Mark as Unread is one publication of notifications, not one per target.
    func testMarkUnreadAtFormerPlaceOnSeveralTargetsPublishesNotificationsOnce() {
        let a = notification(tab: UUID(), surface: UUID(), queuedAt: 10, isRead: true)
        let b = notification(tab: UUID(), surface: UUID(), queuedAt: 20, isRead: true)
        let c = notification(tab: UUID(), surface: UUID(), queuedAt: 30, isRead: true)
        store.replaceNotificationsForTesting([c, b, a])
        var published = 0
        let subscription = store.$notifications.dropFirst().sink { _ in published += 1 }
        defer { subscription.cancel() }

        store.markUnreadAtFormerPlace([pane(a.tabId, a.surfaceId), pane(b.tabId, b.surfaceId), pane(c.tabId, c.surfaceId)])

        XCTAssertEqual(published, 1)
        XCTAssertEqual([a.id, b.id, c.id].compactMap { stored($0)?.isPutBack }, [true, true, true])
    }

    // R5: the other removals take the mark with the notification.
    func testClearingByCorrelationKeyTakesThePutBackMarkWithTheNotification() {
        let n = notification(tab: UUID(), surface: UUID(), queuedAt: 10, isPutBack: true, correlationKey: "question-1")
        store.replaceNotificationsForTesting([n])
        XCTAssertTrue(store.hasUnreadMark(forTabId: n.tabId), "setup")

        store.clearNotifications(forTabId: n.tabId, correlationKey: "question-1")

        XCTAssertNil(stored(n.id))
        XCTAssertFalse(store.hasUnreadMark(forTabId: n.tabId))
    }

    func testClosingThePaneTakesThePutBackMarkWithTheNotification() {
        let n = putBackOnAPane()
        XCTAssertTrue(store.hasUnreadMark(forTabId: n.tabId), "setup")

        store.clearNotifications(forTabId: n.tabId, surfaceId: n.surfaceId)

        XCTAssertNil(stored(n.id))
        XCTAssertFalse(store.hasUnreadMark(forTabId: n.tabId))
    }

    func testClearAllTakesThePutBackMarkWithTheNotification() {
        let n = putBackOnAPane()
        store.clearAll()
        XCTAssertNil(stored(n.id))
        XCTAssertFalse(store.hasUnreadMark(forTabId: n.tabId))
    }


    // MARK: Step 4: Every Mark as Unread entrance on the one path (markUnreadAtFormerPlace)

    private func makeKeyDownEvent(
        key: String,
        modifiers: NSEvent.ModifierFlags = [.control],
        keyCode: UInt16,
        windowNumber: Int
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    // MARK: Scenario 191/192/193: ⌘⌥U through the real resolver seam

    func testScenario191_192_193_ToggleFocusedNotificationUnreadViaShortcut_PanePutsNotificationBack() throws {
        try withMainWindow { appDelegate, manager, window in
            let ws = try XCTUnwrap(manager.selectedWorkspace)
            let panelId = try XCTUnwrap(ws.focusedPanelId)
            let a = notification(tab: ws.id, surface: panelId, queuedAt: 1, isRead: true)
            let otherWs = manager.addWorkspace(select: false, eagerLoadTerminal: false)
            let otherPanelId = try XCTUnwrap(otherWs.focusedPanelId)
            let b = notification(tab: otherWs.id, surface: otherPanelId, queuedAt: 2)
            store.replaceNotificationsForTesting([a, b])

            let event = try XCTUnwrap(makeKeyDownEvent(
                key: "u",
                modifiers: [.command, .option],
                keyCode: 32,
                windowNumber: window.windowNumber
            ))
            #if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
            #else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
            #endif

            let storedA = try XCTUnwrap(stored(a.id))
            XCTAssertFalse(storedA.isRead, "A's notification is unread")
            XCTAssertTrue(storedA.isPutBack, "A's notification is his mark (isPutBack true)")
            XCTAssertEqual(storedA.queuedAt, at(1), "A's notification kept its queue place (queuedAt 1)")
            XCTAssertEqual(walkOrder(), [a.id, b.id], "the walk opens the put-back notification, then B (Scenario 187)") // cmux-rbf: step 4b R8
            XCTAssertFalse(ws.manualUnreadPanelIds.contains(panelId), "no pane mark left behind")
        }
    }

    func testScenario191_192_193_ToggleFocusedNotificationUnreadViaShortcut_WorkspacePutsNotificationBack() throws {
        try withMainWindow { appDelegate, manager, window in
            let ws = try XCTUnwrap(manager.selectedWorkspace)
            let w = notification(tab: ws.id, surface: nil, queuedAt: 1, isRead: true)
            let otherWs = manager.addWorkspace(select: false, eagerLoadTerminal: false)
            let otherPanelId = try XCTUnwrap(otherWs.focusedPanelId)
            let b = notification(tab: otherWs.id, surface: otherPanelId, queuedAt: 2)
            store.replaceNotificationsForTesting([w, b])

            // Removing panels clears focusedPanelId so focusedTarget resolves as workspace-level
            ws.panels.removeAll()

            let event = try XCTUnwrap(makeKeyDownEvent(
                key: "u",
                modifiers: [.command, .option],
                keyCode: 32,
                windowNumber: window.windowNumber
            ))
            #if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
            #else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
            #endif

            let storedW = try XCTUnwrap(stored(w.id))
            XCTAssertFalse(storedW.isRead, "W's notification is unread")
            XCTAssertTrue(storedW.isPutBack, "W's notification is his mark (isPutBack true)")
            XCTAssertEqual(storedW.queuedAt, at(1), "W's notification kept its queue place (queuedAt 1)")
            XCTAssertEqual(walkOrder(), [w.id, b.id], "the walk opens the put-back notification, then B (Scenario 187)") // cmux-rbf: step 4b R8
            XCTAssertFalse(store.hasManualUnread(forTabId: ws.id), "no workspace mark left behind")
        }
    }

    func testScenario191_192_193_ToggleFocusedNotificationUnreadViaShortcut_DockPutsNotificationBack() throws {
        try withMainWindowContext { appDelegate, manager, window, windowId in
            let dock = appDelegate.windowDock(forWindowId: windowId)
            let hostId = UUID()
            dock.setVisibleInUI(true, hostId: hostId)
            defer { dock.setVisibleInUI(false, hostId: hostId) }
            let panel = try seedDockBrowserPanel(dock)
            let d = notification(tab: windowId, surface: panel.id, queuedAt: 1, isRead: true)
            let otherWs = manager.addWorkspace(select: false, eagerLoadTerminal: false)
            let otherPanelId = try XCTUnwrap(otherWs.focusedPanelId)
            let b = notification(tab: otherWs.id, surface: otherPanelId, queuedAt: 2)
            store.replaceNotificationsForTesting([d, b])

            dock.focusPanel(panel.id)
            appDelegate.keyboardFocusCoordinator(for: window)?.noteRightSidebarInteraction(mode: .dock)

            let event = try XCTUnwrap(makeKeyDownEvent(
                key: "u",
                modifiers: [.command, .option],
                keyCode: 32,
                windowNumber: window.windowNumber
            ))
            #if DEBUG
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))
            #else
            XCTFail("debugHandleCustomShortcut is only available in DEBUG")
            #endif

            let storedD = try XCTUnwrap(stored(d.id))
            XCTAssertFalse(storedD.isRead, "D's notification is unread")
            XCTAssertTrue(storedD.isPutBack, "D's notification is his mark (isPutBack true)")
            XCTAssertEqual(storedD.queuedAt, at(1), "D's notification kept its queue place (queuedAt 1)")
            XCTAssertEqual(walkOrder(), [d.id, b.id], "the walk opens the put-back notification, then B (Scenario 187)") // cmux-rbf: step 4b R8
            XCTAssertFalse(store.hasManualUnread(forTabId: windowId, surfaceId: panel.id), "no dock mark left behind")
        }
    }

    /// The SwiftUI row's own actions for `workspaceId`, built by the sidebar's real factory as a list builds them for a realised row
    /// (cm-128.13, step 4b R2). The factory binds `markUnread:` and, in step 5, `sendToBack:` and `canSendToBack:`.
    private func sidebarRowActions(workspaceId: UUID) throws -> SidebarWorkspaceRowActions {
        let suite = "SendToBackAndMarkUnreadTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)
        let sidebar = VerticalTabsSidebar(
            updateViewModel: UpdateStateModel(), fileExplorerState: FileExplorerState(), featureFlags: CmuxFeatureFlags(),
            sidebarUnread: SidebarUnreadModel(), titlebarControlsLayoutModel: TitlebarControlsLayoutModel(),
            windowId: UUID(), onSendFeedback: {}, onToggleSidebar: {}, onNewTab: {},
            observedWindowReference: WeakWindowReference(), chromeBackgroundColor: .black,
            selection: .constant(.tabs), selectedTabIds: .constant([]), lastSidebarSelectionIndex: .constant(nil),
            sidebarRenderWorkerClient: .constant(nil)
        )
        let input = SidebarWorkspaceContextMenuTargetAggregateTests.rowInput(
            workspaceId: workspaceId, groupId: nil, unreadCount: 0, isMultiSelected: false,
            isRemote: false, remoteState: .disconnected, settings: settings
        )
        return sidebar.makeWorkspaceRowActionFactory()(input)
    }

    // Entrance 4: AppKit workspace row right-click Mark Workspace as Unread
    func testAppKitRowMarkUnreadPutsBackAtFormerPlace() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let ws = try XCTUnwrap(manager.selectedWorkspace)
        let otherWs = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let a = notification(tab: ws.id, surface: nil, queuedAt: 1, isRead: true)
        let b = notification(tab: otherWs.id, surface: nil, queuedAt: 2)
        store.replaceNotificationsForTesting([a, b])

        let commands = SidebarWorkspaceRowCommands(
            tab: ws, tabManager: manager, notificationStore: store, index: 0,
            contextMenuWorkspaceIds: [ws.id], remoteContextMenuWorkspaceIds: [],
            allRemoteContextMenuTargetsConnecting: false, allRemoteContextMenuTargetsDisconnected: false,
            contextMenuPinState: nil, workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot(items: []),
            colorScheme: .dark, refreshSnapshot: {}, readSelectedTabIds: { [] }, writeSelectedTabIds: { _ in },
            readLastSelectionIndex: { nil }, writeLastSelectionIndex: { _ in }, setSelectionToTabs: {},
            snapshotProvider: { nil }
        )
        let menu = SidebarWorkspaceRowMenuBuilder(commands: commands).build(onOpen: {}, onClose: {})
        let title = String(localized: "contextMenu.markWorkspaceUnread", defaultValue: "Mark Workspace as Unread")
        let itemIndex = try XCTUnwrap(menu.items.firstIndex { $0.title == title })
        XCTAssertTrue(menu.items[itemIndex].isEnabled)
        menu.performActionForItem(at: itemIndex)

        let storedA = try XCTUnwrap(stored(a.id))
        XCTAssertFalse(storedA.isRead)
        XCTAssertTrue(storedA.isPutBack)
        XCTAssertEqual(storedA.queuedAt, at(1))
        XCTAssertEqual(walkOrder(), [a.id, b.id], "the walk opens the put-back notification, then B (Scenario 187)") // cmux-rbf: step 4b R8
        XCTAssertFalse(store.hasManualUnread(forTabId: ws.id))
    }

    // Entrance 5: SwiftUI workspace row right-click Mark Workspace as Unread
    func testSwiftUIRowActionsMarkUnreadPutsBackAtFormerPlace() throws {
        let wsId = UUID()
        let a = notification(tab: wsId, surface: nil, queuedAt: 1, isRead: true)
        let otherWsId = UUID()
        let b = notification(tab: otherWsId, surface: nil, queuedAt: 2)
        store.replaceNotificationsForTesting([a, b])

        // cmux-rbf: step 4b R2: the row's own actions, built by the sidebar's real factory (`makeWorkspaceRowActionFactory`), so cutting
        // the `markUnread:` binding there fails this test.
        let actions = try sidebarRowActions(workspaceId: wsId)
        actions.markUnread([wsId])

        let storedA = try XCTUnwrap(stored(a.id))
        XCTAssertFalse(storedA.isRead)
        XCTAssertTrue(storedA.isPutBack)
        XCTAssertEqual(storedA.queuedAt, at(1))
        XCTAssertEqual(walkOrder(), [a.id, b.id], "the walk opens the put-back notification, then B (Scenario 187)") // cmux-rbf: step 4b R8
        XCTAssertFalse(store.hasManualUnread(forTabId: wsId))
    }

    // Entrance 6: Palette Mark Workspace as Unread (the registered handler)
    func testPaletteMarkWorkspaceUnreadPutsBackAtFormerPlace() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let ws = try XCTUnwrap(manager.selectedWorkspace)
        let otherWs = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let a = notification(tab: ws.id, surface: nil, queuedAt: 1, isRead: true)
        let b = notification(tab: otherWs.id, surface: nil, queuedAt: 2)
        store.replaceNotificationsForTesting([a, b])

        // cmux-rbf: step 4b R2: the registered handler itself, run from the registry as the palette runs it.
        var registry = CommandPaletteHandlerRegistry()
        ContentView.registerMarkWorkspaceUnreadPaletteHandler(in: &registry, tabManager: manager, notificationStore: store)
        let handler = try XCTUnwrap(registry.handler(for: "palette.markWorkspaceUnread"), "the palette registered no Mark Workspace as Unread handler")
        handler()

        let storedA = try XCTUnwrap(stored(a.id))
        XCTAssertFalse(storedA.isRead)
        XCTAssertTrue(storedA.isPutBack)
        XCTAssertEqual(storedA.queuedAt, at(1))
        XCTAssertFalse(store.hasManualUnread(forTabId: ws.id))
        XCTAssertEqual(walkOrder(), [a.id, b.id], "the walk opens the put-back notification, then B (Scenario 187)") // cmux-rbf: step 4b R8
    }

    // Entrance 7: Menu Bar Mark Selected Workspace as Unread (cmuxApp's body)
    func testMenuBarMarkWorkspaceUnreadPutsBackAtFormerPlace() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let ws = try XCTUnwrap(manager.selectedWorkspace)
        let otherWs = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let a = notification(tab: ws.id, surface: nil, queuedAt: 1, isRead: true)
        let b = notification(tab: otherWs.id, surface: nil, queuedAt: 2)
        store.replaceNotificationsForTesting([a, b])

        // cmux-rbf: step 4b R2: the menu bar's body, which reads the selected workspace itself.
        cmuxApp.markSelectedWorkspaceUnreadAtFormerPlace(in: manager, store: store)

        let storedA = try XCTUnwrap(stored(a.id))
        XCTAssertFalse(storedA.isRead)
        XCTAssertTrue(storedA.isPutBack)
        XCTAssertEqual(storedA.queuedAt, at(1))
        XCTAssertFalse(store.hasManualUnread(forTabId: ws.id))
        XCTAssertEqual(walkOrder(), [a.id, b.id], "the walk opens the put-back notification, then B (Scenario 187)") // cmux-rbf: step 4b R8
    }

    // Entrance 8: Palette Mark Tab as Unread toggle (Workspace.togglePanelUnread)
    func testWorkspaceTogglePanelUnreadPutsBackAtFormerPlace() throws {
        try withMainWindow { appDelegate, manager, _ in
            let ws = try XCTUnwrap(manager.selectedWorkspace)
            let panelId = try XCTUnwrap(ws.focusedPanelId)
            let a = notification(tab: ws.id, surface: panelId, queuedAt: 1, isRead: true)
            let otherWs = manager.addWorkspace(select: false, eagerLoadTerminal: false)
            let otherPanelId = try XCTUnwrap(otherWs.focusedPanelId)
            let b = notification(tab: otherWs.id, surface: otherPanelId, queuedAt: 2)
            store.replaceNotificationsForTesting([a, b])

            XCTAssertTrue(ws.togglePanelUnread(panelId))

            let storedA = try XCTUnwrap(stored(a.id))
            XCTAssertFalse(storedA.isRead)
            XCTAssertTrue(storedA.isPutBack)
            XCTAssertEqual(storedA.queuedAt, at(1))
            XCTAssertEqual(walkOrder(), [a.id, b.id], "the walk opens the put-back notification, then B (Scenario 187)") // cmux-rbf: step 4b R8
            XCTAssertFalse(ws.manualUnreadPanelIds.contains(panelId))
        }
    }

    // Entrance 9: Bonsplit tab right-click Mark as Unread (splitTabBar didRequestTabContextAction)
    func testBonsplitTabContextMarkAsUnreadPutsBackAtFormerPlace() throws {
        try withMainWindow { appDelegate, manager, _ in
            let ws = try XCTUnwrap(manager.selectedWorkspace)
            let panelId = try XCTUnwrap(ws.focusedPanelId)
            let a = notification(tab: ws.id, surface: panelId, queuedAt: 1, isRead: true)
            let otherWs = manager.addWorkspace(select: false, eagerLoadTerminal: false)
            let otherPanelId = try XCTUnwrap(otherWs.focusedPanelId)
            let b = notification(tab: otherWs.id, surface: otherPanelId, queuedAt: 2)
            store.replaceNotificationsForTesting([a, b])

            let tabId = try XCTUnwrap(ws.surfaceIdFromPanelId(panelId))
            let paneId = try XCTUnwrap(ws.paneId(forPanelId: panelId))
            let anchorTab = try XCTUnwrap(ws.bonsplitController.tab(tabId))
            ws.splitTabBar(ws.bonsplitController, didRequestTabContextAction: .markAsUnread, for: anchorTab, inPane: paneId)

            let storedA = try XCTUnwrap(stored(a.id))
            XCTAssertFalse(storedA.isRead)
            XCTAssertTrue(storedA.isPutBack)
            XCTAssertEqual(storedA.queuedAt, at(1))
            XCTAssertEqual(walkOrder(), [a.id, b.id], "the walk opens the put-back notification, then B (Scenario 187)") // cmux-rbf: step 4b R8
            XCTAssertFalse(ws.manualUnreadPanelIds.contains(panelId))
        }
    }

    // Entrance 10 & 11: Palette Dock toggle (`togglePanelUnread`) & Dock tab context Mark as Unread (the handler); both reach `putDockTabBackUnread`
    func testPaletteDockToggleTabUnreadPutsBackAtFormerPlace() throws {
        try withMainWindowContext { appDelegate, manager, window, windowId in
            let dock = appDelegate.windowDock(forWindowId: windowId)
            let hostId = UUID()
            dock.setVisibleInUI(true, hostId: hostId)
            defer { dock.setVisibleInUI(false, hostId: hostId) }
            let panel = try seedDockBrowserPanel(dock)
            let d = notification(tab: windowId, surface: panel.id, queuedAt: 1, isRead: true)
            let otherWs = manager.addWorkspace(select: false, eagerLoadTerminal: false)
            let otherPanelId = try XCTUnwrap(otherWs.focusedPanelId)
            let b = notification(tab: otherWs.id, surface: otherPanelId, queuedAt: 2)
            store.replaceNotificationsForTesting([d, b])

            XCTAssertTrue(dock.togglePanelUnread(panel.id))

            let storedD = try XCTUnwrap(stored(d.id))
            XCTAssertFalse(storedD.isRead)
            XCTAssertTrue(storedD.isPutBack)
            XCTAssertEqual(storedD.queuedAt, at(1))
            XCTAssertEqual(walkOrder(), [d.id, b.id], "the walk opens the put-back notification, then B (Scenario 187)") // cmux-rbf: step 4b R8
            XCTAssertFalse(store.hasManualUnread(forTabId: dock.workspaceId, surfaceId: panel.id), "no Dock mark left behind") // cmux-rbf: step 4b R7
        }
    }

    func testDockTabContextMarkAsUnreadPutsBackAtFormerPlaceAndSetsBadge() throws {
        try withMainWindowContext { appDelegate, manager, window, windowId in
            let dock = appDelegate.windowDock(forWindowId: windowId)
            let hostId = UUID()
            dock.setVisibleInUI(true, hostId: hostId)
            defer { dock.setVisibleInUI(false, hostId: hostId) }
            let panel = try seedDockBrowserPanel(dock)
            let d = notification(tab: windowId, surface: panel.id, queuedAt: 1, isRead: true)
            let otherWs = manager.addWorkspace(select: false, eagerLoadTerminal: false)
            let otherPanelId = try XCTUnwrap(otherWs.focusedPanelId)
            let b = notification(tab: otherWs.id, surface: otherPanelId, queuedAt: 2)
            store.replaceNotificationsForTesting([d, b])

            let tabId = try XCTUnwrap(dock.surfaceId(forPanelId: panel.id))
            // cmux-rbf: step 4b R2: the Dock's tab-menu handler itself, as the workspace test drives its twin.
            let paneId = try XCTUnwrap(dock.bonsplitController.allPaneIds.first)
            dock.bonsplitController.requestTabContextAction(.markAsUnread, for: tabId, inPane: paneId)

            let storedD = try XCTUnwrap(stored(d.id))
            XCTAssertFalse(storedD.isRead)
            XCTAssertTrue(storedD.isPutBack)
            XCTAssertEqual(storedD.queuedAt, at(1))
            XCTAssertEqual(walkOrder(), [d.id, b.id], "the walk opens the put-back notification, then B (Scenario 187)") // cmux-rbf: step 4b R8
            XCTAssertFalse(store.hasManualUnread(forTabId: dock.workspaceId, surfaceId: panel.id), "no Dock mark left behind") // cmux-rbf: step 4b R7
            let tab = try XCTUnwrap(dock.bonsplitController.tab(tabId))
            XCTAssertTrue(tab.showsNotificationBadge, "MISS1: Dock tab badge set on mark unread")
        }
    }

    // Entrance 13 & 14: Group header Mark Group as Unread & Mark All Workspaces in Group as Unread
    func testGroupHeaderMarkUnreadPutsBackAtFormerPlace() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let groupId = try XCTUnwrap(manager.createWorkspaceGroup(name: "G", childWorkspaceIds: []))
        let anchor = try XCTUnwrap(manager.workspaceGroupAnchor(for: groupId))
        let otherWs = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let a = notification(tab: anchor.id, surface: nil, queuedAt: 1, isRead: true)
        let b = notification(tab: otherWs.id, surface: nil, queuedAt: 2)
        store.replaceNotificationsForTesting([a, b])

        let actions = VerticalTabsSidebar.makeWorkspaceGroupHeaderActions(
            groupId: groupId,
            fallbackGroupName: "G",
            fallbackAnchorWorkspaceId: anchor.id,
            placement: nil,
            tabManager: manager,
            notificationStore: store,
            selectedTabIds: .constant([]),
            lastSidebarSelectionIndex: .constant(nil)
        )
        actions.onMarkUnread()

        let storedA = try XCTUnwrap(stored(a.id))
        XCTAssertFalse(storedA.isRead)
        XCTAssertTrue(storedA.isPutBack)
        XCTAssertEqual(storedA.queuedAt, at(1))
        XCTAssertEqual(walkOrder(), [a.id, b.id], "the walk opens the put-back notification, then B (Scenario 187)") // cmux-rbf: step 4b R8
        XCTAssertFalse(store.hasManualUnread(forTabId: anchor.id))
    }

    func testGroupHeaderMarkAllUnreadPutsBackAtFormerPlace() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let ws1 = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let ws2 = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let groupId = try XCTUnwrap(manager.createWorkspaceGroup(name: "G", childWorkspaceIds: [ws1.id, ws2.id]))
        let anchor = try XCTUnwrap(manager.workspaceGroupAnchor(for: groupId))
        let otherWs = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let a1 = notification(tab: ws1.id, surface: nil, queuedAt: 1, isRead: true)
        let a2 = notification(tab: ws2.id, surface: nil, queuedAt: 2, isRead: true)
        let b = notification(tab: otherWs.id, surface: nil, queuedAt: 3)
        store.replaceNotificationsForTesting([a1, a2, b])

        let actions = VerticalTabsSidebar.makeWorkspaceGroupHeaderActions(
            groupId: groupId,
            fallbackGroupName: "G",
            fallbackAnchorWorkspaceId: anchor.id,
            placement: nil,
            tabManager: manager,
            notificationStore: store,
            selectedTabIds: .constant([]),
            lastSidebarSelectionIndex: .constant(nil)
        )
        actions.onMarkAllUnread()

        let storedA1 = try XCTUnwrap(stored(a1.id))
        let storedA2 = try XCTUnwrap(stored(a2.id))
        XCTAssertFalse(storedA1.isRead)
        XCTAssertTrue(storedA1.isPutBack)
        XCTAssertEqual(storedA1.queuedAt, at(1))
        XCTAssertFalse(storedA2.isRead)
        XCTAssertTrue(storedA2.isPutBack)
        XCTAssertEqual(storedA2.queuedAt, at(2))
        XCTAssertEqual(walkOrder(), [a1.id, a2.id, b.id], "the walk opens the put-back notification, then B (Scenario 187)") // cmux-rbf: step 4b R8
        XCTAssertFalse(store.hasManualUnread(forTabId: ws1.id))
        XCTAssertFalse(store.hasManualUnread(forTabId: ws2.id))
    }

    // Entrance 15: Nested group Mark All Workspaces as Unread
    func testNestedGroupHeaderMarkAllUnreadPutsBackAtFormerPlace() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let ws1 = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let otherWs = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let outer = try XCTUnwrap(manager.createWorkspaceGroup(name: "P", childWorkspaceIds: []))
        let inner = try XCTUnwrap(manager.createWorkspaceGroup(name: "Q", childWorkspaceIds: [ws1.id]))
        XCTAssertEqual(manager.moveWorkspaceGroup(groupId: inner, intoParent: outer), .moved)
        let a = notification(tab: ws1.id, surface: nil, queuedAt: 1, isRead: true)
        let b = notification(tab: otherWs.id, surface: nil, queuedAt: 2)
        store.replaceNotificationsForTesting([a, b])

        let nested = SidebarNestedGroupNotifications(tabManager: manager, notificationStore: store, groupId: outer)
        XCTAssertTrue(nested.markAll(read: false))

        let storedA = try XCTUnwrap(stored(a.id))
        XCTAssertFalse(storedA.isRead)
        XCTAssertTrue(storedA.isPutBack)
        XCTAssertEqual(storedA.queuedAt, at(1))
        XCTAssertEqual(walkOrder(), [a.id, b.id], "the walk opens the put-back notification, then B (Scenario 187)") // cmux-rbf: step 4b R8
        XCTAssertFalse(store.hasManualUnread(forTabId: ws1.id))
    }

    // Entrance 16 & 17: Socket workspace.action & tab.action mark_unread
    func testSocketWorkspaceActionMarkUnreadPutsBackAtFormerPlace() throws {
        try withMainWindow { _, manager, _ in
            let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            TerminalController.shared.setActiveTabManager(manager)
            defer { TerminalController.shared.setActiveTabManager(previousManager) }

            let ws = try XCTUnwrap(manager.selectedWorkspace)
            let otherWs = manager.addWorkspace(select: false, eagerLoadTerminal: false)
            let a = notification(tab: ws.id, surface: nil, queuedAt: 1, isRead: true)
            let b = notification(tab: otherWs.id, surface: nil, queuedAt: 2)
            store.replaceNotificationsForTesting([a, b])

            let payload: [String: Any] = [
                "id": "ws-mark-unread",
                "method": "workspace.action",
                "params": [
                    "action": "mark_unread",
                    "workspace_id": ws.id.uuidString,
                ],
            ]
            let line = try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8))
            let data = try XCTUnwrap(TerminalController.shared.handleSocketLine(line).data(using: .utf8))
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")

            let storedA = try XCTUnwrap(stored(a.id))
            XCTAssertFalse(storedA.isRead)
            XCTAssertTrue(storedA.isPutBack)
            XCTAssertEqual(storedA.queuedAt, at(1))
            XCTAssertEqual(walkOrder(), [a.id, b.id], "the walk opens the put-back notification, then B (Scenario 187)") // cmux-rbf: step 4b R8
            XCTAssertFalse(store.hasManualUnread(forTabId: ws.id))
        }
    }

    func testSocketTabActionMarkUnreadPutsBackAtFormerPlace() throws {
        try withMainWindow { _, manager, _ in
            let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            TerminalController.shared.setActiveTabManager(manager)
            defer { TerminalController.shared.setActiveTabManager(previousManager) }

            let ws = try XCTUnwrap(manager.selectedWorkspace)
            let panelId = try XCTUnwrap(ws.focusedPanelId)
            let a = notification(tab: ws.id, surface: panelId, queuedAt: 1, isRead: true)
            let otherWs = manager.addWorkspace(select: false, eagerLoadTerminal: false)
            let otherPanelId = try XCTUnwrap(otherWs.focusedPanelId)
            let b = notification(tab: otherWs.id, surface: otherPanelId, queuedAt: 2)
            store.replaceNotificationsForTesting([a, b])

            let payload: [String: Any] = [
                "id": "tab-mark-unread",
                "method": "tab.action",
                "params": [
                    "action": "mark_unread",
                    "workspace_id": ws.id.uuidString,
                    "surface_id": panelId.uuidString,
                ],
            ]
            let line = try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8))
            let data = try XCTUnwrap(TerminalController.shared.handleSocketLine(line).data(using: .utf8))
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")

            let storedA = try XCTUnwrap(stored(a.id))
            XCTAssertFalse(storedA.isRead)
            XCTAssertTrue(storedA.isPutBack)
            XCTAssertEqual(storedA.queuedAt, at(1))
            XCTAssertEqual(walkOrder(), [a.id, b.id], "the walk opens the put-back notification, then B (Scenario 187)") // cmux-rbf: step 4b R8
            XCTAssertFalse(ws.manualUnreadPanelIds.contains(panelId))
        }
    }

    // Scenario 188 (step 4b R3): a bell and a restored mark stay marks, in a workspace and in the window Dock. Each case runs the code the
    // system path runs; the notification stays read, the mark is a mark, and the walk opens news before it.

    /// A terminal in the window Dock with the Dock's attention routing installed, as `DockRuntimeParityTests` seeds one (that helper is private).
    private func seedDockTerminalPanel(_ dock: DockSplitStore) throws -> TerminalPanel {
        let panel = TerminalPanel(workspaceId: dock.workspaceId, runtimeSpawnPolicy: .pacedSessionRestore)
        let pane = try XCTUnwrap(dock.bonsplitController.allPaneIds.first)
        dock.panels[panel.id] = panel
        let tabId = try XCTUnwrap(dock.bonsplitController.createTab(
            title: panel.displayTitle, icon: panel.displayIcon, kind: panel.panelType.rawValue, isDirty: panel.isDirty, inPane: pane
        ))
        dock.bindSurface(tabId, toPanelId: panel.id)
        dock.installAttentionRouting(for: panel)
        return panel
    }

    func testWorkspaceBellLeavesAPaneMarkAndItsNotificationRead() throws {
        try withMainWindow { appDelegate, manager, _ in
            let here = try XCTUnwrap(manager.selectedWorkspace)
            let otherWs = manager.addWorkspace(select: false, eagerLoadTerminal: false)
            let otherPanelId = try XCTUnwrap(otherWs.focusedPanelId)
            let terminalPanel = try XCTUnwrap(otherWs.panels[otherPanelId] as? TerminalPanel)
            let visualBell = try XCTUnwrap(terminalPanel.surface.onVisualBell)
            let a = notification(tab: otherWs.id, surface: otherPanelId, queuedAt: 1, isRead: true)
            let thirdWs = manager.addWorkspace(select: false, eagerLoadTerminal: false)
            let thirdPanelId = try XCTUnwrap(thirdWs.focusedPanelId)
            let news = notification(tab: thirdWs.id, surface: thirdPanelId, queuedAt: 2)
            store.replaceNotificationsForTesting([news, a])

            // The bell runs `Workspace+AttentionFlashRouting`'s `onVisualBell`, which marks the pane.
            visualBell()

            let storedA = try XCTUnwrap(stored(a.id))
            XCTAssertTrue(storedA.isRead, "the bell turned the notification unread")
            XCTAssertFalse(storedA.isPutBack)
            XCTAssertTrue(otherWs.manualUnreadPanelIds.contains(otherPanelId), "the bell leaves a plain pane mark")
            XCTAssertEqual(walkOrder(), [news.id], "the read notification is no stop: marks come after all news")
            XCTAssertEqual(appDelegate.jumpToOldestUnread()?.id, news.id, "the walk opens the news before the mark")
            XCTAssertEqual(manager.selectedTabId, thirdWs.id, "and goes to the news, not the marked pane (here was \(here.id))")
        }
    }

    func testWorkspaceSessionRestoreLeavesPaneAndWorkspaceMarks() throws {
        try withMainWindow { appDelegate, manager, _ in
            let ws = try XCTUnwrap(manager.selectedWorkspace)
            let panelId = try XCTUnwrap(ws.focusedPanelId)
            let paneRead = notification(tab: ws.id, surface: panelId, queuedAt: 1, isRead: true)
            let newsWs = manager.addWorkspace(select: false, eagerLoadTerminal: false)
            let newsPanel = try XCTUnwrap(newsWs.focusedPanelId)
            let news = notification(tab: newsWs.id, surface: newsPanel, queuedAt: 5) // cmux-rbf: step 7 R4: the walk opens marks after all news
            store.replaceNotificationsForTesting([news, paneRead])

            // A pane's restored mark: `applySessionPanelMetadata` is what the restore runs for each pane (Workspace.swift, isManuallyUnread).
            var panelSnapshot = try XCTUnwrap(ws.sessionSnapshot(includeScrollback: false).panels.first { $0.id == panelId })
            panelSnapshot.isManuallyUnread = true
            ws.applySessionPanelMetadata(panelSnapshot, toPanelId: panelId)
            XCTAssertTrue(ws.manualUnreadPanelIds.contains(panelId), "the restore leaves a pane mark")
            XCTAssertEqual(stored(paneRead.id)?.isRead, true, "the restore turned the notification unread")
            XCTAssertEqual(stored(paneRead.id)?.isPutBack, false)
            XCTAssertEqual(walkOrder(), [news.id], "the read notification is no stop: the restored mark comes after all news")

            // The workspace's restored mark: a whole snapshot through `restoreSessionSnapshot`, as a relaunch runs it.
            let restored = Workspace()
            let seed = notification(tab: restored.id, surface: nil, queuedAt: 2, isRead: true)
            store.replaceNotificationsForTesting([news, paneRead, seed])
            var workspaceSnapshot = restored.sessionSnapshot(includeScrollback: false)
            workspaceSnapshot.isManuallyUnread = true
            workspaceSnapshot.notifications = [SessionNotificationSnapshot(notification: seed)]
            restored.restoreSessionSnapshot(workspaceSnapshot)
            XCTAssertTrue(store.hasManualUnread(forTabId: restored.id), "the restore leaves a workspace mark")
            XCTAssertTrue(store.notifications.filter { $0.tabId == restored.id }.allSatisfy { $0.isRead && !$0.isPutBack },
                          "the restore turned a notification unread")
            XCTAssertEqual(walkOrder(), [news.id], "the restored workspace's read notification is no stop either")
            XCTAssertEqual(appDelegate.jumpToOldestUnread()?.id, news.id, "the walk opens the news before the restored marks")
        }
    }

    func testDockBellLeavesADockMarkAndItsNotificationRead() throws {
        try withMainWindowContext { appDelegate, manager, _, windowId in
            AppFocusState.overrideIsFocused = false // the Dock's bell marks only a surface that doesn't own focus; the helper restores the flag
            let dock = appDelegate.windowDock(forWindowId: windowId)
            let hostId = UUID()
            dock.setVisibleInUI(true, hostId: hostId)
            defer { dock.setVisibleInUI(false, hostId: hostId) }
            let panel = try seedDockTerminalPanel(dock)
            let d = notification(tab: dock.workspaceId, surface: panel.id, queuedAt: 1, isRead: true)
            let other = manager.addWorkspace(select: false, eagerLoadTerminal: false)
            let otherPanelId = try XCTUnwrap(other.focusedPanelId)
            let news = notification(tab: other.id, surface: otherPanelId, queuedAt: 2)
            store.replaceNotificationsForTesting([news, d])
            let bell = try XCTUnwrap(panel.surface.onVisualBell, "the window Dock installed no visual-bell routing")

            bell() // DockSplitStore+AttentionRouting's onVisualBell

            XCTAssertTrue(store.hasManualUnread(forTabId: dock.workspaceId, surfaceId: panel.id), "the Dock's bell leaves a Dock mark")
            XCTAssertEqual(stored(d.id)?.isRead, true, "the bell turned the Dock notification unread")
            XCTAssertEqual(stored(d.id)?.isPutBack, false)
            XCTAssertEqual(walkOrder(), [news.id], "the read notification is no stop: the Dock mark comes after all news")
        }
    }

    // The Dock's restore reaches `adoptManualUnreadState` (DockSplitStore+SessionRestore): driven here at that function, one call above the store helper.
    func testDockRestoreLeavesADockMarkAndItsNotificationRead() throws {
        try withMainWindowContext { appDelegate, manager, _, windowId in
            let dock = appDelegate.windowDock(forWindowId: windowId)
            let hostId = UUID()
            dock.setVisibleInUI(true, hostId: hostId)
            defer { dock.setVisibleInUI(false, hostId: hostId) }
            let panel = try seedDockBrowserPanel(dock)
            let d = notification(tab: dock.workspaceId, surface: panel.id, queuedAt: 1, isRead: true)
            let newsWs = manager.addWorkspace(select: false, eagerLoadTerminal: false)
            let newsPanel = try XCTUnwrap(newsWs.focusedPanelId)
            let news = notification(tab: newsWs.id, surface: newsPanel, queuedAt: 5) // cmux-rbf: step 7 R4: the walk opens marks after all news
            store.replaceNotificationsForTesting([news, d])

            dock.adoptManualUnreadState(true, panelId: panel.id)

            XCTAssertTrue(store.hasManualUnread(forTabId: dock.workspaceId, surfaceId: panel.id), "the Dock's restore leaves a Dock mark")
            XCTAssertEqual(stored(d.id)?.isRead, true, "the restore turned the Dock notification unread")
            XCTAssertEqual(stored(d.id)?.isPutBack, false)
            XCTAssertEqual(walkOrder(), [news.id], "the read notification is no stop: the Dock mark comes after all news")
            XCTAssertEqual(appDelegate.jumpToOldestUnread()?.id, news.id, "the walk opens the news before the Dock mark")
        }
    }

    // Step 4b R4: Mark Tab as Unread on a pane that never notified leaves a pane mark, as today.
    func testTabMenuMarkAsUnreadOnAPaneWithNoNotificationLeavesAPaneMark() throws {
        try withMainWindow { _, manager, _ in
            let ws = try XCTUnwrap(manager.selectedWorkspace)
            let panelId = try XCTUnwrap(ws.focusedPanelId)
            store.replaceNotificationsForTesting([notification(tab: UUID(), surface: UUID(), queuedAt: 1)])
            let tabId = try XCTUnwrap(ws.surfaceIdFromPanelId(panelId))
            let paneId = try XCTUnwrap(ws.paneId(forPanelId: panelId))
            let anchorTab = try XCTUnwrap(ws.bonsplitController.tab(tabId))

            ws.splitTabBar(ws.bonsplitController, didRequestTabContextAction: .markAsUnread, for: anchorTab, inPane: paneId)

            XCTAssertTrue(ws.manualUnreadPanelIds.contains(panelId), "a pane with no notification gets a pane mark, as today")
        }
    }

    // MISS1: Local Dock (scope != .global) retains local state and leaves global store untouched
    func testNonGlobalDockRetainsLocalState() throws {
        try withMainWindowContext { appDelegate, manager, window, windowId in
            let ws = try XCTUnwrap(manager.selectedWorkspace)
            let dock = try XCTUnwrap(ws.dockSplit)
            XCTAssertEqual(dock.scope, .workspace)
            let hostId = UUID()
            dock.setVisibleInUI(true, hostId: hostId)
            defer { dock.setVisibleInUI(false, hostId: hostId) }
            let panel = try seedDockBrowserPanel(dock)
            let d = notification(tab: ws.id, surface: panel.id, queuedAt: 1, isRead: true)
            store.replaceNotificationsForTesting([d])

            // cmux-rbf: step 4b R5: through the tab-menu handler, the entrance that branches on the Dock's scope.
            let tabId = try XCTUnwrap(dock.surfaceId(forPanelId: panel.id))
            let paneId = try XCTUnwrap(dock.bonsplitController.allPaneIds.first)
            dock.bonsplitController.requestTabContextAction(.markAsUnread, for: tabId, inPane: paneId)

            let storedD = try XCTUnwrap(stored(d.id))
            XCTAssertTrue(storedD.isRead, "Local dock does not route to global store put-back")
            XCTAssertFalse(storedD.isPutBack)
            XCTAssertTrue(dock.manualUnreadPanelIds.contains(panel.id), "Local dock adopts manual unread state locally")
        }
    }

    // MARK: Step 5: the Send to Back items

    private var sendToBackTitle: String {
        String(localized: "contextMenu.sendToBackOfUnreadQueue", defaultValue: "Send to Back of Unread Queue")
    }

    /// The AppKit row menu for `tab`'s row with `ids` selected, built the way a right-click builds it.
    private func rowMenu(manager: TabManager, tab: Workspace, index: Int = 0, ids: [UUID]) -> NSMenu {
        let commands = SidebarWorkspaceRowCommands(
            tab: tab, tabManager: manager, notificationStore: store, index: index,
            contextMenuWorkspaceIds: ids, remoteContextMenuWorkspaceIds: [],
            allRemoteContextMenuTargetsConnecting: false, allRemoteContextMenuTargetsDisconnected: false,
            contextMenuPinState: nil, workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot(items: []),
            colorScheme: .dark, refreshSnapshot: {}, readSelectedTabIds: { [] }, writeSelectedTabIds: { _ in },
            readLastSelectionIndex: { nil }, writeLastSelectionIndex: { _ in }, setSelectionToTabs: {},
            snapshotProvider: { nil }
        )
        return SidebarWorkspaceRowMenuBuilder(commands: commands).build(onOpen: {}, onClose: {})
    }

    private func sendToBackItemIndex(in menu: NSMenu) -> Int? {
        menu.items.firstIndex { $0.title == sendToBackTitle }
    }

    // Scenario 170, menu half: right-click a row, choose the item. The waiting pane goes to the back; the others keep their places.
    func testAppKitRowSendToBackPutsTheWaitingPaneAtTheBack() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let rowA = try XCTUnwrap(manager.selectedWorkspace)
        let rowB = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let rowC = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let a = notification(tab: rowA.id, surface: UUID(), queuedAt: 1)
        let b = notification(tab: rowB.id, surface: UUID(), queuedAt: 2)
        let c = notification(tab: rowC.id, surface: UUID(), queuedAt: 3)
        store.replaceNotificationsForTesting([c, b, a])
        XCTAssertEqual(walkOrder(), [a.id, b.id, c.id], "setup: oldest first")

        let menu = rowMenu(manager: manager, tab: rowB, index: 1, ids: [rowB.id])
        let index = try XCTUnwrap(sendToBackItemIndex(in: menu), "the row menu has no Send to Back of Unread Queue item")
        XCTAssertTrue(menu.items[index].isEnabled)
        menu.performActionForItem(at: index)

        XCTAssertEqual(walkOrder(), [a.id, c.id, b.id], "B went to the back; A and C kept their places")
    }

    // Scenario 171, AppKit row: the item moves nothing on screen and opens nothing.
    func testAppKitRowSendToBackOpensNothingAndMovesNoSelection() throws {
        try withMainWindow { appDelegate, manager, _ in
            let here = try XCTUnwrap(manager.selectedWorkspace)
            let herePanel = try XCTUnwrap(here.focusedPanelId)
            let other = manager.addWorkspace(select: false, eagerLoadTerminal: false)
            let otherPanel = try XCTUnwrap(other.focusedPanelId)
            let b = notification(tab: other.id, surface: otherPanel, queuedAt: 1)
            store.replaceNotificationsForTesting([b])
            XCTAssertEqual(appDelegate.frontmostFocusedPane(), .workspace(tabId: here.id, surfaceId: herePanel), "setup: he's on the first workspace")

            let menu = rowMenu(manager: manager, tab: other, index: 1, ids: [other.id])
            let index = try XCTUnwrap(sendToBackItemIndex(in: menu), "the row menu has no Send to Back of Unread Queue item")
            menu.performActionForItem(at: index)

            XCTAssertEqual(manager.selectedTabId, here.id, "the item moved the selection")
            XCTAssertEqual(here.focusedPanelId, herePanel, "the item moved focus")
            XCTAssertEqual(stored(b.id)?.isRead, false, "the item opened B's pane, which reads it")
        }
    }

    // Scenario 172: a row with two waiting panes keeps their order at the back.
    func testAppKitRowSendToBackKeepsTwoPanesInTheirOrder() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let rowX = try XCTUnwrap(manager.selectedWorkspace)
        let rowB = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let rowC = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        // X2's id sorts before X1's, so one shared stamp would hand the order to the tie-break and put X2 first.
        let x1 = notification(id: id(2), tab: rowX.id, surface: UUID(), queuedAt: 1)
        let x2 = notification(id: id(1), tab: rowX.id, surface: UUID(), queuedAt: 3)
        let b = notification(tab: rowB.id, surface: UUID(), queuedAt: 2)
        let c = notification(tab: rowC.id, surface: UUID(), queuedAt: 4)
        store.replaceNotificationsForTesting([c, x2, b, x1])
        XCTAssertEqual(walkOrder(), [x1.id, b.id, x2.id, c.id], "setup")

        let menu = rowMenu(manager: manager, tab: rowX, ids: [rowX.id])
        let index = try XCTUnwrap(sendToBackItemIndex(in: menu), "the row menu has no Send to Back of Unread Queue item")
        menu.performActionForItem(at: index)

        XCTAssertEqual(walkOrder(), [b.id, c.id, x1.id, x2.id], "X's panes land at the back in the order they had")
    }

    // Scenario 173: several rows selected.
    func testAppKitMultiRowSendToBackKeepsTheirOrder() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let rowX = try XCTUnwrap(manager.selectedWorkspace)
        let rowY = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let rowZ = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let x = notification(tab: rowX.id, surface: UUID(), queuedAt: 1)
        let y = notification(tab: rowY.id, surface: UUID(), queuedAt: 2)
        let z = notification(tab: rowZ.id, surface: UUID(), queuedAt: 3)
        store.replaceNotificationsForTesting([z, y, x])
        XCTAssertEqual(walkOrder(), [x.id, y.id, z.id], "setup")

        let menu = rowMenu(manager: manager, tab: rowX, ids: [rowX.id, rowZ.id])
        let index = try XCTUnwrap(sendToBackItemIndex(in: menu), "the row menu has no Send to Back of Unread Queue item")
        menu.performActionForItem(at: index)

        XCTAssertEqual(walkOrder(), [y.id, x.id, z.id], "X and Z went to the back, in the order they had")
    }

    // Scenario 176, AppKit row: enabled whenever a row holds a notification, unread or read; his mark alone is neither.
    func testAppKitSendToBackIsEnabledOnlyForRowsHoldingANotification() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let emptyRow = try XCTUnwrap(manager.selectedWorkspace)
        let markRow = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let readRow = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let unreadRow = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        store.replaceNotificationsForTesting([
            notification(tab: unreadRow.id, surface: UUID(), queuedAt: 2),
            notification(tab: readRow.id, surface: UUID(), queuedAt: 1, isRead: true)
        ])
        store.markUnread(forTabId: markRow.id)
        defer { store.markRead(forTabId: markRow.id) }
        XCTAssertTrue(store.hasManualUnread(forTabId: markRow.id), "setup: the row carries his mark")

        func enabled(_ rows: [Workspace]) throws -> Bool {
            let menu = rowMenu(manager: manager, tab: rows[0], ids: rows.map(\.id))
            let index = try XCTUnwrap(sendToBackItemIndex(in: menu), "the row menu has no Send to Back of Unread Queue item")
            return menu.items[index].isEnabled
        }
        XCTAssertFalse(try enabled([emptyRow]), "no notification")
        XCTAssertFalse(try enabled([markRow]), "his mark alone is neither an unread nor a read target")
        XCTAssertTrue(try enabled([readRow]), "a read target is on: it comes back unread")
        XCTAssertTrue(try enabled([unreadRow]))
        XCTAssertTrue(try enabled([emptyRow, unreadRow]), "any one row is enough")
    }

    // Scenario 176 and the bindings (amendment 3): the SwiftUI row's two closures, built as the sidebar builds them.
    func testSwiftUIRowActionsSendToBackBindingsFollowTheStore() throws {
        let aTab = UUID(), bTab = UUID(), cTab = UUID(), emptyTab = UUID()
        let a = notification(tab: aTab, surface: UUID(), queuedAt: 1)
        let b = notification(tab: bTab, surface: UUID(), queuedAt: 2)
        let c = notification(tab: cTab, surface: UUID(), queuedAt: 3)
        store.replaceNotificationsForTesting([c, b, a])
        // The row's own actions, built by the sidebar's real factory (step 4b R2's `sidebarRowActions`), so cutting either binding fails this test.
        let actions = try sidebarRowActions(workspaceId: bTab)

        XCTAssertFalse(actions.canSendToBack([emptyTab]), "no notification")
        XCTAssertTrue(actions.canSendToBack([bTab]))
        actions.sendToBack([bTab])
        XCTAssertEqual(walkOrder(), [a.id, c.id, b.id], "the closure sent B to the back")
    }

    // Scenario 176, SwiftUI menu: the presented menu asks the shared enabled check, live (render alone must not).
    func testTheSwiftUIMenuAsksTheSharedSendToBackCheckWhenItIsPresented() throws {
        var asked: [[UUID]] = []
        let target = UUID()
        let actions = SidebarWorkspaceContextMenuWindowTargetsTests.actions(
            canSendToBack: { ids in asked.append(ids); return true })
        let row = TabItemView(snapshot: try SidebarWorkspaceContextMenuWindowTargetsTests.rowSnapshot(workspaceId: target, targetWorkspaceIds: [target]),
            actions: actions)
        _ = row.body
        XCTAssertTrue(asked.isEmpty, "rendering the row must not ask whether Send to Back is on")
        _ = TabItemWorkspaceContextMenuContent(row: row).body
        XCTAssertEqual(asked.count, 1, "the presented menu never asked the shared check")
        XCTAssertEqual(asked.first, [target], "the presented menu asked the check with other ids than the row's targets: \(asked)")
    }

    // Scenarios 170 and 171, workspace tab menu: the handler sends the tab's pane to the back and opens nothing.
    func testWorkspaceTabSendToBackPutsThePaneAtTheBackAndOpensNothing() throws {
        try withMainWindow { appDelegate, manager, _ in
            let here = try XCTUnwrap(manager.selectedWorkspace)
            let herePanel = try XCTUnwrap(here.focusedPanelId)
            let other = manager.addWorkspace(select: false, eagerLoadTerminal: false)
            let otherPanel = try XCTUnwrap(other.focusedPanelId)
            let third = manager.addWorkspace(select: false, eagerLoadTerminal: false)
            let thirdPanel = try XCTUnwrap(third.focusedPanelId)
            let a = notification(tab: here.id, surface: herePanel, queuedAt: 1)
            let b = notification(tab: other.id, surface: otherPanel, queuedAt: 2)
            let c = notification(tab: third.id, surface: thirdPanel, queuedAt: 3)
            store.replaceNotificationsForTesting([c, b, a])
            XCTAssertEqual(appDelegate.frontmostFocusedPane(), .workspace(tabId: here.id, surfaceId: herePanel), "setup: he's on A's pane")
            XCTAssertEqual(walkOrder(), [a.id, b.id, c.id], "setup")

            let tabId = try XCTUnwrap(other.surfaceIdFromPanelId(otherPanel))
            let paneId = try XCTUnwrap(other.paneId(forPanelId: otherPanel))
            let tab = try XCTUnwrap(other.bonsplitController.tab(tabId))
            other.splitTabBar(other.bonsplitController, didRequestTabContextAction: .sendToBack, for: tab, inPane: paneId)

            XCTAssertEqual(walkOrder(), [a.id, c.id, b.id], "B's pane went to the back")
            XCTAssertEqual(manager.selectedTabId, here.id, "the item moved the selection")
            XCTAssertEqual(here.focusedPanelId, herePanel, "the item moved focus")
            XCTAssertEqual(stored(b.id)?.isRead, false, "the item opened B's pane, which reads it")
            XCTAssertEqual(stored(c.id)?.isRead, false, "the item walked on to C")
        }
    }

    // The lead's call (2026-11-17): Send to Back has no mark fallback. A pane with no notification has nothing to move.
    func testWorkspaceTabSendToBackOnAPaneWithNoNotificationLeavesNoMark() throws {
        try withMainWindow { _, manager, _ in
            let ws = try XCTUnwrap(manager.selectedWorkspace)
            let panel = try XCTUnwrap(ws.focusedPanelId)
            let unrelated = notification(tab: UUID(), surface: UUID(), queuedAt: 1)
            store.replaceNotificationsForTesting([unrelated])

            let tabId = try XCTUnwrap(ws.surfaceIdFromPanelId(panel))
            let paneId = try XCTUnwrap(ws.paneId(forPanelId: panel))
            let tab = try XCTUnwrap(ws.bonsplitController.tab(tabId))
            ws.splitTabBar(ws.bonsplitController, didRequestTabContextAction: .sendToBack, for: tab, inPane: paneId)

            XCTAssertFalse(ws.manualUnreadPanelIds.contains(panel), "a pane mark appeared: Send to Back has no mark fallback")
            XCTAssertFalse(store.hasManualUnread(forTabId: ws.id), "a workspace mark appeared")
            XCTAssertEqual(store.notifications.map(\.id), [unrelated.id])
            XCTAssertEqual(stored(unrelated.id)?.queuedAt, at(1), "an unrelated notification was moved")
        }
    }

    // Scenario 176, workspace tab: the provider the workspace installs on its Bonsplit controller.
    func testWorkspaceTabProviderFollowsTheStore() throws {
        try withMainWindow { _, manager, _ in
            let ws = try XCTUnwrap(manager.selectedWorkspace)
            let panel = try XCTUnwrap(ws.focusedPanelId)
            let tabId = try XCTUnwrap(ws.surfaceIdFromPanelId(panel))
            let paneId = try XCTUnwrap(ws.paneId(forPanelId: panel))
            let provider = try XCTUnwrap(ws.bonsplitController.tabContextSendToBackAvailabilityProvider,
                                         "the workspace installed no Send to Back availability provider")
            store.replaceNotificationsForTesting([])
            XCTAssertFalse(provider(tabId, paneId), "no notification")

            ws.markPanelUnread(panel)
            XCTAssertFalse(provider(tabId, paneId), "his pane mark alone is neither an unread nor a read target")
            ws.markPanelRead(panel)

            store.replaceNotificationsForTesting([notification(tab: ws.id, surface: nil, queuedAt: 1)])
            XCTAssertFalse(provider(tabId, paneId), "a workspace-level notification is not this pane's")

            store.replaceNotificationsForTesting([notification(tab: ws.id, surface: panel, queuedAt: 1)])
            XCTAssertTrue(provider(tabId, paneId), "an unread notification on the pane")

            store.replaceNotificationsForTesting([notification(tab: ws.id, surface: panel, queuedAt: 1, isRead: true)])
            XCTAssertTrue(provider(tabId, paneId), "a read notification on the pane: it comes back unread")
        }
    }

    // Scenarios 171 and 177 (MISS1), Dock tab menu: the handler sends the Dock surface's notification to the back, sets the badge, opens nothing.
    func testDockTabSendToBackOfAnUnreadDockTabPutsItAtTheBackLeavesItsBadgeAsItWasAndOpensNothing() throws {
        try withMainWindowContext { appDelegate, manager, _, windowId in
            let dock = appDelegate.windowDock(forWindowId: windowId)
            let hostId = UUID()
            dock.setVisibleInUI(true, hostId: hostId)
            defer { dock.setVisibleInUI(false, hostId: hostId) }
            let panel = try seedDockBrowserPanel(dock)
            let here = try XCTUnwrap(manager.selectedWorkspace)
            let other = manager.addWorkspace(select: false, eagerLoadTerminal: false)
            let otherPanel = try XCTUnwrap(other.focusedPanelId)
            let d = notification(tab: dock.workspaceId, surface: panel.id, queuedAt: 1)
            let b = notification(tab: other.id, surface: otherPanel, queuedAt: 2)
            store.replaceNotificationsForTesting([b, d])
            XCTAssertEqual(walkOrder(), [d.id, b.id], "setup")

            let tabId = try XCTUnwrap(dock.surfaceId(forPanelId: panel.id))
            let paneId = try XCTUnwrap(dock.bonsplitController.allPaneIds.first)
            dock.bonsplitController.updateTab(tabId, showsNotificationBadge: false)
            dock.bonsplitController.requestTabContextAction(.sendToBack, for: tabId, inPane: paneId)

            XCTAssertEqual(walkOrder(), [b.id, d.id], "the Dock surface's notification went to the back")
            // Step 9 R2: an unread Dock tab already looks as it should (Q111: nothing new on screen), so the send adds no dot. Only a READ
            // notification turned unread sets it (the s8 test).
            XCTAssertEqual(dock.bonsplitController.tab(tabId)?.showsNotificationBadge, false, "an unread Dock tab's look changed: Send to Back added a dot")
            XCTAssertEqual(manager.selectedTabId, here.id, "the item moved the selection")
            XCTAssertEqual(stored(b.id)?.isRead, false, "the item opened B's pane, which reads it")
        }
    }

    // The lead's call (2026-11-17), Dock: a surface with no notification has nothing to move, so no Dock mark and no badge.
    func testDockTabSendToBackOnASurfaceWithNoNotificationLeavesNoDockMark() throws {
        try withMainWindowContext { appDelegate, manager, _, windowId in
            let dock = appDelegate.windowDock(forWindowId: windowId)
            let hostId = UUID()
            dock.setVisibleInUI(true, hostId: hostId)
            defer { dock.setVisibleInUI(false, hostId: hostId) }
            let panel = try seedDockBrowserPanel(dock)
            store.replaceNotificationsForTesting([])
            let tabId = try XCTUnwrap(dock.surfaceId(forPanelId: panel.id))
            let paneId = try XCTUnwrap(dock.bonsplitController.allPaneIds.first)
            dock.bonsplitController.updateTab(tabId, showsNotificationBadge: false)

            dock.bonsplitController.requestTabContextAction(.sendToBack, for: tabId, inPane: paneId)

            XCTAssertFalse(store.hasManualUnread(forTabId: dock.workspaceId, surfaceId: panel.id), "a Dock mark appeared: Send to Back has no mark fallback")
            XCTAssertEqual(dock.bonsplitController.tab(tabId)?.showsNotificationBadge, false, "the badge was set with nothing to send")
        }
    }

    // Step 8 R4: a READ Dock surface sent back through the Dock tab's menu comes back unread, at the back, and not as his mark.
    func testDockTabSendToBackOfAReadDockNotificationBringsItBackUnreadAtTheBack() throws {
        try withMainWindowContext { appDelegate, manager, _, windowId in
            let dock = appDelegate.windowDock(forWindowId: windowId)
            let hostId = UUID()
            dock.setVisibleInUI(true, hostId: hostId)
            defer { dock.setVisibleInUI(false, hostId: hostId) }
            let panel = try seedDockBrowserPanel(dock)
            let other = manager.addWorkspace(select: false, eagerLoadTerminal: false)
            let otherPanel = try XCTUnwrap(other.focusedPanelId)
            let d = notification(tab: dock.workspaceId, surface: panel.id, queuedAt: 1, isRead: true)
            let b = notification(tab: other.id, surface: otherPanel, queuedAt: 2)
            store.replaceNotificationsForTesting([b, d])
            XCTAssertEqual(walkOrder(), [b.id], "setup: the Dock's notification is read, so it is no stop")
            let tabId = try XCTUnwrap(dock.surfaceId(forPanelId: panel.id))
            let paneId = try XCTUnwrap(dock.bonsplitController.allPaneIds.first)
            dock.bonsplitController.updateTab(tabId, showsNotificationBadge: false)

            dock.bonsplitController.requestTabContextAction(.sendToBack, for: tabId, inPane: paneId)

            XCTAssertEqual(stored(d.id)?.isRead, false, "the read Dock notification did not come back unread")
            XCTAssertEqual(stored(d.id)?.isPutBack, false, "Send to Back is not his mark")
            XCTAssertEqual(walkOrder(), [b.id, d.id], "it came back at the back")
            XCTAssertEqual(dock.bonsplitController.tab(tabId)?.showsNotificationBadge, true, "the Dock tab's badge is set")
        }
    }

    // Scenario 176 (MISS1), Dock tab: the provider, and a Dock with no window-Dock target is greyed.
    func testDockTabProviderFollowsTheStoreAndALocalDockIsGreyed() throws {
        try withMainWindowContext { appDelegate, manager, _, windowId in
            let dock = appDelegate.windowDock(forWindowId: windowId)
            XCTAssertEqual(dock.scope, .global, "setup: the window Dock")
            let hostId = UUID()
            dock.setVisibleInUI(true, hostId: hostId)
            defer { dock.setVisibleInUI(false, hostId: hostId) }
            let panel = try seedDockBrowserPanel(dock)
            let tabId = try XCTUnwrap(dock.surfaceId(forPanelId: panel.id))
            let paneId = try XCTUnwrap(dock.bonsplitController.allPaneIds.first)
            let provider = try XCTUnwrap(dock.bonsplitController.tabContextSendToBackAvailabilityProvider,
                                         "the Dock installed no Send to Back availability provider")

            store.replaceNotificationsForTesting([])
            XCTAssertFalse(provider(tabId, paneId), "no notification")
            _ = store.markWindowDockSurfaceUnread(windowId: dock.workspaceId, surfaceId: panel.id)
            XCTAssertFalse(provider(tabId, paneId), "a Dock mark alone is neither an unread nor a read target")
            _ = store.clearWindowDockSurfaceUnread(windowId: dock.workspaceId, surfaceId: panel.id)
            store.replaceNotificationsForTesting([notification(tab: dock.workspaceId, surface: panel.id, queuedAt: 1)])
            XCTAssertTrue(provider(tabId, paneId), "an unread Dock notification")
            store.replaceNotificationsForTesting([notification(tab: dock.workspaceId, surface: panel.id, queuedAt: 1, isRead: true)])
            XCTAssertTrue(provider(tabId, paneId), "a read Dock notification: it comes back unread")

            // A Dock with no window-Dock target keeps its own state and its Send to Back is greyed.
            let ws = try XCTUnwrap(manager.selectedWorkspace)
            let localDock = try XCTUnwrap(ws.dockSplit)
            XCTAssertEqual(localDock.scope, .workspace, "setup: a workspace-scoped Dock")
            let localHost = UUID()
            localDock.setVisibleInUI(true, hostId: localHost)
            defer { localDock.setVisibleInUI(false, hostId: localHost) }
            let localPanel = try seedDockBrowserPanel(localDock)
            let localTabId = try XCTUnwrap(localDock.surfaceId(forPanelId: localPanel.id))
            let localPaneId = try XCTUnwrap(localDock.bonsplitController.allPaneIds.first)
            store.replaceNotificationsForTesting([notification(tab: localDock.workspaceId, surface: localPanel.id, queuedAt: 1)])
            let localProvider = try XCTUnwrap(localDock.bonsplitController.tabContextSendToBackAvailabilityProvider)
            XCTAssertFalse(localProvider(localTabId, localPaneId), "MISS1: a Dock with no window-Dock target is greyed")
        }
    }

    // MISS1: a Dock with no window-Dock target keeps its own state, so Send to Back there sends nothing.
    func testLocalDockTabSendToBackSendsNothing() throws {
        try withMainWindowContext { _, manager, _, _ in
            let ws = try XCTUnwrap(manager.selectedWorkspace)
            let localDock = try XCTUnwrap(ws.dockSplit)
            XCTAssertEqual(localDock.scope, .workspace, "setup: a workspace-scoped Dock")
            let hostId = UUID()
            localDock.setVisibleInUI(true, hostId: hostId)
            defer { localDock.setVisibleInUI(false, hostId: hostId) }
            let panel = try seedDockBrowserPanel(localDock)
            let other = manager.addWorkspace(select: false, eagerLoadTerminal: false)
            let otherPanel = try XCTUnwrap(other.focusedPanelId)
            let d = notification(tab: localDock.workspaceId, surface: panel.id, queuedAt: 1)
            let b = notification(tab: other.id, surface: otherPanel, queuedAt: 2)
            store.replaceNotificationsForTesting([b, d])
            XCTAssertEqual(walkOrder(), [d.id, b.id], "setup")
            let tabId = try XCTUnwrap(localDock.surfaceId(forPanelId: panel.id))
            let paneId = try XCTUnwrap(localDock.bonsplitController.allPaneIds.first)

            localDock.bonsplitController.requestTabContextAction(.sendToBack, for: tabId, inPane: paneId)

            XCTAssertEqual(walkOrder(), [d.id, b.id], "a Dock with no window-Dock target sent a notification to the back")
        }
    }

    // MARK: Step 7 R4: cases the menus claimed but no test reached

    // Scenario 176: a row with only his pane mark, or only a restored indicator, is neither an unread nor a read target.
    func testAppKitSendToBackIsOffForARowWithOnlyAPaneMarkOrARestoredIndicator() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let paneMarkRow = try XCTUnwrap(manager.selectedWorkspace)
        let restoredRow = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        store.replaceNotificationsForTesting([])
        let panel = try XCTUnwrap(paneMarkRow.focusedPanelId)
        paneMarkRow.markPanelUnread(panel)
        defer { paneMarkRow.markPanelRead(panel) }
        _ = store.restoreUnreadIndicator(forTabId: restoredRow.id)
        defer { _ = store.clearRestoredUnreadIndicator(forTabId: restoredRow.id) }
        XCTAssertTrue(paneMarkRow.manualUnreadPanelIds.contains(panel), "setup: the pane carries his mark")
        XCTAssertTrue(store.hasRestoredUnreadIndicator(forTabId: restoredRow.id), "setup: the row carries a restored indicator")

        for (name, row) in [("pane mark only", paneMarkRow), ("restored indicator only", restoredRow)] {
            let menu = rowMenu(manager: manager, tab: row, ids: [row.id])
            let index = try XCTUnwrap(sendToBackItemIndex(in: menu), "the row menu has no Send to Back of Unread Queue item")
            XCTAssertFalse(menu.items[index].isEnabled, "\(name): the item is on with no notification")
        }
        XCTAssertFalse(store.canSendToBack(forWorkspaceIds: [restoredRow.id]))
    }

    func testWorkspaceTabProviderIgnoresARestoredIndicator() throws {
        try withMainWindow { _, manager, _ in
            let ws = try XCTUnwrap(manager.selectedWorkspace)
            let panel = try XCTUnwrap(ws.focusedPanelId)
            let tabId = try XCTUnwrap(ws.surfaceIdFromPanelId(panel))
            let paneId = try XCTUnwrap(ws.paneId(forPanelId: panel))
            let provider = try XCTUnwrap(ws.bonsplitController.tabContextSendToBackAvailabilityProvider)
            store.replaceNotificationsForTesting([])
            _ = store.restoreUnreadIndicator(forTabId: ws.id)
            defer { _ = store.clearRestoredUnreadIndicator(forTabId: ws.id) }
            XCTAssertTrue(store.hasRestoredUnreadIndicator(forTabId: ws.id), "setup: the workspace carries a restored indicator")

            XCTAssertFalse(provider(tabId, paneId), "a restored indicator is neither an unread nor a read target")
        }
    }

    // Scenario 176: a READ row sent back through the menu comes back unread, at the back, and not as his mark.
    func testAppKitRowSendToBackOfAReadRowBringsItsNewestNotificationBackUnreadAtTheBack() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let readRow = try XCTUnwrap(manager.selectedWorkspace)
        let rowB = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let rowC = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let a = notification(tab: readRow.id, surface: UUID(), queuedAt: 1, isRead: true)
        let b = notification(tab: rowB.id, surface: UUID(), queuedAt: 2)
        let c = notification(tab: rowC.id, surface: UUID(), queuedAt: 3)
        store.replaceNotificationsForTesting([c, b, a])
        XCTAssertEqual(walkOrder(), [b.id, c.id], "setup: A is read, so it is no stop")

        let menu = rowMenu(manager: manager, tab: readRow, ids: [readRow.id])
        let index = try XCTUnwrap(sendToBackItemIndex(in: menu), "the row menu has no Send to Back of Unread Queue item")
        XCTAssertTrue(menu.items[index].isEnabled, "a read target is on")
        menu.performActionForItem(at: index)

        XCTAssertEqual(stored(a.id)?.isRead, false, "the read row's notification did not come back unread")
        XCTAssertEqual(stored(a.id)?.isPutBack, false, "Send to Back is not his mark")
        XCTAssertEqual(walkOrder(), [b.id, c.id, a.id], "it came back at the back of the queue")
    }

    func testWorkspaceTabSendToBackOfAReadPaneBringsItBackUnreadAtTheBack() throws {
        try withMainWindow { _, manager, _ in
            let here = try XCTUnwrap(manager.selectedWorkspace)
            let herePanel = try XCTUnwrap(here.focusedPanelId)
            let readWs = manager.addWorkspace(select: false, eagerLoadTerminal: false)
            let readPanel = try XCTUnwrap(readWs.focusedPanelId)
            let third = manager.addWorkspace(select: false, eagerLoadTerminal: false)
            let thirdPanel = try XCTUnwrap(third.focusedPanelId)
            let a = notification(tab: here.id, surface: herePanel, queuedAt: 1)
            let r = notification(tab: readWs.id, surface: readPanel, queuedAt: 2, isRead: true)
            let c = notification(tab: third.id, surface: thirdPanel, queuedAt: 3)
            store.replaceNotificationsForTesting([c, r, a])

            let tabId = try XCTUnwrap(readWs.surfaceIdFromPanelId(readPanel))
            let paneId = try XCTUnwrap(readWs.paneId(forPanelId: readPanel))
            let tab = try XCTUnwrap(readWs.bonsplitController.tab(tabId))
            readWs.splitTabBar(readWs.bonsplitController, didRequestTabContextAction: .sendToBack, for: tab, inPane: paneId)

            XCTAssertEqual(stored(r.id)?.isRead, false, "the read pane's notification did not come back unread")
            XCTAssertEqual(stored(r.id)?.isPutBack, false)
            XCTAssertEqual(walkOrder(), [a.id, c.id, r.id], "it came back at the back")
        }
    }

    // Scenario 171, SwiftUI row: the item moves nothing on screen and opens nothing, through the sidebar's real factory.
    func testSwiftUIRowSendToBackOpensNothingAndMovesNoSelection() throws {
        try withMainWindow { appDelegate, manager, _ in
            let here = try XCTUnwrap(manager.selectedWorkspace)
            let herePanel = try XCTUnwrap(here.focusedPanelId)
            let other = manager.addWorkspace(select: false, eagerLoadTerminal: false)
            let otherPanel = try XCTUnwrap(other.focusedPanelId)
            let b = notification(tab: other.id, surface: otherPanel, queuedAt: 1)
            store.replaceNotificationsForTesting([b])
            XCTAssertEqual(appDelegate.frontmostFocusedPane(), .workspace(tabId: here.id, surfaceId: herePanel), "setup: he's on the first workspace")

            let actions = try sidebarRowActions(workspaceId: other.id)
            actions.sendToBack([other.id])

            XCTAssertEqual(manager.selectedTabId, here.id, "the SwiftUI item moved the selection")
            XCTAssertEqual(here.focusedPanelId, herePanel, "the SwiftUI item moved focus")
            XCTAssertEqual(stored(b.id)?.isRead, false, "the SwiftUI item opened B's pane, which reads it")
        }
    }

    // The workspace handler's guard: a pane with no notification of its own, beside an unread workspace-level one, sends nothing, so
    // nothing is re-stamped (without the guard the store would send the workspace-level notification back).
    func testWorkspaceTabSendToBackOnAPaneWithNoNotificationLeavesAWorkspaceLevelNotificationAlone() throws {
        try withMainWindow { _, manager, _ in
            let ws = try XCTUnwrap(manager.selectedWorkspace)
            let panel = try XCTUnwrap(ws.focusedPanelId)
            let w = notification(tab: ws.id, surface: nil, queuedAt: 1)
            let other = notification(tab: UUID(), surface: UUID(), queuedAt: 2)
            store.replaceNotificationsForTesting([other, w])

            let tabId = try XCTUnwrap(ws.surfaceIdFromPanelId(panel))
            let paneId = try XCTUnwrap(ws.paneId(forPanelId: panel))
            let tab = try XCTUnwrap(ws.bonsplitController.tab(tabId))
            ws.splitTabBar(ws.bonsplitController, didRequestTabContextAction: .sendToBack, for: tab, inPane: paneId)

            XCTAssertEqual(stored(w.id)?.queuedAt, at(1), "the workspace-level notification was re-stamped by a send from a pane with none of its own")
            XCTAssertEqual(walkOrder(), [w.id, other.id])
        }
    }

    // MARK: Step 6: the Notifications popover row (Scenario 196's unit half)

    /// Renders the popover row for `notification` at 2x in the light appearance, as the sidebar tests render a hosted view.
    private func renderPopoverRow(_ notification: TerminalNotification) throws -> NSBitmapImageRep {
        let row = NotificationPopoverRow(notification: notification, workspaceTitle: "main", onOpen: {}, onClear: {}, onToggleRead: {})
        let host = NSHostingView(rootView: row.environment(\.colorScheme, .light).frame(width: 320, height: 80, alignment: .topLeading))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 80)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
        }
        host.wantsLayer = true
        host.displayIfNeeded()
        let layer = try XCTUnwrap(host.layer, "the hosting view has no layer")
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 160, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        graphics.cgContext.setFillColor(NSColor.white.cgColor)
        graphics.cgContext.fill(CGRect(x: 0, y: 0, width: 640, height: 160))
        graphics.cgContext.scaleBy(x: 2, y: 2)
        // Pin the drawing appearance to Aqua: semantic colours such as `.secondary` follow it, and this Mac switches between Light and
        // Dark by the clock, so the pixel thresholds below would otherwise depend on the time of day.
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { layer.render(in: graphics.cgContext) }
        window.close()
        return rep
    }

    /// The bounds, in points from the top left, of the pixels `matches` accepts, or nil when none does. The hosted layer renders upside down
    /// into the bitmap (its rows run bottom to top), so rows are flipped once, here and in `topDownColor`, and every y below reads top down.
    private func topDownColor(_ rep: NSBitmapImageRep, x: Int, y: Int) -> NSColor? {
        rep.colorAt(x: x, y: rep.pixelsHigh - 1 - y)?.usingColorSpace(.deviceRGB)
    }

    /// The bounds, in points from the top left, of the pixels `matches` accepts, or nil when none does (see `topDownColor` for the flip).
    private func pixelBounds(_ rep: NSBitmapImageRep, fromY: CGFloat = 0, where matches: (NSColor) -> Bool) -> (minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat)? {
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity, minY = CGFloat.infinity, maxY = -CGFloat.infinity
        for y in Int(fromY * 2)..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = topDownColor(rep, x: x, y: y), matches(color) else { continue }
                minX = min(minX, CGFloat(x) / 2); maxX = max(maxX, CGFloat(x + 1) / 2)
                minY = min(minY, CGFloat(y) / 2); maxY = max(maxY, CGFloat(y + 1) / 2)
            }
        }
        return minX.isFinite ? (minX, maxX, minY, maxY) : nil
    }

    func testNotificationPopoverRowDrawsHisDotInPlaceOfTheBarForAPutBackEntry() throws {
        var resolvedAccent: NSColor?
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { resolvedAccent = cmuxAccentNSColor().usingColorSpace(.deviceRGB) } // returns Void: the colour comes out through the capture
        let accent = try XCTUnwrap(resolvedAccent, "the accent colour did not resolve in the light appearance")
        func isAccent(_ c: NSColor) -> Bool {
            let d = pow(c.redComponent - accent.redComponent, 2) + pow(c.greenComponent - accent.greenComponent, 2) + pow(c.blueComponent - accent.blueComponent, 2)
            return d.squareRoot() < 0.2
        }
        func isDark(_ c: NSColor) -> Bool { c.redComponent < 0.35 && c.greenComponent < 0.35 && c.blueComponent < 0.35 }
        // A title and a body, so the row has second and third lines whose left edge is a ruler for the first line's.
        func note(isRead: Bool = false, isPutBack: Bool = false) -> TerminalNotification {
            TerminalNotification(
                id: UUID(), tabId: UUID(), surfaceId: UUID(), title: "Claude Code", subtitle: "", body: "Waiting for your answer",
                createdAt: Date(timeIntervalSince1970: 1), queuedAt: Date(timeIntervalSince1970: 1), isRead: isRead, isPutBack: isPutBack
            )
        }

        let plain = try renderPopoverRow(note())
        let mine = try renderPopoverRow(note(isPutBack: true))
        let read = try renderPopoverRow(note(isRead: true, isPutBack: true)) // read wins: a read entry draws nothing, whatever its flag says

        // B's and C's entries keep their bar: 2.5 pt wide, most of the row tall.
        let bar = try XCTUnwrap(pixelBounds(plain, where: isAccent), "an unread entry draws no accent bar")
        XCTAssertLessThan(bar.maxX - bar.minX, 3.0, "the bar is 2.5 pt wide (measured 2.5; a 3.5-pt slot fails here)") // cmux-rbf: step 7 R2
        XCTAssertGreaterThan(bar.maxY - bar.minY, 30, "the bar runs most of the row's height")
        XCTAssertNil(pixelBounds(read, where: isAccent), "a read entry draws neither a bar nor a dot")

        // A's entry: his dot, 6 pt, no bar, centred on the bar's slot and on the first text line.
        let dot = try XCTUnwrap(pixelBounds(mine, where: isAccent), "a put-back entry draws no accent at all")
        XCTAssertEqual(dot.maxX - dot.minX, 6, accuracy: 0.5, "the dot is 6 pt wide (measured 6.0; a bar here would be 2.5 wide and tall)")
        XCTAssertEqual(dot.maxY - dot.minY, 6, accuracy: 0.5, "the dot is 6 pt tall (measured 6.0): the bar is still drawn if this is taller")
        XCTAssertEqual((dot.minX + dot.maxX) / 2, 4 + 2.5 / 2, accuracy: 0.5, "the dot is centred on the bar's slot (4 pt padding + half of 2.5; measured 5.5)")
        let darkRows = try XCTUnwrap(pixelBounds(mine, where: isDark), "no title text rendered")
        // The title is the only dark ink in the row (the lines below are gray), so its rows are the first line's. A row-by-row scan that
        // stops at the first empty row cuts the line at the gap between the dot of the "i" and its stem.
        let line = (minY: darkRows.minY, maxY: darkRows.maxY)
        XCTAssertEqual((dot.minY + dot.maxY) / 2, (line.minY + line.maxY) / 2, accuracy: 1.0, "the dot is level with the first text line (measured within 0.25)")

        // The text did not move: the dot is drawn over the slot, not placed in the layout (Scenario 196). Two checks. (1) The same text sits
        // in the same place in the bar row, the read row and the dot row. (2) Within each row the first line's left edge is the second
        // and third lines' left edge (the VStack's): a shift of only the first line, in every row alike, would pass (1) and fails here.
        func isInk(_ c: NSColor) -> Bool { !isAccent(c) && (c.redComponent + c.greenComponent + c.blueComponent) / 3 < 0.85 }
        func layout(_ rep: NSBitmapImageRep, _ name: String) throws -> (titleX: CGFloat, titleY: CGFloat, belowX: CGFloat, belowBottom: CGFloat) {
            let title = try XCTUnwrap(pixelBounds(rep, where: isDark), "\(name): no title text")
            let below = try XCTUnwrap(pixelBounds(rep, fromY: title.maxY + 1.5) { isInk($0) }, "\(name): no second or third line below the title (title bounds \(title))")
            XCTAssertEqual(title.minX, below.minX, accuracy: 1.5, "\(name): the first line does not start where the lines below it do")
            // Absolute: from the row's own leading edge, the first line starts at 4 (leading padding) + 2.5 (the bar's slot) + 10 (content
            // padding) + 1.0 (the side bearing of "m" at 12.5 pt) = 17.5. 17.5 is the measured value of the unchanged row (title.minX in the
            // bar, read and dot rows; the lines below start at 17.0), from s6-green-send4 on 2026-11-17. Widening the slot to fit the 6-pt dot
            // moves every line of every row alike, which the comparisons above cannot see. If a font change moves the glyph, recalibrate.
            XCTAssertEqual(title.minX, 17.5, accuracy: 0.5, "\(name): the text is not where the unchanged row puts it (4 + 2.5 + 10 + bearing)")
            return (title.minX, title.minY, below.minX, below.maxY)
        }
        let barLayout = try layout(plain, "bar row"), readLayout = try layout(read, "read row"), dotLayout = try layout(mine, "dot row")
        for (name, other) in [("bar row", barLayout), ("read row", readLayout)] {
            XCTAssertEqual(dotLayout.titleX, other.titleX, accuracy: 0.5, "the first line moved sideways beside his dot (against the \(name))")
            XCTAssertEqual(dotLayout.titleY, other.titleY, accuracy: 0.5, "the first line moved vertically beside his dot (against the \(name))")
            XCTAssertEqual(dotLayout.belowX, other.belowX, accuracy: 0.5, "the lines below moved sideways beside his dot (against the \(name))")
            XCTAssertEqual(dotLayout.belowBottom, other.belowBottom, accuracy: 0.5, "the row's text block changed height beside his dot (against the \(name))")
        }
    }

    // MARK: Step 10: the window Dock's tab dot clears once nothing unread is left (Tom, 2026-11-18)

    /// A window Dock with one browser tab; `body` gets the tab and its pane. (cm-128.13)
    private func withDockTab(
        _ body: (DockSplitStore, BrowserPanel, TabID, PaneID) throws -> Void
    ) throws {
        try withMainWindowContext { appDelegate, _, _, windowId in
            let dock = appDelegate.windowDock(forWindowId: windowId)
            XCTAssertEqual(dock.scope, .global, "setup: the window Dock")
            let hostId = UUID()
            dock.setVisibleInUI(true, hostId: hostId)
            defer { dock.setVisibleInUI(false, hostId: hostId) }
            let panel = try seedDockBrowserPanel(dock)
            let tabId = try XCTUnwrap(dock.surfaceId(forPanelId: panel.id))
            let paneId = try XCTUnwrap(dock.bonsplitController.allPaneIds.first)
            try body(dock, panel, tabId, paneId)
        }
    }

    // (cm-128.13) A Dock tab he put back keeps its dot while the notification is unread and loses it when that notification is read.
    func testAPutBackDockTabsDotClearsWhenItsNotificationIsRead() throws {
        try withDockTab { dock, panel, tabId, paneId in
            let d = notification(tab: dock.workspaceId, surface: panel.id, queuedAt: 1, isRead: true)
            store.replaceNotificationsForTesting([d])
            dock.bonsplitController.requestTabContextAction(.markAsUnread, for: tabId, inPane: paneId)
            XCTAssertEqual(stored(d.id)?.isPutBack, true, "setup: the notification came back as his mark")
            XCTAssertEqual(dock.bonsplitController.tab(tabId)?.showsNotificationBadge, true, "setup: the Dock tab shows its dot")

            store.markRead(forTabId: dock.workspaceId, surfaceId: panel.id)

            XCTAssertEqual(stored(d.id)?.isRead, true, "setup: the read took")
            XCTAssertEqual(dock.bonsplitController.tab(tabId)?.showsNotificationBadge, false, "the dot outlived the read of its notification")
        }
    }

    // (cm-128.13) A Dock tab sent back from read: the dot is set by the send, and the later read clears it.
    func testADockTabSentBackFromReadLosesItsDotAfterTheRead() throws {
        try withDockTab { dock, panel, tabId, paneId in
            let d = notification(tab: dock.workspaceId, surface: panel.id, queuedAt: 1, isRead: true)
            store.replaceNotificationsForTesting([d])
            dock.bonsplitController.requestTabContextAction(.sendToBack, for: tabId, inPane: paneId)
            XCTAssertEqual(stored(d.id)?.isRead, false, "setup: it came back unread")
            XCTAssertEqual(dock.bonsplitController.tab(tabId)?.showsNotificationBadge, true, "setup: the Dock tab shows its dot")

            store.markRead(forTabId: dock.workspaceId, surfaceId: panel.id)

            XCTAssertEqual(dock.bonsplitController.tab(tabId)?.showsNotificationBadge, false, "the dot outlived the read of the notification sent back")
        }
    }

    // (cm-128.13) A Dock mark with no notification keeps its dot, even through other changes for the same window, until the mark is read.
    func testADockMarkWithNoNotificationKeepsItsDotUntilTheMarkIsRead() throws {
        try withDockTab { dock, panel, tabId, paneId in
            store.replaceNotificationsForTesting([])
            dock.bonsplitController.requestTabContextAction(.markAsUnread, for: tabId, inPane: paneId)
            XCTAssertTrue(store.hasManualUnread(forTabId: dock.workspaceId, surfaceId: panel.id), "setup: a Dock mark")
            XCTAssertEqual(dock.bonsplitController.tab(tabId)?.showsNotificationBadge, true, "setup: the Dock tab shows its dot")

            // Another surface of the same window changes in the store (a Dock mark; `replaceNotificationsForTesting` would drop this
            // Dock's own mark): the store tells this Dock, and its marked tab keeps the dot.
            let otherSurface = UUID()
            _ = store.markWindowDockSurfaceUnread(windowId: dock.workspaceId, surfaceId: otherSurface)
            defer { _ = store.clearWindowDockSurfaceUnread(windowId: dock.workspaceId, surfaceId: otherSurface) }
            XCTAssertTrue(store.hasManualUnread(forTabId: dock.workspaceId, surfaceId: panel.id), "setup: the mark is still there")
            XCTAssertEqual(dock.bonsplitController.tab(tabId)?.showsNotificationBadge, true, "the dot went while the Dock mark held")

            _ = store.clearWindowDockSurfaceUnread(windowId: dock.workspaceId, surfaceId: panel.id)

            XCTAssertEqual(dock.bonsplitController.tab(tabId)?.showsNotificationBadge, false, "the dot outlived its Dock mark")
        }
    }

    // (cm-128.13, step 11 R4) A put-back Dock notification that is removed, not read, takes the dot with it.
    func testARemovedPutBackDockNotificationClearsItsDot() throws {
        try withDockTab { dock, panel, tabId, paneId in
            let d = notification(tab: dock.workspaceId, surface: panel.id, queuedAt: 1, isRead: true)
            store.replaceNotificationsForTesting([d])
            dock.bonsplitController.requestTabContextAction(.markAsUnread, for: tabId, inPane: paneId)
            XCTAssertEqual(stored(d.id)?.isPutBack, true, "setup: the notification came back as his mark")
            XCTAssertEqual(dock.bonsplitController.tab(tabId)?.showsNotificationBadge, true, "setup: the Dock tab shows its dot")

            store.clearNotifications(forTabId: dock.workspaceId, surfaceId: panel.id)

            XCTAssertNil(stored(d.id), "setup: the notification is gone")
            XCTAssertEqual(dock.bonsplitController.tab(tabId)?.showsNotificationBadge, false, "the dot outlived the removal of its notification")
        }
    }

    // (cm-128.13, step 11, the cold read's "Unproven") A read Dock notification beside a Dock mark and the focused-read indicator,
    // sent back through the store alone (⌘⌃U's path: nothing sets the dot afterwards): the end state is an unread notification, so the
    // dot stays. The store must not publish the indicator's clear while the notification is still read.
    func testSendingBackAReadDockNotificationBesideAMarkAndTheFocusedReadIndicatorKeepsTheDot() throws {
        try withDockTab { dock, panel, tabId, _ in
            let d = notification(tab: dock.workspaceId, surface: panel.id, queuedAt: 1, isRead: true)
            store.replaceNotificationsForTesting([d])
            _ = store.markWindowDockSurfaceUnread(windowId: dock.workspaceId, surfaceId: panel.id)
            store.setFocusedReadIndicator(forTabId: dock.workspaceId, surfaceId: panel.id)
            dock.bonsplitController.updateTab(tabId, showsNotificationBadge: true)
            XCTAssertEqual(dock.bonsplitController.tab(tabId)?.showsNotificationBadge, true, "setup: the Dock tab shows its dot")

            _ = store.sendToBack([.windowDock(WindowDockUnreadTarget(windowId: dock.workspaceId, surfaceId: panel.id))])

            XCTAssertEqual(stored(d.id)?.isRead, false, "setup: the read notification came back unread")
            XCTAssertEqual(dock.bonsplitController.tab(tabId)?.showsNotificationBadge, true, "the dot went at a moment when the notification was still read, though the end state is unread")
        }
    }

    // The same through Mark as Unread's own store path (the popover's item, `markNotificationFeedUnread`).
    func testMarkingAReadDockNotificationUnreadBesideAMarkAndTheFocusedReadIndicatorKeepsTheDot() throws {
        try withDockTab { dock, panel, tabId, _ in
            let d = notification(tab: dock.workspaceId, surface: panel.id, queuedAt: 1, isRead: true)
            store.replaceNotificationsForTesting([d])
            _ = store.markWindowDockSurfaceUnread(windowId: dock.workspaceId, surfaceId: panel.id)
            store.setFocusedReadIndicator(forTabId: dock.workspaceId, surfaceId: panel.id)
            dock.bonsplitController.updateTab(tabId, showsNotificationBadge: true)

            store.markUnread(id: d.id)

            XCTAssertEqual(stored(d.id)?.isRead, false, "setup: the notification came back unread")
            XCTAssertEqual(dock.bonsplitController.tab(tabId)?.showsNotificationBadge, true, "the dot went at a moment when the notification was still read, though the end state is unread")
        }
    }

    // (cm-128.13) Nothing ever adds a dot for news: a notification on a Dock tab leaves its badge as it was.
    func testNewsOnADockTabNeverSetsItsDot() throws {
        try withDockTab { dock, panel, tabId, _ in
            XCTAssertEqual(dock.bonsplitController.tab(tabId)?.showsNotificationBadge, false, "setup: no dot")

            store.replaceNotificationsForTesting([notification(tab: dock.workspaceId, surface: panel.id, queuedAt: 1)])

            XCTAssertTrue(store.hasUnreadNotification(forTabId: dock.workspaceId, surfaceId: panel.id), "setup: news on the Dock surface")
            XCTAssertEqual(dock.bonsplitController.tab(tabId)?.showsNotificationBadge, false, "news set a dot on the Dock tab")
        }
    }

    // (cm-128.13) A Dock with no window-Dock target keeps today's behaviour: its badge is not the store's to clear.
    func testALocalDocksBadgeIsLeftAloneWhenTheStoreChanges() throws {
        try withMainWindowContext { _, manager, _, _ in
            let ws = try XCTUnwrap(manager.selectedWorkspace)
            let localDock = try XCTUnwrap(ws.dockSplit)
            XCTAssertEqual(localDock.scope, .workspace, "setup: a workspace-scoped Dock")
            localDock.notificationStore = store // reachable by the listener if it did not stop at the scope
            let hostId = UUID()
            localDock.setVisibleInUI(true, hostId: hostId)
            defer { localDock.setVisibleInUI(false, hostId: hostId) }
            let panel = try seedDockBrowserPanel(localDock)
            let tabId = try XCTUnwrap(localDock.surfaceId(forPanelId: panel.id))
            localDock.bonsplitController.updateTab(tabId, showsNotificationBadge: true)
            let d = notification(tab: localDock.workspaceId, surface: panel.id, queuedAt: 1)
            store.replaceNotificationsForTesting([d])

            store.markRead(forTabId: localDock.workspaceId, surfaceId: panel.id)
            store.replaceNotificationsForTesting([notification(tab: localDock.workspaceId, surface: UUID(), queuedAt: 2)])

            XCTAssertEqual(localDock.bonsplitController.tab(tabId)?.showsNotificationBadge, true, "the store cleared a local Dock's badge")
        }
    }

    // MARK: Step 3: the four checks

    private func withMainWindow(_ body: (AppDelegate, TabManager, NSWindow) throws -> Void) throws {
        try withMainWindowContext { appDelegate, manager, window, _ in try body(appDelegate, manager, window) }
    }

    private func withMainWindowContext(_ body: (AppDelegate, TabManager, NSWindow, UUID) throws -> Void) throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let originalStore = appDelegate.notificationStore
        let originalTabManager = appDelegate.tabManager
        let originalFocus = AppFocusState.overrideIsFocused
        store.replaceNotificationsForTesting([])
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = true
        let windowId = appDelegate.createMainWindow(shouldActivate: false)
        defer {
#if DEBUG
            debugShortcutRoutingFocusedWindowOverrideForTesting.window = nil
#endif
            appDelegate.windowForMainWindowId(windowId)?.performClose(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            store.replaceNotificationsForTesting([])
            appDelegate.notificationStore = originalStore
            appDelegate.tabManager = originalTabManager
            AppFocusState.overrideIsFocused = originalFocus
        }
        let window = try XCTUnwrap(appDelegate.windowForMainWindowId(windowId))
        let manager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: windowId))
        appDelegate.tabManager = manager
#if DEBUG
        // Resolve "the pane he's on" in this window, not in the test host's own key window (as NotificationJumpOldestFirstTests does).
        debugShortcutRoutingFocusedWindowOverrideForTesting.window = window
#endif
        try body(appDelegate, manager, window, windowId)
    }

    // MARK: Scenario 192: app activation (AppDelegate.readNotificationOnActivation, the handler's read)

    func testActivationLeavesAPutBackNotificationUnreadAndUnflashed() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let mine = notification(tab: UUID(), surface: UUID(), queuedAt: 10, isPutBack: true)
        store.replaceNotificationsForTesting([mine])
        var flashes: [UUID] = []

        appDelegate.readNotificationOnActivation(
            store: store, target: (workspaceID: mine.tabId, surfaceID: mine.surfaceId!)
        ) { _, panel in flashes.append(panel) }

        XCTAssertEqual(flashes, [], "it is his mark: nothing on it is news")
        XCTAssertEqual(stored(mine.id)?.isRead, false)
        XCTAssertEqual(stored(mine.id)?.isPutBack, true)
    }

    func testActivationFlashesAndReadsTheNewsBesideAPutBackNotificationAndKeepsTheMark() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let tab = UUID(), surface = UUID()
        let mine = notification(tab: tab, surface: surface, queuedAt: 10, isPutBack: true)
        let news = notification(tab: tab, surface: surface, queuedAt: 20)
        store.replaceNotificationsForTesting([news, mine])
        var flashes: [UUID] = []

        appDelegate.readNotificationOnActivation(store: store, target: (workspaceID: tab, surfaceID: surface)) { _, panel in
            flashes.append(panel)
        }

        XCTAssertEqual(flashes, [surface], "the news flashes the pane")
        XCTAssertEqual(stored(news.id)?.isRead, true)
        XCTAssertEqual(stored(mine.id)?.isRead, false, "the put-back one stays unread")
        XCTAssertEqual(stored(mine.id)?.isPutBack, true)
    }

    func testActivationDoesNotFlashForAPutBackNotificationBesideNewsThatAsksNoFlash() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let tab = UUID(), surface = UUID()
        let mine = notification(tab: tab, surface: surface, queuedAt: 10, isPutBack: true)
        let quietNews = TerminalNotification(
            id: UUID(), tabId: tab, surfaceId: surface, title: "t", subtitle: "", body: "",
            createdAt: at(20), isRead: false, paneFlash: false
        )
        store.replaceNotificationsForTesting([quietNews, mine])
        var flashes = 0

        appDelegate.readNotificationOnActivation(store: store, target: (workspaceID: tab, surfaceID: surface)) { _, _ in
            flashes += 1
        }

        XCTAssertEqual(flashes, 0, "a flash is for news, and the news asked for none: his mark never asks for one")
        XCTAssertEqual(stored(quietNews.id)?.isRead, true)
        XCTAssertEqual(stored(mine.id)?.isRead, false)
    }

    func testActivationOnAWindowDockSurfaceLeavesAPutBackNotificationUnflashed() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let window = UUID(), dockSurface = UUID()
        let mine = notification(tab: window, surface: dockSurface, queuedAt: 10, isPutBack: true)
        store.replaceNotificationsForTesting([mine])
        var flashes = 0

        appDelegate.readNotificationOnActivation(store: store, target: (workspaceID: window, surfaceID: dockSurface)) { _, _ in
            flashes += 1
        }

        XCTAssertEqual(flashes, 0)
        XCTAssertEqual(stored(mine.id)?.isRead, false)
        XCTAssertEqual(stored(mine.id)?.isPutBack, true)
    }

    // R2: the handler applicationDidBecomeActive itself, so a rewrite of its tail is caught.
    func testTheActivationHandlerLeavesAPutBackNotificationUnread() throws {
        try withMainWindow { appDelegate, manager, _ in
            let ws = try XCTUnwrap(manager.selectedWorkspace)
            let panel = try XCTUnwrap(ws.focusedPanelId)
            let mine = notification(tab: ws.id, surface: panel, queuedAt: 1, isPutBack: true)
            store.replaceNotificationsForTesting([mine])
            let target = try XCTUnwrap(appDelegate.notificationAttentionTargetOnActivation(tabManager: manager), "setup: the activation target")
            XCTAssertEqual(target.surfaceID, panel, "setup: A's pane is focused")

            appDelegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))

            XCTAssertEqual(stored(mine.id)?.isRead, false, "his mark stays through activation")
            XCTAssertEqual(stored(mine.id)?.isPutBack, true)
        }
    }

    func testTheActivationHandlerLeavesAPutBackDockNotificationUnread() throws {
        try withMainWindowContext { appDelegate, manager, window, windowId in
            let dock = appDelegate.windowDock(forWindowId: windowId)
            let hostId = UUID()
            dock.setVisibleInUI(true, hostId: hostId)
            defer { dock.setVisibleInUI(false, hostId: hostId) }
            let panel = try seedDockBrowserPanel(dock)
            dock.focusPanel(panel.id)
            window.makeKeyAndOrderFront(nil)
            appDelegate.keyboardFocusCoordinator(for: window)?.noteRightSidebarInteraction(mode: .dock)
            let mine = notification(tab: dock.workspaceId, surface: panel.id, queuedAt: 1, isPutBack: true)
            store.replaceNotificationsForTesting([mine])
            let target = try XCTUnwrap(appDelegate.notificationAttentionTargetOnActivation(tabManager: manager), "setup: the activation target")
            XCTAssertEqual(target.surfaceID, panel.id, "setup: the Dock surface is the target")

            appDelegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))

            XCTAssertEqual(stored(mine.id)?.isRead, false)
            XCTAssertEqual(stored(mine.id)?.isPutBack, true)
        }
    }

    // R4: with only a put-back notification unread, activation neither flashes nor reads, so a store surface mark beside it survives
    // (the guard is the one thing between it and markRead's side effects).
    func testActivationKeepsHisStoreSurfaceMarkBesideAPutBackNotification() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let tab = UUID(), surface = UUID()
        let mine = notification(tab: tab, surface: surface, queuedAt: 10, isPutBack: true)
        store.replaceNotificationsForTesting([mine])
        store.markUnread(forTabId: tab, surfaceId: surface)
        defer { store.clearManualUnread(forTabId: tab, surfaceId: surface) }
        XCTAssertTrue(store.hasManualUnread(forTabId: tab, surfaceId: surface), "setup: his surface mark")

        appDelegate.readNotificationOnActivation(store: store, target: (workspaceID: tab, surfaceID: surface)) { _, _ in }

        XCTAssertTrue(store.hasManualUnread(forTabId: tab, surfaceId: surface), "nothing was read, so his mark is not cleared")
        XCTAssertEqual(stored(mine.id)?.isRead, false)
    }

    // MARK: Scenario 191: the walk passes the pane he's on by (AppDelegate.jumpToOldestUnread, the eight ways in)

    func testTheWalkPassesThePaneHesOnByWhenItHoldsAPutBackNotification() throws {
        try withMainWindow { appDelegate, manager, _ in
            let here = try XCTUnwrap(manager.selectedWorkspace)
            let herePanel = try XCTUnwrap(here.focusedPanelId)
            let other = manager.addWorkspace(select: false, eagerLoadTerminal: false)
            let a = notification(tab: here.id, surface: herePanel, queuedAt: 1, isPutBack: true)
            let otherPanel = try XCTUnwrap(other.focusedPanelId)
            let b = notification(tab: other.id, surface: otherPanel, queuedAt: 2)
            store.replaceNotificationsForTesting([b, a])
            XCTAssertEqual(appDelegate.frontmostFocusedPane(), .workspace(tabId: here.id, surfaceId: herePanel),
                           "setup: A's pane is the pane he's on")

            // Other stops waiting: the press opens the next one, and his pane stays unread with its mark.
            XCTAssertEqual(appDelegate.jumpToOldestUnread()?.id, b.id, "the press opened B, the stop after A")
            XCTAssertEqual(stored(a.id)?.isRead, false, "A is the pane he's on and holds his mark: the press passes it by")
            XCTAssertEqual(stored(a.id)?.isPutBack, true)
            XCTAssertEqual(stored(b.id)?.isRead, true, "the press opened B, the stop after A")

            // With focus now on B, A isn't the pane he's on: the next press opens A like any other stop, reads it, and drops the mark.
            XCTAssertEqual(appDelegate.frontmostFocusedPane(), .workspace(tabId: other.id, surfaceId: otherPanel), "setup: the press moved him to B")
            XCTAssertEqual(appDelegate.jumpToOldestUnread()?.id, a.id, "from B, A is a stop like any other")
            XCTAssertEqual(stored(a.id)?.isRead, true)
            XCTAssertEqual(stored(a.id)?.isPutBack, false, "reading it drops the mark")

            // Only his pane left: the press leaves him on it, still unread.
            manager.selectedTabId = here.id
            store.replaceNotificationsForTesting([a])
            XCTAssertNil(appDelegate.jumpToOldestUnread())
            XCTAssertEqual(stored(a.id)?.isRead, false)
            XCTAssertEqual(stored(a.id)?.isPutBack, true)
        }
    }

    // (R5) The exclusion is for a put-back notification only: with plain news on the pane he's on, the press reads it and goes on (.11's Q77/Q97).
    func testTheWalkStillReadsThePaneHesOnWhenItHoldsPlainNews() throws {
        try withMainWindow { appDelegate, manager, _ in
            let here = try XCTUnwrap(manager.selectedWorkspace)
            let herePanel = try XCTUnwrap(here.focusedPanelId)
            let other = manager.addWorkspace(select: false, eagerLoadTerminal: false)
            let otherPanel = try XCTUnwrap(other.focusedPanelId)
            let a = notification(tab: here.id, surface: herePanel, queuedAt: 1)
            let b = notification(tab: other.id, surface: otherPanel, queuedAt: 2)
            store.replaceNotificationsForTesting([b, a])
            XCTAssertEqual(appDelegate.frontmostFocusedPane(), .workspace(tabId: here.id, surfaceId: herePanel), "setup")

            XCTAssertEqual(appDelegate.jumpToOldestUnread()?.id, b.id, "A is read as the pane he's on, and the press goes on to B")
            XCTAssertEqual(stored(a.id)?.isRead, true, "plain news on the pane he's on is read, as before")
        }
    }

    // MARK: Scenario 193, app half: the real TabManager host

    func testAClickLeavesAPutBackNotificationUnreadAndItsFeedRecordUnread() throws {
        try withMainWindow { _, manager, _ in
            let ws = try XCTUnwrap(manager.selectedWorkspace)
            let panel = try XCTUnwrap(ws.focusedPanelId)
            let mine = notification(tab: ws.id, surface: panel, queuedAt: 1, isPutBack: true)
            store.replaceNotificationsForTesting([mine])
            store.notificationFeedHistory.reconcileActiveNotifications(store.notifications)

            manager.dismissNotificationOnDirectInteraction(tabId: ws.id, surfaceId: panel)

            XCTAssertEqual(stored(mine.id)?.isRead, false)
            XCTAssertEqual(stored(mine.id)?.isPutBack, true)
            XCTAssertEqual(store.notificationFeedHistory.snapshot.notifications.first(where: { $0.id == mine.id })?.isRead, false,
                           "the phone's list agrees")
        }
    }

    func testAClickKeepsAPutBackNotificationBesideNews() throws {
        try withMainWindow { _, manager, _ in
            let ws = try XCTUnwrap(manager.selectedWorkspace)
            let panel = try XCTUnwrap(ws.focusedPanelId)
            let mine = notification(tab: ws.id, surface: panel, queuedAt: 1, isPutBack: true)
            let news = notification(tab: ws.id, surface: panel, queuedAt: 2)
            store.replaceNotificationsForTesting([news, mine])

            manager.dismissNotificationOnDirectInteraction(tabId: ws.id, surfaceId: panel)

            XCTAssertEqual(stored(news.id)?.isRead, true, "the news is read")
            XCTAssertEqual(stored(mine.id)?.isRead, false, "the put-back one is left")
            XCTAssertEqual(stored(mine.id)?.isPutBack, true)
        }
    }

    private func broadcastExplicitFocus(tab: UUID, surface: UUID) {
        NotificationCenter.default.post(
            name: .ghosttyDidFocusSurface, object: nil,
            userInfo: [GhosttyNotificationKey.tabId: tab, GhosttyNotificationKey.surfaceId: surface, GhosttyNotificationKey.explicitFocusIntent: true]
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    }

    // Scenario 193: a click into the pane arrives as the focus broadcast with explicit intent.
    func testAFocusBroadcastWithExplicitIntentLeavesAPutBackNotificationUnread() throws {
        try withMainWindow { _, manager, _ in
            let ws = try XCTUnwrap(manager.selectedWorkspace)
            let panel = try XCTUnwrap(ws.focusedPanelId)
            let mine = notification(tab: ws.id, surface: panel, queuedAt: 1, isPutBack: true)
            let news = notification(tab: ws.id, surface: panel, queuedAt: 2)
            store.replaceNotificationsForTesting([news, mine])

            broadcastExplicitFocus(tab: ws.id, surface: panel)

            XCTAssertEqual(stored(news.id)?.isRead, true, "setup: the broadcast reaches the dismissal and reads the news")
            XCTAssertEqual(stored(mine.id)?.isRead, false, "the put-back one is left")
            XCTAssertEqual(stored(mine.id)?.isPutBack, true)
        }
    }

    // The window Dock's focus transaction is a different host (the Dock's reference TabManager, tabId = the window).
    private func seedDockBrowserPanel(_ dock: DockSplitStore) throws -> BrowserPanel {
        let panel = BrowserPanel(
            workspaceId: dock.workspaceId,
            initialURL: try XCTUnwrap(URL(string: "https://example.com/put-back")),
            renderInitialNavigation: false
        )
        let pane = try XCTUnwrap(dock.bonsplitController.allPaneIds.first)
        dock.panels[panel.id] = panel
        let tabId = try XCTUnwrap(dock.bonsplitController.createTab(
            title: panel.displayTitle, icon: panel.displayIcon, kind: "browser", isDirty: panel.isDirty, inPane: pane
        ))
        dock.bindSurface(tabId, toPanelId: panel.id)
        return panel
    }

    func testTheWindowDocksFocusLeavesAPutBackDockNotificationUnread() throws {
        try withMainWindowContext { appDelegate, _, window, windowId in
            let dock = appDelegate.windowDock(forWindowId: windowId)
            let hostId = UUID()
            dock.setVisibleInUI(true, hostId: hostId)
            defer { dock.setVisibleInUI(false, hostId: hostId) }
            let panel = try seedDockBrowserPanel(dock)
            let mine = notification(tab: dock.workspaceId, surface: panel.id, queuedAt: 1, isPutBack: true)
            let news = notification(tab: dock.workspaceId, surface: panel.id, queuedAt: 2)
            store.replaceNotificationsForTesting([news, mine])

            dock.focusPanelFromDockInteraction(panel.id, window: window)

            XCTAssertEqual(stored(news.id)?.isRead, true, "setup: the Dock's focus transaction reaches the dismissal and reads the news")
            XCTAssertEqual(stored(mine.id)?.isRead, false, "the put-back Dock notification is left")
            XCTAssertEqual(stored(mine.id)?.isPutBack, true)
        }
    }

    func testTypingReadsAPutBackNotificationOnAWorkspaceWhoseOnlyUnreadIsIt() throws {
        try withMainWindow { _, manager, _ in
            let ws = try XCTUnwrap(manager.selectedWorkspace)
            let panel = try XCTUnwrap(ws.focusedPanelId)
            let mine = notification(tab: ws.id, surface: panel, queuedAt: 1, isPutBack: true)
            store.replaceNotificationsForTesting([mine])

            manager.dismissNotificationOnTerminalInteraction(tabId: ws.id, surfaceId: panel)

            XCTAssertEqual(stored(mine.id)?.isRead, true, "typing reads it, as it reads his dot")
            XCTAssertEqual(stored(mine.id)?.isPutBack, false)
        }
    }

    func testTheAppsHostAnswersNewsOnlyForAWorkspaceWhoseOnlyUnreadIsAPutBackNotification() throws {
        try withMainWindow { _, manager, _ in
            let ws = try XCTUnwrap(manager.selectedWorkspace)
            let panel = try XCTUnwrap(ws.focusedPanelId)
            let mine = notification(tab: ws.id, surface: panel, queuedAt: 1, isPutBack: true)
            store.replaceNotificationsForTesting([mine])

            XCTAssertTrue(manager.storeHasUnreadNotification(workspaceId: ws.id, surfaceId: panel), "the plain read counts it")
            XCTAssertFalse(manager.storeHasUnreadNewsNotification(workspaceId: ws.id, surfaceId: panel), "the news read does not")
            XCTAssertFalse(manager.storeHasVisibleNewsIndicator(workspaceId: ws.id, surfaceId: panel))
            manager.storeMarkRead(workspaceId: ws.id, surfaceId: panel, keepingPutBack: true)
            XCTAssertEqual(stored(mine.id)?.isRead, false, "the host passes the keep to the store")
        }
    }

    // Unproven 1 (the lead's call, 2026-11-16): a notification recorded while its pane was focused leaves the focused-read indicator;
    // putting it back makes the mark provide the unread state, so the indicator gives way and a click flashes nothing.
    func testPuttingBackANotificationRecordedWhileFocusedClearsTheFocusedReadIndicator() throws {
        try withMainWindow { _, manager, _ in
            let ws = try XCTUnwrap(manager.selectedWorkspace)
            let panel = try XCTUnwrap(ws.focusedPanelId)
            let n = notification(tab: ws.id, surface: panel, queuedAt: 1, isRead: true)
            store.replaceNotificationsForTesting([n])
            store.setFocusedReadIndicator(forTabId: ws.id, surfaceId: panel)
            XCTAssertEqual(store.focusedReadIndicatorSurfaceId(forTabId: ws.id), panel, "setup: the indicator")

            store.markUnreadAtFormerPlace([pane(ws.id, panel)])

            XCTAssertNil(store.focusedReadIndicatorSurfaceId(forTabId: ws.id), "the mark provides the unread state: the indicator gives way to his dot")
            XCTAssertFalse(manager.dismissNotificationOnDirectInteraction(tabId: ws.id, surfaceId: panel), "a click into the pane dismisses nothing, so no flash")
            XCTAssertEqual(stored(n.id)?.isRead, false)
            XCTAssertEqual(stored(n.id)?.isPutBack, true)
        }
    }

    // Unproven 2: the walk's predicate maps one side at a time through the owning panel, as the walk matches a stop.
    func testThePaneHesOnHoldsAPutBackNotificationThroughItsOwningPanel() {
        let tab = UUID(), container = UUID(), inner = UUID(), unrelated = UUID()
        let mine = notification(tab: tab, surface: inner, queuedAt: 1, isPutBack: true)
        store.replaceNotificationsForTesting([mine])
        let innerBelongsToContainer: (UUID, UUID) -> UUID = { _, surface in surface == inner ? container : surface }

        XCTAssertTrue(store.holdsUnreadPutBackNotification(on: pane(tab, container), owningPanelId: innerBelongsToContainer),
                      "he's on the container pane; the notification is keyed by the inner surface")
        XCTAssertFalse(store.holdsUnreadPutBackNotification(on: pane(tab, unrelated), owningPanelId: innerBelongsToContainer))

        let keyedByContainer = notification(tab: tab, surface: container, queuedAt: 2, isPutBack: true)
        store.replaceNotificationsForTesting([keyedByContainer])
        XCTAssertTrue(store.holdsUnreadPutBackNotification(on: pane(tab, inner), owningPanelId: innerBelongsToContainer),
                      "the reverse: he's on the inner pane, the notification is keyed by its container")
    }

    // Unproven 3: a focused target with no surface names no pane, so it derives no exclusion.
    func testAFocusedTargetWithNoSurfaceDerivesNoExclusion() {
        let tab = UUID(), surface = UUID()
        let mine = notification(tab: tab, surface: surface, queuedAt: 1, isPutBack: true)
        let workspaceLevel = notification(tab: tab, surface: nil, queuedAt: 2, isPutBack: true)
        store.replaceNotificationsForTesting([mine])

        XCTAssertFalse(store.holdsUnreadPutBackNotification(on: pane(tab, nil), owningPanelId: { $1 }),
                       "a workspace target would match every pane of the workspace, news on other panes included")

        store.replaceNotificationsForTesting([workspaceLevel])
        XCTAssertTrue(store.holdsUnreadPutBackNotification(on: pane(tab, surface), owningPanelId: { $1 }),
                      "a put-back workspace-level notification is on every pane of its workspace (isOnPane's rule)")
    }

    // MARK: Scenario 194: visits don't end the mark

    func testVisitsToOtherPanesAndWorkspacesDoNotClearAPutBackNotification() throws {
        try withMainWindowContext { appDelegate, manager, window, windowId in
            let ws = try XCTUnwrap(manager.selectedWorkspace)
            let panel = try XCTUnwrap(ws.focusedPanelId)
            let otherPanel = try XCTUnwrap(ws.newTerminalSplit(from: panel, orientation: .horizontal, focus: false))
            let otherWorkspace = manager.addWorkspace(select: false, eagerLoadTerminal: false)
            let mine = notification(tab: ws.id, surface: panel, queuedAt: 1, isPutBack: true)
            store.replaceNotificationsForTesting([mine])

            let dock = appDelegate.windowDock(forWindowId: windowId)
            let hostId = UUID()
            dock.setVisibleInUI(true, hostId: hostId)
            defer { dock.setVisibleInUI(false, hostId: hostId) }
            let dockPanel = try seedDockBrowserPanel(dock)
            @MainActor func stillHisMark(_ after: String) {
                XCTAssertEqual(stored(mine.id)?.isRead, false, "A is still unread after \(after)")
                XCTAssertEqual(stored(mine.id)?.isPutBack, true, "A is still his mark after \(after)")
                broadcastExplicitFocus(tab: ws.id, surface: panel)
                XCTAssertEqual(stored(mine.id)?.isRead, false, "A is still unread after \(after), and a focus broadcast for A")
                XCTAssertEqual(stored(mine.id)?.isPutBack, true, "A is still his mark after \(after), and a focus broadcast for A")
            }
            ws.focusPanel(otherPanel.id)
            stillHisMark("a visit to pane B")
            ws.focusPanel(panel)
            stillHisMark("coming back to A (Workspace.focusPanel)")
            manager.selectedTabId = otherWorkspace.id
            stillHisMark("a visit to another workspace")
            manager.selectedTabId = ws.id
            stillHisMark("coming back to A's workspace (TabManager.selectedTabId)")
            dock.focusPanel(dockPanel.id)
            stillHisMark("a visit to a window Dock surface (DockSplitStore.focusPanel)")
            ws.focusPanel(panel)
            stillHisMark("coming back from the Dock")
            let secondWindowId = appDelegate.createMainWindow(shouldActivate: false)
            defer { appDelegate.windowForMainWindowId(secondWindowId)?.performClose(nil) }
            appDelegate.windowForMainWindowId(secondWindowId)?.makeKeyAndOrderFront(nil)
            stillHisMark("a second main window becoming key")
            window.makeKeyAndOrderFront(nil)
            stillHisMark("the first window key again")
            manager.dismissNotificationOnDirectInteraction(tabId: ws.id, surfaceId: panel)
            stillHisMark("a click into A")
        }
    }
}
