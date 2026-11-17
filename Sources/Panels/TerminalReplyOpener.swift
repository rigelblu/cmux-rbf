import AppKit
import Foundation

/// Opens the Reply panel on a terminal request. The one open path for both
/// entrances: the `⌘⇧`-drag (`#cm-89`) and the inline toolbar's `Add to reply`
/// (`cm-136.7`), so they share one request sequence and one expiry.
@MainActor
enum TerminalReplyOpener {
    private static var seq = 0

    /// The next request number. Every entrance draws from this one sequence.
    static func nextSeq() -> Int {
        seq += 1
        return seq
    }

    /// Whether the keyboard has to be taken off `pane`: it is on `pane` or on a
    /// view inside it.
    static func holdsKeyboard(_ firstResponder: NSResponder?, pane: NSView?) -> Bool {
        guard let pane, let view = firstResponder as? NSView else { return false }
        // `isDescendant(of:)` is true for `pane` itself.
        return view.isDescendant(of: pane)
    }

    /// Hands the request to the window's Reply sidebar, brings it forward, and
    /// takes the keyboard off `pane` (the terminal view, or the scroll view that
    /// holds it) so keys typed before the note field has the caret never reach
    /// the agent.
    static func open(
        _ request: TerminalReplyRequest,
        sidebar: FileExplorerState,
        window: NSWindow,
        from pane: NSView?
    ) {
        sidebar.terminalReplyRequest = request
        // A request the panel cannot take soon is dropped, never kept: left in
        // place it fires whenever Reply next appears — minutes later, on a
        // highlight nobody asked for (cold code review 2026-09-13, Required
        // 1). A cold open took 430 ms in dogfood; 5 s leaves room for a long
        // transcript to load.
        let expiringSeq = request.seq
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak sidebar] in
            guard let sidebar, sidebar.terminalReplyRequest?.seq == expiringSeq else { return }
            #if DEBUG
            cmuxDebugLog("reply.terminalStart expired seq=\(expiringSeq)")
            #endif
            sidebar.terminalReplyRequest = nil
        }
        _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
            mode: .reply,
            focusFirstItem: false,
            preferredWindow: window
        )
        // The call returns `true` while focus is merely *requested*
        // (`MainWindowFocusController.focusRightSidebar`), so test where the
        // keyboard actually is. On a cold open neither the page nor the
        // sidebar host may be able to take it yet; keys typed before the note
        // field has the caret must go nowhere, never to the agent.
        if holdsKeyboard(window.firstResponder, pane: pane) {
            window.makeFirstResponder(nil)
        }
        #if DEBUG
        cmuxDebugLog("reply.terminalStart focus fr=\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
        #endif
    }
}
