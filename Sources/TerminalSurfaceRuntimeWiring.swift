import AppKit
import Bonsplit
import Foundation
import CmuxTerminal
import CmuxTerminalCore
import GhosttyKit
import CmuxSettings
import struct CmuxSettings.AgentIntegrationSettingsStore

// The app-side conformances and bridges injected into the CmuxTerminal
// package through `GhosttyApp.terminalSurfaceRuntimeDependencies`. Each type
// here carries behavior verbatim from the legacy god-file reach-up it
// replaces; this file is intended composition-root residue.

// MARK: Engine

extension GhosttyApp: TerminalEngineHosting {
    var runtimeApp: ghostty_app_t? { app }
    var runtimeConfig: ghostty_config_t? { config }
    // `userGhosttyShellIntegrationMode` already matches the seam requirement.
}

// MARK: Views

/// Creates the concrete `GhosttyNSView` + `GhosttySurfaceScrollView` pair the
/// surface model historically constructed in its initializer.
struct TerminalSurfaceViewFactory: TerminalSurfaceViewProviding {
    @MainActor
    func makeSurfaceViews(
        initialFrame: NSRect
    ) -> (surfaceView: any TerminalSurfaceNativeViewing, paneHost: any TerminalSurfacePaneHosting) {
        let view = GhosttyNSView(frame: initialFrame)
        return (view, GhosttySurfaceScrollView(surfaceView: view))
    }
}

// MARK: Spawn policy

/// Live settings/control-plane reads for spawn assembly (the legacy inline
/// reads of the integration-settings enums, `sidebarShellIntegration`,
/// `SidebarWorkspaceDetailDefaults`, and `TerminalController`'s socket path).
@MainActor
final class TerminalSurfaceSpawnPolicyBridge: TerminalSurfaceSpawnPolicyProviding {
    func currentSpawnPolicy() -> TerminalSurfaceSpawnPolicy {
        let integrations = AgentIntegrationSettingsStore(defaults: .standard)
        return TerminalSurfaceSpawnPolicy(
            socketAuthenticationEnvironment: TerminalController.shared.socketClientCapabilityEnvironment(),
            claudeHooksEnabled: integrations.claudeCodeHooksEnabled,
            codexHooksEnabled: integrations.codexHooksEnabled,
            customClaudePath: integrations.customClaudePath,
            subagentNotificationEnvironmentKey: AgentIntegrationSettingsStore.subagentSuppressionEnvironmentKey,
            suppressSubagentNotifications: integrations.suppressesSubagentNotifications,
            cursorHooksEnabled: integrations.cursorHooksEnabled,
            geminiHooksEnabled: integrations.geminiHooksEnabled,
            kiroHooksEnabled: integrations.kiroHooksEnabled,
            kiroNotificationLevel: integrations.kiroNotificationLevel.rawValue,
            ampHooksEnabled: integrations.ampHooksEnabled,
            shellIntegrationEnabled: UserDefaults.standard.object(forKey: "sidebarShellIntegration") as? Bool ?? true,
            watchGitStatusEnabled: SidebarWorkspaceDetailDefaults.watchGitStatusValue(defaults: .standard),
            showPullRequestsEnabled: SidebarWorkspaceDetailDefaults.showPullRequestsValue(defaults: .standard)
        )
    }

    func controlSocketPath() -> String {
        TerminalController.shared.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
    }
}

// MARK: Terminal output tee

/// Installs the libghostty PTY tee for `MobileTerminalByteTee` and keys
/// drop/replay state by surface id (the legacy inline
/// `ghostty_surface_set_pty_tee_cb` + `MobileTerminalByteTee.shared` calls).
final class TerminalOutputByteTeeBridge: TerminalByteTeeBinding {
    /// Wraps the retained tee userdata; `release()` runs exactly where the
    /// surface released the legacy `Unmanaged` context.
    /// @unchecked Sendable: the Unmanaged box is exclusively owned by this
    /// lease from install until release, mirroring the teardown-request
    /// transport.
    final class Lease: TerminalByteTeeLease, @unchecked Sendable {
        private let context: Unmanaged<TerminalOutputTeeContext>

        init(context: Unmanaged<TerminalOutputTeeContext>) {
            self.context = context
        }

        func release() {
            context.release()
        }
    }

    @MainActor
    func installTee(
        on surface: ghostty_surface_t,
        workspaceID: UUID,
        surfaceID: UUID
    ) -> any TerminalByteTeeLease {
        let teeContext = Unmanaged.passRetained(TerminalOutputTeeContext(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            agentDefinitions: CmuxTaskManagerCodingAgentDefinition.builtIns,
            codexRenameHandler: { confirmation in
                // Runs on Ghostty's PTY read path. Codex redraws the same
                // confirmation cell repeatedly, and only a pending submission
                // makes any of them a real rename, so the discriminating check
                // runs first and here — the submission store is lock-guarded and
                // Sendable, so a redraw never reaches the main actor at all. That
                // actor also services keystrokes; a rejected confirmation must
                // not queue work on it.
                let consumed = CodexExplicitRenameSubmissionStore.shared.consumeMatching(
                    surfaceID: surfaceID,
                    name: confirmation.name
                )
#if DEBUG
                if !consumed {
                    // Logged after all: this fires only when the detector emits a
                    // confirmation, which happens on rename output — not per
                    // keystroke — so it is rare and bounded. Silencing it made
                    // "the detector never saw the rename" indistinguishable from
                    // "nothing was armed", which is the first fork any diagnosis
                    // needs to take.
                    Task { @MainActor in
                        cmuxDebugLog(
                            "codexRename.detectedButUnarmed "
                            + "surface=\(surfaceID.uuidString.prefix(8)) "
                            + "thread=\(confirmation.threadID.prefix(8)) "
                            + "name=\"\(confirmation.name)\""
                        )
                    }
                }
#endif
                guard consumed else { return }
                Task { @MainActor in
                    // Every rejection below is logged. A feature whose whole job
                    // is conditional application must say why it declined:
                    // silent `false` returns cost a full debugging session when a
                    // proven rename reached here and no session was registered.
                    func reject(_ reason: String) {
#if DEBUG
                        cmuxDebugLog(
                            "codexRename.rejected reason=\(reason) "
                            + "surface=\(surfaceID.uuidString.prefix(8)) "
                            + "thread=\(confirmation.threadID.prefix(8)) "
                            + "name=\"\(confirmation.name)\""
                        )
#endif
                    }
                    let controller = TerminalController.shared
                    guard let registry = controller.agentChatTranscriptService?.registry else {
                        reject("no_transcript_service")
                        return
                    }
                    guard let record = registry.liveSession(surfaceID: surfaceID.uuidString) else {
                        // Reached here on a machine where Codex launched outside
                        // cmux's wrapper, so no hook ever registered the session.
                        reject("no_live_session")
                        return
                    }
                    guard record.agentKind == .codex else {
                        reject("agent_kind_\(record.agentKind.sourceName)")
                        return
                    }
                    guard record.sessionID.caseInsensitiveCompare(confirmation.threadID)
                        == .orderedSame else {
                        reject("thread_mismatch_record=\(record.sessionID.prefix(8))")
                        return
                    }
                    guard record.workspaceID == nil ||
                        record.workspaceID?.caseInsensitiveCompare(workspaceID.uuidString)
                            == .orderedSame else {
                        reject("workspace_mismatch")
                        return
                    }
                    guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceID),
                        let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
                        reject("workspace_not_found")
                        return
                    }
                    guard let panelId = workspace.panelIdHostingTerminalSurface(surfaceID) else {
                        reject("no_panel_for_surface")
                        return
                    }
                    // A sibling Codex session or a Teams subagent sharing this
                    // workspace keeps the rename on its own tab.
                    let workspaceEligible = WorkspaceAgentOccupancy.isSoleAgentSurface(
                        .terminalSession(sessionID: record.sessionID),
                        in: workspace,
                        registry: registry
                    )
                    let applied = workspace.applyCodexSessionName(
                        confirmation.name,
                        panelId: panelId,
                        workspaceEligible: workspaceEligible
                    )
#if DEBUG
                    // Logged on success too: "the rename was proven but the
                    // workspace declined it" and "nothing reached here at all"
                    // look identical from the outside otherwise.
                    cmuxDebugLog(
                        "codexRename.applied surface=\(surfaceID.uuidString.prefix(8)) "
                        + "name=\"\(confirmation.name)\" eligible=\(workspaceEligible) "
                        + "workspaceApplied=\(applied.workspaceApplied) "
                        + "panelApplied=\(applied.panelApplied.map(String.init(describing:)) ?? "nil")"
                    )
#endif
                }
            }
        ))
#if DEBUG
        // Absence of this line is the proof that a silent rename never had a
        // detector at all — the fork that separates "tee not installed on the
        // renaming surface" from every downstream explanation.
        cmuxDebugLog(
            "codexRename.teeInstalled surface=\(surfaceID.uuidString.prefix(8)) "
            + "workspace=\(workspaceID.uuidString.prefix(8))"
        )
#endif
        ghostty_surface_set_pty_tee_cb(
            surface,
            cmuxTerminalOutputTeeCallback,
            teeContext.toOpaque()
        )
        return Lease(context: teeContext)
    }

    @MainActor
    func dropSurface(surfaceID: UUID) {
        MobileTerminalByteTee.shared.dropSurface(surfaceID: surfaceID)
    }
}

// MARK: Renderer reclamation

extension RendererRealizationController: TerminalRendererRealizationScheduling {}

// MARK: Agent hibernation

/// The legacy `recordAgentHibernationTerminalInput` free helper as an
/// injected recorder: same gate, same timestamp capture, same main-actor hop.
final class TerminalAgentHibernationRecorder: AgentHibernationRecording {
    func recordTerminalInput(workspaceId: UUID, panelId: UUID) {
        guard AgentHibernationTrackingGate.isEnabled() else { return }
        let recordedAt = Date()
        Task { @MainActor in
            AgentHibernationController.shared.recordTerminalInput(
                workspaceId: workspaceId,
                panelId: panelId,
                recordedAt: recordedAt
            )
        }
    }
}

// MARK: Filesystem

extension TerminalSurfaceRuntimeFilesystem {
    static func live() -> TerminalSurfaceRuntimeFilesystem {
        TerminalSurfaceRuntimeFilesystem(
            claudeCommandShimTemporaryDirectory: FileManager.default.temporaryDirectory,
            installClaudeCommandShim: {
                TerminalSurface.installClaudeCommandShimIfPossible(
                    wrapperURL: $0,
                    surfaceId: $1,
                    temporaryDirectory: $2,
                    fileManager: .default
                )
            },
            isExecutableFile: { FileManager.default.isExecutableFile(atPath: $0) }
        )
    }
}

// MARK: Construction

extension TerminalSurface {
    /// The legacy app-target initializer signature, forwarding to the package
    /// initializer with the process-wide collaborator bundle. Keeps every
    /// existing call site byte-identical while construction is injected
    /// (dissolves when a real composition root constructs surfaces).
    @MainActor
    convenience init(
        id: UUID = UUID(),
        tabId: UUID,
        context: ghostty_surface_context_e,
        configTemplate: CmuxSurfaceConfigTemplate?,
        workingDirectory: String? = nil,
        portOrdinal: Int = 0,
        initialCommand: String? = nil,
        tmuxStartCommand: String? = nil,
        initialInput: String? = nil,
        initialEnvironmentOverrides: [String: String] = [:],
        additionalEnvironment: [String: String] = [:],
        focusPlacement: TerminalSurfaceFocusPlacement = .workspace,
        manualIO: Bool = false,
        manualInputHandler: (@Sendable (Data) -> Void)? = nil,
        runtimeSpawnPolicy: TerminalSurfaceRuntimeSpawnPolicy = .immediate,
        preparePaneHost: @Sendable @MainActor (any TerminalSurfacePaneHosting) -> Void = { _ in }
    ) {
        self.init(
            id: id,
            tabId: tabId,
            context: context,
            configTemplate: configTemplate,
            workingDirectory: workingDirectory,
            portOrdinal: portOrdinal,
            initialCommand: initialCommand,
            tmuxStartCommand: tmuxStartCommand,
            initialInput: initialInput,
            initialEnvironmentOverrides: initialEnvironmentOverrides,
            additionalEnvironment: additionalEnvironment,
            focusPlacement: focusPlacement,
            manualIO: manualIO,
            manualInputHandler: manualInputHandler,
            runtimeSpawnPolicy: runtimeSpawnPolicy,
            preparePaneHost: preparePaneHost,
            dependencies: GhosttyApp.terminalSurfaceRuntimeDependencies
        )
    }
}
