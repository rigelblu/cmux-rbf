/// The two sidebar sections below a window's pinned rows.
public enum WorkspaceSectionOrder: String, Codable, CaseIterable, Sendable {
    /// Ordinary workspace items precede the Statuses section.
    case workspacesFirst
    /// The Statuses section precedes ordinary workspace items.
    case statusesFirst
}
