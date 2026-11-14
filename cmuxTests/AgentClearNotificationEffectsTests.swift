import CMUXAgentLaunch
import CmuxAgentJournal
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// What a clear does to notifications and to a waiting Feed card (cm-128.2, Scenario 28): the notifications stay, read, and
/// the card stays usable, where every other resolve deletes the first and cancels the second.
@MainActor
@Suite("Clear Agent State notification effects", .serialized)
struct AgentClearNotificationEffectsTests {
    private func notification(_ harness: ClearAgentStateHarness, key: String, surface: UUID? = nil) -> TerminalNotification {
        TerminalNotification(id: UUID(), tabId: harness.workspace.id, surfaceId: surface ?? harness.panel,
            correlationKey: key, title: "Agent", subtitle: "", body: "Answer", createdAt: Date(), isRead: false)
    }

    /// Installs the shared store with no delivery side effects for the test's lifetime.
    private func withStore(_ harness: ClearAgentStateHarness, _ notifications: [TerminalNotification]) -> TerminalNotificationStore {
        let store = TerminalNotificationStore.shared
        store.replaceNotificationsForTesting(notifications)
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        harness.appDelegate.notificationStore = store
        return store
    }

    private func release(_ store: TerminalNotificationStore) {
        store.replaceNotificationsForTesting([])
        store.resetNotificationDeliveryHandlerForTesting()
    }

    // MARK: - Case A: no Feed decision

    @Test func aClearKeepsTheWaitsNotificationMarkedRead() async throws {
        try await ClearAgentStateHarness.run { cleared in
            let waiting = notification(cleared, key: "wait-clear")
            let store = withStore(cleared, [waiting])
            defer { release(store) }
            cleared.observe(.approvalRequested, correlationKey: "wait-clear")
            await cleared.settle()
            #expect(cleared.marks["claude_code"] == .needsInput)
            #expect(cleared.workspace.clearAgentState(journal: cleared.center, notifications: store))
            await cleared.settle()
            TerminalMutationBus.shared.drainForTesting()
            let kept = try #require(store.notifications.first { $0.id == waiting.id }, "the clear deleted the notification")
            #expect(kept.isRead)
            #expect(cleared.marks["claude_code"] == .unknown)
        }
    }

    /// Control for the test above: the same wait answered by a key press loses its notification.
    @Test func aKeyPressOnTheSameWaitDeletesItsNotification() async throws {
        try await ClearAgentStateHarness.run { keyed in
            let answered = notification(keyed, key: "wait-key")
            let store = withStore(keyed, [answered])
            defer { release(store) }
            keyed.observe(.approvalRequested, correlationKey: "wait-key")
            await keyed.settle()
            keyed.center.resolvePaneInput(workspaceId: keyed.workspace.id, surfaceId: keyed.panel, isEscape: false)
            await keyed.settle()
            TerminalMutationBus.shared.drainForTesting()
            #expect(store.notifications.first { $0.id == answered.id } == nil, "control: an answer removes its notification")
        }
    }

    // MARK: - Case B: a Feed decision is pending

    /// A pending Feed decision, raised the way the ingest path raises it (waiter registered, attention overlay surfaced,
    /// overlay attached to the waiter) but without the ingest: that needs the Feed's store and a blocked worker thread,
    /// which other suites' tests also install on the shared coordinator. The decision's own journal event (what the Feed
    /// forwards for a card) goes through the harness's journal, so a clear closes it there too.
    private func raiseNow(_ requestId: String, in harness: ClearAgentStateHarness) -> FeedWaiterRegistry.Registration? {
        let event = WorkstreamEvent(sessionId: "feed-session", hookEventName: .permissionRequest, source: "claude",
            workspaceId: harness.workspace.id.uuidString, surfaceId: harness.panel.uuidString, cwd: "/tmp",
            toolName: "Bash", toolInputJSON: #"{"command":"true"}"#, requestId: requestId)
        let feed = FeedCoordinator.shared
        guard let registered = feed.waiterRegistry.register(requestID: requestId, event: event),
              let target = feed.surfaceBlockingDecisionAttention(event: event,
                  resolved: (harness.workspace.id, harness.panel), tabManager: harness.tabManager),
              feed.waiterRegistry.setAttention(target, requestID: requestId) else { return nil }
        harness.observe(.approvalRequested, sessionId: "feed-session", request: requestId, correlationKey: requestId)
        return registered
    }

    private func raise(_ requestId: String, in harness: ClearAgentStateHarness) async -> FeedWaiterRegistry.Registration? {
        // Another suite's test can hold the process-wide `attentionSurfaceObserver`, which would receive this event and turn
        // the surfacing into a no-op. The check and the call below run in one main-actor job, so the observer cannot
        // appear between them; until it is clear, wait.
        for _ in 0..<250 {
            if FeedCoordinatorTestHooks.attentionSurfaceObserver == nil {
                return raiseNow(requestId, in: harness)
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    @Test(arguments: [true, false])
    func aClearDropsTheFeedHandButTheCardStaysUsableAndNoAnswerOrderLeavesAStaleOrMissingHand(
        answerClearedCardFirst: Bool
    ) async throws {
        try await ClearAgentStateHarness.run { harness in
            let idA = "feed-a-\(answerClearedCardFirst)-\(UUID().uuidString)"
            let idB = "feed-b-\(answerClearedCardFirst)-\(UUID().uuidString)"
            let pending = notification(harness, key: idA)
            let store = withStore(harness, [pending])
            defer { release(store) }
            let feed = FeedCoordinator.shared
            let slot = FeedCoordinator.attentionStatusKey(forSource: "claude")

            let first = try #require(await raise(idA, in: harness))
            await harness.settle()
            #expect(harness.marks[slot] == .needsInput, "the Feed never raised its hand")
            #expect(harness.workspace.statusEntries[slot] != nil)

            #expect(harness.workspace.clearAgentState(journal: harness.center, notifications: store))
            await harness.settle()
            #expect(harness.marks[slot] == nil, "the Feed's hand stayed")
            #expect(harness.workspace.statusEntries[slot] == nil, "the Feed's pill stayed")
            #expect(harness.state(fallback: .idle) == .unknown)
            #expect(feed.waiterRegistry.liveRequestIDs().contains(idA), "the clear cancelled the card")
            let kept = try #require(store.notifications.first { $0.id == pending.id })
            #expect(kept.isRead)

            // A newer decision on the same pane raises the hand again; the older card's answer must not take it down.
            let second = try #require(await raise(idB, in: harness))
            await harness.settle()
            #expect(harness.marks[slot] == .needsInput, "the newer decision raised no hand")
            @MainActor func answer(_ requestId: String, _ registration: FeedWaiterRegistry.Registration) {
                // deliverReply is synchronous on the main actor: route just this answer into the isolated journal,
                // then restore before yielding, so other suites keep their coordinator journal.
                let previousJournal = feed.notificationJournal
                feed.notificationJournal = harness.center
                defer { feed.notificationJournal = previousJournal }
                feed.deliverReply(requestId: requestId, decision: .permission(.once))
                let finished = feed.waiterRegistry.finish(registration)
                guard case .resolved = finished.outcome.result else {
                    Issue.record("\(requestId) did not return its decision to the hook: \(finished.outcome.result)")
                    return
                }
            }
            if answerClearedCardFirst {
                let beforeOldAnswer = harness.marks
                answer(idA, first)
                await harness.settle()
                #expect(harness.marks == beforeOldAnswer, "answering the cleared card changed the journal projection")
                #expect(harness.marks[slot] == .needsInput, "an answer to the cleared card took down the newer decision's hand")
                answer(idB, second)
                await harness.settle()
                #expect(harness.marks["claude_code"] == .running,
                    "positive control: answering B must resolve its wait in the harness journal")
            } else {
                answer(idB, second)
                await harness.settle()
                #expect(harness.marks["claude_code"] == .running,
                    "positive control: answering B must resolve its wait in the harness journal")
                #expect(harness.marks[slot] == nil, "the cleared card's overlay kept the newer decision's hand up")
                let beforeOldAnswer = harness.marks
                answer(idA, first)
                await harness.settle()
                #expect(harness.marks == beforeOldAnswer, "answering the cleared card changed the journal projection")
            }
            #expect(harness.marks[slot] == nil)
        }
    }

    @Test func anOldTimeoutQueuedBeforeTheClearCannotConcludeANewerRequestsAttention() async throws {
        try await queuedCleanupCannotConcludeNewAttention(timeout: true)
    }

    @Test func anOldInvalidationQueuedBeforeTheClearCannotConcludeANewerRequestsAttention() async throws {
        try await queuedCleanupCannotConcludeNewAttention(timeout: false)
    }

    private func queuedCleanupCannotConcludeNewAttention(timeout: Bool) async throws {
        try await ClearAgentStateHarness.run { harness in
            let feed = FeedCoordinator.shared
            let idA = "queued-cleanup-a-\(UUID().uuidString)"
            let idB = "queued-cleanup-b-\(UUID().uuidString)"
            let first = try #require(await raise(idA, in: harness))
            defer { _ = feed.waiterRegistry.finish(first) }
            await harness.settle()
            let queued = DispatchSemaphore(value: 0)
            if timeout {
                // Join the already-surfaced request, so this exercises the real timeout path without installing a store.
                let event = WorkstreamEvent(sessionId: "feed-session", hookEventName: .permissionRequest, source: "claude",
                    workspaceId: harness.workspace.id.uuidString, surfaceId: harness.panel.uuidString, cwd: "/tmp",
                    toolName: "Bash", toolInputJSON: #"{"command":"true"}"#, requestId: idA)
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = feed.ingestBlocking(event: event, waitTimeout: 1)
                    if case .timedOut = result {} else { Issue.record("expected timeout, got \(result)") }
                    queued.signal()
                }
                let deadline = Date().addingTimeInterval(0.5)
                while feed.waiterRegistry.subscriberCount(idA) != 2 && Date() < deadline {
                    _ = DispatchSemaphore(value: 0).wait(timeout: .now() + 0.001)
                }
                try #require(feed.waiterRegistry.subscriberCount(idA) == 2, "the timeout worker never joined A")
                #expect(!feed.waiterRegistry.finish(first).shouldCancel, "the worker must own the last subscription")
            } else {
                DispatchQueue.global(qos: .userInitiated).async {
                    feed.invalidateSemanticRequest(requestId: idA, source: "claude", sessionId: "feed-session")
                    queued.signal()
                }
            }
            // Do not yield until cleanup is queued. Clear and reuse its slot before the queued main-actor mutation runs.
            try #require(queued.wait(timeout: .now() + 5) == .success)
            #expect(harness.workspace.clearAgentState(journal: harness.center))
            try #require(FeedCoordinatorTestHooks.attentionSurfaceObserver == nil)
            let second = try #require(raiseNow(idB, in: harness))
            defer {
                feed.invalidateSemanticRequest(requestId: idB, source: "claude", sessionId: "feed-session")
                _ = feed.waiterRegistry.finish(second)
            }
            let slot = FeedCoordinator.attentionStatusKey(forSource: "claude")
            #expect(harness.marks[slot] == .needsInput)
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            #expect(harness.marks[slot] == .needsInput,
                "the old request's queued cleanup removed the newer request's hand")
            #expect(!feed.waiterRegistry.liveRequestIDs().contains(idA))
            await harness.settle()
        }
    }

    @Test func anOldReplyQueuedBeforeTheClearCannotConcludeANewerRequestsAttention() async throws {
        try await ClearAgentStateHarness.run { harness in
            let feed = FeedCoordinator.shared
            // The queued resolve reads this journal on main. Keep both replies in this gate-held fixture's temporary
            // journal, including B's deferred cleanup, and restore the coordinator before releasing the fixture.
            let previousJournal = feed.notificationJournal
            feed.notificationJournal = harness.center
            defer { feed.notificationJournal = previousJournal }
            let idA = "queued-a-\(UUID().uuidString)"
            let idB = "queued-b-\(UUID().uuidString)"
            let first = try #require(await raise(idA, in: harness))
            defer { _ = feed.waiterRegistry.finish(first) }
            await harness.settle()
            for _ in 0..<250 {
                if FeedCoordinatorTestHooks.attentionSurfaceObserver == nil { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            try #require(FeedCoordinatorTestHooks.attentionSurfaceObserver == nil)
            // Hold this main-actor job until the worker has queued its reply, then clear and raise B before any hop runs.
            let queued = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                feed.deliverReply(requestId: idA, decision: .permission(.once))
                queued.signal()
            }
            try #require(queued.wait(timeout: .now() + 5) == .success)
            #expect(harness.workspace.clearAgentState(journal: harness.center))
            let second = try #require(raiseNow(idB, in: harness))
            defer {
                feed.deliverReply(requestId: idB, decision: .permission(.once))
                _ = feed.waiterRegistry.finish(second)
            }
            let slot = FeedCoordinator.attentionStatusKey(forSource: "claude")
            #expect(harness.marks[slot] == .needsInput)
            // Main-queue FIFO drains the already-queued reply before the barrier continuation resumes.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            #expect(harness.marks[slot] == .needsInput,
                "the old card's queued conclusion removed the newer request's hand")
            await harness.settle()
        }
    }

    // MARK: - Case C: his own unread marks

    @Test func aClearLeavesTheManualWorkspaceMarkHeMadeOnAWorkspaceWithAHand() async throws {
        try await ClearAgentStateHarness.run { harness in
            let store = withStore(harness, [])
            defer { release(store) }
            harness.workspace.setAgentLifecycle(key: "claude_code", panelId: harness.panel, lifecycle: .needsInput)
            store.markUnread(forTabId: harness.workspace.id)
            #expect(store.workspaceIsUnread(forTabId: harness.workspace.id))
            #expect(harness.workspace.clearAgentState(journal: harness.center, notifications: store))
            #expect(harness.marks["claude_code"] == .unknown)
            #expect(store.hasManualUnread(forTabId: harness.workspace.id), "the clear dropped his unread mark")
            #expect(store.workspaceIsUnread(forTabId: harness.workspace.id))
        }
    }

    @Test func aClearMarksAScriptsNotificationReadAndLeavesHisPaneMarkOnAnotherPane() async throws {
        try await ClearAgentStateHarness.run { harness in
            let otherPane = UUID()
            let scripted = notification(harness, key: "cmux-notify")
            let store = withStore(harness, [scripted])
            defer { release(store) }
            store.markUnread(forTabId: harness.workspace.id, surfaceId: otherPane)
            #expect(store.hasManualUnread(forTabId: harness.workspace.id, surfaceId: otherPane))
            harness.workspace.setAgentLifecycle(key: "claude_code", panelId: harness.panel, lifecycle: .running)
            #expect(harness.workspace.clearAgentState(journal: harness.center, notifications: store))
            let kept = try #require(store.notifications.first { $0.id == scripted.id }, "the clear deleted a notification")
            #expect(kept.isRead, "every notification on the workspace goes read, a script's included")
            #expect(store.hasManualUnread(forTabId: harness.workspace.id, surfaceId: otherPane), "the clear dropped his pane mark")
        }
    }
}
