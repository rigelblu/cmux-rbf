import AppKit
import GhosttyKit

// `cm-136.1` reply inline's release gather and pane accessors, split out of
// GhosttyTerminalView.swift. The stored properties stay in the class bodies.

extension GhosttyNSView {
    /// `cm-136.1` — a release that made or changed a selection in an agent
    /// pane brings up the Reply toolbar over it.
    ///
    /// The decision is ``ReplyInlineTrigger``, which runs its checks cheapest
    /// first through the closures below, so a release that is not a selection
    /// never reads one. `⌘⇧` stays `#cm-89`'s (the decision's first check, on
    /// the release flags `startReplyFromTerminalIfRequested` reads). This
    /// only gathers the facts and acts on `.show`.
    func showReplyInlineIfRequested(
        with event: NSEvent,
        pressFlags: NSEvent.ModifierFlags,
        didDrag: Bool,
        clickCount: Int,
        surface: ghostty_surface_t
    ) {
        // First statement, as `startReplyFromTerminalIfRequested`'s is: `⌘⇧` is
        // `#cm-89`'s, and must not even create this pane's controller.
        guard !event.modifierFlags.contains([.command, .shift]) else { return }
        guard let terminalSurface, let window,
              let pane = terminalSurface.paneHost as? GhosttySurfaceScrollView else { return }
        // A release that shows makes the pane's controller. Any other release reads the
        // controller that exists, or the one production environment, and makes nothing.
        let environment = pane.replyInlineIfCreated?.environment
            ?? pane.replyInlineEnvironmentForNewController
            ?? ReplyInlineEnvironment.production
        let panelID = terminalSurface.id
        let decision = ReplyInlineTrigger.decide(ReplyInlineTriggerInput(
            releaseModifiers: event.modifierFlags,
            pressModifiers: pressFlags,
            didDrag: didDrag,
            clickCount: clickCount,
            settingEnabled: environment.settingEnabled(),
            hasSelection: { environment.hasSelection(surface) },
            isAgentPane: { environment.isAgentPane(panelID) },
            readSelection: { [weak self] in
                guard let self, let surface = self.surface else { return nil }
                return environment.readSelection(self, surface)
            },
            grid: { environment.grid(surface) },
            sourcePanelID: panelID
        ))
        switch decision {
        case .ignore(let reason):
            #if DEBUG
            // Only a release that made or changed a selection says why it was
            // turned away, so ordinary clicks log nothing.
            switch reason {
            case .notAgentPane, .blankSelection:
                environment.log("ignore reason=\(reason) surface=\(panelID.uuidString.prefix(5))")
            default:
                break
            }
            #endif
        case .show(let passage):
            pane.showReplyInline(passage, in: window) { [weak self] in
                guard let self, let surface = self.surface, environment.hasSelection(surface) else { return nil }
                return environment.readSelection(self, surface)
            }
        }
    }
}

extension GhosttySurfaceScrollView {
    /// This pane's Reply toolbar. Mounted here, in the AppKit layer the find
    /// bar uses, and never from a SwiftUI panel container: portal-hosted
    /// terminal views can sit above SwiftUI during split and workspace churn.
    var replyInline: ReplyInlineToolbarController {
        if let existing = replyInlineStorage { return existing }
        let created = ReplyInlineToolbarController(
            host: self,
            environment: replyInlineEnvironmentForNewController
        )
        replyInlineStorage = created
        return created
    }

    /// Whether this pane has made its controller yet; a `⌘⇧` release (which is
    /// `#cm-89`'s) must leave it unmade.
    var replyInlineIfCreated: ReplyInlineToolbarController? { replyInlineStorage }

    @discardableResult
    func showReplyInline(
        _ passage: ReplyInlinePassage,
        in window: NSWindow,
        currentSelection: @escaping () -> ReplyInlineSelectionGeometry?
    ) -> Bool {
        replyInline.show(passage, contentFrame: sessionContentFrame, in: window, currentSelection: currentSelection)
    }
}
