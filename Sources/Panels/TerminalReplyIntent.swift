import Foundation

/// What a terminal reply request asks the Reply panel to do.
///
/// `start` is the `⌘⇧`-drag: the panel finds the passage in the agent's newest
/// reply and highlights it, or says why it could not. `add` is the inline
/// toolbar's `Add to reply` while the panel already shows this agent's newest
/// reply: the passage joins that reply's highlights, wrapped rows included.
enum TerminalReplyIntent: Equatable {
    case start
    case add
}
