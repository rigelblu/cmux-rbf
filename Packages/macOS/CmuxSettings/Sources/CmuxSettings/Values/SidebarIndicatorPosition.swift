import Foundation

/// Which side of a sidebar workspace row a status indicator (the loading
/// spinner or the unread notification badge) appears on. `leading` draws on the
/// line under the workspace name, the badge first, then the agent marks;
/// `trailing` sits toward the close-button corner (cm-128.9).
public enum SidebarIndicatorPosition: String, CaseIterable, Sendable, SettingCodable {
    /// The left, on the line under the workspace name (cm-128.9).
    case leading
    /// The right side of the row, toward the close-button corner.
    case trailing
}
