import AppKit
import CmuxFoundation
import CmuxSidebar
import Foundation

/// Actual source-row provenance bound to the existing native/session generation, with no new wire payload.
@MainActor
final class SidebarStatusGroupDragSource {
    static let shared = SidebarStatusGroupDragSource()
    struct Record {
        let windowId: UUID
        let session: SidebarWorkspaceDragSession
        let rowId: SidebarWorkspaceRenderItemID?
        let kind: SidebarStatusGroupDropRules.SourceKind
    }
    private var latest: Record?

    func began(windowId: UUID, session: SidebarWorkspaceDragSession, rowId: SidebarWorkspaceRenderItemID?) {
        let kind: SidebarStatusGroupDropRules.SourceKind
        if let groupId = rowId?.groupId { kind = .workspaceGroupHeader(groupId: groupId) }
        else if rowId == .workspace(session.workspaceId) { kind = .workspace }
        else { kind = .unknown }
        latest = .init(windowId: windowId, session: session, rowId: rowId, kind: kind)
    }

    func source(windowId: UUID, workspaceId: UUID, sessionId: UUID, dragState: SidebarDragState) -> Record? {
        guard let latest, latest.windowId == windowId, latest.session.workspaceId == workspaceId,
              latest.session.id == sessionId,
              dragState.acceptsWorkspaceDragSession(sessionId: sessionId, workspaceId: workspaceId) else { return nil }
        return latest
    }

    /// Compatibility clients retain the old begin callback; current app callers receive the actual source row.
    static func begin(workspaceId: UUID, rowId: SidebarWorkspaceRenderItemID?, actions: SidebarWorkspaceTableActions) {
        if let begin = actions.beginWorkspaceDragFromRow { begin(workspaceId, rowId) }
        else { actions.beginWorkspaceDrag(workspaceId) }
    }
}
