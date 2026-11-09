/// The live signals a workspace samples to infer its ``WorkspaceTaskStatus``.
/// A pure value so inference is unit-testable without live app state.
public struct WorkspaceTaskStatusSignals: Equatable, Sendable {
    /// Whether any agent in the workspace needs the user: waiting on an answer, or stopped on an error (cm-128.5).
    public var anyAgentNeedsInput: Bool
    /// Whether any agent is waiting on an answer, an error excluded. The hand reads this one (cm-128.5).
    public var anyAgentWaiting: Bool
    /// Whether any agent stopped on an error (cm-128.5).
    public var anyAgentError: Bool
    /// Whether any agent in the workspace is running.
    public var anyAgentRunning: Bool
    /// Whether any agent has finished its turn and is watching background work.
    public var anyAgentMonitoring: Bool
    /// Whether any sidebar pull request is open.
    public var anyOpenPullRequest: Bool
    /// Whether the workspace has any sidebar pull requests at all.
    public var hasPullRequests: Bool
    /// Whether every sidebar pull request is merged or closed.
    public var allPullRequestsMergedOrClosed: Bool
    /// Whether any tracked git working tree is dirty.
    public var isGitDirty: Bool

    /// Creates a signal sample (everything defaults to `false`).
    public init(
        anyAgentNeedsInput: Bool = false,
        anyAgentRunning: Bool = false,
        anyOpenPullRequest: Bool = false,
        hasPullRequests: Bool = false,
        allPullRequestsMergedOrClosed: Bool = false,
        isGitDirty: Bool = false,
        anyAgentMonitoring: Bool = false,
        anyAgentWaiting: Bool? = nil,
        anyAgentError: Bool = false
    ) {
        self.anyAgentNeedsInput = anyAgentNeedsInput
        // A sample that only says "needs input" still raises the hand, as before the error had its own value.
        self.anyAgentWaiting = anyAgentWaiting ?? anyAgentNeedsInput
        self.anyAgentError = anyAgentError
        self.anyAgentRunning = anyAgentRunning
        self.anyAgentMonitoring = anyAgentMonitoring
        self.anyOpenPullRequest = anyOpenPullRequest
        self.hasPullRequests = hasPullRequests
        self.allPullRequestsMergedOrClosed = allPullRequestsMergedOrClosed
        self.isGitDirty = isGitDirty
    }
}
