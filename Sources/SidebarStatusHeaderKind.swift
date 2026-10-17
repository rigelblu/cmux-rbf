import Foundation

/// Distinguishes status-related headers from upstream workspace group headers. // (#cm-110.1)
public enum SidebarStatusHeaderKind: Equatable, Hashable, Sendable { // (#cm-110.1)
    /// The root `Statuses` area header.
    case statusesArea
    /// A header for a specific status group in the user's file.
    case statusGroup(String)
}
