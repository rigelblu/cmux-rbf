import Foundation

/// Why a panel notification is being dismissed. The context decides which
/// indicator classes the dismissal may clear.
public enum NotificationDismissalContext: Sendable {
    /// Generic active focus (restore or programmatic selection included).
    case activeFocus
    /// The user explicitly resumed/selected the workspace.
    case explicitWorkspaceResume
    /// The user directly interacted with the panel (click, jump-to-unread).
    case directInteraction
    /// The user typed into the terminal.
    case terminalInteraction

    /// Whether dismissal in this context requires the app to be active.
    public var requiresActiveApp: Bool {
        switch self {
        case .activeFocus, .explicitWorkspaceResume:
            return true
        case .directInteraction, .terminalInteraction:
            return false
        }
    }

    /// Whether this context leaves a notification he put back unread (cm-128.13): it is his mark, which every
    /// dismissal but typing in the pane leaves, as it leaves his dot. Exhaustive, so a future context must decide.
    public var leavesPutBackNotification: Bool {
        switch self {
        case .activeFocus, .explicitWorkspaceResume, .directInteraction:
            return true
        case .terminalInteraction:
            return false
        }
    }

    /// Whether a dismissal in this context flashes the pane.
    ///
    /// - Parameter flashOnTyping: Whether terminal typing should flash the
    ///   pane after it dismisses a notification.
    public func flashesOnDismiss(flashOnTyping: Bool) -> Bool {
        switch self {
        case .terminalInteraction:
            return flashOnTyping
        case .activeFocus, .explicitWorkspaceResume, .directInteraction:
            return true
        }
    }

    /// Whether a dismissal in this context flashes the pane using the calmer
    /// default for terminal typing.
    public var flashesOnDismiss: Bool {
        flashesOnDismiss(flashOnTyping: false)
    }

    /// Whether this context may clear a manually-set unread indicator.
    public var canDismissManualUnreadIndicator: Bool {
        self == .terminalInteraction
    }

    /// Whether this context may clear a session-restored unread indicator.
    ///
    /// Generic active focus can be produced by restore/programmatic
    /// selection. Kept exhaustive so any future context must make an
    /// explicit restored-unread policy decision.
    public var canDismissRestoredUnreadIndicator: Bool {
        switch self {
        case .activeFocus:
            return false
        case .explicitWorkspaceResume, .directInteraction, .terminalInteraction:
            return true
        }
    }
}
