import Foundation

/// Why a directional split cannot be performed in the requested direction.
enum TerminalSplitUnsupportedReason: Equatable {
    /// cmux does not yet emit tmux's insert-before flag for Left/Up.
    case remoteMirrorCannotInsertBefore

    /// A stable token for logs and tests. Never shown to a person.
    var logToken: String {
        switch self {
        case .remoteMirrorCannotInsertBefore: return "remote-mirror-insert-before"
        }
    }

    /// A localized explanation suitable for disabled-control help.
    var localizedHelp: String {
        switch self {
        case .remoteMirrorCannotInsertBefore:
            return String(
                localized: "split.unavailable.remoteMirrorInsertBefore",
                defaultValue: "cmux can't add a pane to the left or above in a remote tmux workspace yet."
            )
        }
    }
}
