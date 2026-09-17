import CmuxRestartCommands

enum RestartCommandPaneProjection {
    static func candidates(
        in panels: [SessionPanelSnapshot],
        workspaceIsRemote: Bool
    ) -> [RestartCommandPaneCandidate] {
        panels.compactMap { panel in
            guard panel.type == .terminal, let terminal = panel.terminal else { return nil }
            let agentWasRunningAtQuit = terminal.wasAgentRunning ?? true
            let hasExistingResumeIntent = (terminal.agent != nil && agentWasRunningAtQuit)
                || terminal.tmuxStartCommand != nil
                || terminal.hibernation != nil
                || resumes(terminal.resumeBinding, agentWasRunningAtQuit: agentWasRunningAtQuit)
                || resumes(terminal.managedAgentResumeBinding, agentWasRunningAtQuit: agentWasRunningAtQuit)
            return RestartCommandPaneCandidate(
                panelID: panel.id,
                binding: terminal.restartCommandBinding,
                hasExistingResumeIntent: hasExistingResumeIntent,
                isRemote: workspaceIsRemote || terminal.isRemoteTerminal == true,
                savedWorkingDirectory: terminal.workingDirectory ?? panel.directory
            )
        }
    }

    /// Whether this binding alone would bring the pane back, so running the pane's
    /// approved restart command would be a second launch in the same pane.
    ///
    /// The `agent-hook` half mirrors restore's own agent-hook-only gate
    /// (`Workspace.swift` → `WorkspaceSessionRestorePolicyService.approvedSurfaceResumeBinding`,
    /// and the dock copy in `DockSplitStore+SessionRestore`). The `process-detected` half is
    /// only correct while BOTH pre-filters survive — see `mayResumePaneOnItsOwn`.
    private static func resumes(
        _ binding: SurfaceResumeBindingSnapshot?,
        agentWasRunningAtQuit: Bool
    ) -> Bool {
        guard let binding, binding.mayResumePaneOnItsOwn else { return false }
        return !binding.isAgentHookBinding || agentWasRunningAtQuit
    }
}
