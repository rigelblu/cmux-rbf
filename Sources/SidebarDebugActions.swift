import AppKit
import Foundation

#if DEBUG
/// DEBUG access to the section actions the sidebar parent supplies, shared by both renderers.
@MainActor
final class SidebarDebugActions {
    enum Header: String, CaseIterable {
        case statuses
        case workspaces

        var id: UUID {
            switch self {
            case .statuses: return SidebarStatusHeaderIdentity.statusesAreaUUID
            case .workspaces: return SidebarStatusHeaderIdentity.workspacesAreaUUID
            }
        }

        var rowKind: String {
            switch self {
            case .statuses: return "statusesHeader"
            case .workspaces: return "workspacesHeader"
            }
        }
    }

    struct Action {
        let header: Header
        let isCollapsed: () -> Bool
        let toggle: () -> Void
    }

    private struct Entry {
        let owner: ObjectIdentifier
        let actions: [Action]
        let handler: ((SidebarDebugDropRequest) -> SidebarDebugDropResult?)?
    }

    private var entries: [UUID: Entry] = [:]

    func update(windowId: UUID, owner: NSView, actions: [Action],
        handler: ((SidebarDebugDropRequest) -> SidebarDebugDropResult?)? = nil) {
        entries[windowId] = Entry(owner: ObjectIdentifier(owner), actions: actions, handler: handler)
    }

    func remove(windowId: UUID, owner: NSView) {
        guard entries[windowId]?.owner == ObjectIdentifier(owner) else { return }
        entries.removeValue(forKey: windowId)
    }

    func perform(windowId: UUID, request: SidebarDebugDropRequest) -> SidebarDebugDropResult? {
        entries[windowId]?.handler?(request)
    }

    /// A missing or inactive header refuses instead of manufacturing a section for a test.
    func setCollapsed(_ collapsed: Bool, header: Header, windowId: UUID) -> Bool {
        guard let action = entries[windowId]?.actions.first(where: { $0.header == header }) else { return false }
        if action.isCollapsed() != collapsed { action.toggle() }
        return action.isCollapsed() == collapsed
    }

    static func identity(_ raw: String, items: [SidebarWorkspaceRenderItem]) -> UUID? {
        guard let header = Header(rawValue: raw),
              items.contains(where: { $0.headerDropIdentity == header.id }) else { return nil }
        return header.id
    }

    func rows(_ rows: [SidebarDebugRow], windowId: UUID) -> [SidebarDebugRow] {
        let actions = entries[windowId]?.actions ?? []
        return rows.map { row in
            guard let action = actions.first(where: { $0.header.id.uuidString == row.id }) else { return row }
            return SidebarDebugRow(kind: action.header.rowKind, id: row.id, title: row.title,
                header: row.header, folded: action.isCollapsed(), statusId: row.statusId)
        }
    }
}

#endif
