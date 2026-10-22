import AppKit
import Bonsplit
import CmuxFoundation

@MainActor
final class SidebarBonsplitTabWorkspaceDropView: NSView {
    private static let pasteboardType = NSPasteboard.PasteboardType(BonsplitTabDragPayload.typeIdentifier)

    private struct PendingDrop {
        let requestId: UInt64
        let point: CGPoint
        let transfer: BonsplitTabDragPayload.Transfer
    }

    var targetBridge: SidebarBonsplitTabWorkspaceDropOverlay.TargetBridge?
    var canPerformAction: (SidebarDropPlanner.WorkspaceDropAction, BonsplitTabDragPayload.Transfer) -> Bool = { _, _ in false }
    var updateAutoscroll: () -> Void = {}
    var setWorkspaceDropTargetCollectionActive: (Bool) -> Void = { _ in }
    var setDropIndicator: (SidebarDropIndicator?) -> Void = { _ in }
    var performExistingWorkspaceMove: (UUID, BonsplitTabDragPayload.Transfer) -> Bool = { _, _ in false }
    var performNewWorkspaceMove: (Int, SidebarDropIndicator, BonsplitTabDragPayload.Transfer) -> Bool = { _, _, _ in false }
    /// Asks the status-group drop plan where a new workspace would land at a point; `true` limits it to a status group's header. // (#cm-110.10)
    var resolveStatusLanding: (CGPoint, Bool) -> SidebarTabStatusLanding? = { _, _ in nil } // (#cm-110.10)
    var performNewWorkspaceLandingMove: (SidebarTabStatusLanding, BonsplitTabDragPayload.Transfer) -> Bool = { _, _ in false } // (#cm-110.10)
    var landingPaintUpdate: (SidebarTabStatusLanding) -> SidebarWorkspaceTableReorderDropUpdate? = { _ in nil } // (#cm-110.10)
    var paintLandingUpdate: (SidebarWorkspaceTableReorderDropUpdate) -> Void = { _ in } // (#cm-110.10)
    let ownershipFeedback = SurfaceDropFeedback()
    private var isRequestingWorkspaceDropTargets = false
    private var workspaceDropTargetRequestId: UInt64 = 0
    private var pendingDrop: PendingDrop?
    /// What a pointer means for a dragged tab: the planner's action, or a landing the status-group plan decided. // (#cm-110.10)
    private enum Resolution { // (#cm-110.10)
        case action(SidebarDropPlanner.WorkspaceDropAction) // (#cm-110.10)
        case landing(SidebarTabStatusLanding) // (#cm-110.10)
        /// What `canPerformAction` is asked: a landing is a new workspace made from the tab. // (#cm-110.10)
        var admissionAction: SidebarDropPlanner.WorkspaceDropAction { // (#cm-110.10)
            switch self { // (#cm-110.10)
            case .action(let action): return action // (#cm-110.10)
            case .landing(let landing): return .newWorkspace(insertionIndex: 0, indicator: landing.indicator) // (#cm-110.10)
            } // (#cm-110.10)
        } // (#cm-110.10)
    } // (#cm-110.10)

    private var targets: SidebarDropPlanner.OrderedWorkspaceDropTargets {
        targetBridge?.targets ?? SidebarDropPlanner.OrderedWorkspaceDropTargets([])
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func draggingEnded(_ sender: any NSDraggingInfo) { ownershipFeedback.clear() }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil { ownershipFeedback.clear() }
        super.viewWillMove(toSuperview: newSuperview)
    }

    /// Retires drag state before a retained presentation is hidden or disconnected.
    func suspendPresentation() {
        ownershipFeedback.clear()
        pendingDrop = nil
        isRequestingWorkspaceDropTargets = false
        setWorkspaceDropTargetCollectionActive(false)
        setDropIndicator(nil)
        targetBridge?.clearTargets()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([Self.pasteboardType])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        shouldCaptureHitTest() ? super.hitTest(point) : nil
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateWorkspaceDropTargetCollection(sender, isActive: true)
        return updateDrag(sender, phase: "entered")
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateWorkspaceDropTargetCollection(sender, isActive: true)
        return updateDrag(sender, phase: "updated")
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        ownershipFeedback.clear()
        guard pendingDrop == nil else {
            completeOrClearPendingDropAfterDragTeardown()
            setDropIndicator(nil)
            return
        }
        updateWorkspaceDropTargetCollection(sender, isActive: false)
#if DEBUG
        dlog("sidebar.workspaceDropOverlay.exited clear=1")
#endif
        setDropIndicator(nil)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let action = action(for: sender)
        let accepted = acceptedTransfer(sender, action: action) != nil || pendingTransfer(sender) != nil
#if DEBUG
        dlog(
            "sidebar.workspaceDropOverlay.prepare accepted=\(accepted ? 1 : 0) " +
            "action=\(debugActionDescription(action))"
        )
#endif
        return accepted
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { ownershipFeedback.clear() }
        let action = action(for: sender)
        if let action, let transfer = acceptedTransfer(sender, action: action) {
            let moved = perform(action: action, transfer: transfer)
            if moved {
                AppDelegate.shared?.finishAcceptedBonsplitTabDrop(
                    from: sender.draggingPasteboard
                )
            }
            pendingDrop = nil
            updateWorkspaceDropTargetCollection(sender, isActive: false)
            setDropIndicator(nil)
#if DEBUG
            dlog(
                "sidebar.workspaceDropOverlay.perform moved=\(moved ? 1 : 0) " +
                "action=\(debugActionDescription(action))"
            )
#endif
            return moved
        }

        if let transfer = pendingTransfer(sender) {
            pendingDrop = PendingDrop(
                requestId: workspaceDropTargetRequestId,
                point: localPoint(sender),
                transfer: transfer
            )
            AppDelegate.shared?.finishAcceptedBonsplitTabDrop(
                from: sender.draggingPasteboard
            )
#if DEBUG
            dlog("sidebar.workspaceDropOverlay.perform pendingTargets=1")
#endif
            return true
        }

        updateWorkspaceDropTargetCollection(sender, isActive: false)
        setDropIndicator(nil)
#if DEBUG
        dlog(
            "sidebar.workspaceDropOverlay.perform moved=0 reason=notAccepted " +
            "action=\(debugActionDescription(action))"
        )
#endif
        return false
    }

    func performPendingDropIfPossible() {
        guard let pendingDrop,
              pendingDrop.requestId == workspaceDropTargetRequestId,
              isRequestingWorkspaceDropTargets,
              !targets.isEmpty else {
            return
        }
        self.pendingDrop = nil
        defer {
            updateWorkspaceDropTargetCollection(nil, isActive: false)
            setDropIndicator(nil)
        }

        guard let action = resolution(at: pendingDrop.point), // (#cm-110.10)
              canPerformAction(action.admissionAction, pendingDrop.transfer) else { // (#cm-110.10)
#if DEBUG
            dlog("sidebar.workspaceDropOverlay.performPending moved=0 reason=notAccepted")
#endif
            return
        }

        let moved = perform(action: action, transfer: pendingDrop.transfer)
#if DEBUG
        dlog(
            "sidebar.workspaceDropOverlay.performPending moved=\(moved ? 1 : 0) " +
            "action=\(debugActionDescription(action))"
        )
#endif
    }

    func clearPendingDrop() {
        ownershipFeedback.clear()
        pendingDrop = nil
        isRequestingWorkspaceDropTargets = false
        workspaceDropTargetRequestId &+= 1
    }

    func clearPendingDropIfIdle() {
        guard !isRequestingWorkspaceDropTargets else { return }
        clearPendingDrop()
    }

    private func perform(
        action resolution: Resolution, // (#cm-110.10)
        transfer: BonsplitTabDragPayload.Transfer
    ) -> Bool {
        switch resolution { // (#cm-110.10)
        case .landing(let landing): return performNewWorkspaceLandingMove(landing, transfer) // (#cm-110.10)
        case .action(.existingWorkspace(let workspaceId)): // (#cm-110.10)
            return performExistingWorkspaceMove(workspaceId, transfer)
        case .action(.newWorkspace(let insertionIndex, let indicator)): // (#cm-110.10)
            return performNewWorkspaceMove(insertionIndex, indicator, transfer)
        }
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        ownershipFeedback.clear()
        guard pendingDrop == nil else {
            completeOrClearPendingDropAfterDragTeardown()
            setDropIndicator(nil)
            return
        }
        updateWorkspaceDropTargetCollection(sender, isActive: false)
#if DEBUG
        dlog("sidebar.workspaceDropOverlay.concluded clear=1")
#endif
        setDropIndicator(nil)
    }

    private func updateDrag(_ sender: any NSDraggingInfo, phase: String) -> NSDragOperation {
        let action = action(for: sender)
        var plannerAction: SidebarDropPlanner.WorkspaceDropAction? // (#cm-110.10)
        if case .action(let planned)? = action { plannerAction = planned } // (#cm-110.10)
        updateOwnershipFeedback(action: plannerAction, pasteboard: sender.draggingPasteboard) // (#cm-110.10)
        if isRequestingWorkspaceDropTargets,
           targets.isEmpty,
           BonsplitTabDragPayload.transfer(
               from: sender.draggingPasteboard,
               registry: AppDelegate.shared?.tabDragTransferRegistry
           ) != nil {
            setDropIndicator(nil)
#if DEBUG
            dlog("sidebar.workspaceDropOverlay.\(phase) accepted=1 pendingTargets=1")
#endif
            return .move
        }
        guard acceptedTransfer(sender, action: action) != nil, let action else {
            setDropIndicator(nil)
#if DEBUG
            dlog(
                "sidebar.workspaceDropOverlay.\(phase) accepted=0 clear=1 " +
                "action=\(debugActionDescription(action))"
            )
#endif
            return []
        }

        updateAutoscroll()
        switch action {
        case .landing(let landing): // (#cm-110.10)
            if let update = landingPaintUpdate(landing) { paintLandingUpdate(update) } else { setDropIndicator(landing.indicator) } // (#cm-110.10)
        case .action(.newWorkspace(_, let indicator)): // (#cm-110.10)
            setDropIndicator(indicator)
        case .action(.existingWorkspace): // (#cm-110.10)
            setDropIndicator(nil)
        }

#if DEBUG
        dlog(
            "sidebar.workspaceDropOverlay.\(phase) accepted=1 " +
            "action=\(debugActionDescription(action))"
        )
#endif
        return .move
    }

    private func completeOrClearPendingDropAfterDragTeardown() {
        completeOrClearPendingDropAfterDragTeardown(remainingFrameWaits: 3)
    }

    private func completeOrClearPendingDropAfterDragTeardown(remainingFrameWaits: Int) {
        let requestId = workspaceDropTargetRequestId
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.pendingDrop?.requestId == requestId else {
                return
            }

            if self.targets.isEmpty, remainingFrameWaits > 0 {
                self.completeOrClearPendingDropAfterDragTeardown(
                    remainingFrameWaits: remainingFrameWaits - 1
                )
                return
            }

            self.performPendingDropIfPossible()
            guard self.pendingDrop?.requestId == requestId else { return }

            self.clearPendingDrop()
            self.setWorkspaceDropTargetCollectionActive(false)
            self.setDropIndicator(nil)
#if DEBUG
            dlog("sidebar.workspaceDropOverlay.pendingTeardown clear=1")
#endif
        }
    }

    private func updateWorkspaceDropTargetCollection(
        _ sender: (any NSDraggingInfo)?,
        isActive: Bool
    ) {
        let pasteboard = sender?.draggingPasteboard ?? NSPasteboard(name: .drag)
        let shouldRequestTargets = isActive && BonsplitTabDragPayload.transfer(
            from: pasteboard,
            registry: AppDelegate.shared?.tabDragTransferRegistry
        ) != nil
        if !shouldRequestTargets {
            pendingDrop = nil
        }
        if shouldRequestTargets, !isRequestingWorkspaceDropTargets {
            workspaceDropTargetRequestId &+= 1
        }
        isRequestingWorkspaceDropTargets = shouldRequestTargets
        setWorkspaceDropTargetCollectionActive(shouldRequestTargets)
    }

    private func acceptedTransfer(
        _ sender: any NSDraggingInfo,
        action: Resolution? // (#cm-110.10)
    ) -> BonsplitTabDragPayload.Transfer? {
        let pasteboard = sender.draggingPasteboard
        guard pasteboard.types?.contains(Self.pasteboardType) == true,
              let transfer = BonsplitTabDragPayload.transfer(
                  from: pasteboard,
                  registry: AppDelegate.shared?.tabDragTransferRegistry
              ),
              let action,
              canPerformAction(action.admissionAction, transfer) else { // (#cm-110.10)
            return nil
        }
        return transfer
    }

    private func pendingTransfer(_ sender: any NSDraggingInfo) -> BonsplitTabDragPayload.Transfer? {
        guard isRequestingWorkspaceDropTargets, targets.isEmpty else { return nil }
        return BonsplitTabDragPayload.transfer(
            from: sender.draggingPasteboard,
            registry: AppDelegate.shared?.tabDragTransferRegistry
        )
    }

    private func action(for sender: any NSDraggingInfo) -> Resolution? { // (#cm-110.10)
        resolution(at: localPoint(sender)) // (#cm-110.10)
    }

    /// The planner decides "into this workspace" versus "new workspace" from the row's edge bands; only a new-workspace // (#cm-110.10)
    /// point, or any point on a status group's header, is asked for a landing from the status-group drop plan. // (#cm-110.10)
    private func resolution(at point: CGPoint) -> Resolution? { // (#cm-110.10)
        guard let base = SidebarDropPlanner().workspaceAction(for: point, targets: targets) else { return nil } // (#cm-110.10)
        let headersOnly: Bool // (#cm-110.10)
        switch base { // (#cm-110.10)
        case .existingWorkspace: headersOnly = true // (#cm-110.10)
        case .newWorkspace: headersOnly = false // (#cm-110.10)
        } // (#cm-110.10)
        if let landing = resolveStatusLanding(point, headersOnly) { return .landing(landing) } // (#cm-110.10)
        return .action(base) // (#cm-110.10)
    } // (#cm-110.10)

    private func shouldCaptureHitTest() -> Bool {
        let eventType = NSApp.currentEvent?.type
        guard WindowInputRoutingContext.allowsWorkspaceDropOverlayHitTesting(eventType: eventType) else {
            return false
        }
        guard BonsplitTabDragPayload.transfer(
            from: NSPasteboard(name: .drag),
            registry: AppDelegate.shared?.tabDragTransferRegistry
        ) != nil else { return false }
        return true
    }

    private func localPoint(_ sender: any NSDraggingInfo) -> CGPoint {
        convert(sender.draggingLocation, from: nil)
    }

#if DEBUG // (#cm-110.10)
    /// Runs the pointer through the same action, admission and perform steps a real drop takes, minus AppKit's dragging info. // (#cm-110.10)
    func debugDrop(point: CGPoint, transfer: BonsplitTabDragPayload.Transfer) -> (accepted: Bool, performed: Bool, indicator: SidebarDropIndicator?, paint: SidebarWorkspaceTableReorderDropUpdate?) { // (#cm-110.10)
        defer { setDropIndicator(nil) } // (#cm-110.10)
        guard let action = resolution(at: point), // (#cm-110.10)
              canPerformAction(action.admissionAction, transfer) else { return (false, false, nil, nil) } // (#cm-110.10)
        var indicator: SidebarDropIndicator? // (#cm-110.10)
        var paint: SidebarWorkspaceTableReorderDropUpdate? // (#cm-110.10)
        switch action { // (#cm-110.10)
        case .landing(let landing): indicator = landing.indicator; paint = landingPaintUpdate(landing) // (#cm-110.10)
        case .action(.newWorkspace(_, let line)): indicator = line // (#cm-110.10)
        case .action(.existingWorkspace): break // (#cm-110.10)
        } // (#cm-110.10)
        return (true, perform(action: action, transfer: transfer), indicator, paint) // (#cm-110.10)
    } // (#cm-110.10)
#endif // (#cm-110.10)

#if DEBUG
    private func debugActionDescription(_ action: Resolution?) -> String { // (#cm-110.10)
        guard let action else { return "nil" }
        switch action {
        case .landing(let landing): // (#cm-110.10)
            return "landing:indicator=\(debugIndicatorDescription(landing.indicator))" // (#cm-110.10)
        case .action(.existingWorkspace(let workspaceId)): // (#cm-110.10)
            return "existing:\(debugShortId(workspaceId))"
        case .action(.newWorkspace(let insertionIndex, let indicator)): // (#cm-110.10)
            return "new:index=\(insertionIndex),indicator=\(debugIndicatorDescription(indicator))"
        }
    }

    private func debugIndicatorDescription(_ indicator: SidebarDropIndicator) -> String {
        let target = indicator.tabId.map(debugShortId) ?? "end"
        let edge = indicator.edge == .top ? "top" : "bottom"
        return "\(target):\(edge)"
    }

    private func debugShortId(_ id: UUID) -> String {
        String(id.uuidString.prefix(5))
    }
#endif
}
