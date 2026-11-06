import AppKit
import CmuxNotifications
import CmuxRestartCommands
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The app-side jump behind all eight ways in (cm-128.11): the pane unread longest opens first, the
/// pane he's on is read and passed, and a restart summary takes its place by its own time. These run
/// the real `AppDelegate.jumpToOldestUnread` on real workspaces and the real notification store.
@MainActor
final class NotificationJumpOldestFirstTests: XCTestCase {
    private var appDelegate: AppDelegate!
    private let store = TerminalNotificationStore.shared
    private var originalNotificationStore: TerminalNotificationStore?
    private var originalSummaryStore: RestartCommandRestoreSummaryStore!
    private var originalFocusOverride: Bool?
    private var originalTabManager: TabManager?
    private var windowId: UUID!
    private var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        appDelegate = AppDelegate.shared ?? AppDelegate()
        originalNotificationStore = appDelegate.notificationStore
        originalSummaryStore = appDelegate.restartCommandSummaryStore
        originalFocusOverride = AppFocusState.overrideIsFocused
        originalTabManager = appDelegate.tabManager
        store.replaceNotificationsForTesting([])
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false // no pane is "the pane he's on" unless a test says so
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotificationJumpOldestFirstTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        appDelegate.restartCommandSummaryStore = RestartCommandRestoreSummaryStore(
            repository: RestartCommandRestoreSummaryRepository(
                fileURL: tempDirectory.appendingPathComponent("summaries.json")
            )
        )
        windowId = appDelegate.createMainWindow(shouldActivate: false)
#if DEBUG
        // Resolve "the pane he's on" in this window, not in the test host's own key window.
        debugShortcutRoutingFocusedWindowOverrideForTesting.window = appDelegate.windowForMainWindowId(windowId)
#endif
    }

    override func tearDown() async throws {
#if DEBUG
        debugShortcutRoutingFocusedWindowOverrideForTesting.window = nil
#endif
        appDelegate.windowForMainWindowId(windowId)?.performClose(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        store.replaceNotificationsForTesting([])
        appDelegate.notificationStore = originalNotificationStore
        appDelegate.restartCommandSummaryStore = originalSummaryStore
        appDelegate.tabManager = originalTabManager
        AppFocusState.overrideIsFocused = originalFocusOverride
        try? FileManager.default.removeItem(at: tempDirectory)
        try await super.tearDown()
    }

    // MARK: Fixtures

    private struct Pane {
        let workspaceId: UUID
        let panelId: UUID
    }

    /// The window's selected workspace and `count - 1` more, each with its focused panel.
    private func makePanes(_ count: Int) throws -> (TabManager, [Pane]) {
        let manager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: windowId))
        appDelegate.tabManager = manager // the active manager is where "the pane he's on" is resolved
        var panes: [Pane] = []
        let first = try XCTUnwrap(manager.selectedWorkspace)
        panes.append(Pane(workspaceId: first.id, panelId: try XCTUnwrap(first.focusedPanelId)))
        while panes.count < count {
            let workspace = manager.addWorkspace(select: false, eagerLoadTerminal: false)
            panes.append(Pane(workspaceId: workspace.id, panelId: try XCTUnwrap(workspace.focusedPanelId)))
        }
        return (manager, panes)
    }

    private func news(
        _ pane: Pane, queuedAt: TimeInterval, createdAt: TimeInterval? = nil, isRead: Bool = false
    ) -> TerminalNotification {
        TerminalNotification(
            id: UUID(),
            tabId: pane.workspaceId,
            surfaceId: pane.panelId,
            title: "n\(Int(queuedAt))",
            subtitle: "",
            body: "",
            createdAt: Date(timeIntervalSince1970: createdAt ?? queuedAt),
            queuedAt: Date(timeIntervalSince1970: queuedAt),
            isRead: isRead
        )
    }

    private func isRead(_ notification: TerminalNotification) -> Bool? {
        store.notifications.first(where: { $0.id == notification.id })?.isRead
    }

    private func insertSummary(createdAt: TimeInterval) async throws -> RestartCommandRestoreSummary {
        let summary = RestartCommandRestoreSummary(
            operationID: UUID(),
            createdAt: Date(timeIntervalSince1970: createdAt),
            rows: [],
            overflowCount: 0
        )
        appDelegate.restartCommandSummaryStore.insert(summary)
        for _ in 0..<200 where !appDelegate.restartCommandSummaryStore.summaries.contains(where: { $0.id == summary.id }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(appDelegate.restartCommandSummaryStore.summaries.contains(where: { $0.id == summary.id }))
        return summary
    }

    // MARK: Scenarios 150, 151: oldest first, a new arrival at the back

    func testJumpsVisitPanesInTheOrderTheyWentUnreadAndReadEach() throws {
        let (manager, panes) = try makePanes(3)
        let a = news(panes[0], queuedAt: 1), b = news(panes[1], queuedAt: 2), c = news(panes[2], queuedAt: 3)
        store.replaceNotificationsForTesting([c, b, a]) // the store is newest first

        XCTAssertEqual(appDelegate.jumpToOldestUnread()?.id, a.id)
        XCTAssertEqual(manager.selectedTabId, panes[0].workspaceId)
        XCTAssertEqual(isRead(a), true, "a visit reads the pane")
        XCTAssertEqual(isRead(b), false)

        XCTAssertEqual(appDelegate.jumpToOldestUnread()?.id, b.id)
        XCTAssertEqual(manager.selectedTabId, panes[1].workspaceId)
        XCTAssertEqual(appDelegate.jumpToOldestUnread()?.id, c.id)
        XCTAssertNil(appDelegate.jumpToOldestUnread(), "nothing unread: nothing happens")
    }

    // MARK: Scenario 157: ⌘⌃U sends the pane to the back (end to end)

    private func sendFocusedPaneToBack() -> TerminalNotification? {
        appDelegate.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread(
            preferredWindow: appDelegate.windowForMainWindowId(windowId)
        )
    }

    func testSendToBackVisitsTheOthersFirstAndTheSentPaneLast() throws {
        let (manager, panes) = try makePanes(3)
        let a = news(panes[0], queuedAt: 1), b = news(panes[1], queuedAt: 2), c = news(panes[2], queuedAt: 3)
        store.replaceNotificationsForTesting([c, b, a])

        XCTAssertEqual(appDelegate.jumpToOldestUnread()?.id, a.id) // the visit reads A; he is on A
        XCTAssertEqual(isRead(a), true)

        XCTAssertEqual(sendFocusedPaneToBack()?.id, b.id, "A goes to the back, unread; B opens")
        XCTAssertEqual(manager.selectedTabId, panes[1].workspaceId)
        XCTAssertEqual(isRead(a), false)

        XCTAssertEqual(appDelegate.jumpToOldestUnread()?.id, c.id)
        XCTAssertEqual(appDelegate.jumpToOldestUnread()?.id, a.id, "then the pane that was sent back")
    }

    func testSendToBackWithNothingElseUnreadLeavesHimOnThePaneStillUnread() throws {
        let (manager, panes) = try makePanes(1)
        let a = news(panes[0], queuedAt: 1, isRead: true)
        store.replaceNotificationsForTesting([a])

        XCTAssertNil(sendFocusedPaneToBack(), "nothing else opened")

        XCTAssertEqual(manager.selectedTabId, panes[0].workspaceId)
        XCTAssertEqual(isRead(a), false, "still unread: the walk never reads the pane just sent back")
    }

    private func workspaceLevel(_ pane: Pane, queuedAt: TimeInterval) -> TerminalNotification {
        TerminalNotification(
            id: UUID(), tabId: pane.workspaceId, surfaceId: nil, title: "ws", subtitle: "", body: "",
            createdAt: Date(timeIntervalSince1970: queuedAt), queuedAt: Date(timeIntervalSince1970: queuedAt), isRead: false
        )
    }

    // Review carry-over (b), and step-2 review finding 1: a workspace-level notification W in the sent-back
    // pane's workspace opens by focusing, and so reading, that pane. Send to Back sends W back with the pane,
    // so neither the follow-on press nor the next ⌘⇧U reaches it before the others.
    func testSendToBackDoesNotReadThePaneThroughAWorkspaceLevelNotification() throws {
        let (_, panes) = try makePanes(3)
        let a = news(panes[0], queuedAt: 1, isRead: true), b = news(panes[1], queuedAt: 3), c = news(panes[2], queuedAt: 4)
        let w = workspaceLevel(panes[0], queuedAt: 2)
        store.replaceNotificationsForTesting([c, b, w, a])

        XCTAssertEqual(sendFocusedPaneToBack()?.id, b.id, "A goes to the back; B, the next, opens")
        XCTAssertEqual(isRead(a), false, "opening W would have read the focused pane")
        XCTAssertEqual(isRead(w), false)

        XCTAssertEqual(appDelegate.jumpToOldestUnread()?.id, c.id, "the next ⌘⇧U: C, not W (W went back with A)")
        XCTAssertEqual(isRead(a), false, "A is still unread, behind C")
        XCTAssertEqual(isRead(w), false)

        XCTAssertNotNil(appDelegate.jumpToOldestUnread(), "then the pane that was sent back")
        XCTAssertEqual(isRead(a), true)
    }

    // Step-2 review finding 1, the worse-than-today case: A has no notification of its own, W is in its workspace.
    func testSendToBackOfAPaneWithNoNotificationOfItsOwnIsNotUndoneByAWorkspaceLevelNotification() throws {
        let (manager, panes) = try makePanes(4)
        let workspace = try XCTUnwrap(manager.tabs.first(where: { $0.id == panes[0].workspaceId }))
        let b = news(panes[1], queuedAt: 3), c = news(panes[2], queuedAt: 4), d = news(panes[3], queuedAt: 5)
        let w = workspaceLevel(panes[0], queuedAt: 2)
        store.replaceNotificationsForTesting([d, c, b, w])

        XCTAssertEqual(sendFocusedPaneToBack()?.id, b.id, "A is marked at the back; B opens")
        XCTAssertTrue(workspace.manualUnreadPanelIds.contains(panes[0].panelId), "the mark ⌘⌃U set")

        XCTAssertEqual(appDelegate.jumpToOldestUnread()?.id, c.id, "W went back with A: C opens, not W")
        XCTAssertEqual(appDelegate.jumpToOldestUnread()?.id, d.id)
        XCTAssertTrue(workspace.manualUnreadPanelIds.contains(panes[0].panelId), "the mark survives both presses")
        XCTAssertEqual(isRead(w), false)
    }

    // MARK: Scenario 158: the order survives a relaunch

    func testTheWalkOrderIsTheSameAfterTheNotificationsAreSavedAndRestored() throws {
        let (_, panes) = try makePanes(3)
        // Created in the reverse of the order they went unread: createdAt alone would walk C, B, A.
        let a = news(panes[0], queuedAt: 1, createdAt: 30), b = news(panes[1], queuedAt: 2, createdAt: 20)
        let c = news(panes[2], queuedAt: 3, createdAt: 10)
        store.replaceNotificationsForTesting([c, b, a])
        XCTAssertEqual(store.notifications.sorted { $0.queuedAt < $1.queuedAt }.map(\.id), [a.id, b.id, c.id])

        for n in [a, b, c] {
            let data = try JSONEncoder().encode(SessionNotificationSnapshot(notification: n))
            let restored = try JSONDecoder().decode(SessionNotificationSnapshot.self, from: data)
                .terminalNotification(tabId: n.tabId, surfaceId: n.surfaceId, panelId: n.panelId)
            store.restoreSessionNotifications([restored], forTabId: n.tabId)
        }

        XCTAssertEqual(store.notifications.count, 3)
        XCTAssertEqual(appDelegate.jumpToOldestUnread()?.id, a.id)
        XCTAssertEqual(appDelegate.jumpToOldestUnread()?.id, b.id)
        XCTAssertEqual(appDelegate.jumpToOldestUnread()?.id, c.id)
    }

    func testSendToBackThenARestartSummaryOlderThanTheNextPaneOpens() async throws {
        let (_, panes) = try makePanes(2)
        let a = news(panes[0], queuedAt: 100, isRead: true), b = news(panes[1], queuedAt: 300)
        store.replaceNotificationsForTesting([b, a])
        let summary = try await insertSummary(createdAt: 200)

        XCTAssertNil(sendFocusedPaneToBack())

        XCTAssertEqual(appDelegate.restartCommandSummaryStore.requestedFocusSummaryID, summary.id)
        XCTAssertEqual(isRead(b), false)
    }

    // MARK: Scenario 163: Mark as Unread puts it back where it was (end to end)

    func testANotificationMarkedUnreadAgainIsVisitedAtItsOldPlace() throws {
        let (_, panes) = try makePanes(3)
        let a = news(panes[0], queuedAt: 1), b = news(panes[1], queuedAt: 2)
        let c = news(panes[2], queuedAt: 0, createdAt: 500, isRead: true) // createdAt after the others': not its place
        store.replaceNotificationsForTesting([b, a, c])

        store.markUnread(id: c.id) // the popover's path

        XCTAssertEqual(appDelegate.jumpToOldestUnread()?.id, c.id)
        XCTAssertEqual(appDelegate.jumpToOldestUnread()?.id, a.id)
        XCTAssertEqual(appDelegate.jumpToOldestUnread()?.id, b.id)
    }

    // MARK: Scenario 156: a restart summary takes its place by its own time

    func testASummaryOlderThanTheNotificationsOpensFirst() async throws {
        let (manager, panes) = try makePanes(2)
        let n = news(panes[1], queuedAt: 200)
        store.replaceNotificationsForTesting([n])
        let summary = try await insertSummary(createdAt: 100)

        XCTAssertNil(appDelegate.jumpToOldestUnread(), "a summary opened, not a notification")

        XCTAssertEqual(appDelegate.restartCommandSummaryStore.requestedFocusSummaryID, summary.id)
        XCTAssertEqual(isRead(n), false)
        XCTAssertNotEqual(manager.selectedTabId, panes[1].workspaceId)
    }

    func testANotificationOlderThanTheSummaryOpensFirst() async throws {
        let (manager, panes) = try makePanes(2)
        let n = news(panes[1], queuedAt: 100)
        store.replaceNotificationsForTesting([n])
        let summary = try await insertSummary(createdAt: 200)

        XCTAssertEqual(appDelegate.jumpToOldestUnread()?.id, n.id)
        XCTAssertEqual(manager.selectedTabId, panes[1].workspaceId)
        XCTAssertNil(appDelegate.restartCommandSummaryStore.requestedFocusSummaryID)

        XCTAssertNil(appDelegate.jumpToOldestUnread())
        XCTAssertEqual(appDelegate.restartCommandSummaryStore.requestedFocusSummaryID, summary.id)
    }

    func testAfterSendingAPaneBackASummaryOlderThanTheNextPaneOpens() async throws {
        let (_, panes) = try makePanes(2)
        let a = news(panes[0], queuedAt: 100), b = news(panes[1], queuedAt: 300)
        store.replaceNotificationsForTesting([b, a])
        let summary = try await insertSummary(createdAt: 200)

        // ⌘⌃U's follow-on jump excludes the pane just sent back.
        XCTAssertNil(appDelegate.jumpToOldestUnread(excludingPane: .workspace(tabId: panes[0].workspaceId, surfaceId: panes[0].panelId)))

        XCTAssertEqual(appDelegate.restartCommandSummaryStore.requestedFocusSummaryID, summary.id)
        XCTAssertEqual(isRead(b), false, "today's terminal-only jump opened B here")
    }

    func testWithTwoUnreadSummariesTheOldestOpensFirst() async throws {
        let (_, panes) = try makePanes(2)
        let n = news(panes[1], queuedAt: 200)
        store.replaceNotificationsForTesting([n])
        let oldest = try await insertSummary(createdAt: 100)
        _ = try await insertSummary(createdAt: 400)

        XCTAssertNil(appDelegate.jumpToOldestUnread())

        XCTAssertEqual(
            appDelegate.restartCommandSummaryStore.requestedFocusSummaryID, oldest.id,
            "the summary that has waited longest, not the newest one"
        )
        XCTAssertEqual(isRead(n), false, "the notification is later than the oldest summary and earlier than the newest")
    }

    // MARK: Q6 (the lead): the summary is weighed against the stop after the pane he's on

    func testSummaryBetweenHisPaneAndTheNextPaneOpensAfterHisPaneIsRead() async throws {
        let (_, panes) = try makePanes(2)
        AppFocusState.overrideIsFocused = true
        let hisPane = news(panes[0], queuedAt: 100), next = news(panes[1], queuedAt: 300)
        store.replaceNotificationsForTesting([next, hisPane])
        let summary = try await insertSummary(createdAt: 200)

        XCTAssertNil(appDelegate.jumpToOldestUnread())

        XCTAssertEqual(isRead(hisPane), true, "the pane he's on was the next stop: read and passed")
        XCTAssertEqual(appDelegate.restartCommandSummaryStore.requestedFocusSummaryID, summary.id)
        XCTAssertEqual(isRead(next), false)
    }

    // MARK: Scenario 154 (app side): the pane he's on is read and passed

    func testThePaneHesOnIsReadAndTheNextPaneOpens() throws {
        let (manager, panes) = try makePanes(2)
        AppFocusState.overrideIsFocused = true
        XCTAssertEqual(manager.selectedTabId, panes[0].workspaceId)
        let hisPane = news(panes[0], queuedAt: 100), next = news(panes[1], queuedAt: 200)
        store.replaceNotificationsForTesting([next, hisPane])

        let opened = appDelegate.jumpToOldestUnread()

        let state = "opened=\(String(describing: opened?.id)) his=\(hisPane.id) next=\(next.id) read(his)=\(String(describing: isRead(hisPane))) read(next)=\(String(describing: isRead(next))) selected=\(String(describing: manager.selectedTabId)) ws0=\(panes[0].workspaceId) ws1=\(panes[1].workspaceId)"
        XCTAssertEqual(opened?.id, next.id, state)
        XCTAssertEqual(isRead(hisPane), true, state)
        XCTAssertEqual(manager.selectedTabId, panes[1].workspaceId, state)
    }

    func testWithNothingElseTheFocusedPaneIsReadAndHeStays() throws {
        let (manager, panes) = try makePanes(2)
        AppFocusState.overrideIsFocused = true
        let hisPane = news(panes[0], queuedAt: 100)
        store.replaceNotificationsForTesting([hisPane])

        XCTAssertEqual(appDelegate.jumpToOldestUnread()?.id, hisPane.id)

        XCTAssertEqual(isRead(hisPane), true)
        XCTAssertEqual(manager.selectedTabId, panes[0].workspaceId)
    }

    // MARK: Entrances (Scenario 159)

    func testTheSocketMethodTakesTheSameOrder() throws {
        let (_, panes) = try makePanes(2)
        let a = news(panes[0], queuedAt: 1), b = news(panes[1], queuedAt: 2)
        store.replaceNotificationsForTesting([b, a])

        XCTAssertEqual(TerminalController.shared.controlNotificationJumpToUnread()?.id, a.id)
        XCTAssertEqual(TerminalController.shared.controlNotificationJumpToUnread()?.id, b.id)
        XCTAssertNil(TerminalController.shared.controlNotificationJumpToUnread(), "{\"opened\": false}")
    }

    func testTheShortcutTakesTheSameOrder() throws {
#if DEBUG
        let (manager, panes) = try makePanes(2)
        let window = try XCTUnwrap(appDelegate.windowForMainWindowId(windowId))
        let a = news(panes[1], queuedAt: 1), b = news(panes[0], queuedAt: 2)
        store.replaceNotificationsForTesting([b, a])
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "u", charactersIgnoringModifiers: "u", isARepeat: false, keyCode: 32
        ))
        XCTAssertTrue(KeyboardShortcutSettings.shortcut(for: .jumpToUnread).matches(event: event))

        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event))

        XCTAssertEqual(manager.selectedTabId, panes[1].workspaceId, "the pane unread longest, not the newest")
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }
}
