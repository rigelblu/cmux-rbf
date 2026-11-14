import AppKit
@testable import CmuxNotifications
@testable import CmuxAgentJournal
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct AgentUnattendedNudgeDeliveryTests {
    @Test func recordHandoffPostsOnceUnderTheOriginalIDWithoutRecording() async throws {
        try await withFixture { fixture, clock, probe in
            try await enqueue(fixture, sourceTitle: "Pi · fix login bug", agent: "pi")
            let original = try #require(fixture.store.notifications.first)
            let before = fixture.store.notifications
            await fixture.store.notificationFeedHistory.loadingTask?.value
            let history = fixture.store.notificationFeedHistory.snapshot
            let journal = try await journalStorageSnapshot()
            #expect(fixture.source.agentHibernationLifecycleState(panelId: fixture.panelId, fallback: .unknown) == .unknown)
            let order = fixture.manager.tabs.map(\.id)
            await expectArmed(clock)
            clock.advance(by: .seconds(59))
            await spin { false }
            #expect(probe.delivered.count == 1)
            clock.advance(by: .seconds(1))
            await spin { probe.delivered.count == 2 }
            #expect(probe.delivered.count == 2)
            let nudge = try #require(probe.delivered.last)
            #expect(!nudge.effects.record)
            #expect(nudge.notification.id == original.id)
            #expect(nudge.notification.title == "Pi · fix login bug · Finished 1 min ago, still unread")
            #expect(nudge.notification.subtitle == original.subtitle)
            #expect(nudge.notification.body == original.body)
            #expect(nudge.notification.replyShape == original.replyShape)
            #expect(nudge.notification.clickAction == original.clickAction)
            #expect(nudge.notification.soundContext?.alertType == .turnDone)
            #expect(!nudge.effects.markUnread && !nudge.effects.reorderWorkspace)
            #expect(!nudge.effects.command && !nudge.effects.paneFlash)
            #expect(nudge.effects.desktop && nudge.effects.sound)
            #expect(fixture.store.notifications == before)
            #expect(fixture.store.notificationFeedHistory.snapshot == history)
            #expect(try await journalStorageSnapshot() == journal, "The nudge writes neither events nor receipts")
            #expect(fixture.source.agentHibernationLifecycleState(panelId: fixture.panelId, fallback: .unknown) == .unknown)
            #expect(fixture.manager.tabs.map(\.id) == order)
            #expect(probe.forwarded == [original.id], "A nudge must not forward to the phone")
            clock.advance(by: .seconds(120))
            await spin { false }
            #expect(probe.delivered.count == 2)
            fixture.store.markRead(id: original.id)
            #expect(fixture.store.notifications.first?.title == original.title)
            #expect(fixture.store.notifications.first?.createdAt == original.createdAt)
        }
    }

    @Test(arguments: [false, true])
    func focusedPaneUsesPresenceAndAwayBypassesSuppressedFeedback(_ present: Bool) async throws {
        try await withFixture(present: present) { fixture, clock, probe in
            AppFocusState.overrideIsFocused = true
            try await enqueue(fixture)
            let original = try #require(fixture.store.notifications.first)
            #expect(!original.isRead)
            #expect(probe.suppressed.count == 1)
            #expect(probe.delivered.isEmpty)
            await expectArmed(clock)
            clock.advance(by: .seconds(60))
            await spin { !probe.delivered.isEmpty }
            #expect(probe.delivered.count == (present ? 0 : 1))
            #expect(probe.suppressed.count == 1, "Away must use the banner handler, never suppressed feedback")
            #expect(fixture.store.notifications == [original])
        }
    }

    @Test func aRealDeferredSelectionReadCancelsTheNudge() async throws {
        try await withFixture { fixture, clock, probe in
            fixture.manager.selectedTabId = fixture.destination.id
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            AppFocusState.overrideIsFocused = true
            fixture.manager.selectedTabId = fixture.source.id
            // Drain notification delivery synchronously before the selected
            // workspace's already-queued focus/dismissal completion executes.
            #expect(AgentNotificationDelivery().enqueue(workspaceID: fixture.source.id, surfaceID: fixture.panelId,
                title: "Claude Code · Finished", subtitle: "cm-128", body: "Result",
                category: .turnComplete, pending: false, sourceTitle: "Claude Code"))
            TerminalMutationBus.shared.drainForTesting()
            let original = try #require(fixture.store.notifications.first)
            #expect(!original.isRead)
            await spin { fixture.store.notifications.first?.isRead == true }
            #expect(fixture.store.notifications.first?.isRead == true)
            clock.advance(by: .seconds(60))
            await spin { clock.sleeperCount == 0 }
            #expect(probe.delivered.isEmpty)
            #expect(probe.suppressed.count == 1)
        }
    }

    @Test(arguments: ["read", "clear", "setting-off"])
    func readRemovalAndSettingOffCancelThePendingNudge(_ reason: String) async throws {
        try await withFixture { fixture, clock, probe in
            try await enqueue(fixture)
            let original = try #require(fixture.store.notifications.first)
            await expectArmed(clock)
            clock.advance(by: .seconds(30))
            switch reason {
            case "read": fixture.store.markRead(id: original.id)
            case "clear": fixture.store.clearAll()
            default:
                UserDefaults.standard.set(false, forKey: "notificationAgentIdleReminderEnabled")
            }
            await spin { clock.sleeperCount == 0 }
            #expect(clock.sleeperCount == 0, "Cancellation must release the pending timer before its deadline")
            if reason == "setting-off" {
                UserDefaults.standard.set(true, forKey: "notificationAgentIdleReminderEnabled")
            }
            clock.advance(by: .seconds(60))
            await spin { false }
            #expect(probe.delivered.count == 1)
        }
    }

    @Test(arguments: ["pending", "prompt-turn", "setting-off"], ["claude", "codex"])
    func pendingWorkPromptTurnAndDisabledSettingDoNotArm(_ reason: String, _ agent: String) async throws {
        try await withFixture { fixture, clock, probe in
            if reason == "setting-off" { UserDefaults.standard.set(false, forKey: "notificationAgentIdleReminderEnabled") }
            try await enqueue(fixture, pending: reason == "pending", prompt: reason == "prompt-turn",
                sourceTitle: agent == "claude" ? "Claude Code" : "Codex", agent: agent)
            #expect(fixture.store.notifications.count == 1, "Turn mode always still records a pending completion")
            await spin { false }
            #expect(clock.sleeperCount == 0)
            clock.advance(by: .seconds(60))
            await spin { false }
            #expect(probe.delivered.count == 1)
        }
    }

    @Test func aNewJournalTurnCancelsTheRecordedCompletionsNudge() async throws {
        try await withFixture { fixture, clock, probe in
            fixture.source.surfaceResumeBindingsByPanelId[fixture.panelId] = SurfaceResumeBindingSnapshot(
                kind: "claude", command: "claude --resume session", checkpointId: "session", source: "agent-hook")
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("c128-new-turn-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let center = AgentJournalLifecycleCenter(databaseURL: root.appendingPathComponent("journal.sqlite"))
            @MainActor func draft(_ kind: AgentJournalEventKind, at time: Int64) -> AgentJournalEventDraft {
                AgentJournalEventDraft(kind: kind, occurredAtMs: time, source: "claude", agentKey: "claude_code",
                    sessionId: "session", workspaceId: fixture.source.id.uuidString, surfaceId: fixture.panelId.uuidString,
                    declaredPhase: kind == .stateChanged ? .idle : nil,
                    attention: AgentAttentionContext(turnIdentity: kind == .turnStarted ? "turn-\(time)" : nil,
                        notification: kind == .turnCompleted
                            ? .init(title: "Claude Code · Finished", subtitle: "cm-128", body: "Result",
                                category: "turn-complete", sourceTitle: "Claude Code") : nil))
            }
            _ = await center.admitNotification(draft(.turnStarted, at: 1))
            center.observe(draft(.turnCompleted, at: 2))
            await AgentNotificationRegressionTests().waitForNotification(in: fixture.store)
            let original = try #require(fixture.store.notifications.first)
            await expectArmed(clock)
            clock.advance(by: .seconds(40))
            center.observe(draft(.turnStarted, at: 3))
            _ = await center.admitNotification(draft(.stateChanged, at: 4)) // FIFO worker barrier.
            TerminalMutationBus.shared.drainForTesting()
            await spin { clock.sleeperCount == 0 }
            #expect(clock.sleeperCount == 0, "A new journal turn must cancel the recorded completion's timer")
            #expect(!fixture.store.notifications.contains { $0.id == original.id && !$0.isRead })
            clock.advance(by: .seconds(60))
            await spin { false }
            #expect(probe.delivered.count == 1, "A working pane must receive no still-unread nudge")
        }
    }

    @Test func claudesOwnIdlePromptDoesNotMoveOrRepeatTheRecordedTurnsNudge() async throws {
        try await withFixture { fixture, clock, probe in
            fixture.source.surfaceResumeBindingsByPanelId[fixture.panelId] = SurfaceResumeBindingSnapshot(
                kind: "claude", command: "claude --resume session", checkpointId: "session", source: "agent-hook")
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("c128-idle-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let center = AgentJournalLifecycleCenter(databaseURL: root.appendingPathComponent("journal.sqlite"))
            @MainActor func draft(_ kind: AgentJournalEventKind, at time: Int64) -> AgentJournalEventDraft {
                let notification: AgentJournalNotification? = kind == .turnCompleted || kind == .idleObserved
                    ? .init(title: "Claude Code · Finished", subtitle: "cm-128", body: "Result",
                        category: kind == .turnCompleted ? "turn-complete" : "idle-reminder", sourceTitle: "Claude Code") : nil
                return AgentJournalEventDraft(kind: kind, occurredAtMs: time, source: "claude", agentKey: "claude_code",
                    sessionId: "session", workspaceId: fixture.source.id.uuidString, surfaceId: fixture.panelId.uuidString,
                    declaredPhase: kind == .stateChanged ? .idle : nil,
                    attention: AgentAttentionContext(turnIdentity: kind == .turnStarted ? "turn" : nil,
                        notification: notification))
            }
            _ = await center.admitNotification(draft(.turnStarted, at: 1))
            center.observe(draft(.turnCompleted, at: 2))
            await AgentNotificationRegressionTests().waitForNotification(in: fixture.store)
            let original = try #require(fixture.store.notifications.first)
            await expectArmed(clock)
            clock.advance(by: .seconds(30))
            center.observe(draft(.idleObserved, at: 3))
            _ = await center.admitNotification(draft(.stateChanged, at: 4)) // FIFO worker barrier.
            TerminalMutationBus.shared.drainForTesting()
            #expect(fixture.store.notifications == [original], "The native idle prompt spends no second receipt/effect")
            #expect(probe.delivered.count == 1)
            clock.advance(by: .seconds(29))
            await spin { false }
            #expect(probe.delivered.count == 1)
            clock.advance(by: .seconds(1))
            await spin { probe.delivered.count == 2 }
            #expect(probe.delivered.count == 2, "The native idle prompt must not reset the original 60-second deadline")
            center.observe(draft(.idleObserved, at: 5))
            _ = await center.admitNotification(draft(.stateChanged, at: 6))
            TerminalMutationBus.shared.drainForTesting()
            #expect(fixture.store.notifications == [original])
            #expect(probe.delivered.count == 2, "An idle prompt after the nudge must not repeat its effects")
        }
    }

    @Test(arguments: [false, true])
    func nativeDeliveryRemovesOnlyTheNudgesDeliveredOriginalBeforeScheduling(_ isNudge: Bool) async throws {
        try await withFixture { fixture, clock, _ in
            let center = AgentNudgeCallingCenter()
            let service = UserNotificationCenterService(center: center, timeout: .seconds(2), sleep: {
                try await ContinuousClock().sleep(for: $0)
            })
            let store = TerminalNotificationStore.makeForTesting(userNotificationCenter: service)
            store.configurePhoneForwardingForTesting(enabled: { false }, forward: { _, _ in })
            store.unattendedNudges = AgentUnattendedNudgeDelivery(store: store, clock: clock, isPresent: { false })
            store.configureNativeNotificationDeliveryHooksForTesting { hooks in
                hooks.authorizationHandlerForTesting = { completion in
                    Task { @MainActor in completion(true, .authorized) }
                }
                hooks.commandRunner = { _, _, _, _ in }
                hooks.unavailableFeedbackPlayer = { _, _ in }
            }
            if isNudge { store.configureNotificationDeliveryHandlerForTesting { _, _, _ in } }
            defer {
                center.releaseAdd(fails: false)
                store.clearAll()
            }
            let id = try #require(store.addNotification(tabId: fixture.source.id, surfaceId: fixture.panelId,
                title: "Claude Code · Finished", subtitle: "cm-128", body: "Result",
                unattendedNudgeTitle: "Claude Code · Finished 1 min ago, still unread"))
            let before = store.notifications
            if isNudge {
                center.seedDelivered(id.uuidString)
                await expectArmed(clock)
                store.resetNotificationDeliveryHandlerForTesting()
                clock.advance(by: .seconds(60))
            }
            await spin { center.hasHeldAdd }
            #expect(center.hasHeldAdd)
            let requestID = isNudge ? "\(id.uuidString).reminder" : id.uuidString
            #expect(center.addedIDs == [requestID])
            #expect(center.addedNotificationIDs == [id.uuidString], "A reminder click must still target the original record")
            let expected = isNudge
                ? ["removeDelivered:\(id.uuidString)", "add:\(requestID)"]
                : ["add:\(requestID)"]
            #expect(center.deliveryEvents == expected,
                "Only the nudge removes the delivered original, then schedules its derived reminder id")
            #expect(store.notifications == before, "Re-alerting must leave the original store record unchanged")
        }
    }

    @Test func readingTheOriginalRemovesBothNativeIdentifiers() async throws {
        try await withFixture { fixture, _, _ in
            let center = AgentNudgeCallingCenter()
            let service = UserNotificationCenterService(center: center, timeout: .seconds(2), sleep: {
                try await ContinuousClock().sleep(for: $0)
            })
            let store = TerminalNotificationStore.makeForTesting(userNotificationCenter: service)
            store.configureNotificationDeliveryHandlerForTesting { _, _, _ in }
            defer { store.clearAll() }
            let id = try #require(store.addNotification(tabId: fixture.source.id, surfaceId: fixture.panelId,
                title: "Claude Code · Finished", subtitle: "cm-128", body: "Result"))
            let identifiers = [id.uuidString, "\(id.uuidString).reminder"]
            for identifier in identifiers { center.seedDelivered(identifier) }
            store.markRead(id: id)
            await spin { center.removalCount >= 2 }
            for identifier in identifiers {
                #expect(center.deliveryEvents.contains("removeDelivered:\(identifier)"))
                #expect(center.deliveryEvents.contains("removePending:\(identifier)"))
            }
            #expect(center.survivingIDs.isEmpty)
            #expect(store.notifications.first?.isRead == true)
        }
    }

    @Test func readingWhileAuthorizationIsHeldAdmitsNoLateStillUnreadBanner() async throws {
        try await withFixture { fixture, clock, probe in
            try await enqueue(fixture)
            let original = try #require(fixture.store.notifications.first)
            await expectArmed(clock)
            let authorization = probe.authorization
            let nativeIDs = probe.nativeRequestIDs
            fixture.store.configureNativeNotificationDeliveryHooksForTesting { hooks in
                hooks.authorizationHandlerForTesting = { completion in authorization.withLock { $0 = completion } }
                hooks.scheduler = { request, completion in
                    nativeIDs.withLock { $0.append(request.identifier) }
                    completion(nil)
                }
            }
            fixture.store.resetNotificationDeliveryHandlerForTesting()
            clock.advance(by: .seconds(60))
            await spin { authorization.withLock { $0 != nil } }
            #expect(authorization.withLock { $0 != nil })
            fixture.store.markRead(id: original.id)
            let completion = authorization.withLock { value in
                defer { value = nil }
                return value
            }
            completion?(true, .authorized)
            await spin { false }
            #expect(nativeIDs.withLock { $0.isEmpty })
            #expect(fixture.store.notifications.first?.isRead == true)
        }
    }

    @Test(arguments: [false, true])
    func readDuringNativeAddRemovesTheReminderAfterItsLateCompletion(_ fails: Bool) async throws {
        try await withFixture { fixture, clock, _ in
            let center = AgentNudgeCallingCenter()
            let service = UserNotificationCenterService(center: center, timeout: .seconds(2), sleep: {
                try await ContinuousClock().sleep(for: $0)
            })
            let store = TerminalNotificationStore.makeForTesting(userNotificationCenter: service)
            store.configurePhoneForwardingForTesting(enabled: { false }, forward: { _, _ in })
            store.unattendedNudges = AgentUnattendedNudgeDelivery(store: store, clock: clock, isPresent: { false })
            store.configureNotificationDeliveryHandlerForTesting { _, _, _ in }
            defer { store.clearAll() }
            let id = try #require(store.addNotification(tabId: fixture.source.id, surfaceId: fixture.panelId,
                title: "Claude Code · Finished", subtitle: "cm-128", body: "Result",
                unattendedNudgeTitle: "Claude Code · Finished 1 min ago, still unread"))
            await expectArmed(clock)
            let forbiddenFeedback = center.forbiddenFeedback
            store.configureNativeNotificationDeliveryHooksForTesting { hooks in
                hooks.authorizationHandlerForTesting = { completion in
                    Task { @MainActor in completion(true, .authorized) }
                }
                hooks.commandRunner = { _, _, _, _ in forbiddenFeedback.withLock { $0 += 1 } }
                hooks.unavailableFeedbackPlayer = { _, _ in forbiddenFeedback.withLock { $0 += 1 } }
            }
            store.resetNotificationDeliveryHandlerForTesting()
            clock.advance(by: .seconds(60))
            await spin { center.hasHeldAdd }
            #expect(center.hasHeldAdd)
            #expect(center.addedIDs == ["\(id.uuidString).reminder"])
            store.markRead(id: id)
            await spin { center.removalCount >= 2 }
            let removalsBeforeRelease = center.removalCount
            #expect(removalsBeforeRelease >= 2)
            center.releaseAdd(fails: fails)
            await spin { center.removalCount >= removalsBeforeRelease + 2 }
            #expect(center.removalCount >= removalsBeforeRelease + 2,
                "Late native completion must remove delivered and pending requests again")
            #expect(center.survivingIDs.isEmpty)
            let lateEvents = Array(center.deliveryEvents.suffix(4))
            #expect(lateEvents.contains("removeDelivered:\(id.uuidString).reminder"))
            #expect(lateEvents.contains("removePending:\(id.uuidString).reminder"))
            #expect(forbiddenFeedback.withLock { $0 == 0 })
            #expect(store.notifications.first?.isRead == true)
        }
    }

    @Test(arguments: ["sound", "desktop"])
    func admittedHookEffectsAreKeptAndTheHookDoesNotRunAgain(_ disabled: String) async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("c128-nudge-hook-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let command = "printf x >> '\(marker.path)'; sed 's/\"\(disabled)\":[[:space:]]*true/\"\(disabled)\":false/g'"
        try await withFixture(policyHookCommand: command) { fixture, clock, probe in
            try await enqueue(fixture)
            let original = try #require(fixture.store.notifications.first)
            #expect(try String(contentsOf: marker, encoding: .utf8) == "x")
            await expectArmed(clock)
            clock.advance(by: .seconds(60))
            await spin { probe.delivered.count == 2 }
            let nudge = try #require(probe.delivered.last)
            #expect(!nudge.effects.record)
            #expect(nudge.effects.sound == (disabled != "sound"))
            #expect(nudge.effects.desktop == (disabled != "desktop"))
            #expect(!nudge.effects.command && !nudge.effects.paneFlash && !nudge.effects.reorderWorkspace)
            #expect(try String(contentsOf: marker, encoding: .utf8) == "x")
            #expect(fixture.store.notifications == [original])
            #expect(probe.forwarded == [original.id])
        }
    }

    @Test func theSixtySecondsStartAtTheRecordAfterAnAsyncPolicyHook() async throws {
        let release = FileManager.default.temporaryDirectory.appendingPathComponent("c128-nudge-release-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: release) }
        let command = "while [ ! -f '\(release.path)' ]; do sleep 0.01; done; cat"
        try await withFixture(policyHookCommand: command) { fixture, clock, probe in
            #expect(AgentNotificationDelivery().enqueue(workspaceID: fixture.source.id, surfaceID: fixture.panelId,
                title: "Claude Code · Finished", subtitle: "cm-128", body: "Result",
                category: .turnComplete, pending: false, agentKind: "claude", sourceTitle: "Claude Code"))
            TerminalMutationBus.shared.drainForTesting()
            #expect(fixture.store.notifications.isEmpty)
            clock.advance(by: .seconds(50))
            try Data().write(to: release)
            await AgentNotificationRegressionTests().waitForNotification(in: fixture.store)
            await expectArmed(clock)
            clock.advance(by: .seconds(10))
            await spin { false }
            #expect(probe.delivered.count == 1)
            clock.advance(by: .seconds(50))
            await spin { probe.delivered.count == 2 }
            #expect(probe.delivered.count == 2)
        }
    }

    @Test(arguments: ["claude", "pi"])
    func unreadErrorReportedGetsOneNudgeUnderDerivedIDWithOriginalBodyAndErrorSound(_ agent: String) async throws {
        try await withFixture { fixture, clock, probe in
            let sourceTitle = agent == "pi" ? "Pi · fix login bug" : "Claude Code"
            let agentKey = agent == "pi" ? "pi" : "claude_code"
            fixture.source.surfaceResumeBindingsByPanelId[fixture.panelId] = SurfaceResumeBindingSnapshot(
                kind: agent, command: "\(agent) --resume session", checkpointId: "session", source: "agent-hook")
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("c128-error-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let center = AgentJournalLifecycleCenter(databaseURL: root.appendingPathComponent("journal.sqlite"))
            let draft = AgentJournalEventDraft(kind: .errorReported, occurredAtMs: 1, source: agent, agentKey: agentKey,
                sessionId: "session", workspaceId: fixture.source.id.uuidString, surfaceId: fixture.panelId.uuidString,
                attention: AgentAttentionContext(turnIdentity: "turn-1",
                    notification: AgentJournalNotification(
                        title: "\(sourceTitle) · Stopped on an error",
                        subtitle: "cm-128",
                        body: "Rate limit reached",
                        category: "other",
                        sourceTitle: sourceTitle)))
            center.observe(draft)
            TerminalMutationBus.shared.drainForTesting()
            await AgentNotificationRegressionTests().waitForNotification(in: fixture.store)
            let original = try #require(fixture.store.notifications.first)
            let beforeCount = fixture.store.notifications.count

            await expectArmed(clock)
            clock.advance(by: .seconds(59))
            await spin { false }
            #expect(probe.delivered.count == 1)

            clock.advance(by: .seconds(1))
            await spin { probe.delivered.count == 2 }
            #expect(probe.delivered.count == 2)
            let nudge = try #require(probe.delivered.last)
            #expect(nudge.notification.id == original.id)
            let expectedTitle = agent == "pi"
                ? "Pi · fix login bug · Stopped on an error 1 min ago, still unread"
                : "Claude Code · Stopped on an error 1 min ago, still unread"
            #expect(nudge.notification.title == expectedTitle)
            #expect(nudge.notification.subtitle == original.subtitle)
            #expect(nudge.notification.body == original.body)
            #expect(nudge.notification.soundContext?.alertType == .errorStalled)
            #expect(!nudge.effects.record && !nudge.effects.markUnread && !nudge.effects.reorderWorkspace)
            #expect(!nudge.effects.command && !nudge.effects.paneFlash)
            #expect(nudge.effects.desktop && nudge.effects.sound)
            #expect(fixture.store.notifications.count == beforeCount, "Nudge must not add a record to the store")

            fixture.store.markRead(id: original.id)
            #expect(fixture.store.notifications.first?.isRead == true)
        }
    }

    /// Scenario 82, cases 1 and 2: the error nudge is its own native request, derived from the original's id, and it
    /// still targets the original record; a read removes the banners of both ids.
    @Test func unreadErrorNudgeUsesTheDerivedNativeRequestAndAReadRemovesBothBanners() async throws {
        try await withFixture { fixture, clock, _ in
            let center = AgentNudgeCallingCenter()
            let service = UserNotificationCenterService(center: center, timeout: .seconds(2), sleep: {
                try await ContinuousClock().sleep(for: $0)
            })
            let store = TerminalNotificationStore.makeForTesting(userNotificationCenter: service)
            store.configurePhoneForwardingForTesting(enabled: { false }, forward: { _, _ in })
            store.unattendedNudges = AgentUnattendedNudgeDelivery(store: store, clock: clock, isPresent: { false })
            store.configureNativeNotificationDeliveryHooksForTesting { hooks in
                hooks.authorizationHandlerForTesting = { completion in
                    Task { @MainActor in completion(true, .authorized) }
                }
                hooks.commandRunner = { _, _, _, _ in }
                hooks.unavailableFeedbackPlayer = { _, _ in }
            }
            store.configureNotificationDeliveryHandlerForTesting { _, _, _ in }
            defer {
                center.releaseAdd(fails: false)
                store.clearAll()
            }
            fixture.source.setAgentLifecycle(key: "claude_code", panelId: fixture.panelId, lifecycle: .error)
            let id = try #require(store.addNotification(tabId: fixture.source.id, surfaceId: fixture.panelId,
                title: "Claude Code · Stopped on an error", subtitle: "cm-128", body: "Rate limit reached",
                unattendedNudgeTitle: "Claude Code · Stopped on an error 1 min ago, still unread",
                unattendedNudgeKind: .error, unattendedNudgeAgentKey: "claude_code"))
            let before = store.notifications
            center.seedDelivered(id.uuidString)
            await expectArmed(clock)
            store.resetNotificationDeliveryHandlerForTesting()
            clock.advance(by: .seconds(60))
            await spin { center.hasHeldAdd }
            #expect(center.hasHeldAdd, "the error nudge never reached the native center")
            #expect(center.addedIDs == ["\(id.uuidString).reminder"], "request ids \(center.addedIDs)")
            #expect(center.addedNotificationIDs == [id.uuidString], "A reminder click must still target the original record")
            #expect(store.notifications == before, "The nudge must not add or change a record")
            center.releaseAdd(fails: false)
            store.markRead(id: id)
            await spin { center.removalCount >= 2 }
            for identifier in [id.uuidString, "\(id.uuidString).reminder"] {
                #expect(center.deliveryEvents.contains("removeDelivered:\(identifier)"), "events \(center.deliveryEvents)")
            }
            #expect(center.survivingIDs.isEmpty, "banners left after a read: \(center.survivingIDs)")
        }
    }

    /// F1: the raising agent is found in every window, not the active one only.
    @Test func anErrorInASecondWindowsWorkspaceGetsItsNudge() async throws {
        try await withFixture { fixture, clock, probe in
            let delegate = try #require(AppDelegate.shared)
            let second = TabManager(autoWelcomeIfNeeded: false)
            let windowId = delegate.registerMainWindowContextForTesting(tabManager: second)
            defer {
                delegate.unregisterMainWindowContextForTesting(windowId: windowId)
                delegate.forgetRecoverableMainWindowRoute(windowId: windowId)
            }
            let other = second.addWorkspace(select: true)
            defer { second.closeWorkspace(other) }
            let panel = try #require(other.focusedPanelId)
            #expect(fixture.manager.workspacesById[other.id] == nil, "control: the workspace is not in the active window")
            other.setAgentLifecycle(key: "claude_code", panelId: panel, lifecycle: .error)
            try await enqueueError(fixture, workspaceID: other.id, surfaceID: panel)
            await expectArmed(clock)
            clock.advance(by: .seconds(60))
            await spin { probe.delivered.count == 2 }
            #expect(probe.delivered.count == 2, "an error in another window's workspace got no nudge")
        }
    }

    /// F1: a Dock pane's error gets its nudge too. Only a window Dock (`.global`) takes notifications at all, so the pane
    /// moves into the Dock of a second window.
    @Test func anErrorInADockPaneGetsItsNudge() async throws {
        try await withFixture { fixture, clock, probe in
            let delegate = try #require(AppDelegate.shared)
            let second = TabManager(autoWelcomeIfNeeded: false)
            let windowId = delegate.registerMainWindowContextForTesting(tabManager: second)
            defer {
                delegate.unregisterMainWindowContextForTesting(windowId: windowId)
                delegate.forgetRecoverableMainWindowRoute(windowId: windowId)
            }
            let pane = try #require(fixture.source.paneId(forPanelId: fixture.panelId))
            let moved = try #require(fixture.source.newTerminalSurface(inPane: pane, focus: false)).id
            fixture.source.setAgentLifecycle(key: "claude_code", panelId: moved, lifecycle: .error)
            let dock = delegate.windowDock(forWindowId: windowId)
            defer { dock.closeAllPanels() }
            let dockPane = try #require(dock.bonsplitController.allPaneIds.first)
            let detached = try #require(fixture.source.detachSurface(panelId: moved))
            #expect(dock.attachDetachedSurface(detached, inPane: dockPane, focus: false) == moved)
            #expect(dock.scope == .global, "control: a window Dock takes notifications")
            #expect(dock.agentRuntimeByPanelId[moved]?.agentLifecycleStates["claude_code"] == .error, "control: the Dock holds the error")
            #expect(fixture.manager.workspacesById[dock.workspaceId] == nil, "control: no workspace in the active window owns the pane")
            try await enqueueError(fixture, workspaceID: dock.workspaceId, surfaceID: moved)
            await expectArmed(clock)
            clock.advance(by: .seconds(60))
            await spin { probe.delivered.count == 2 }
            #expect(probe.delivered.count == 2, "an error in a Dock pane got no nudge")
        }
    }

    @Test(arguments: ["read", "new-turn", "session-ended", "clear-agent-state", "setting-off", "agent-leaves-error", "present"])
    func unreadErrorReportedCancelledWhenReadNewTurnSettingOffAgentLeavesErrorOrPresent(_ reason: String) async throws {
        let isPresent = reason == "present"
        try await withFixture(present: isPresent) { fixture, clock, probe in
            if isPresent { AppFocusState.overrideIsFocused = true }
            fixture.source.surfaceResumeBindingsByPanelId[fixture.panelId] = SurfaceResumeBindingSnapshot(
                kind: "claude", command: "claude --resume session", checkpointId: "session", source: "agent-hook")
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("c128-error-cancel-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let center = AgentJournalLifecycleCenter(databaseURL: root.appendingPathComponent("journal.sqlite"))
            @MainActor func draft(_ kind: AgentJournalEventKind, at time: Int64) -> AgentJournalEventDraft {
                AgentJournalEventDraft(kind: kind, occurredAtMs: time, source: "claude", agentKey: "claude_code",
                    sessionId: "session", workspaceId: fixture.source.id.uuidString, surfaceId: fixture.panelId.uuidString,
                    attention: AgentAttentionContext(turnIdentity: kind == .turnStarted ? "turn-\(time)" : nil,
                        notification: kind == .errorReported
                            ? AgentJournalNotification(title: "Claude Code · Stopped on an error", subtitle: "cm-128",
                                body: "Error details", category: "other", sourceTitle: "Claude Code") : nil))
            }
            center.observe(draft(.errorReported, at: 1))
            TerminalMutationBus.shared.drainForTesting()
            await AgentNotificationRegressionTests().waitForNotification(in: fixture.store)
            let original = try #require(fixture.store.notifications.first)
            await expectArmed(clock)

            clock.advance(by: .seconds(30))
            switch reason {
            case "read":
                fixture.store.markRead(id: original.id)
                await spin { clock.sleeperCount == 0 }
                #expect(clock.sleeperCount == 0)
            case "new-turn":
                center.observe(draft(.turnStarted, at: 2))
                _ = await center.admitNotification(draft(.stateChanged, at: 3))
                TerminalMutationBus.shared.drainForTesting()
                await spin { clock.sleeperCount == 0 }
                #expect(clock.sleeperCount == 0)
            case "session-ended":
                center.observe(draft(.sessionEnded, at: 2))
                _ = await center.admitNotification(draft(.stateChanged, at: 3))
                TerminalMutationBus.shared.drainForTesting()
                await spin { clock.sleeperCount == 0 }
                #expect(clock.sleeperCount == 0)
            case "clear-agent-state":
                fixture.source.clearAgentState(notifications: fixture.store)
                await spin { clock.sleeperCount == 0 }
                #expect(clock.sleeperCount == 0)
            case "setting-off":
                UserDefaults.standard.set(false, forKey: "notificationAgentIdleReminderEnabled")
                await spin { clock.sleeperCount == 0 }
                #expect(clock.sleeperCount == 0)
                UserDefaults.standard.set(true, forKey: "notificationAgentIdleReminderEnabled")
            case "agent-leaves-error":
                fixture.source.setAgentLifecycle(key: "claude_code", panelId: fixture.panelId, lifecycle: .running)
            case "present":
                break
            default:
                break
            }

            clock.advance(by: .seconds(30))
            await spin { false }
            #expect(probe.delivered.count == (reason == "present" ? 0 : 1), "Cancelled or present error notification must not nudge")
        }
    }

    @Test(arguments: ["claude-recovered", "codex-recovered"])
    func unreadErrorReportedTwoAgentsOnPaneTracksRaisingAgentKeyNotSourceSlug(_ scenario: String) async throws {
        try await withFixture { fixture, clock, probe in
            fixture.source.surfaceResumeBindingsByPanelId[fixture.panelId] = SurfaceResumeBindingSnapshot(
                kind: "claude", command: "claude --resume session", checkpointId: "session", source: "agent-hook")
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("c128-error-multi-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let center = AgentJournalLifecycleCenter(databaseURL: root.appendingPathComponent("journal.sqlite"))

            let draft = AgentJournalEventDraft(kind: .errorReported, occurredAtMs: 1, source: "claude", agentKey: "claude_code",
                sessionId: "session", workspaceId: fixture.source.id.uuidString, surfaceId: fixture.panelId.uuidString,
                attention: AgentAttentionContext(turnIdentity: "turn-1",
                    notification: AgentJournalNotification(title: "Claude Code · Stopped on an error", subtitle: "cm-128",
                        body: "Rate limit reached", category: "other", sourceTitle: "Claude Code")))
            center.observe(draft)
            TerminalMutationBus.shared.drainForTesting()
            await AgentNotificationRegressionTests().waitForNotification(in: fixture.store)
            await expectArmed(clock)

            clock.advance(by: .seconds(30))
            if scenario == "claude-recovered" {
                fixture.source.setAgentLifecycle(key: "claude_code", panelId: fixture.panelId, lifecycle: .running)
                fixture.source.setAgentLifecycle(key: "codex", panelId: fixture.panelId, lifecycle: .error)
            } else {
                fixture.source.setAgentLifecycle(key: "claude_code", panelId: fixture.panelId, lifecycle: .error)
                fixture.source.setAgentLifecycle(key: "codex", panelId: fixture.panelId, lifecycle: .running)
            }

            clock.advance(by: .seconds(30))
            if scenario == "claude-recovered" {
                await spin { false }
                #expect(probe.delivered.count == 1, "When raising agent left .error, no nudge even if another agent has .error")
            } else {
                await spin { probe.delivered.count == 2 }
                #expect(probe.delivered.count == 2, "When raising agent still has .error, nudge must fire using agentKey")
            }
        }
    }

    @Test(arguments: ["direct-enqueue", "custom-agent", "journal-message"])
    func otherCategoryWithoutErrorReportedDoesNotArmNudge(_ origin: String) async throws {
        try await withFixture { fixture, clock, probe in
            // The journal's directory outlives the `if` below: the center opens its store on its own task.
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("c128-message-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            // The center's deinit cancels its consumer, which then drops the event unreported: it outlives the `if`.
            var journal: AgentJournalLifecycleCenter?
            defer { withExtendedLifetime(journal) {} }
            if origin == "journal-message" {
                // A Claude PushNotification: the journal lane's `messagePublished` in category `other`.
                fixture.source.surfaceResumeBindingsByPanelId[fixture.panelId] = SurfaceResumeBindingSnapshot(
                    kind: "claude", command: "claude --resume session", checkpointId: "session", source: "agent-hook")
                let center = AgentJournalLifecycleCenter(databaseURL: root.appendingPathComponent("journal.sqlite"))
                journal = center
                center.observe(AgentJournalEventDraft(kind: .messagePublished, occurredAtMs: 1, source: "claude", agentKey: "claude_code",
                    sessionId: "session", workspaceId: fixture.source.id.uuidString, surfaceId: fixture.panelId.uuidString,
                    nativeEvent: "PostToolUse",
                    attention: AgentAttentionContext(notification: AgentJournalNotification(
                        title: "Claude Code · Notification", subtitle: "cm-128", body: "Generic notification",
                        category: "other", sourceTitle: "Claude Code"))))
            } else {
                #expect(AgentNotificationDelivery().enqueue(workspaceID: fixture.source.id, surfaceID: fixture.panelId,
                    title: origin == "custom-agent" ? "Custom Agent · Notification" : "Claude Code",
                    subtitle: "cm-128", body: "Generic notification",
                    category: .other, pending: false, agentKind: origin == "custom-agent" ? "custom" : "claude",
                    sourceTitle: origin == "custom-agent" ? "Custom Agent" : "Claude Code"))
            }
            TerminalMutationBus.shared.drainForTesting()
            await AgentNotificationRegressionTests().waitForNotification(in: fixture.store)
            #expect(fixture.store.notifications.count == 1)
            await spin { false }
            #expect(clock.sleeperCount == 0, ".other category without errorReported must never arm the nudge")
            clock.advance(by: .seconds(60))
            await spin { false }
            #expect(probe.delivered.count == 1)
        }
    }

    private func withFixture(present: Bool = false, policyHookCommand: String? = nil,
        _ body: @MainActor (AgentNotificationRegressionTests.Fixture, AgentNudgeManualClock, AgentNudgeDeliveryProbe) async throws -> Void
    ) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            _ = try #require(AppDelegate.shared)
            let fixture = try AgentNotificationRegressionTests().makeFixture(policyHookCommand: policyHookCommand)
            let store = fixture.store
            let defaults = UserDefaults.standard
            let keys = ["notificationAgentTurnComplete", "notificationAgentIdleReminderEnabled"]
            let previous = keys.map { defaults.object(forKey: $0) }
            defaults.set("always", forKey: keys[0])
            defaults.set(true, forKey: keys[1])
            let clock = AgentNudgeManualClock()
            let probe = AgentNudgeDeliveryProbe()
            let originalNudges = store.unattendedNudges
            var originalHooks: NativeNotificationDeliveryHooks?
            store.configureNativeNotificationDeliveryHooksForTesting { originalHooks = $0 }
            store.unattendedNudges = AgentUnattendedNudgeDelivery(store: store, clock: clock, isPresent: { present })
            store.configureNotificationDeliveryHandlerForTesting { _, notification, effects in
                probe.delivered.append((notification, effects))
            }
            store.configureSuppressedNotificationFeedbackHandlerForTesting { _, notification, _ in
                probe.suppressed.append(notification)
            }
            store.configurePhoneForwardingForTesting(enabled: { true }, forward: { notification, _ in
                probe.forwarded.append(notification.id)
            })
            defer {
                fixture.restore()
                store.unattendedNudges = originalNudges
                if let originalHooks { store.configureNativeNotificationDeliveryHooksForTesting { $0 = originalHooks } }
                store.resetPhoneForwardingForTesting()
                for (index, key) in keys.enumerated() {
                    if let value = previous[index] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
                }
            }
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            try await body(fixture, clock, probe)
        }
    }

    private func enqueue(_ fixture: AgentNotificationRegressionTests.Fixture, pending: Bool = false,
                         prompt: Bool = false, sourceTitle: String = "Claude Code", agent: String = "claude") async throws {
        #expect(AgentNotificationDelivery().enqueue(workspaceID: fixture.source.id, surfaceID: fixture.panelId,
            title: "\(sourceTitle) · Finished", subtitle: "cm-128", body: "The agent's result",
            category: .turnComplete, pending: pending,
            soundContext: NotificationSoundOverrideContext(agentID: agent, alertType: .turnDone),
            agentKind: agent, correlationKey: UUID().uuidString,
            sourceTitle: sourceTitle, isPromptTurn: prompt))
        TerminalMutationBus.shared.drainForTesting()
        await AgentNotificationRegressionTests().waitForNotification(in: fixture.store)
        #expect(fixture.store.notifications.count == 1)
    }

    /// An unread Stopped-on-an-error notification for one pane, through the real delivery path.
    private func enqueueError(_ fixture: AgentNotificationRegressionTests.Fixture, workspaceID: UUID, surfaceID: UUID) async throws {
        #expect(AgentNotificationDelivery().enqueue(workspaceID: workspaceID, surfaceID: surfaceID,
            title: "Claude Code · Stopped on an error", subtitle: "cm-128", body: "Rate limit reached",
            category: .other, pending: false,
            soundContext: NotificationSoundOverrideContext(agentID: "claude", alertType: .errorStalled),
            agentKind: "claude", correlationKey: UUID().uuidString, sourceTitle: "Claude Code",
            journalKind: .errorReported, agentKey: "claude_code"))
        TerminalMutationBus.shared.drainForTesting()
        await AgentNotificationRegressionTests().waitForNotification(in: fixture.store)
    }

    private func journalStorageSnapshot() async throws -> [Int64] {
        try await Task.detached {
            let store = try #require(AgentJournalLifecycleCenter.shared.journalStoreForTesting())
            let receipts = try store.withDatabase {
                try AgentJournalStore.scalarInt64($0, "SELECT COUNT(*) FROM agent_notification_receipt;", binding: [])
            }
            return [try store.headSequence(), try #require(receipts)]
        }.value
    }

    private func expectArmed(_ clock: AgentNudgeManualClock) async {
        await spin { clock.sleeperCount == 1 }
        #expect(clock.sleeperCount == 1, "The record point must arm the unread completion")
    }

    private func spin(_ complete: () -> Bool) async {
        for _ in 0..<2_000 {
            if complete() { return }
            await Task.yield()
        }
    }
}
