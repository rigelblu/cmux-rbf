# CmuxNotifications

The notification package owns delivery coordination, unread projections, agent source lines, and unattended reminder deadlines. App and OS access arrive through injected seams.

Construct the nudge scheduler on the main actor with a clock, live admission facts, and a banner callback:

```swift
let scheduler = AgentUnattendedNudgeScheduler(
    clock: ContinuousClock(),
    state: { id in liveState(for: id) },
    notify: { id in postBannerOnly(for: id) }
)
scheduler.arm(notificationID: originalID, pendingWork: false, promptTurn: false)
```

Tests use the same initializer with `NudgeManualClock` from the test target, advance it by sixty seconds, and inspect the callback. No AppKit, notification daemon, user defaults, or real-time delay is required. Cancel the original id when it is read or removed, and cancel all deadlines when reminders are disabled. Those calls also release retained handoff identities.
