public import Foundation

/// Schedules one reminder deadline per recorded completion using an injected clock.
///
/// The app supplies live eligibility and performs the banner-only effect. This
/// scheduler owns no notification records, journal events, receipts, or OS access.
@MainActor
public final class AgentUnattendedNudgeScheduler {
    private let makeSleep: () -> (@Sendable () async throws -> Void)
    private let state: @MainActor (UUID) -> AgentUnattendedNudgeState
    private let notify: @MainActor (UUID) -> Void
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var handedOffIDs: Set<UUID> = []
    var pendingCount: Int { tasks.count }

    /// Creates an isolated scheduler whose timer starts at each record handoff.
    /// - Parameters:
    ///   - clock: The production continuous clock or a deterministic test clock.
    ///   - state: A fresh eligibility snapshot for the original notification.
    ///   - notify: The admitted banner-only effect, receiving the original id.
    public init<C: Clock>(clock: C, state: @escaping @MainActor (UUID) -> AgentUnattendedNudgeState,
                          notify: @escaping @MainActor (UUID) -> Void) where C.Duration == Duration {
        self.makeSleep = {
            let deadline = clock.now.advanced(by: .seconds(60))
            return { try await clock.sleep(until: deadline, tolerance: nil) }
        }
        self.state = state
        self.notify = notify
    }

    deinit {
        for task in tasks.values { task.cancel() }
    }

    /// Arms a recorded completion's sixty-second deadline.
    /// - Parameters:
    ///   - notificationID: The id handed off by the notification record point.
    ///   - pendingWork: Whether that completion still had background work pending.
    ///   - promptTurn: Whether the completion came from prompt-line detection.
    /// - Returns: Whether the recorded completion was admitted and scheduled.
    @discardableResult
    public func arm(notificationID: UUID, pendingWork: Bool, promptTurn: Bool) -> Bool {
        let initial = state(notificationID)
        guard !pendingWork, !promptTurn, initial.enabled, initial.exists, initial.unread,
              handedOffIDs.insert(notificationID).inserted else { return false }
        let sleep = makeSleep()
        tasks[notificationID] = Task { [weak self] in
            do { try await sleep() } catch {
                if !Task.isCancelled { self?.tasks.removeValue(forKey: notificationID) }
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.tasks.removeValue(forKey: notificationID)
            let current = self.state(notificationID)
            guard current.enabled, current.exists, current.unread,
                  !(current.focusedInFrontmostApp && current.present) else { return }
            self.notify(notificationID)
        }
        return true
    }

    /// Cancels a read, removed, or invalidated completion's pending deadline.
    /// - Parameter notificationID: The original notification id.
    public func cancel(notificationID: UUID) {
        tasks.removeValue(forKey: notificationID)?.cancel()
        handedOffIDs.remove(notificationID)
    }

    /// Cancels every pending deadline, for example when the setting turns off.
    public func cancelAll() {
        let pending = tasks.values
        tasks.removeAll()
        handedOffIDs.removeAll()
        for task in pending { task.cancel() }
    }
}
