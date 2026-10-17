import CmuxSidebar
import Foundation

/// Window ownership of an existing opaque drag session; no new payload, protocol or persisted field.
@MainActor
final class SidebarStatusHeaderDragSession {
    static let shared = SidebarStatusHeaderDragSession()
    private var sourceWindowId: UUID?
    private var sourceSession: SidebarWorkspaceDragSession?

    func began(windowId: UUID, session: SidebarWorkspaceDragSession) {
        sourceWindowId = windowId
        sourceSession = session
    }

    /// The cached/deferred commit uses this same gate, including after native completion.
    func commitIfAccepted(headerId: UUID, windowId: UUID, sessionId: UUID, dragState: SidebarDragState,
                          perform: @MainActor () -> Bool) -> Bool {
        guard acceptsCommit(headerId: headerId, windowId: windowId, sessionId: sessionId, dragState: dragState) else { return false }
        return perform()
    }

    func isKnownHeader(_ id: UUID) -> Bool { sourceSession?.workspaceId == id }

    func acceptsCommit(headerId: UUID, windowId: UUID, sessionId: UUID, dragState: SidebarDragState) -> Bool {
        sourceWindowId == windowId && sourceSession?.id == sessionId && sourceSession?.workspaceId == headerId
            && dragState.acceptsWorkspaceDragSession(sessionId: sessionId, workspaceId: headerId)
    }

    func activateIfLocal(headerId: UUID, windowId: UUID, dragState: SidebarDragState) -> Bool {
        guard sourceWindowId == windowId, let sourceSession,
              sourceSession.workspaceId == headerId,
              dragState.currentWorkspaceDragId == headerId,
              dragState.currentWorkspaceDragSessionId == sourceSession.id else { return false }
        return dragState.activateDragging(tabId: headerId)
    }
}
