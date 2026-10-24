import Foundation

/// Distinguishes status-related headers from upstream workspace group headers. // (#cm-110.1)
public enum SidebarStatusHeaderKind: Equatable, Hashable, Sendable { // (#cm-110.1)
    /// The root `Statuses` area header.
    case statusesArea
    /// The ordinary workspace section, below pinned rows.
    case workspacesArea
    /// The root `Pinned` area header above pinned rows.
    case pinnedArea // (#cm-110.5)
    /// A header for a specific status group in the user's file.
    case statusGroup(String)

    var isSection: Bool {
        switch self {
        case .statusesArea, .workspacesArea, .pinnedArea: return true
        case .statusGroup: return false
        }
    }
}
