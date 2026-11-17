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
