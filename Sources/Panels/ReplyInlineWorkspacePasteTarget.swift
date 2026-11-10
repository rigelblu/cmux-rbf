import AppKit
import Combine
import CmuxAgentChat
import Foundation

/// Pastes into the pane whose panel id is given, and no other.
struct ReplyInlineWorkspacePasteTarget: ReplyInlinePasteTarget {
    /// Main thread only: Reply is a click on a view.
    func send(_ events: [TextBoxSubmit.DispatchEvent], toPanel id: UUID) -> Bool {
        MainActor.assumeIsolated {
            guard let located = AppDelegate.shared?.locateSurface(surfaceId: id),
                  let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
                  let panel = workspace.panels[id] as? TerminalPanel else { return false }
            TextBoxSubmit.sendEvents(events, via: panel.surface)
            return true
        }
    }
}
