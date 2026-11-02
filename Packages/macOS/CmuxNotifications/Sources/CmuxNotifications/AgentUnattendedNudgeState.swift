/// Live admission facts checked when a finished-turn reminder reaches its deadline.
public struct AgentUnattendedNudgeState: Sendable {
    /// Whether the idle-reminder setting is currently enabled.
    public let enabled: Bool
    /// Whether the original notification still exists.
    public let exists: Bool
    /// Whether the original notification is still unread.
    public let unread: Bool
    /// Whether its pane is focused in the active workspace of the frontmost app.
    public let focusedInFrontmostApp: Bool
    /// Whether the existing Mac presence policy reports the user present.
    public let present: Bool

    /// Creates live facts without reading the app, notification store, or hardware.
    /// - Parameters:
    ///   - enabled: Current idle-reminder setting.
    ///   - exists: Original notification existence.
    ///   - unread: Original notification unread state.
    ///   - focusedInFrontmostApp: Exact focused-pane and frontmost-app conjunction.
    ///   - present: Current Mac presence result.
    public init(enabled: Bool, exists: Bool, unread: Bool, focusedInFrontmostApp: Bool, present: Bool) {
        self.enabled = enabled
        self.exists = exists
        self.unread = unread
        self.focusedInFrontmostApp = focusedInFrontmostApp
        self.present = present
    }
}
