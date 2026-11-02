public import Foundation

// cmux-rbf #cm-126.3: the Agent Pane's refusal reasons.

/// Why showing a page must leave app state unchanged.
public enum ControlAgentPaneRefusal: Sendable, Equatable {
    /// No workspace contains this live surface identifier.
    case notFound(surfaceID: UUID)
    /// The caller is a different kind of surface.
    case notTerminal(surfaceID: UUID, type: String)
    /// A Dock terminal cannot own an Agent Pane.
    case inDock
    /// Only file, https, and http pages are accepted.
    case badScheme
    /// A Figma editor or preview must be wrapped in the agent's own page.
    case figmaAddress
    /// The browser's URL policy refuses this page; the message is already localized.
    case urlBlocked(message: String)
    /// The host is not allowed to use insecure HTTP.
    case insecureHTTP(host: String)
    /// The embedded browser is disabled.
    case browserOff
}
