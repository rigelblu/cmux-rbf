// cmux-rbf #cm-126.3: a read-only Agent Pane check.

/// The result of validating a caller and page before any mutation.
public enum ControlAgentPaneCheck: Sendable, Equatable {
    /// Nothing may change; report this reason.
    case refused(ControlAgentPaneRefusal)
    /// The app may apply this plan.
    case ready(ControlAgentPanePlan)
}
