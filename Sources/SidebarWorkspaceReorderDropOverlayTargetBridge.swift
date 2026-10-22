import Foundation

@MainActor
final class SidebarWorkspaceReorderDropOverlayTargetBridge {
    private let views = NSHashTable<SidebarWorkspaceReorderDropView>.weakObjects()
    private var targets: [SidebarWorkspaceReorderDropOverlayTarget] = []
    /// The rows last measured for this overlay; a dragged tab's landing is planned against them. // (#cm-110.10)
    var currentTargets: [SidebarWorkspaceReorderDropOverlayTarget] { targets } // (#cm-110.10)

    func attach(_ view: SidebarWorkspaceReorderDropView) {
        views.add(view)
        view.targets = targets
    }

    func updateTargets(_ targets: [SidebarWorkspaceReorderDropOverlayTarget]) {
        self.targets = targets
        for view in views.allObjects {
            view.targets = targets
            view.targetsDidUpdate()
        }
    }
}
