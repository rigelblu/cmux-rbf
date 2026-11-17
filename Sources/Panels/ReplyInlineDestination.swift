import Foundation

/// Where the toolbar's passage goes when its button is clicked.
///
/// `prompt` is today's Reply: paste the passage into the agent's prompt.
/// `replyPanel` is `Add to reply`: add it to the reply the Reply panel shows.
enum ReplyInlineDestination: Equatable {
    case prompt
    case replyPanel

    /// `replyPanel` only when the sidebar shows Reply, the panel is bound to
    /// the passage's own pane, and the panel follows the newest reply.
    /// Everything else is `prompt`.
    static func resolve(
        sidebarShowingReply: Bool,
        boundPanelID: UUID?,
        sourcePanelID: UUID,
        viewingOlderReply: Bool
    ) -> ReplyInlineDestination {
        guard sidebarShowingReply,
              boundPanelID == sourcePanelID,
              !viewingOlderReply
        else { return .prompt }
        return .replyPanel
    }
}
