import Foundation

/// The shared source line and working-folder subtitle for an agent notification.
public struct AgentNotificationPresentation: Equatable, Sendable {
    /// The reason an agent notification needs the user's attention.
    public enum Kind: Sendable {
        /// The turn finished.
        case finished
        /// The agent needs an answer.
        case answer
        /// The agent needs approval for an action or plan.
        case approval
        /// The agent stopped on an error.
        case error
        /// A finished turn remains unread after one minute.
        case unreadReminder
        /// An agent error turn remains unread after one minute.
        case errorUnreadReminder
    }

    /// The agent's display name, optional session title, and localized kind.
    public let title: String
    /// The last component of the working directory, or empty when unavailable.
    public let subtitle: String

    /// Creates presentation without changing the upstream agent/session title.
    /// - Parameters:
    ///   - agentTitle: The existing display name, including Pi's session title.
    ///   - kind: The notification kind, or nil for a model-initiated push.
    ///   - cwd: The agent's working directory, when available.
    public init(agentTitle: String, kind: Kind?, cwd: String?) {
        let label: String?
        switch kind {
        case .finished:
            label = String(localized: "agent.notification.kind.finished", defaultValue: "Finished")
        case .answer:
            label = String(localized: "agent.notification.kind.answer", defaultValue: "Needs your answer")
        case .approval:
            label = String(localized: "agent.notification.kind.approval", defaultValue: "Needs your approval")
        case .error:
            label = String(localized: "agent.notification.kind.error", defaultValue: "Stopped on an error")
        case .unreadReminder:
            label = String(localized: "agent.notification.kind.unreadReminder", defaultValue: "Finished 1 min ago, still unread")
        case .errorUnreadReminder:
            label = String(localized: "agent.notification.kind.errorUnreadReminder", defaultValue: "Stopped on an error 1 min ago, still unread")
        case nil:
            label = nil
        }
        title = label.map { "\(agentTitle) · \($0)" } ?? agentTitle
        // String components avoid URL's differing root behavior on macOS 14/26.
        subtitle = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/").last.map(String.init) ?? ""
    }
}
