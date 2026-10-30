import AppKit
import CmuxAppKitSupportUI
import CmuxWorkspaces
import SwiftUI

/// Pure calculation of available vertical space for a popover on a screen.
/// - Parameters:
///   - anchorRect: The anchor view's rect in screen coordinates.
///   - screenVisibleFrame: The visible frame of the target screen.
///   - preferredEdge: The edge on which the popover prefers to open (.minX, .maxX, .minY, .maxY).
///   - margin: Safety margin from screen boundaries (default: 20 pt).
/// - Returns: Available vertical height for popover content.
func availableScreenHeight(
    anchorRect: NSRect,
    screenVisibleFrame: NSRect,
    preferredEdge: NSRectEdge,
    margin: CGFloat = 20
) -> CGFloat {
    SidebarRowSwiftUIPopoverPresenter.availableScreenHeight(
        anchorRect: anchorRect,
        screenVisibleFrame: screenVisibleFrame,
        preferredEdge: preferredEdge,
        margin: margin
    )
}

// MARK: - SwiftUI popover presenter

/// Presents existing SwiftUI popover content (`SidebarWorkspaceStatusPopover`,
/// `SidebarWorkspaceChecklistPopover`) from a pure-AppKit row cell. Popovers
/// sit off the scroll path, so hosting SwiftUI here reuses the legacy views
/// wholesale for exact parity instead of reimplementing them in AppKit.
///
/// Follows `SidebarWorkspaceTodoPopoverHost`'s contract:
/// - No `sizingOptions` on the hosting controller; `contentSize` is driven
///   manually from `fittingSize` (clamped to `minWidth`/`maxHeight`).
/// - Each hidden-to-shown transition bumps the SwiftUI view identity so every
///   open gets fresh view-local state.
/// - The popover window is promoted to key on show so embedded fields and
///   keyboard navigation receive input (`PopoverKeyWindowElevator`).
@MainActor
final class SidebarRowSwiftUIPopoverPresenter: NSObject, NSPopoverDelegate {
#if DEBUG
    static var screenVisibleFrameOverrideForTesting: NSRect?
#endif
    nonisolated static func availableScreenHeight(
        anchorRect: NSRect,
        screenVisibleFrame: NSRect,
        preferredEdge: NSRectEdge,
        margin: CGFloat = 20
    ) -> CGFloat {
        guard screenVisibleFrame.height > 0 else { return .greatestFiniteMagnitude }
        switch preferredEdge {
        case .minX, .maxX:
            return max(0, screenVisibleFrame.height - margin)
        case .minY, .maxY:
            let spaceAbove = screenVisibleFrame.maxY - anchorRect.maxY
            let spaceBelow = anchorRect.minY - screenVisibleFrame.minY
            let bestSpace = max(spaceAbove, spaceBelow)
            return max(0, bestSpace - margin)
        @unknown default:
            return max(0, screenVisibleFrame.height - margin)
        }
    }
    var minWidth: CGFloat = 200
    var maxHeight: CGFloat = 480
    private weak var currentAnchorView: NSView?
    private var currentAnchorRect: NSRect = .zero
    private var currentPreferredEdge: NSRectEdge = .maxX
#if DEBUG
    var popoverForTesting: NSPopover? { popover }
    var contentSizeForTesting: NSSize? { popover?.contentSize }
#endif
    /// Called when AppKit closed the popover out from under the container
    /// (transient click-away, app deactivation) — NOT for programmatic
    /// `close()` calls. Containers use this to write presentation state back.
    var onExternalDismiss: (() -> Void)?

    /// Lazy: cells allocate presenters eagerly, but the hosting machinery
    /// only spins up when a popover actually presents (off the scroll path).
    private lazy var hostingController = NSHostingController(rootView: AnyView(EmptyView()))
    private var popover: NSPopover?
    private var presentationCount = 0
    private var closingProgrammatically = false
    /// Visible refreshes arrive from the table's configure pass (inside a
    /// representable update turn); defer + coalesce them like
    /// `SidebarWorkspaceTodoPopoverHost` does instead of forcing synchronous
    /// hosted-view layout per publisher burst.
    private let visibleUpdateScheduler = CmuxPopoverVisibleUpdateScheduler()
    private var pendingRoot: AnyView?

    var isShown: Bool { popover?.isShown == true }

    func present(
        _ root: AnyView,
        relativeTo rect: NSRect,
        of view: NSView,
        preferredEdge: NSRectEdge
    ) {
        guard view.window != nil else { return }
        let popover = self.popover ?? makePopover()
        guard !popover.isShown else {
            update(root)
            return
        }
        visibleUpdateScheduler.cancel()
        pendingRoot = nil
        presentationCount += 1
        currentAnchorView = view
        currentAnchorRect = rect
        currentPreferredEdge = preferredEdge
        applyRootView(root)
        popover.show(relativeTo: rect, of: view, preferredEdge: preferredEdge)
    }

    /// Live refresh while shown: mutations reach the row through the normal
    /// configure pass, which forwards the fresh content here so open popovers
    /// repaint instead of showing creation-time state. Deferred + coalesced
    /// outside the current update turn.
    func update(_ root: AnyView) {
        guard isShown else { return }
        pendingRoot = root
        visibleUpdateScheduler.schedule { [weak self] in
            guard let self, self.isShown, let root = self.pendingRoot else { return }
            self.pendingRoot = nil
            self.applyRootView(root)
        }
    }

    func close() {
        visibleUpdateScheduler.cancel()
        pendingRoot = nil
        guard let popover, popover.isShown else { return }
        closingProgrammatically = true
        popover.performClose(nil)
    }

    private func applyRootView(_ root: AnyView) {
        hostingController.rootView = AnyView(root.id(presentationCount))
        hostingController.view.invalidateIntrinsicContentSize()
        hostingController.view.layoutSubtreeIfNeeded()
        updateContentSize()
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = hostingController
        popover.delegate = self
        self.popover = popover
        return popover
    }

    private func updateContentSize() {
        let fitting = hostingController.view.fittingSize
        guard fitting.width > 0, fitting.height > 0, let popover else { return }
        let available: CGFloat
        if let currentAnchorView, let window = currentAnchorView.window {
            let winRect = currentAnchorView.convert(currentAnchorRect, to: nil)
            let screenRect = window.convertToScreen(winRect)
            let screen = window.screen ?? NSScreen.main
#if DEBUG
            let screenVisibleFrame = Self.screenVisibleFrameOverrideForTesting ?? (screen?.visibleFrame ?? .zero)
#else
            let screenVisibleFrame = screen?.visibleFrame ?? .zero
#endif
            available = Self.availableScreenHeight(
                anchorRect: screenRect,
                screenVisibleFrame: screenVisibleFrame,
                preferredEdge: currentPreferredEdge
            )
        } else {
            let screen = NSScreen.main
#if DEBUG
            let screenVisibleFrame = Self.screenVisibleFrameOverrideForTesting ?? (screen?.visibleFrame ?? .zero)
#else
            let screenVisibleFrame = screen?.visibleFrame ?? .zero
#endif
            available = Self.availableScreenHeight(
                anchorRect: .zero,
                screenVisibleFrame: screenVisibleFrame,
                preferredEdge: currentPreferredEdge
            )
        }
        let targetHeight = ceil(min(fitting.height, maxHeight, available))
        CmuxPopoverMutation.setContentSize(NSSize(
            width: ceil(max(fitting.width, minWidth)),
            height: max(1, targetHeight)
        ), on: popover)
    }

    func popoverDidShow(_ notification: Notification) {
        let popoverWindow = hostingController.view.window
        PopoverKeyWindowElevator.promoteToKeyIfPossible(popoverWindow)
    }

    func popoverDidClose(_ notification: Notification) {
        visibleUpdateScheduler.cancel()
        pendingRoot = nil
        popover = nil
        // Release the hosted content: the root view's action closures capture
        // the presented workspace strongly, and this presenter lives on a
        // pooled table cell — keeping the last root would retain a closed
        // workspace across cell reuse.
        hostingController.rootView = AnyView(EmptyView())
        let external = !closingProgrammatically
        closingProgrammatically = false
        if external {
            onExternalDismiss?()
        }
        onExternalDismiss = nil
    }
}
