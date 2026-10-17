import AppKit
import CmuxFoundation
import CmuxSidebar
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
struct SidebarStatusGroupDragSourceTests {
    enum Role: CaseIterable, Sendable { case workspaceAnchor, groupHeader, emptyGroupHeader, selectedHeaders }
    enum NativeBranch: CaseIterable, Sendable { case writer, noWriter, provisionalWriter }

    @Test(arguments: Role.allCases, NativeBranch.allCases)
    func actualNativeSourceRowsSurvivePromotionAndProvisionalReconstruction(_ role: Role, _ branch: NativeBranch) async throws {
        let f = await Fixture.mount(role)
        let session = NativeSession(board: f.board)
        var writers: [SidebarWorkspaceDragPasteboardWriter] = []
        defer {
            if branch == .provisionalWriter {
                writers.last?.tableView(f.container.tableView, draggingSession: session, endedAt: .zero, operation: [])
            } else {
                f.controller.tableView(f.container.tableView, draggingSession: session, endedAt: .zero, operation: [])
            }
            f.close()
        }
        let index = role == .selectedHeaders && branch != .noWriter ? 1 : 0
        let expected = f.rows[index]
        if branch != .noWriter {
            for row in f.rows.indices {
                let writer = try #require(f.controller.tableView(f.container.tableView, pasteboardWriterForRow: row) as? SidebarWorkspaceDragPasteboardWriter)
                writers.append(writer)
            }
            let writer = try #require(writers.last)
            #expect(f.board.writeObjects([writer]))
            #expect(SidebarTabDragPayload.workspaceId(fromPasteboardString: SidebarTabDragPayload.pasteboardString(from: f.board)) == expected.payload)
            if branch == .provisionalWriter {
                f.controller.dismantleContainerView(f.container)
                try #require(f.container.tableView.delegate === writer) // The actual retained-writer fallback is selected.
                writer.tableView(f.container.tableView, draggingSession: session, willBeginAt: .zero, forRowIndexes: IndexSet(f.rows.indices))
            } else {
                f.controller.tableView(f.container.tableView, draggingSession: session, willBeginAt: .zero, forRowIndexes: IndexSet(f.rows.indices))
            }
        } else {
            f.controller.tableView(f.container.tableView, draggingSession: session, willBeginAt: .zero, forRowIndexes: IndexSet(f.rows.indices))
        }
        try #require(f.forwardedRows.count == 1 && f.forwardedRows.first! == expected.rowId)
        let token = try #require(f.state.currentWorkspaceDragSessionId)
        try #require(f.state.currentWorkspaceDragId == expected.payload)
        let captured = try #require(f.scope.source(windowId: f.windowId, workspaceId: expected.payload, sessionId: token, dragState: f.state))
        #expect(captured.rowId == expected.rowId)
        #expect(captured.kind == expected.kind)
    }

    @Test(arguments: Role.allCases)
    func actualPointerThresholdCarriesTheCandidateRowDespiteAnIdenticalAnchorPayload(_ role: Role) throws {
        let f = Fixture(role)
        defer { f.close() }
        let expected = f.rows.last!
        let pointer = SidebarPointerInteractionMonitor()
        for (index, row) in f.rows.enumerated() {
            pointer.updateFrame(CGRect(x: 0, y: CGFloat(index) * 50, width: 240, height: 48), for: row.rowId, workspaceId: row.payload)
        }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 320))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.systemBlue.cgColor
        f.window.contentView = host // Pointer tracking has a real non-control surface, rather than the native table.
        let monitor = SidebarWorkspaceDragSourceMonitor()
        monitor.attach(to: host)
        var attempts = 0
        var forwarded: SidebarWorkspaceDragCandidate?
        monitor.start(resolveCandidate: { pointer.workspaceDragCandidate(at: $0) }, onBeginDrag: { candidate, _, _, _, _ in
            attempts += 1; forwarded = candidate
            let session = f.state.beginDragging(tabId: candidate.workspaceId)
            f.scope.began(windowId: f.windowId, session: session, rowId: candidate.renderItemId)
            return true
        })
        defer { monitor.stop(); f.state.finishDrag() }
        let y = host.bounds.height - CGFloat(f.rows.count - 1) * 50 - 20
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: y),
            modifierFlags: [], timestamp: 1, windowNumber: f.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let dragged = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 30, y: y - 10),
            modifierFlags: [], timestamp: 2, windowNumber: f.window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
        #expect(monitor.handle(down) === down)
        #expect(monitor.handle(dragged) === dragged)
        try #require(attempts == 1 && forwarded?.workspaceId == expected.payload && forwarded?.renderItemId == expected.rowId)
        let token = try #require(f.state.currentWorkspaceDragSessionId)
        let captured = try #require(f.scope.source(windowId: f.windowId, workspaceId: expected.payload, sessionId: token, dragState: f.state))
        #expect(captured.kind == expected.kind)
    }

    @Test(arguments: [false, true])
    func matchingLiveAndCompletedSessionsRetainTheirActualWorkspaceSourceKind(_ completed: Bool) throws {
        let f = Fixture(.workspaceAnchor); defer { f.close() }
        let row = f.rows[0], session = f.state.beginDragging(tabId: f.rows[0].payload)
        f.scope.began(windowId: f.windowId, session: session, rowId: row.rowId)
        if completed { f.state.finishDrag() }
        let record = try #require(f.scope.source(windowId: f.windowId, workspaceId: row.payload, sessionId: session.id, dragState: f.state))
        #expect(record.kind == .workspace)
        #expect(completed ? f.state.draggedTabId == nil : f.state.draggedTabId == row.payload)
    }

    enum InvalidCapability: CaseIterable, Sendable { case window, token, workspace, newerLive, newerCompleted, missingRow }
    @Test(arguments: InvalidCapability.allCases)
    func invalidOrSupersededSourceCapabilitiesCannotAuthorizeAStatusDrop(_ invalid: InvalidCapability) throws {
        let f = Fixture(.workspaceAnchor); defer { f.close() }
        let row = f.rows[0], session = f.state.beginDragging(tabId: f.rows[0].payload)
        f.scope.began(windowId: f.windowId, session: session, rowId: invalid == .missingRow ? nil : row.rowId)
        let valid = try #require(f.scope.source(windowId: f.windowId, workspaceId: row.payload, sessionId: session.id, dragState: f.state))
        try #require(valid.rowId == (invalid == .missingRow ? nil : row.rowId))
        if invalid == .newerLive || invalid == .newerCompleted {
            let newer = f.state.beginDragging(tabId: row.payload)
            f.scope.began(windowId: f.windowId, session: newer, rowId: row.rowId)
            if invalid == .newerCompleted { f.state.finishDrag() }
        }
        let record = f.scope.source(windowId: invalid == .window ? UUID() : f.windowId,
            workspaceId: invalid == .workspace ? UUID() : row.payload,
            sessionId: invalid == .token ? UUID() : session.id, dragState: f.state)
        if invalid == .missingRow {
            let unknown = try #require(record)
            #expect(unknown.kind == .unknown)
        } else { #expect(record == nil) }
    }

#if DEBUG
    @Test(arguments: Role.allCases)
    func typedDebugSourcesPreserveTheSameConcreteRowKinds(_ role: Role) {
        let f = Fixture(role); defer { f.close() }
        let expected = f.rows.last!
        let items: [SidebarWorkspaceRenderItem] = f.rows.map { row in
            if let group = row.rowId.groupId { return .groupHeader(groupId: group, anchorWorkspaceId: row.payload) }
            return .workspace(workspaceId: row.payload)
        }
        let selector = expected.rowId.groupId.map { "group:\($0.uuidString)" } ?? "workspace:\(expected.payload.uuidString)"
        #expect(VerticalTabsSidebar.workspaceStatusDebugSourceRow(selector, items: items) == expected.rowId)
    }
    @Test(arguments: ["missing", "wrong-kind", "anchor-without-workspace-row"])
    func missingTypedDebugSourcesNeverFallBackToAGroupAnchorWorkspace(_ reason: String) {
        let group = Fixture.group, anchor = Fixture.anchor
        let items: [SidebarWorkspaceRenderItem] = [.groupHeader(groupId: group, anchorWorkspaceId: anchor)]
        let selector: String
        switch reason {
        case "wrong-kind": selector = "workspace:\(group.uuidString)"
        case "anchor-without-workspace-row": selector = "workspace:\(anchor.uuidString)"
        default: selector = "group:\(UUID().uuidString)"
        }
        #expect(VerticalTabsSidebar.workspaceStatusDebugSourceRow(selector, items: items) == nil)
    }
#endif

    private struct Row {
        let rowId: SidebarWorkspaceRenderItemID
        let payload: UUID
        let kind: SidebarStatusGroupDropRules.SourceKind
    }
    private struct Content: View, Equatable { var body: some View { Color.blue.frame(height: 30) } }
    @MainActor
    private final class Fixture {
        static let anchor = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        static let group = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        static let anchorB = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        static let groupB = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let windowId = UUID(), scope = SidebarStatusGroupDragSource()
        let board: NSPasteboard
        let state: SidebarDragState
        let rows: [Row]
        let controller = SidebarWorkspaceTableController()
        let container: SidebarWorkspaceTableContainerView
        let window: NSWindow
        var forwardedRows: [SidebarWorkspaceRenderItemID?] = []
        init(_ role: Role) {
            _ = NSApplication.shared
            let pasteboard = NSPasteboard(name: .init("p4-source-kind-\(UUID().uuidString)"))
            board = pasteboard
            state = SidebarDragState(workspaceDragRegistry: SidebarWorkspaceDragRegistry(dragPasteboardProvider: { pasteboard }))
            switch role {
            case .workspaceAnchor: rows = [.init(rowId: .workspace(Self.anchor), payload: Self.anchor, kind: .workspace)]
            case .groupHeader: rows = [.init(rowId: .group(Self.group), payload: Self.anchor, kind: .workspaceGroupHeader(groupId: Self.group))]
            case .emptyGroupHeader: rows = [.init(rowId: .group(Self.group), payload: Self.group, kind: .workspaceGroupHeader(groupId: Self.group))]
            case .selectedHeaders: rows = [
                .init(rowId: .group(Self.group), payload: Self.anchor, kind: .workspaceGroupHeader(groupId: Self.group)),
                .init(rowId: .group(Self.groupB), payload: Self.anchorB, kind: .workspaceGroupHeader(groupId: Self.groupB))]
            }
            container = controller.makeContainerView()
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 320), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = container
        }
        static func mount(_ role: Role) async -> Fixture {
            let f = Fixture(role)
            let environment = SidebarWorkspaceTableEnvironmentSnapshot(colorScheme: .light, globalFontMagnificationPercent: 100, lazyContractProbe: .init())
            let configurations = f.rows.map { row in
                SidebarWorkspaceTableRowConfiguration(id: row.rowId, workspaceId: row.payload, groupId: row.rowId.groupId,
                    isGroupHeader: row.rowId.groupId != nil, isPinned: false, environment: environment,
                    equivalenceValue: Content(), makeContent: { _, _ in AnyView(Content()) })
            }
            var actions = f.actions()
            actions.workspaceGroupAnchorIdsForDrag = { Dictionary(uniqueKeysWithValues: f.rows.compactMap { row in row.rowId.groupId.map { ($0, row.payload) } }) }
            f.controller.apply(rows: configurations, actions: actions, workspaceIds: f.rows.map(\.payload), selectedWorkspaceId: nil, selectedScrollTargetWorkspaceId: nil)
            await withCheckedContinuation { c in RunLoop.main.perform(inModes: [.common]) { c.resume() } }
            f.container.layoutSubtreeIfNeeded()
            return f
        }
        func close() { state.finishDrag(); controller.dismantleContainerView(container); window.contentView = nil; window.close() }
        func actions() -> SidebarWorkspaceTableActions {
            var actions = SidebarWorkspaceTableActions(attachScrollView: { _ in }, closeWorkspace: { _ in }, createWorkspaceAtEnd: {}, createEmptyWorkspaceGroup: {},
                beginWorkspaceDrag: { [self] id in _ = state.beginDragging(tabId: id) }, movingWorkspaceCount: { _ in 1 }, endWorkspaceDrag: { [self] in state.finishDrag() },
                isValidWorkspaceDrag: { true }, updateWorkspaceDrag: { _, _, _ in nil }, performWorkspaceDrop: { _, _, _ in false },
                commitWorkspaceDropPlan: { _ in false }, clearWorkspaceDropIndicator: {}, currentDropIndicator: { nil }, currentDropIndicatorScope: { .raw },
                canPerformBonsplitAction: { _, _ in false }, moveBonsplitToExistingWorkspace: { _, _ in false }, moveBonsplitToNewWorkspace: { _, _ in nil },
                didMoveBonsplitToWorkspace: { _ in }, updateDragAutoscroll: {}, setBonsplitDropTargetCollectionActive: { _ in }, setBonsplitDropIndicator: { _ in },
                nativeWorkspaceDragLifecycle: SidebarWorkspaceTableActions.NativeWorkspaceDragLifecycle(currentSessionId: { [self] in state.currentWorkspaceDragSessionId },
                    finish: { [self] id, value in state.finishDrag(sessionId: id, capabilityValue: value) }, reclaimSupersededNativeSources: { _ in }))
            actions.beginWorkspaceDragFromRow = { [self] id, row in
                forwardedRows.append(row)
                let session = state.beginDragging(tabId: id)
                scope.began(windowId: windowId, session: session, rowId: row)
            }
            return actions
        }
    }
    private final class NativeSession: NSDraggingSession {
        let board: NSPasteboard
        init(board: NSPasteboard) { self.board = board; super.init() }
        override var draggingSequenceNumber: Int { 749 }
        override var draggingPasteboard: NSPasteboard { board }
        override func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?,
            classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
            using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    }
}
