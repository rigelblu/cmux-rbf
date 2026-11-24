import CmuxFoundation
import CMUXMobileCore
import CmuxSettings
import Foundation

public enum RestartCommandsFileProblem: Equatable, Sendable {
    case invalidJSON(line: Int)
    case unknownField(line: Int, field: String)
    case missingField(line: Int, field: String)
    case invalidValue(line: Int, field: String)
    case repeatedID(line: Int)
}

/// Host-owned global restart state projected into the package-only Settings UI.
public enum RestartAllowlistedCommandsSettingsStatus: Equatable, Sendable {
    public enum ShippedWarning: Equatable, Sendable {
        case validChanged
        case unusableUserFile(problem: RestartCommandsFileProblem?)
    }

    case enabledShipped(commandCount: Int)
    case enabledApproved(commandCount: Int)
    case enabledFallback(warning: ShippedWarning)
    case off
    case stateUnavailable

    public var isEnabled: Bool {
        switch self {
        case .enabledShipped, .enabledApproved, .enabledFallback: true
        case .off, .stateUnavailable: false
        }
    }

    public var displayText: String {
        switch self {
        case .enabledShipped(let commandCount):
            String.localizedStringWithFormat(
                String(
                    localized: "settings.terminal.restartCommands.status.shipped",
                    defaultValue: "Enabled · %lld shipped definitions"
                ),
                Int64(commandCount)
            )
        case .enabledApproved(let commandCount):
            String.localizedStringWithFormat(
                String(
                    localized: "settings.terminal.restartCommands.status.approved",
                    defaultValue: "Enabled · %lld approved definitions"
                ),
                Int64(commandCount)
            )
        case .enabledFallback:
            String(
                localized: "settings.terminal.restartCommands.status.fallback",
                defaultValue: "Enabled · Using shipped definitions"
            )
        case .off:
            String(localized: "settings.terminal.restartCommands.status.off", defaultValue: "Off")
        case .stateUnavailable:
            String(
                localized: "settings.terminal.restartCommands.status.stateUnavailable",
                defaultValue: "Off · Restart state unavailable"
            )
        }
    }

    var warningText: String? {
        switch self {
        case .enabledFallback(.validChanged):
            return String(
                localized: "settings.terminal.restartCommands.definitionsChangedWarning",
                defaultValue: "Custom definitions changed — review to use them."
            )
        case .enabledFallback(.unusableUserFile(let problem)):
            switch problem {
            case .invalidJSON(let line):
                return String.localizedStringWithFormat(
                    String(
                        localized: "settings.terminal.restartCommands.fallbackWarning.atLine",
                        defaultValue: "Line %lld contains invalid JSON. Shipped definitions are running; custom definitions aren’t."
                    ),
                    Int64(line)
                )
            case .unknownField(let line, let field):
                return String.localizedStringWithFormat(
                    String(
                        localized: "settings.terminal.restartCommands.fallbackWarning.unknownField",
                        defaultValue: "Line %lld has a field cmux doesn’t know: “%@”. Shipped definitions are running; custom definitions aren’t."
                    ),
                    Int64(line),
                    Self.warningField(field)
                )
            case .missingField(let line, let field):
                return String.localizedStringWithFormat(
                    String(
                        localized: "settings.terminal.restartCommands.fallbackWarning.missingField",
                        defaultValue: "Line %lld is missing “%@”. Shipped definitions are running; custom definitions aren’t."
                    ),
                    Int64(line),
                    Self.warningField(field)
                )
            case .invalidValue(let line, let field):
                return String.localizedStringWithFormat(
                    String(
                        localized: "settings.terminal.restartCommands.fallbackWarning.invalidValue",
                        defaultValue: "Line %lld has an invalid “%@” value. Shipped definitions are running; custom definitions aren’t."
                    ),
                    Int64(line),
                    Self.warningField(field)
                )
            case .repeatedID(let line):
                return String.localizedStringWithFormat(
                    String(
                        localized: "settings.terminal.restartCommands.fallbackWarning.repeatedID",
                        defaultValue: "Line %lld repeats an id used above. Shipped definitions are running; custom definitions aren’t."
                    ),
                    Int64(line)
                )
            case nil:
                return String(
                    localized: "settings.terminal.restartCommands.fallbackWarning",
                    defaultValue: "Your definitions file couldn’t be used. Shipped definitions are running; custom definitions aren’t."
                )
            }
        default:
            return nil
        }
    }

    private static func warningField(_ field: String) -> String {
        let isTruncated = field.count > 32
        let prefix = String(field.prefix(32))
        var escaped = ""
        for scalar in prefix.unicodeScalars {
            switch scalar.value {
            case 0x09:
                escaped += "\\t"
            case 0x0A:
                escaped += "\\n"
            case 0x0D:
                escaped += "\\r"
            case 0x00...0x1F, 0x7F, 0x202A...0x202E, 0x2066...0x2069:
                escaped += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped + (isTruncated ? "…" : "")
    }
}

public struct RestartAllowlistedCommandsSettingsMutationResult: Equatable, Sendable {
    public let status: RestartAllowlistedCommandsSettingsStatus
    public let inlineError: String?

    public init(status: RestartAllowlistedCommandsSettingsStatus, inlineError: String? = nil) {
        self.status = status
        self.inlineError = inlineError
    }
}

/// Posted by the host when a sidebar menu or command-palette action should open the template gallery.
public extension Notification.Name {
    static let customSidebarTemplateGalleryRequested = Notification.Name("cmux.settings.customSidebarTemplateGalleryRequested")
}

/// Holds a gallery request until the progressively mounted Custom Sidebars
/// section is ready to present it.
// lint:allow namespace-type — one-shot, main-actor handoff from a host menu to the lazily mounted Custom Sidebars section (#15931); candidate to become an injected SettingsRuntime value.
@MainActor
public final class CustomSidebarTemplateGalleryRequest {
    public static let shared = CustomSidebarTemplateGalleryRequest()

    private var pending = false

    private init() {}

    public func request() {
        pending = true
        NotificationCenter.default.post(name: .customSidebarTemplateGalleryRequested, object: nil)
    }

    public func consume() -> Bool {
        guard pending else { return false }
        pending = false
        return true
    }
}

/// Host-supplied callbacks the package's section views invoke for
/// actions that live outside the catalog — clearing browser history,
/// opening the user's editor on cmux.json, sending feedback, posting
/// test notifications, restarting the app after a language change,
/// and launching the browser import workflow.
///
/// The package doesn't carry these implementations because they
/// depend on host-app services that have no place in a
/// Foundation-only settings package. The host implements this
/// protocol once and injects it via ``SettingsRuntime``; sections
/// check for `nil` callbacks and hide the corresponding buttons
/// when no host action is available.
@MainActor
public protocol SettingsHostActions: AnyObject, CloudMachinesSettingsActions {
    func computersSettingsActions() -> ComputersSettingsActions
    /// A registry snapshot used to populate the per-agent notification sound
    /// matrix. The host owns discovery so newly registered agents appear
    /// without a second list in the settings package.
    func notificationSoundAgentOptions() async -> [NotificationSoundAgentOption]

    /// Validates and prepares a custom notification sound before a matrix cell
    /// is persisted. Returning `false` keeps the previous cell untouched.
    func validateNotificationSoundFile(path: String) async -> Bool

    /// Whether this build offers Chief; off hides its Settings card.
    var isChiefAvailable: Bool { get }

    /// Deletes the user's browser history (visited-page suggestions,
    /// omnibar autocomplete cache). Idempotent.
    func clearBrowserHistory()

    /// Opens the cmux JSON config file in the user's preferred
    /// external editor. The package's inline editor still works;
    /// this is the escape hatch for users who prefer their own
    /// editor.
    func openConfigInExternalEditor()

    /// Current effective state of the separate restart-command authority.
    func restartAllowlistedCommandsStatus() -> RestartAllowlistedCommandsSettingsStatus

    /// Live state changes caused by file edits or another Settings action.
    func restartAllowlistedCommandsStatusUpdates() -> AsyncStream<RestartAllowlistedCommandsSettingsStatus>

    /// Applies the one global enable/disable decision.
    func setRestartAllowlistedCommandsEnabled(
        _ enabled: Bool
    ) -> RestartAllowlistedCommandsSettingsMutationResult

    /// Approves current custom definitions in fallback mode.
    func approveRestartCommandDefinitions() -> RestartAllowlistedCommandsSettingsMutationResult

    /// Materializes and opens the dedicated definitions file.
    @discardableResult
    func openRestartCommandDefinitionsFile() -> Bool

    /// Existing signed-prefix approvals shown in the preserved legacy row.
    func legacyResumeCommandCount() -> Int

    /// Reads the existing config-backed automation rules for Settings status.
    func automationRulesStatus() async -> AutomationRulesStatus

    /// Opens ~/.cmuxterm/automations.json in the user's preferred editor.
    func openAutomationRulesInExternalEditor()

    /// Asks the running automation engine to reload its existing config file.
    /// Returns false when the host has no live automation engine.
    @discardableResult
    func reloadAutomationRules() -> Bool

    /// Names of custom sidebar files currently discovered by the host.
    func customSidebarNames() -> [String]

    /// Streams sidebar names after external filesystem changes, including an initial snapshot.
    func customSidebarNamesUpdates() async -> AsyncStream<[String]>

    /// Creates a starter custom sidebar and opens it in the preferred editor.
    func createCustomSidebar() -> CustomSidebarOnboardingResult

    /// Copies one bundled template into the custom-sidebar directory, selects it, and opens it.
    func installCustomSidebarTemplate(id: String) -> CustomSidebarOnboardingResult

    /// Installs a template and selects it without opening the editor.
    func useCustomSidebarTemplate(id: String) -> CustomSidebarOnboardingResult

    /// Temporarily selects a template for gallery preview.
    func previewCustomSidebarTemplate(id: String) -> CustomSidebarOnboardingResult

    /// Keeps or discards the active gallery preview.
    func keepCustomSidebarPreview() -> CustomSidebarOnboardingResult
    func revertCustomSidebarPreview()

    /// Copies one bundled example into the custom-sidebar directory and opens it.
    func installCustomSidebarExample(id: String) -> CustomSidebarOnboardingResult

    /// Opens an existing discovered custom sidebar in the preferred editor.
    func openCustomSidebarInExternalEditor(named name: String)

    /// Creates the custom-sidebar directory when needed, then reveals it in Finder.
    func openCustomSidebarsFolder()

    /// Launches the host's feedback flow (typically a "Send Feedback"
    /// URL or in-app form).
    func sendFeedback()

    /// Posts a synthetic test notification so the user can confirm
    /// the configured sound + behavior.
    func sendTestNotification()

    /// Opens System Settings to the cmux notifications pane so the
    /// user can grant / revoke OS-level notification permission.
    func openSystemNotificationSettings()

    /// Returns the host's current macOS notification authorization state.
    func desktopNotificationAuthorizationStatus() -> DesktopNotificationAuthorizationState

    /// Emits a fresh authorization state when the host observes a macOS
    /// notification permission change.
    func desktopNotificationAuthorizationStatusUpdates() -> AsyncStream<DesktopNotificationAuthorizationState>

    /// Asks the host to refresh macOS notification permission from
    /// `UNUserNotificationCenter`.
    func refreshDesktopNotificationAuthorizationStatus()

    /// Restarts the cmux app. Used after the user changes the
    /// language picker, which requires a full process restart.
    func restartApp()

    /// Applies the current persisted control-socket configuration to the live server.
    func socketControlConfigurationDidChange()

    /// Live-reloads Ghostty after the adaptive-default-theme preference commits.
    func terminalAdaptiveDefaultThemeDidChange()

    /// Lists the current opt-in local tmux sessions using the host app's bundled CLI.
    func localTmuxSessions() async throws -> [LocalTmuxSessionSummary]

    /// Starts and attaches a named opt-in local tmux session.
    func startLocalTmuxSession(name: String) async throws

    /// Attaches an existing opt-in local tmux session.
    func attachLocalTmuxSession(_ session: LocalTmuxSessionSummary) async throws

    /// Opens the interactive terminal theme picker in a focused cmux terminal pane.
    func openTerminalThemePicker()

    /// Theme directories, managed config file and current theme for the
    /// Settings theme gallery, or `nil` to show only the terminal picker button.
    func terminalThemeGalleryContext() -> TerminalThemeGalleryContext?

    /// Reloads terminals after the gallery rewrote the managed theme block.
    func terminalThemeConfigDidChange(phase: TerminalThemeReloadPhase)

    /// Opens a focused cmux terminal pane running `cmux import`, which lists other
    /// terminals' settings and imports the one the user picks.
    func openTerminalImport()

    /// Launches the host's browser-import flow (Safari / Chrome /
    /// Firefox source picker + profile selection + cookie prompt).
    func openBrowserImportFlow()

    /// Asks the OS for notification authorization. No-op if the user
    /// has already responded (granted or denied).
    func requestNotificationAuthorization()

    /// Opens the cmux terminal config preview window (the legacy
    /// "Open Config" row in the App section). The host owns the
    /// window scene so the package can't open it directly.
    func openTerminalConfigWindow()

    /// Opens the user's workspace-layout action definitions for editing.
    func customizeWorkspaceLayouts()

    /// Validates a custom palette edit and snapshots its explicit-assignment impact.
    func previewWorkspacePaletteColorEdit(
        paletteName: String,
        expectedOldHex: String,
        proposedHex: String
    ) -> Result<WorkspacePaletteColorEditPreview, WorkspacePaletteColorEditRejection>

    /// Applies one still-current custom palette edit through the host's shared owner.
    func applyWorkspacePaletteColorEdit(
        _ preview: WorkspacePaletteColorEditPreview,
        decision: WorkspacePaletteColorEditDecision
    ) -> WorkspacePaletteColorEditResult

    /// Commits a still-current color preference or broad reset through one host action.
    /// - Parameters:
    ///   - action: Completed user action.
    ///   - expected: Complete saved state the interaction started from.
    /// - Returns: The committed complete state.
    /// - Throws: A stale or failed save, leaving the preceding saved state intact.
    func applyWorkspaceColorPreferences(
        _ action: WorkspaceColorSettingsSnapshot.Action,
        expected: WorkspaceColorSettingsSnapshot
    ) async throws -> WorkspaceColorSettingsSnapshot

    /// Persists an explicit menu-bar-only preference change in the host app.
    ///
    /// The host pairs the visible `app.menuBarOnly` setting with any hidden
    /// safety marker it needs before changing the process activation policy.
    ///
    /// - Returns: `true` when the host handled persistence for this change.
    @discardableResult
    func setMenuBarOnly(_ enabled: Bool) -> Bool

    /// Opens the iOS pairing window, which walks through signing in to the
    /// same account on the iPhone. The host owns the window so the package
    /// can't open it directly.
    func openMobilePairingWindow()

    /// Plays the currently configured notification sound so the user
    /// can preview it from the Settings UI.
    func previewNotificationSound(value: String, customFilePath: String)

    /// Returns the current number of saved browser-history entries, or
    /// `nil` if the host hasn't loaded the history store yet. The
    /// Browser section uses this to render a dynamic "N saved pages"
    /// subtitle next to the Clear History button.
    func browserHistoryEntryCount() -> Int?

    /// The current left-sidebar font size with the range + default the
    /// slider should use. Backed by the Ghostty config file, not
    /// `UserDefaults`, so it comes from the host rather than the catalog.
    func sidebarFontSize() -> SettingsFontSize

    /// Persists a new left-sidebar font size (in points) to the Ghostty
    /// config and live-reloads open windows. The host clamps to the valid
    /// range, so callers may pass any finite value.
    ///
    /// - Returns: `true` if the value was written and reloaded, `false` if
    ///   persistence failed. Callers should surface a save-failed message to
    ///   the user when this returns `false`, since the slider position no
    ///   longer reflects what is stored on disk.
    ///
    ///   The implementation performs the disk write off the main actor, so this
    ///   is `async`; call it from a `Task` in the slider/reset action.
    @discardableResult
    func setSidebarFontSize(_ points: Double) async -> Bool

    /// The customizable right-sidebar tabs in the user's order, hidden tabs
    /// included. Backed by host-owned mode metadata and tab preferences the
    /// package cannot read; empty when the host has no right sidebar
    /// (previews/tests).
    func rightSidebarTabs() -> [RightSidebarTabSettingsItem]

    /// Shows or hides one right-sidebar tab.
    ///
    /// - Returns: `false` when the host refused the change (hiding the last
    ///   visible tab); the card re-reads state so the toggle snaps back.
    @discardableResult
    func setRightSidebarTabVisible(id: String, visible: Bool) -> Bool

    /// Moves one right-sidebar tab by `offset` within the ordered tab list
    /// (negative is toward the front). Hidden tabs keep their slot.
    func moveRightSidebarTab(id: String, offset: Int)

    /// Yields a fresh tab list whenever the tabs change from any entrypoint
    /// (this card, the mode bar's context menu, shortcut rebinds that change
    /// the displayed digit hints).
    func rightSidebarTabsUpdates() -> AsyncStream<[RightSidebarTabSettingsItem]>

    /// The current workspace tab-bar font size with its range + default.
    /// Backed by the Ghostty config file (`surface-tab-bar-font-size`).
    func surfaceTabBarFontSize() -> SettingsFontSize

    /// Persists a new workspace tab-bar font size (in points) and reloads.
    /// The host clamps to the valid range.
    ///
    /// - Returns: `true` if the value was written and reloaded, `false` if
    ///   persistence failed. See ``setSidebarFontSize(_:)`` for how callers
    ///   should react to a `false` result and why this is `async`.
    @discardableResult
    func setSurfaceTabBarFontSize(_ points: Double) async -> Bool

    /// Formats a point size for display next to a font-size slider
    /// (e.g. `12`, `13.5`), trimming trailing zeros.
    func formattedFontSize(_ points: Double) -> String

    /// The effective values of the Ghostty options Settings > Terminal edits
    /// natively, folded from the user's Ghostty config and cmux's config in
    /// load order, with the file that last set each key. Reads the config
    /// files off the main actor.
    func terminalGhosttyOptions() async -> GhosttyTerminalOptionsSnapshot

    /// Writes one option's key to cmux's Ghostty config and reloads the
    /// configuration so open terminals pick it up.
    ///
    /// - Returns: `false` when the write failed.
    @discardableResult
    func applyTerminalGhosttyOption(_ change: GhosttyTerminalOptionChange) async -> Bool

    /// The current status of the Mac-side iOS pairing host (the actual bound
    /// port, whether it fell back from the configured port, the active iOS
    /// connection count, the effective display name, and the routes the phone
    /// can reach this Mac on), or `nil` when the host has not started the
    /// mobile service yet (or in previews/tests). The Mobile section renders
    /// the bound-port indicator and diagnostics from this.
    ///
    /// Backed by host-app runtime state, so it lives here rather than in the
    /// catalog. See ``mobilePairingStatusUpdates()`` for live refresh.
    func mobilePairingStatus() -> MobilePairingStatusSnapshot?

    /// A stream that yields a fresh ``MobilePairingStatusSnapshot`` whenever the
    /// pairing host's status changes (listener bound/stopped, bound port
    /// changed, connection count changed). The Mobile section subscribes so the
    /// bound-port indicator and connection count stay live without polling.
    func mobilePairingStatusUpdates() -> AsyncStream<MobilePairingStatusSnapshot>

    /// The name of the terminal theme that is pinned across both appearances —
    /// i.e. the user's resolved Ghostty `theme` gives light and dark the *same*
    /// theme — or `nil` when the theme follows the appearance.
    ///
    /// The App section's Theme picker shows this as a caveat, because the
    /// picker's System tile is a split light/dark thumbnail: a picture of the
    /// app switching. When the terminal cannot honor half of it, the picture is
    /// a half-truth and the row says so.
    ///
    /// Lives here rather than in the catalog because it is not a setting — it is
    /// derived host state, read from the user's resolved Ghostty config across
    /// *every* discovered path (their own `~/.config/ghostty/config` as well as
    /// any cmux-managed override), so the answer matches the pixels rather than
    /// one file's opinion of them. See ``terminalThemePinnedAcrossAppearancesUpdates()``
    /// for live refresh.
    func terminalThemePinnedAcrossAppearances() -> String?

    /// A stream that yields the pinned-theme name (or `nil`) whenever the
    /// Ghostty config reloads. The Theme picker subscribes so the caveat cannot
    /// go stale in a long-lived Settings window after the user edits their
    /// config or runs `cmux themes set --light X --dark Y`.
    func terminalThemePinnedAcrossAppearancesUpdates() -> AsyncStream<String?>

    /// Cross-platform Iroh and private-network settings controller supplied by
    /// the host app. `nil` in previews and hosts without the Iroh runtime.
    func irohSettingsController() -> (any CmxIrohSettingsControlling)?

    /// The Mac's system name (e.g. `Host.current().localizedName`) used as the
    /// iOS pairing display name when the user sets no override. The Mobile
    /// section shows it as the display-name field placeholder. Empty when
    /// unavailable (previews/tests). This is a stable host value, not derived
    /// from the override, so the placeholder never goes stale as the override
    /// is edited.
    func mobilePairingDefaultDisplayName() -> String

    /// Applies an explicitly-requested iOS pairing port, checking availability
    /// first so a port already in use leaves the running listener untouched. The
    /// Mobile section calls this from its **Apply** button and renders the
    /// returned ``MobilePairingPortApplyResult`` as inline feedback; the live
    /// status stream then reflects the actual bound port.
    ///
    /// `async` because the availability check probes a real bind.
    func applyMobilePairingPort(_ port: Int) async -> MobilePairingPortApplyResult

    /// Current Mac-owned forwarding policy for cmux mobile push notifications.
    func mobilePhonePushSettings() -> MobilePhonePushSettingsSnapshot

    /// Live forwarding-policy updates from every app entrypoint.
    func mobilePhonePushSettingsUpdates() -> AsyncStream<MobilePhonePushSettingsSnapshot>

    /// Applies one forwarding-policy field through the host's shared owner.
    func updateMobilePhonePushSettings(
        _ mutation: MobilePhonePushSettingsMutation
    ) -> MobilePhonePushSettingsSnapshot

    /// Shows the Sleepy Mode screensaver as a non-locking preview (any key/click
    /// exits, no Touch ID). The host owns the overlay window.
    func sleepyModePreview()

    /// Starts Sleepy Mode using the user's current settings. The host owns the
    /// overlay window.
    func sleepyModeStart()

    /// The app-owned Sleepy Mode settings store, so the Preferences section binds
    /// to the same instance the overlay renderer reads (rather than a package
    /// singleton). Previews/tests get a fresh isolated store via the default.
    func sleepyModeStore() -> SleepyModeSettingsStore

    /// Runs host-owned live-refresh side effects after the package resets every
    /// catalog-backed setting.
    func resetAllSettingsSideEffects()

    /// Invalidates host-owned shortcut caches after Settings persists a shortcut change.
    func notifyShortcutSettingsDidChange()

    /// Reloads cmux.json after Settings writes it, so its values apply to
    /// UserDefaults and live chrome before the file watcher notices.
    func reloadSettingsFile()

    /// Whether the host can register `shortcut` as its system-wide hotkey.
    ///
    /// The macOS host applies Carbon conversion and app-reservation checks that
    /// the settings package cannot perform by itself.
    ///
    /// - Parameter shortcut: The complete Show/Hide shortcut proposed by Settings.
    /// - Returns: `true` when the host's runtime registrar can use the shortcut.
    func canRegisterSystemWideHotkey(_ shortcut: StoredShortcut) -> Bool

    /// Applies the host-side OS `AppleLanguages` override for a changed app
    /// language selection.
    func applyLanguageOverride(_ language: AppLanguage)

    /// Gives the host a chance to refresh computer-use permission state.
    func refreshComputerUsePermissions() async

    /// Whether the Computer Use helper currently has Accessibility permission.
    func computerUseAccessibilityGranted() -> Bool

    /// Whether the Computer Use helper currently has Screen Recording permission.
    func computerUseScreenRecordingGranted() -> Bool

    /// Whether the displayed Computer Use permission values are authoritative.
    func computerUsePermissionStatusIsKnown() -> Bool

    /// The remaining setup step, including capture confirmation beyond the TCC grants.
    func computerUseSetupStatus() -> ComputerUseSetupStatus

    /// One runtime-owned enablement, permission, and setup snapshot.
    func computerUseSetupSnapshot() -> ComputerUseSettingsSnapshot

    /// Emits coalesced invalidations of the host's cached permission and setup snapshot.
    func computerUseSetupUpdates() -> AsyncStream<Void>

    /// Opens the explicit setup flow, including when both TCC grants already exist.
    func finishComputerUseSetup()

    /// Starts the helper-owned Accessibility permission flow.
    func requestComputerUseAccessibility()

    /// Starts the helper-owned Screen Recording permission flow.
    func requestComputerUseScreenRecording()

    /// Opens the Accessibility pane in System Settings.
    func openComputerUseAccessibilitySettings()

    /// Opens the Screen Recording pane in System Settings.
    func openComputerUseScreenRecordingSettings()

}

/// Host-provided summary of the existing config-backed automation rules.
public struct AutomationRulesStatus: Equatable, Sendable {
    public let configPath: String
    public let ruleCount: Int
    public let enabledCount: Int
    public let configExists: Bool
    public let hasError: Bool

    public init(
        configPath: String,
        ruleCount: Int,
        enabledCount: Int,
        configExists: Bool,
        hasError: Bool = false
    ) {
        self.configPath = configPath
        self.ruleCount = max(0, ruleCount)
        self.enabledCount = min(max(0, enabledCount), max(0, ruleCount))
        self.configExists = configExists
        self.hasError = hasError
    }

    /// Number of configured rules that are currently disabled.
    public var disabledCount: Int {
        ruleCount - enabledCount
    }
}

/// One right-sidebar tab as the Sidebar section's customization card renders
/// it. `id` is the host's stable mode identifier (the mode raw value).
public struct RightSidebarTabSettingsItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let symbolName: String
    public let isVisible: Bool
    /// Resolved switch-shortcut label (e.g. `⌃4`); empty when unbound.
    public let shortcutLabel: String

    public init(
        id: String,
        title: String,
        symbolName: String,
        isVisible: Bool,
        shortcutLabel: String
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.isVisible = isVisible
        self.shortcutLabel = shortcutLabel
    }
}

public extension SettingsHostActions {
    /// Returns the registry-backed agent choices shown by notification sound settings.
    func notificationSoundAgentOptions() -> [NotificationSoundAgentOption] { [] }

    /// Validates a candidate custom notification sound path on the host.
    func validateNotificationSoundFile(path: String) async -> Bool { false }

    func restartAllowlistedCommandsStatus() -> RestartAllowlistedCommandsSettingsStatus {
        .stateUnavailable
    }

    func restartAllowlistedCommandsStatusUpdates() -> AsyncStream<RestartAllowlistedCommandsSettingsStatus> {
        AsyncStream { $0.finish() }
    }

    func setRestartAllowlistedCommandsEnabled(
        _ enabled: Bool
    ) -> RestartAllowlistedCommandsSettingsMutationResult {
        _ = enabled
        return .init(status: restartAllowlistedCommandsStatus())
    }

    func approveRestartCommandDefinitions() -> RestartAllowlistedCommandsSettingsMutationResult {
        .init(status: restartAllowlistedCommandsStatus())
    }

    func openRestartCommandDefinitionsFile() -> Bool { false }

    func legacyResumeCommandCount() -> Int { 0 }
    /// Empty automation summary for previews and package-only hosts.
    func automationRulesStatus() async -> AutomationRulesStatus {
        AutomationRulesStatus(
            configPath: "~/.cmuxterm/automations.json",
            ruleCount: 0,
            enabledCount: 0,
            configExists: false
        )
    }

    /// Default no-op for hosts without app-owned automation files.
    func openAutomationRulesInExternalEditor() {}

    /// Default failure for hosts without a live automation engine.
    @discardableResult
    func reloadAutomationRules() -> Bool { false }

    /// Default no-op for previews and tests without a live control socket.
    func socketControlConfigurationDidChange() {}

    /// Right-sidebar tab defaults for previews, tests, and package-only
    /// hosts: no tabs, refuse mutations, no updates.
    func rightSidebarTabs() -> [RightSidebarTabSettingsItem] { [] }
    @discardableResult
    func setRightSidebarTabVisible(id: String, visible: Bool) -> Bool { false }
    func moveRightSidebarTab(id: String, offset: Int) {}
    func rightSidebarTabsUpdates() -> AsyncStream<[RightSidebarTabSettingsItem]> {
        AsyncStream { $0.finish() }
    }

    /// Default no-op for package-only settings hosts without Ghostty.
    func terminalAdaptiveDefaultThemeDidChange() {}

    /// Package-only previews expose no local tmux runtime.
    func localTmuxSessions() async throws -> [LocalTmuxSessionSummary] { [] }
    func startLocalTmuxSession(name: String) async throws {
        throw LocalTmuxSettingsActionError.unavailable
    }
    func attachLocalTmuxSession(_ session: LocalTmuxSessionSummary) async throws {
        throw LocalTmuxSettingsActionError.unavailable
    }

    /// Default no-op for package-only settings hosts without a terminal theme picker.
    func openTerminalThemePicker() {}

    /// Package-only hosts have no Ghostty config, so the gallery stays hidden.
    func terminalThemeGalleryContext() -> TerminalThemeGalleryContext? { nil }
    func terminalThemeConfigDidChange(phase: TerminalThemeReloadPhase) {}

    /// Default no-op for package-only settings hosts without a bundled cmux CLI.
    func openTerminalImport() {}

    /// Default no-op for hosts with no app-owned reset side effects.
    func resetAllSettingsSideEffects() {}

    /// Default no-op for hosts with no app-owned shortcut caches.
    func notifyShortcutSettingsDidChange() {}

    /// Default no-op for hosts without a settings file store.
    func reloadSettingsFile() {}

    /// Custom-sidebar defaults for package previews and tests without a live host.
    func customSidebarNames() -> [String] { [] }

    func customSidebarNamesUpdates() async -> AsyncStream<[String]> {
        let names = customSidebarNames()
        return AsyncStream { continuation in
            continuation.yield(names)
            continuation.finish()
        }
    }
    func createCustomSidebar() -> CustomSidebarOnboardingResult {
        .writeFailed
    }
    func installCustomSidebarTemplate(id: String) -> CustomSidebarOnboardingResult {
        _ = id
        return .writeFailed
    }
    func useCustomSidebarTemplate(id: String) -> CustomSidebarOnboardingResult {
        _ = id
        return .writeFailed
    }
    func previewCustomSidebarTemplate(id: String) -> CustomSidebarOnboardingResult {
        _ = id
        return .writeFailed
    }
    func keepCustomSidebarPreview() -> CustomSidebarOnboardingResult { .templateUnavailable }
    func revertCustomSidebarPreview() {}

    func installCustomSidebarExample(id: String) -> CustomSidebarOnboardingResult {
        installCustomSidebarTemplate(id: id)
    }
    func openCustomSidebarInExternalEditor(named name: String) { _ = name }
    func openCustomSidebarsFolder() {}

    /// Default no-op for package previews and tests without host layout editing.
    func customizeWorkspaceLayouts() {}

    /// Default package-only validation for previews and non-macOS hosts.
    func canRegisterSystemWideHotkey(_ shortcut: StoredShortcut) -> Bool {
        ShortcutAction.showHideAllWindows.shortcutBindingPolicyResult(
            for: shortcut
        ) == .accepted
    }

    /// Default no-op for package previews and tests without app-language ownership.
    func applyLanguageOverride(_ language: AppLanguage) {}

    func openMobilePairingWindow() {}

    /// Default no-op preview action for hosts without a Sleepy Mode overlay.
    func sleepyModePreview() {}
    /// Default no-op start action for hosts without a Sleepy Mode overlay.
    func sleepyModeStart() {}
    /// Default isolated store for previews/tests with no Sleepy Mode host.
    func sleepyModeStore() -> SleepyModeSettingsStore { SleepyModeSettingsStore() }

    /// Default no-op for package previews and tests that have no activation-policy host.
    func setMenuBarOnly(_ enabled: Bool) -> Bool { false }

    func browserHistoryEntryCount() -> Int? { nil }

    /// Default: unknown permission state, for previews and tests without a host.
    func desktopNotificationAuthorizationStatus() -> DesktopNotificationAuthorizationState { .unknown }

    /// Default: no live permission updates, for previews and tests without a host.
    func desktopNotificationAuthorizationStatusUpdates() -> AsyncStream<DesktopNotificationAuthorizationState> {
        AsyncStream { $0.finish() }
    }

    /// Default: no refresh hook, for previews and tests without a host.
    func refreshDesktopNotificationAuthorizationStatus() {}

    /// Default: no status, for hosts without a live mobile service (previews/tests).
    func mobilePairingStatus() -> MobilePairingStatusSnapshot? { nil }

    /// Default: an immediately-finished stream, for hosts without a live mobile service.
    func mobilePairingStatusUpdates() -> AsyncStream<MobilePairingStatusSnapshot> {
        AsyncStream { $0.finish() }
    }

    /// Default: not pinned, for hosts with no Ghostty config to read
    /// (previews/tests). Silence is the safe default — a caveat shown where none
    /// is warranted is worse than one that never appears, because it teaches the
    /// reader to stop believing the row.
    func terminalThemePinnedAcrossAppearances() -> String? { nil }

    /// Default: an immediately-finished stream, for hosts with no config reloads.
    func terminalThemePinnedAcrossAppearancesUpdates() -> AsyncStream<String?> {
        AsyncStream { $0.finish() }
    }

    func irohSettingsController() -> (any CmxIrohSettingsControlling)? { nil }

    /// Default: empty, for hosts that cannot resolve the Mac's system name.
    func mobilePairingDefaultDisplayName() -> String { "" }

    /// Default: save-for-later, for hosts without a live mobile service (previews/tests).
    func applyMobilePairingPort(_ port: Int) async -> MobilePairingPortApplyResult {
        (1...65535).contains(port) ? .savedForLater(port: port) : .invalid(requestedPort: port)
    }

    func mobilePhonePushSettings() -> MobilePhonePushSettingsSnapshot {
        .defaultValue
    }

    func mobilePhonePushSettingsUpdates() -> AsyncStream<MobilePhonePushSettingsSnapshot> {
        AsyncStream { $0.finish() }
    }

    func updateMobilePhonePushSettings(
        _ mutation: MobilePhonePushSettingsMutation
    ) -> MobilePhonePushSettingsSnapshot {
        _ = mutation
        return mobilePhonePushSettings()
    }

    func sidebarFontSize() -> SettingsFontSize {
        SettingsFontSize(points: 12.5, minimum: 10, maximum: 20, defaultValue: 12.5)
    }

    func setSidebarFontSize(_ points: Double) async -> Bool { true }

    func surfaceTabBarFontSize() -> SettingsFontSize {
        SettingsFontSize(points: 11, minimum: 8, maximum: 14, defaultValue: 11)
    }

    func setSurfaceTabBarFontSize(_ points: Double) async -> Bool { true }

    func formattedFontSize(_ points: Double) -> String {
        let scaled = (points * 100).rounded()
        let whole = Int(scaled / 100)
        let fraction = abs(Int(scaled) % 100)
        if fraction == 0 { return "\(whole)" }
        if fraction % 10 == 0 { return "\(whole).\(fraction / 10)" }
        return "\(whole).\(fraction < 10 ? "0" : "")\(fraction)"
    }
}

/// No-op ``SettingsHostActions`` for previews, tests, and any context
/// that renders settings without a live host. Lets the runtime expose a
/// non-optional ``SettingsRuntime/hostActions`` so section views never
/// have to branch on an optional host.
@MainActor
public final class NoopSettingsHostActions: SettingsHostActions {
    public init() {}
    public func clearBrowserHistory() {}
    public func openConfigInExternalEditor() {}
    public func sendFeedback() {}
    public func sendTestNotification() {}
    public func openSystemNotificationSettings() {}
    public func restartApp() {}
    public func openBrowserImportFlow() {}
    public func requestNotificationAuthorization() {}
    public func openTerminalConfigWindow() {}
    public func openMobilePairingWindow() {}
    /// No-op notification sound preview used by tests, previews, and
    /// package-only settings hosts.
    public func previewNotificationSound(value: String, customFilePath: String) {}
    public func browserHistoryEntryCount() -> Int? { nil }
}

public extension SettingsHostActions {
    /// Fail-closed default for previews and package-only hosts.
    var isChiefAvailable: Bool { false }
}
