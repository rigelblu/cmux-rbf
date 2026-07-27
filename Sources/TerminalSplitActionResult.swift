import AppKit

/// The terminal outcome of one directional split request.
enum TerminalSplitActionResult: Equatable {
    /// A local pane was created and focused.
    case created(panelID: UUID)
    /// The mutation was handed to the remote tmux session.
    case routedToRemote
    /// The target cannot honor this direction; nothing was mutated.
    case unsupported(TerminalSplitUnsupportedReason)
    /// The split was attempted and did not happen.
    case failed

    /// Whether the entry point must stop without attempting a fallback.
    var isHandled: Bool {
        true
    }

    /// Whether the requested split was accepted.
    var didSucceed: Bool {
        switch self {
        case .created, .routedToRemote: return true
        case .unsupported, .failed: return false
        }
    }

    /// Emits the standard immediate-action rejection feedback when needed.
    ///
    /// - Parameter beep: Injectable feedback sink used by behavior tests.
    /// - Returns: Whether rejection feedback was emitted.
    @MainActor
    @discardableResult
    func presentUserFeedback(beep: () -> Void = { NSSound.beep() }) -> Bool {
        switch self {
        case .unsupported:
            beep()
            return true
        case .created, .routedToRemote, .failed:
            return false
        }
    }
}
