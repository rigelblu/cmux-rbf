import Foundation
import Testing
@testable import CmuxNotifications

@MainActor
struct AgentUnattendedNudgeTests {
    @Test func unreadCompletionFiresAtSixtySecondsExactlyOnce() async {
        let clock = NudgeManualClock(), id = UUID()
        var fired: [UUID] = []
        let scheduler = AgentUnattendedNudgeScheduler(clock: clock, state: { _ in Self.eligible }, notify: { fired.append($0) })
        scheduler.arm(notificationID: id, pendingWork: false, promptTurn: false)
        clock.advance(by: .seconds(59))
        for _ in 0..<20 { await Task.yield() }
        #expect(fired.isEmpty)
        clock.advance(by: .seconds(1))
        await drain(scheduler)
        #expect(fired == [id])
        clock.advance(by: .seconds(120))
        for _ in 0..<20 { await Task.yield() }
        #expect(fired == [id])
    }

    @Test(arguments: ["read", "removed", "setting-off", "looking"])
    func liveStateAtDeadlineCanFinallySkipTheNudge(_ reason: String) async {
        let clock = NudgeManualClock()
        var state = Self.eligible
        var fired = 0
        let scheduler = AgentUnattendedNudgeScheduler(clock: clock, state: { _ in state }, notify: { _ in fired += 1 })
        scheduler.arm(notificationID: UUID(), pendingWork: false, promptTurn: false)
        clock.advance(by: .seconds(30))
        state = .init(enabled: reason != "setting-off", exists: reason != "removed", unread: reason != "read",
            focusedInFrontmostApp: reason == "looking", present: true)
        clock.advance(by: .seconds(30))
        await drain(scheduler)
        #expect(fired == 0)
        state = Self.eligible
        clock.advance(by: .seconds(120))
        for _ in 0..<20 { await Task.yield() }
        #expect(fired == 0, "A skip is final; there is no second check")
    }

    @Test(arguments: [false, true])
    func leavingThePaneOrBeingAwayAllowsTheNudge(_ stillFocused: Bool) async {
        let clock = NudgeManualClock()
        var state = AgentUnattendedNudgeState(enabled: true, exists: true, unread: true,
            focusedInFrontmostApp: true, present: true)
        var fired = 0
        let scheduler = AgentUnattendedNudgeScheduler(clock: clock, state: { _ in state }, notify: { _ in fired += 1 })
        scheduler.arm(notificationID: UUID(), pendingWork: false, promptTurn: false)
        clock.advance(by: .seconds(50))
        state = .init(enabled: true, exists: true, unread: true, focusedInFrontmostApp: stillFocused, present: !stillFocused)
        clock.advance(by: .seconds(10))
        await drain(scheduler)
        #expect(fired == 1)
    }

    @Test(arguments: ["pending", "prompt-turn", "setting-off"])
    func ineligibleCompletionDoesNotArm(_ reason: String) async {
        let clock = NudgeManualClock()
        var fired = 0
        let scheduler = AgentUnattendedNudgeScheduler(clock: clock, state: { _ in
            .init(enabled: reason != "setting-off", exists: true, unread: true,
                focusedInFrontmostApp: false, present: true)
        }, notify: { _ in fired += 1 })
        scheduler.arm(notificationID: UUID(), pendingWork: reason == "pending", promptTurn: reason == "prompt-turn")
        #expect(scheduler.pendingCount == 0)
        clock.advance(by: .seconds(60))
        await drain(scheduler)
        #expect(fired == 0)
    }

    @Test(arguments: ["read", "new-turn", "setting-off"])
    func explicitCancellationStopsTheTimer(_ reason: String) async {
        let clock = NudgeManualClock(), id = UUID()
        var fired = 0
        let scheduler = AgentUnattendedNudgeScheduler(clock: clock, state: { _ in Self.eligible }, notify: { _ in fired += 1 })
        scheduler.arm(notificationID: id, pendingWork: false, promptTurn: false)
        clock.advance(by: .seconds(reason == "new-turn" ? 40 : 30))
        if reason == "setting-off" { scheduler.cancelAll() } else { scheduler.cancel(notificationID: id) }
        clock.advance(by: .seconds(60))
        await drain(scheduler)
        #expect(fired == 0)
    }

    @Test func aDrainTurnGetsItsOwnDeadlineAndAnIdlePromptDoesNotMoveIt() async {
        let clock = NudgeManualClock(), old = UUID(), drainID = UUID()
        var fired: [UUID] = []
        let scheduler = AgentUnattendedNudgeScheduler(clock: clock, state: { _ in Self.eligible }, notify: { fired.append($0) })
        scheduler.arm(notificationID: old, pendingWork: true, promptTurn: false)
        clock.advance(by: .seconds(40))
        scheduler.arm(notificationID: drainID, pendingWork: false, promptTurn: false)
        clock.advance(by: .seconds(30))
        // An idle_prompt has no scheduler handoff; duplicate record handoffs
        // cannot shorten or reset an already-armed completion either.
        scheduler.arm(notificationID: drainID, pendingWork: false, promptTurn: false)
        clock.advance(by: .seconds(30))
        await drain(scheduler)
        #expect(fired == [drainID])
    }

    @Test func destructionCancelsPendingTimers() async {
        let clock = NudgeManualClock()
        var fired = 0
        var scheduler: AgentUnattendedNudgeScheduler? = .init(clock: clock,
            state: { _ in Self.eligible }, notify: { _ in fired += 1 })
        scheduler?.arm(notificationID: UUID(), pendingWork: false, promptTurn: false)
        for _ in 0..<2_000 {
            if clock.sleeperCount == 1 { break }
            await Task.yield()
        }
        #expect(clock.sleeperCount == 1)
        scheduler = nil
        #expect(clock.sleeperCount == 0)
        clock.advance(by: .seconds(60))
        for _ in 0..<100 { await Task.yield() }
        #expect(fired == 0)
    }

    @Test func aRepeatedHandoffAfterFiringCannotNudgeTheSameTurnTwice() async {
        let clock = NudgeManualClock(), id = UUID()
        var fired = 0
        let scheduler = AgentUnattendedNudgeScheduler(clock: clock, state: { _ in Self.eligible }, notify: { _ in fired += 1 })
        scheduler.arm(notificationID: id, pendingWork: false, promptTurn: false)
        clock.advance(by: .seconds(60))
        await drain(scheduler)
        #expect(fired == 1)
        scheduler.arm(notificationID: id, pendingWork: false, promptTurn: false)
        clock.advance(by: .seconds(60))
        await drain(scheduler)
        #expect(fired == 1)
    }

    private static var eligible: AgentUnattendedNudgeState {
        .init(enabled: true, exists: true, unread: true, focusedInFrontmostApp: false, present: true)
    }

    private func drain(_ scheduler: AgentUnattendedNudgeScheduler) async {
        for _ in 0..<2_000 {
            if scheduler.pendingCount == 0 { return }
            await Task.yield()
        }
        #expect(scheduler.pendingCount == 0, "Due clock work did not finish")
    }
}
