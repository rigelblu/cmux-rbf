import Foundation

extension CLINotifyProcessIntegrationRegressionTests {
    final class MockSocketServerState: @unchecked Sendable {
        private let lock = NSLock()
        private let notifications = AgentHookTestNotificationPipeline()
        private(set) var commands: [String] = []
        private var commandTimestamps: [TimeInterval] = []
        // cmux-rbf (#cm-124.5): what the mock app answers to `agent_events.rows`. Nil leaves the method unrecognized, as
        // an app without the table; a delay holds the answer back, as an app that is slow to reply.
        private var agentEventRows: [[String: String]]?
        private var agentEventRowsDelay: TimeInterval = 0

        func setAgentEventRows(_ rows: [[String: String]]?, delay: TimeInterval = 0) {
            lock.lock()
            agentEventRows = rows
            agentEventRowsDelay = delay
            lock.unlock()
        }

        func agentEventRowsAnswer() -> (rows: [[String: String]]?, delay: TimeInterval) {
            lock.lock()
            let value = (agentEventRows, agentEventRowsDelay)
            lock.unlock()
            return value
        }

        // cmux-rbf (#cm-124.6, #cm-142.1): whether the mock app answers `agent.resolve_delivery_target` as the owner of
        // the context's surface. Off by default, so upstream's tests on this mock keep the Feed's fail-closed refusal.
        private var resolvesDeliveryTarget = false

        func setResolvesDeliveryTarget(_ value: Bool) {
            lock.lock()
            resolvesDeliveryTarget = value
            lock.unlock()
        }

        func resolvesDeliveryTargetAnswer() -> Bool {
            lock.lock()
            let value = resolvesDeliveryTarget
            lock.unlock()
            return value
        }

        // cmux-rbf (#cm-142.1): whether the mock app answers `agent.hook.barrier`. The CLI stamps a blocking Feed request
        // (`_hook_sent_at_ms`) only behind a completed barrier, and upstream's supersede never retires an unstamped request.
        // Off by default, so the other tests on this mock keep the frames they were written against.
        private var answersHookBarrier = false

        func setAnswersHookBarrier(_ value: Bool) {
            lock.lock()
            answersHookBarrier = value
            lock.unlock()
        }

        func answersHookBarrierAnswer() -> Bool {
            lock.lock()
            let value = answersHookBarrier
            lock.unlock()
            return value
        }

        func append(_ command: String) {
            lock.lock()
            let entries = [command] + notifications.effects(for: command)
            commands.append(contentsOf: entries)
            commandTimestamps.append(contentsOf: entries.map { _ in ProcessInfo.processInfo.systemUptime })
            lock.unlock()
        }

        func snapshot() -> [String] {
            lock.lock()
            let value = commands
            lock.unlock()
            return value
        }

        func admittedNotificationKeysSnapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return notifications.admittedCorrelationKeys
        }

        func timestampedSnapshot() -> [(command: String, timestamp: TimeInterval)] {
            lock.lock()
            let value = zip(commands, commandTimestamps).map {
                (command: $0.0, timestamp: $0.1)
            }
            lock.unlock()
            return value
        }
    }
}
