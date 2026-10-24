public import Foundation

/// Row provenance needed by status-drop admission; ordinary reorder callers retain their existing defaults.
public enum SidebarWorkspaceReorderDropTargetKind: Equatable, Sendable {
    case workspace
    case statusGroupHeader(statusId: String)
    case statusesArea
    case workspaceSectionHeader // (#cm-110.4) either header in the two-section layout
    case colorSectionHeader
}
