import CmuxRestartCommands
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Restart command pane projection")
struct RestartCommandPaneProjectionTests {
    private enum BindingPlacement {
        case resume
        case managed
    }

    @Test("agent-hook retired")
    func agentHookRetired() throws {
        try expectAgentHookIntent(autoResume: false, wasAgentRunning: true, expected: false)
    }

    @Test("agent-hook armed, agent not running at quit")
    func agentHookArmedAgentNotRunningAtQuit() throws {
        try expectAgentHookIntent(autoResume: true, wasAgentRunning: false, expected: false)
    }

    @Test("agent-hook legacy auto-resume flag")
    func agentHookLegacyAutoResumeFlag() throws {
        try expectAgentHookIntent(autoResume: nil, wasAgentRunning: true, expected: false)
    }

    @Test("process-detected auto-resume disabled")
    func processDetectedAutoResumeDisabled() throws {
        try expectBindingIntent(source: "process-detected", autoResume: false, expected: false)
    }

    @Test("process-detected legacy auto-resume flag")
    func processDetectedLegacyAutoResumeFlag() throws {
        try expectBindingIntent(source: "process-detected", autoResume: nil, expected: false)
    }

    @Test("agent-hook armed, agent running at quit")
    func agentHookArmedAgentRunningAtQuit() throws {
        try expectAgentHookIntent(autoResume: true, wasAgentRunning: true, expected: true)
    }

    @Test("agent-hook armed, legacy running state")
    func agentHookArmedLegacyRunningState() throws {
        try expectAgentHookIntent(autoResume: true, wasAgentRunning: nil, expected: true)
    }

    @Test("process-detected auto-resume enabled")
    func processDetectedAutoResumeEnabled() throws {
        try expectBindingIntent(source: "process-detected", autoResume: true, expected: true)
    }

    @Test("cli saved auto-resume disabled")
    func cliSavedAutoResumeDisabled() throws {
        try expectBindingIntent(source: "cli", autoResume: false, expected: true)
    }

    @Test("cli ignores agent running state")
    func cliIgnoresAgentRunningState() throws {
        try expectBindingIntent(
            source: "cli",
            autoResume: false,
            wasAgentRunning: false,
            expected: true
        )
    }

    @Test("agent snapshot remains a resume intent")
    func agentSnapshotRemainsAResumeIntent() throws {
        try expectCandidateIntent(
            agent: SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: "session-cm-96-3",
                workingDirectory: "/saved",
                launchCommand: nil
            ),
            expected: true
        )
    }

    @Test("tmux start command remains a resume intent")
    func tmuxStartCommandRemainsAResumeIntent() throws {
        try expectCandidateIntent(tmuxStartCommand: "tmux attach", expected: true)
    }

    @Test("hibernation remains a resume intent")
    func hibernationRemainsAResumeIntent() throws {
        try expectCandidateIntent(
            hibernation: SessionAgentHibernationSnapshot(
                hibernatedAt: 123,
                lastActivityAt: 122
            ),
            expected: true
        )
    }

    @Test("agent snapshot, agent not running at quit")
    func agentSnapshotAgentNotRunningAtQuit() throws {
        try expectCandidateIntent(
            agent: SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: "session-cm-96-3-idle",
                workingDirectory: "/saved",
                launchCommand: nil
            ),
            wasAgentRunning: false,
            expected: false
        )
    }

    @Test("dock shape: retired managed binding beside a disabled process-detected binding")
    func dockShapeBothBindingsDead() throws {
        try expectCandidateIntent(
            resumeBinding: binding(source: "process-detected", autoResume: false),
            managedAgentResumeBinding: binding(source: "agent-hook", autoResume: false),
            expected: false
        )
    }

    @Test("dock shape: armed managed binding beside a disabled process-detected binding")
    func dockShapeArmedManagedBinding() throws {
        try expectCandidateIntent(
            resumeBinding: binding(source: "process-detected", autoResume: false),
            managedAgentResumeBinding: binding(source: "agent-hook", autoResume: true),
            expected: true
        )
    }

    @Test("a remote workspace marks the candidate remote")
    func remoteWorkspaceMarksCandidateRemote() throws {
        try expectCandidateIntent(
            resumeBinding: binding(source: "agent-hook", autoResume: false),
            workspaceIsRemote: true,
            expectedIsRemote: true,
            expected: false
        )
    }

    @Test("a remote terminal marks the candidate remote")
    func remoteTerminalMarksCandidateRemote() throws {
        try expectCandidateIntent(
            resumeBinding: binding(source: "agent-hook", autoResume: false),
            isRemoteTerminal: true,
            expectedIsRemote: true,
            expected: false
        )
    }

    @Test("a pane with no saved working directory falls back to the panel's")
    func missingWorkingDirectoryFallsBackToPanelDirectory() throws {
        try expectCandidateIntent(
            resumeBinding: binding(source: "agent-hook", autoResume: false),
            workingDirectory: nil,
            expectedWorkingDirectory: "/panel-directory",
            expected: false
        )
    }

    private func binding(source: String, autoResume: Bool?) -> SurfaceResumeBindingSnapshot {
        SurfaceResumeBindingSnapshot(
            command: "cmux restore test",
            source: source,
            autoResume: autoResume,
            updatedAt: 123
        )
    }

    private func expectAgentHookIntent(
        autoResume: Bool?,
        wasAgentRunning: Bool?,
        expected: Bool
    ) throws {
        try expectBindingIntent(
            source: "agent-hook",
            autoResume: autoResume,
            wasAgentRunning: wasAgentRunning,
            placement: .resume,
            expected: expected
        )
        try expectBindingIntent(
            source: "agent-hook",
            autoResume: autoResume,
            wasAgentRunning: wasAgentRunning,
            placement: .managed,
            expected: expected
        )
    }

    private func expectBindingIntent(
        source: String,
        autoResume: Bool?,
        wasAgentRunning: Bool? = true,
        placement: BindingPlacement = .resume,
        expected: Bool
    ) throws {
        let binding = SurfaceResumeBindingSnapshot(
            command: "cmux restore test",
            source: source,
            autoResume: autoResume,
            updatedAt: 123
        )
        try expectCandidateIntent(
            resumeBinding: placement == .resume ? binding : nil,
            managedAgentResumeBinding: placement == .managed ? binding : nil,
            wasAgentRunning: wasAgentRunning,
            expected: expected
        )
    }

    private func expectCandidateIntent(
        agent: SessionRestorableAgentSnapshot? = nil,
        tmuxStartCommand: String? = nil,
        hibernation: SessionAgentHibernationSnapshot? = nil,
        resumeBinding: SurfaceResumeBindingSnapshot? = nil,
        managedAgentResumeBinding: SurfaceResumeBindingSnapshot? = nil,
        wasAgentRunning: Bool? = true,
        workingDirectory: String? = "/saved",
        workspaceIsRemote: Bool = false,
        isRemoteTerminal: Bool? = nil,
        expectedIsRemote: Bool = false,
        expectedWorkingDirectory: String = "/saved",
        expected: Bool
    ) throws {
        let panelID = UUID()
        let restartBinding = PaneRestartCommandBinding(
            definitionID: "jjui",
            detectorFingerprint: String(repeating: "a", count: 64),
            observedAt: 123,
            snapshotIdentity: RestartCommandSnapshotIdentity(
                rootGenerationID: UUID(),
                captureKind: .pendingTermination
            )
        )
        let panel = SessionPanelSnapshot(
            id: panelID,
            type: .terminal,
            title: "Restart candidate",
            customTitle: nil,
            directory: "/panel-directory",
            isPinned: false,
            isManuallyUnread: false,
            listeningPorts: [],
            ttyName: "ttys096",
            terminal: SessionTerminalPanelSnapshot(
                workingDirectory: workingDirectory,
                agent: agent,
                tmuxStartCommand: tmuxStartCommand,
                hibernation: hibernation,
                resumeBinding: resumeBinding,
                managedAgentResumeBinding: managedAgentResumeBinding,
                restartCommandBinding: restartBinding,
                isRemoteTerminal: isRemoteTerminal,
                wasAgentRunning: wasAgentRunning
            ),
            browser: nil,
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil
        )
        let candidates = RestartCommandPaneProjection.candidates(
            in: [panel],
            workspaceIsRemote: workspaceIsRemote
        )

        let candidate = try #require(candidates.count == 1 ? candidates[0] : nil)
        #expect(candidate.panelID == panelID)
        #expect(candidate.binding == restartBinding)
        #expect(candidate.hasExistingResumeIntent == expected)
        #expect(candidate.isRemote == expectedIsRemote)
        #expect(candidate.savedWorkingDirectory == expectedWorkingDirectory)
    }
}
