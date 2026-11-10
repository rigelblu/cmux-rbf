import AppKit
import CmuxFoundation
import CmuxNotifications
import CmuxSettings
import CmuxSidebar
import CmuxUpdater
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

    @Test func pinnedAreaRefusesPasteboardWriter() async throws { // (#cm-110.5)
        let (controller, container) = await Self.mount(kind: .pinnedArea)
        defer { controller.dismantleContainerView(container) }
        let writer = controller.tableView(container.tableView, pasteboardWriterForRow: 0)
        #expect(writer == nil, "AppKit must refuse drag writer for .pinnedArea")
    }

    @Test func pinnedAreaRefusesDragInSharedDropAdapter() async throws { // (#cm-110.5)
        try await AppContextSerialGate.withExclusiveAppContext {
            let restoreStatusList = try SidebarNestedStatusDropFixture.installStatusListInUse() // (#cm-110.5) the app's real store, not a test-only hook
            defer { restoreStatusList() }
            let pinUUID = SidebarStatusHeaderIdentity.pinnedAreaUUID
            let sidebar = VerticalTabsSidebar(
                updateViewModel: UpdateStateModel(), fileExplorerState: FileExplorerState(), featureFlags: CmuxFeatureFlags(),
                sidebarUnread: SidebarUnreadModel(), titlebarControlsLayoutModel: TitlebarControlsLayoutModel(),
                windowId: UUID(), onSendFeedback: {}, onToggleSidebar: {}, onNewTab: {},
                observedWindowReference: WeakWindowReference(), chromeBackgroundColor: .black,
                selection: .constant(.tabs), selectedTabIds: .constant([]), lastSidebarSelectionIndex: .constant(nil),
                sidebarRenderWorkerClient: .constant(nil)
            )
            #expect(sidebar.activateStatusHeaderDrag(pinUUID) == nil, "Shared drop adapter must refuse activateStatusHeaderDrag for pinnedArea")
        }
    }

    @Test func pinnedAreaRefusesToBeginAStatusAwareDrag() async throws { // (#cm-110.5)
        try await AppContextSerialGate.withExclusiveAppContext {
            let restoreStatusList = try SidebarNestedStatusDropFixture.installStatusListInUse() // (#cm-110.5) the app's real store, not a test-only hook
            defer { restoreStatusList() }
            let windowId = UUID()
            let sidebar = VerticalTabsSidebar(
                updateViewModel: UpdateStateModel(), fileExplorerState: FileExplorerState(), featureFlags: CmuxFeatureFlags(),
                sidebarUnread: SidebarUnreadModel(), titlebarControlsLayoutModel: TitlebarControlsLayoutModel(),
                windowId: windowId, onSendFeedback: {}, onToggleSidebar: {}, onNewTab: {},
                observedWindowReference: WeakWindowReference(), chromeBackgroundColor: .black,
                selection: .constant(.tabs), selectedTabIds: .constant([]), lastSidebarSelectionIndex: .constant(nil),
                sidebarRenderWorkerClient: .constant(nil)
            )
            // A drag already in flight, recorded as the source: a refused begin must leave both as they are.
            let other = UUID()
            let session = sidebar.dragState.beginDragging(tabId: other)
            SidebarStatusGroupDragSource.shared.began(windowId: windowId, session: session, rowId: .workspace(other))
            defer { sidebar.dragState.finishDrag() }
            sidebar.beginStatusAwareWorkspaceDrag(SidebarStatusHeaderIdentity.pinnedAreaUUID)
            #expect(sidebar.dragState.draggedTabId == other, "The refused begin starts no session: the dragged id is still the earlier drag's")
            #expect(SidebarStatusGroupDragSource.shared.source(windowId: windowId, workspaceId: other, sessionId: session.id, dragState: sidebar.dragState) != nil,
                "The refused begin records no source: the earlier drag's record is still the latest")
        }
    }

    @Test func pinnedAreaRefusesBeginSidebarNativeDrag() async throws { // (#cm-110.5)
        try await AppContextSerialGate.withExclusiveAppContext {
            let restoreStatusList = try SidebarNestedStatusDropFixture.installStatusListInUse() // (#cm-110.5) the app's real store, not a test-only hook
            defer { restoreStatusList() }
            let key = BetaFeaturesCatalogSection().workspaceTodoControls.userDefaultsKey
            let prev = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.set(true, forKey: key)
            defer { UserDefaults.standard.set(prev, forKey: key) }

            let sidebar = VerticalTabsSidebar(
                updateViewModel: UpdateStateModel(), fileExplorerState: FileExplorerState(), featureFlags: CmuxFeatureFlags(),
                sidebarUnread: SidebarUnreadModel(), titlebarControlsLayoutModel: TitlebarControlsLayoutModel(),
                windowId: UUID(), onSendFeedback: {}, onToggleSidebar: {}, onNewTab: {},
                observedWindowReference: WeakWindowReference(), chromeBackgroundColor: .black,
                selection: .constant(.tabs), selectedTabIds: .constant([]), lastSidebarSelectionIndex: .constant(nil),
                sidebarRenderWorkerClient: .constant(nil)
            )
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
            window.contentView = view
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            let began = sidebar.beginSidebarNativeDrag(
                dragId: SidebarStatusHeaderIdentity.pinnedAreaUUID,
                sourceView: view,
                event: event,
                draggingFrame: NSRect(x: 0, y: 0, width: 100, height: 30),
                dragImage: NSImage(size: NSSize(width: 10, height: 10))
            )
            #expect(began == false, "Pinned header must refuse beginSidebarNativeDrag")
        }
    }
    @Test func unknownWorkspaceAndRemovedStatusIdsAreNotHeaders() {
        #expect(SidebarStatusHeaderIdentity.kind(forDragId: UUID(), list: Self.list) == nil)
        #expect(SidebarStatusHeaderIdentity.kind(forDragId: SidebarStatusHeaderIdentity.uuid(forStatusId: "removed"), list: Self.list) == nil)
        #expect(SidebarStatusHeaderIdentity.kind(forDragId: SidebarStatusHeaderIdentity.statusesAreaUUID, list: .cmuxFive) == nil)
    }

    private static func configuration(kind: SidebarStatusHeaderKind) -> SidebarWorkspaceTableRowConfiguration {
        VerticalTabsSidebar.statusHeaderConfiguration(kind: kind, presentation: nil, memberCount: 0, memberIds: [],
            folds: .init(), environment: .init(colorScheme: .light, globalFontMagnificationPercent: 100,
                                              lazyContractProbe: .init()),
            sidebarFontScale: 1.0, // (cm-128.16)
            onToggle: {})
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
