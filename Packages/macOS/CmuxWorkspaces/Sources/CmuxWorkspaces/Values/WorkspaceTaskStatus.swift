/// A workspace's todo lifecycle lane, shown in the sidebar and settable over
/// the control socket / CLI. Raw values are a control-socket and session
/// wire format; frozen.
public enum WorkspaceTaskStatus: String, Codable, CaseIterable, Sendable {
    case todo
    case working
    case needsAttention = "needs-attention"
    case review
    case done

    /// The status inferred from live workspace signals, first match wins:
    /// an agent waiting on input beats a running agent, which beats an open
    /// PR, which beats an all-merged/closed PR set, which beats a dirty
    /// working tree; a workspace with none of these is plain `todo`.
    ///
    /// - Parameter signals: The live signals sampled from the workspace.
    /// - Returns: The inferred status.
    public static func inferred(from signals: WorkspaceTaskStatusSignals) -> WorkspaceTaskStatus {
        if signals.anyAgentNeedsInput { return .needsAttention }
        if signals.anyAgentRunning { return .working }
        if signals.anyOpenPullRequest { return .review }
        if signals.hasPullRequests && signals.allPullRequestsMergedOrClosed { return .done }
        if signals.isGitDirty { return .working }
        return .todo
    }

    // (#cm-109.4)
    /// The status inferred without agent or working-tree states (an agent
    /// waiting or running, or uncommitted changes): an open pull request gives
    /// `.review`, pull requests all merged or closed give `.done`, anything
    /// else is `.todo`.
    ///
    /// - Parameter signals: The live signals sampled from the workspace.
    /// - Returns: The inferred status without states.
    public static func inferredWithoutStates(from signals: WorkspaceTaskStatusSignals) -> WorkspaceTaskStatus { // (#cm-109.4)
        if signals.anyOpenPullRequest { return .review } // (#cm-109.4)
        if signals.hasPullRequests && signals.allPullRequestsMergedOrClosed { return .done } // (#cm-109.4)
        return .todo // (#cm-109.4)
    } // (#cm-109.4)

    // (#cm-109.4)
    /// Picks upstream's live inference or detection without states:
    /// with no status list in use, or when the deciding status is cmux's
    /// Working or Needs Attention, upstream's detection applies; otherwise
    /// detection without states applies.
    ///
    /// - Parameters:
    ///   - signals: The live workspace signals.
    ///   - hasStatusList: Whether a status list is in use.
    ///   - decidingStatus: On a write, the status being set; on a read, the status held.
    /// - Returns: The resolved inference.
    public static func resolveInferred( // (#cm-109.4)
        from signals: WorkspaceTaskStatusSignals, // (#cm-109.4)
        hasStatusList: Bool, // (#cm-109.4)
        decidingStatus: WorkspaceTaskStatus? // (#cm-109.4)
    ) -> WorkspaceTaskStatus { // (#cm-109.4)
        if !hasStatusList || decidingStatus == .working || decidingStatus == .needsAttention { // (#cm-109.4)
            return inferred(from: signals) // (#cm-109.4)
        } // (#cm-109.4)
        return inferredWithoutStates(from: signals) // (#cm-109.4)
    } // (#cm-109.4)

    /// The next lane in round-robin declaration order
    /// (todo → working → needs-attention → review → done → todo), used by the
    /// `cycleWorkspaceStatus` shortcut / `workspace.status.cycle` verb.
    public var next: WorkspaceTaskStatus {
        let all = WorkspaceTaskStatus.allCases
        guard let index = all.firstIndex(of: self) else { return .todo }
        return all[(index + 1) % all.count]
    }
}
