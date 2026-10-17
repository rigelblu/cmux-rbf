import AppKit
import CmuxSidebar
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SidebarStatusHeaderDragScopeTests {
    private static let kinds: [SidebarStatusHeaderKind] = [.statusesArea, .statusGroup("parked")]

    @Test(arguments: kinds)
    func sourceWindowAcceptsItsOwnLiveSession(_ kind: SidebarStatusHeaderKind) {
        let f = Fixture(kind: kind)
        #expect(f.scope.activateIfLocal(headerId: f.header, windowId: f.window, dragState: f.origin))
    }
    @Test(arguments: kinds)
    func aRebuiltSourceViewKeepsTheWindowAndOpaqueToken(_ kind: SidebarStatusHeaderKind) {
        let f = Fixture(kind: kind)
        let rebuilt = SidebarDragState(workspaceDragRegistry: f.registry)
        #expect(rebuilt.draggedTabId == nil)
        #expect(f.scope.activateIfLocal(headerId: f.header, windowId: f.window, dragState: rebuilt))
        #expect(rebuilt.draggedTabId == f.header)
    }
    @Test(arguments: kinds)
    func anotherWindowCannotActivateOrMutateAHeaderDrag(_ kind: SidebarStatusHeaderKind) {
        let f = Fixture(kind: kind)
        let destination = SidebarDragState(workspaceDragRegistry: f.registry)
        #expect(!f.scope.activateIfLocal(headerId: f.header, windowId: UUID(), dragState: destination))
        #expect(destination.draggedTabId == nil)
    }
    @Test(arguments: kinds)
    func aNewSessionOfTheSameHeaderCannotReuseTheOldCapability(_ kind: SidebarStatusHeaderKind) {
        let f = Fixture(kind: kind)
        let newer = SidebarDragState(workspaceDragRegistry: f.registry)
        let newSession = newer.beginDragging(tabId: f.header)
        #expect(newSession.id != f.session.id)
        let rebuilt = SidebarDragState(workspaceDragRegistry: f.registry)
        #expect(!f.scope.activateIfLocal(headerId: f.header, windowId: f.window, dragState: rebuilt))
        #expect(rebuilt.draggedTabId == nil)
    }

    @Test(arguments: kinds)
    func anAcceptedPendingDropCommitsAfterNativeSourceCompletion(_ kind: SidebarStatusHeaderKind) {
        let f = Fixture(kind: kind)
        f.origin.finishDrag()
        let rebuilt = SidebarDragState(workspaceDragRegistry: f.registry)
        #expect(rebuilt.currentWorkspaceDragSessionId == nil)
        var commits = 0
        #expect(f.scope.commitIfAccepted(headerId: f.header, windowId: f.window, sessionId: f.session.id, dragState: rebuilt,
            perform: { commits += 1; return true }))
        #expect(commits == 1)
        #expect(rebuilt.draggedTabId == nil) // Commit must not reactivate a completed native source.
    }
    @Test(arguments: kinds, [false, true])
    func aNewerLiveOrCompletedSessionFencesAnOldCachedPlan(_ kind: SidebarStatusHeaderKind, _ ended: Bool) {
        let f = Fixture(kind: kind)
        f.origin.finishDrag()
        let newer = SidebarDragState(workspaceDragRegistry: f.registry)
        let newSession = newer.beginDragging(tabId: f.header)
        #expect(newSession.id != f.session.id)
        if ended { newer.finishDrag() }
        var commits = 0
        #expect(!f.scope.commitIfAccepted(headerId: f.header, windowId: f.window, sessionId: f.session.id, dragState: newer,
            perform: { commits += 1; return true }))
        #expect(commits == 0)
    }
    enum WrongCapability: CaseIterable, Sendable { case window, header, token }
    @Test(arguments: kinds, WrongCapability.allCases)
    func aCompletedCapabilityStillChecksWindowHeaderAndOpaqueToken(_ kind: SidebarStatusHeaderKind, _ wrong: WrongCapability) {
        let f = Fixture(kind: kind)
        f.origin.finishDrag()
        let rebuilt = SidebarDragState(workspaceDragRegistry: f.registry)
        var commits = 0
        #expect(!f.scope.commitIfAccepted(headerId: wrong == .header ? UUID() : f.header,
            windowId: wrong == .window ? UUID() : f.window, sessionId: wrong == .token ? UUID() : f.session.id,
            dragState: rebuilt, perform: { commits += 1; return true }))
        #expect(commits == 0)
    }
    @Test(arguments: kinds)
    func anOldNativeEndCannotEraseANewerHeaderCapability(_ kind: SidebarStatusHeaderKind) {
        let f = Fixture(kind: kind)
        let newer = SidebarDragState(workspaceDragRegistry: f.registry)
        let session = newer.beginDragging(tabId: f.header)
        f.scope.began(windowId: f.window, session: session)
        f.origin.finishDrag(sessionId: f.session.id, capabilityValue: f.session.pasteboardValue)
        #expect(newer.currentWorkspaceDragSessionId == session.id)
        var commits = 0
        #expect(f.scope.commitIfAccepted(headerId: f.header, windowId: f.window, sessionId: session.id, dragState: newer,
            perform: { commits += 1; return true }))
        #expect(commits == 1)
    }

    @MainActor
    private struct Fixture {
        let window = UUID()
        let scope = SidebarStatusHeaderDragSession()
        let registry: SidebarWorkspaceDragRegistry
        let origin: SidebarDragState
        let header: UUID
        let session: SidebarWorkspaceDragSession
        init(kind: SidebarStatusHeaderKind) {
            let board = NSPasteboard(name: .init("p3-header-scope-\(UUID().uuidString)"))
            registry = SidebarWorkspaceDragRegistry(dragPasteboardProvider: { board })
            origin = SidebarDragState(workspaceDragRegistry: registry)
            header = SidebarStatusHeaderIdentity.uuid(for: kind)
            session = origin.beginDragging(tabId: header)
            scope.began(windowId: window, session: session)
        }
    }
}
