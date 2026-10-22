import AppKit
import Bonsplit
import CmuxFoundation
import SwiftUI

@MainActor
struct SidebarBonsplitTabWorkspaceDropOverlay: NSViewRepresentable {
    @MainActor
    final class TargetBridge {
        weak var view: SidebarBonsplitTabWorkspaceDropView?
        var targets = SidebarDropPlanner.OrderedWorkspaceDropTargets([])

        func updateTargets(_ targets: [SidebarDropPlanner.WorkspaceDropTarget]) {
            self.targets = SidebarDropPlanner.OrderedWorkspaceDropTargets(targets)
            guard !self.targets.isEmpty else { return }
            DispatchQueue.main.async { [weak view] in
                view?.performPendingDropIfPossible()
            }
        }

        func clearTargets() {
            targets = SidebarDropPlanner.OrderedWorkspaceDropTargets([])
        }
    }

    struct TargetWriter: View {
        let targetBridge: TargetBridge
        let targets: [SidebarDropPlanner.WorkspaceDropTarget]

        var body: some View {
            Color.clear
                .onAppear {
                    targetBridge.updateTargets(targets)
                }
                .onChange(of: targets) { _, newTargets in
                    targetBridge.updateTargets(newTargets)
                }
                .onDisappear {
                    targetBridge.clearTargets()
                }
        }
    }

    let currentSelectedTabId: () -> UUID?
    let sidebarIndexForTabId: (UUID) -> Int?
    let moveToExistingWorkspace: (UUID, BonsplitTabDragPayload.Transfer) -> Bool
    let moveToNewWorkspace: (Int, BonsplitTabDragPayload.Transfer) -> UUID?
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    @Binding var dropIndicator: SidebarDropIndicator?
    let updateAutoscroll: () -> Void
    let setWorkspaceDropTargetCollectionActive: (Bool) -> Void
    let isWorkspaceDropTargetCollectionActive: Bool
    let targetBridge: TargetBridge
    /// Where the status-group drop plan would land a new workspace made from the tab; the AppKit sidebar wires the same four. // (#cm-110.10)
    var resolveStatusLanding: (CGPoint, Bool) -> SidebarTabStatusLanding? = { _, _ in nil } // (#cm-110.10)
    var moveToNewWorkspaceAtLanding: (SidebarTabStatusLanding, BonsplitTabDragPayload.Transfer) -> UUID? = { _, _ in nil } // (#cm-110.10)
    var landingPaintUpdate: (SidebarTabStatusLanding) -> SidebarWorkspaceTableReorderDropUpdate? = { _ in nil } // (#cm-110.10)
    var paintLandingUpdate: (SidebarWorkspaceTableReorderDropUpdate) -> Void = { _ in } // (#cm-110.10)

    func makeNSView(context: Context) -> SidebarBonsplitTabWorkspaceDropView {
        SidebarBonsplitTabWorkspaceDropView()
    }

    func updateNSView(_ nsView: SidebarBonsplitTabWorkspaceDropView, context: Context) {
        targetBridge.view = nsView
        nsView.targetBridge = targetBridge
        nsView.canPerformAction = { action, transfer in
            guard let app = AppDelegate.shared else {
                return false
            }
            switch action {
            case .existingWorkspace(let workspaceId):
                return app.canMoveBonsplitTab(tabId: transfer.tab.id, toWorkspace: workspaceId)
            case .newWorkspace:
                return app.canMoveBonsplitTabToNewWorkspace(tabId: transfer.tab.id)
            }
        }
        nsView.updateAutoscroll = updateAutoscroll
        nsView.setWorkspaceDropTargetCollectionActive = setWorkspaceDropTargetCollectionActive
        nsView.setDropIndicator = { indicator in
            dropIndicator = indicator
        }
        nsView.performExistingWorkspaceMove = { workspaceId, transfer in
            guard moveToExistingWorkspace(workspaceId, transfer) else { return false }
            selectedTabIds = [workspaceId]
            syncSidebarSelection(preferredSelectedTabId: workspaceId)
            return true
        }
        nsView.resolveStatusLanding = resolveStatusLanding // (#cm-110.10)
        nsView.landingPaintUpdate = landingPaintUpdate // (#cm-110.10)
        nsView.paintLandingUpdate = paintLandingUpdate // (#cm-110.10)
        nsView.performNewWorkspaceLandingMove = { landing, transfer in // (#cm-110.10)
            guard let destinationWorkspaceId = moveToNewWorkspaceAtLanding(landing, transfer) else { return false } // (#cm-110.10)
            selectedTabIds = [destinationWorkspaceId] // (#cm-110.10)
            syncSidebarSelection(preferredSelectedTabId: destinationWorkspaceId) // (#cm-110.10)
            return true // (#cm-110.10)
        } // (#cm-110.10)
        nsView.performNewWorkspaceMove = { insertionIndex, _, transfer in
            guard let destinationWorkspaceId = moveToNewWorkspace(insertionIndex, transfer) else { return false }
            selectedTabIds = [destinationWorkspaceId]
            syncSidebarSelection(preferredSelectedTabId: destinationWorkspaceId)
            return true
        }
        if !isWorkspaceDropTargetCollectionActive, targetBridge.targets.isEmpty {
            nsView.clearPendingDropIfIdle()
        }
        if !targetBridge.targets.isEmpty {
            DispatchQueue.main.async { [weak nsView] in
                nsView?.performPendingDropIfPossible()
            }
        }
    }

    private func syncSidebarSelection(preferredSelectedTabId: UUID? = nil) {
        let selectedId = preferredSelectedTabId ?? currentSelectedTabId()
        if let selectedId {
            lastSidebarSelectionIndex = sidebarIndexForTabId(selectedId)
        } else {
            lastSidebarSelectionIndex = nil
        }
    }
}
