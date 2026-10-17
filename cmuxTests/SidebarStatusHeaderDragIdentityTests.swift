import AppKit
import CmuxFoundation
import CmuxSidebar
import CmuxWorkspaces
import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SidebarStatusHeaderDragIdentityTests {
    private static let kinds: [SidebarStatusHeaderKind] = [.statusesArea, .statusGroup("parked")]
    private static let list = WorkspaceStatusList(entries: [WorkspaceStatusEntry(id: "parked", name: "Parked", extends: .todo)], source: .file)

    @Test(arguments: kinds)
    func pasteboardPayloadIsTheHeaderIdentity(_ kind: SidebarStatusHeaderKind) async throws {
        let (controller, container) = await Self.mount(kind: kind)
        defer { controller.dismantleContainerView(container) }
        let writer = try #require(controller.tableView(container.tableView, pasteboardWriterForRow: 0))
        // Exercise the real AppKit writing path, as the existing workspace writer round-trip does.
        let board = NSPasteboard(name: .init("p3-header-payload-\(UUID().uuidString)"))
        #expect(board.writeObjects([writer]))
        let value = SidebarTabDragPayload.pasteboardString(from: board)
        let identity = try #require(SidebarTabDragPayload.workspaceId(fromPasteboardString: value))
        #expect(identity == SidebarStatusHeaderIdentity.uuid(for: kind))
    }

    @Test(arguments: kinds)
    func nativeBeginBranchUsesHeaderIdentityWithoutWriterFallback(_ kind: SidebarStatusHeaderKind) async {
        var began: [UUID] = []
        let (controller, container) = await Self.mount(kind: kind, actions: Self.tableActions(begin: { began.append($0) }))
        let session = NativeSession()
        defer {
            controller.tableView(container.tableView, draggingSession: session, endedAt: .zero, operation: [])
            controller.dismantleContainerView(container)
        }
        controller.tableView(container.tableView, draggingSession: session, willBeginAt: .zero, forRowIndexes: IndexSet(integer: 0))
        #expect(began == [SidebarStatusHeaderIdentity.uuid(for: kind)])
    }

    @Test(arguments: kinds)
    func nativeDragImageBranchDoesNotResolveAWorkspaceOrGroup(_ kind: SidebarStatusHeaderKind) async {
        var resolvedForImage: [UUID] = []
        let (controller, container) = await Self.mount(kind: kind,
            actions: Self.tableActions(moving: { resolvedForImage.append($0); return 1 }))
        let session = NativeSession(enumeratesOneItem: true)
        defer {
            controller.tableView(container.tableView, draggingSession: session, endedAt: .zero, operation: [])
            controller.dismantleContainerView(container)
        }
        controller.tableView(container.tableView, draggingSession: session, willBeginAt: .zero, forRowIndexes: IndexSet(integer: 0))
        #expect(session.enumeratedCount == 1) // Proves execution reached the image enumeration, independently of its identity result.
        #expect(resolvedForImage == [SidebarStatusHeaderIdentity.uuid(for: kind)])
    }

    @Test(arguments: kinds)
    func retainedRowResolverUsesHeaderIdentity(_ kind: SidebarStatusHeaderKind) {
        let row = Self.configuration(kind: kind)
        #expect(SidebarWorkspaceTableController().workspaceIdForDrag(row, actions: nil) == SidebarStatusHeaderIdentity.uuid(for: kind))
    }

    @Test(arguments: kinds)
    func reverseMapUsesOnlyTheCurrentList(_ kind: SidebarStatusHeaderKind) {
        #expect(SidebarStatusHeaderIdentity.kind(forDragId: SidebarStatusHeaderIdentity.uuid(for: kind), list: Self.list) == kind)
    }
    @Test func unknownWorkspaceAndRemovedStatusIdsAreNotHeaders() {
        #expect(SidebarStatusHeaderIdentity.kind(forDragId: UUID(), list: Self.list) == nil)
        #expect(SidebarStatusHeaderIdentity.kind(forDragId: SidebarStatusHeaderIdentity.uuid(forStatusId: "removed"), list: Self.list) == nil)
        #expect(SidebarStatusHeaderIdentity.kind(forDragId: SidebarStatusHeaderIdentity.statusesAreaUUID, list: .cmuxFive) == nil)
    }

    private static func configuration(kind: SidebarStatusHeaderKind) -> SidebarWorkspaceTableRowConfiguration {
        VerticalTabsSidebar.statusHeaderConfiguration(kind: kind, presentation: nil, memberCount: 0, memberIds: [],
            folds: .init(), environment: .init(colorScheme: .light, globalFontMagnificationPercent: 100,
                                              lazyContractProbe: .init()), onToggle: {})
    }
    private static func mount(kind: SidebarStatusHeaderKind, actions: SidebarWorkspaceTableActions? = nil)
        async -> (SidebarWorkspaceTableController, SidebarWorkspaceTableContainerView) {
        _ = NSApplication.shared
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        container.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        controller.apply(rows: [configuration(kind: kind)], actions: actions ?? tableActions(), workspaceIds: [],
                         selectedWorkspaceId: nil, selectedScrollTargetWorkspaceId: nil)
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.common]) { continuation.resume() }
        }
        return (controller, container)
    }

    @MainActor
    private final class NativeSession: NSDraggingSession {
        private let board = NSPasteboard(name: .init("p3-header-\(UUID().uuidString)"))
        private let enumeratesOneItem: Bool
        private(set) var enumeratedCount = 0
        init(enumeratesOneItem: Bool = false) { self.enumeratesOneItem = enumeratesOneItem; super.init() }
        override var draggingSequenceNumber: Int { 53 }
        override var draggingPasteboard: NSPasteboard { board }
        override func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?,
            classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
            using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
            guard enumeratesOneItem else { return }
            var stop = ObjCBool(false)
            enumeratedCount += 1
            block(NSDraggingItem(pasteboardWriter: NSPasteboardItem()), 0, &stop)
        }
    }

    private static func tableActions(begin: @escaping (UUID) -> Void = { _ in }, moving: @escaping (UUID) -> Int = { _ in 1 }) -> SidebarWorkspaceTableActions {
        SidebarWorkspaceTableActions(
            attachScrollView: { _ in }, closeWorkspace: { _ in }, createWorkspaceAtEnd: {}, createEmptyWorkspaceGroup: {},
            beginWorkspaceDrag: begin, movingWorkspaceCount: moving, endWorkspaceDrag: {}, isValidWorkspaceDrag: { true },
            updateWorkspaceDrag: { _, _, _ in nil }, performWorkspaceDrop: { _, _, _ in false },
            commitWorkspaceDropPlan: { _ in false }, clearWorkspaceDropIndicator: {}, currentDropIndicator: { nil },
            currentDropIndicatorScope: { .raw }, canPerformBonsplitAction: { _, _ in false },
            moveBonsplitToExistingWorkspace: { _, _ in false }, moveBonsplitToNewWorkspace: { _, _ in nil },
            didMoveBonsplitToWorkspace: { _ in }, updateDragAutoscroll: {},
            setBonsplitDropTargetCollectionActive: { _ in }, setBonsplitDropIndicator: { _ in }
        )
    }
}
