import Foundation

/// Tracks whether the terminal theme is pinned to one theme across both
/// appearances, and which theme that is.
///
/// This is host-app runtime state derived from the user's resolved Ghostty
/// config, not a catalog setting, so it arrives through ``SettingsHostActions``
/// rather than ``DefaultsValueModel`` — mirroring ``MobilePairingStatusModel``:
///
/// 1. On construction it keeps ``pinnedThemeName`` `nil` and does not touch the host.
/// 2. ``startObserving()`` seeds it from
///    ``SettingsHostActions/terminalThemePinnedAcrossAppearances()`` and subscribes to
///    ``SettingsHostActions/terminalThemePinnedAcrossAppearancesUpdates()`` via a
///    ``SettingReadDriver``, so the Theme picker's caveat cannot go stale in a
///    long-lived Settings window after the user edits their config or runs
///    `cmux themes set --light X --dark Y`.
///
/// Lifecycle matches ``DefaultsValueModel``: the driver owns the subscription
/// task and cancels it on `deinit`, finishing the stream and tearing down the
/// host's underlying observation.
@MainActor
@Observable
final class TerminalThemePinModel {
    /// The theme name pinned across both appearances, or `nil` when the theme
    /// follows the appearance (and in previews/tests, where no host answers).
    private(set) var pinnedThemeName: String?

    @ObservationIgnored private let currentPinnedThemeName: () -> String?
    @ObservationIgnored private let makeStream: () -> AsyncStream<String?>
    @ObservationIgnored private let driver = SettingReadDriver<String?>()
    @ObservationIgnored private var hasStarted = false

    /// Creates a model bound to the host's pinned-theme stream.
    ///
    /// - Parameter hostActions: The host bridge that supplies the current
    ///   pinned-theme name and a change stream.
    convenience init(hostActions: SettingsHostActions) {
        self.init(
            currentPinnedThemeName: { hostActions.terminalThemePinnedAcrossAppearances() },
            makeStream: { hostActions.terminalThemePinnedAcrossAppearancesUpdates() }
        )
    }

    init(
        currentPinnedThemeName: @escaping () -> String?,
        makeStream: @escaping () -> AsyncStream<String?>
    ) {
        self.currentPinnedThemeName = currentPinnedThemeName
        self.makeStream = makeStream
        pinnedThemeName = nil
    }

    /// Starts the host stream for the retained model.
    ///
    /// Idempotent: the first call reads the current value and starts
    /// observation; later calls are ignored by ``SettingReadDriver``.
    func startObserving() {
        guard !hasStarted else { return }
        hasStarted = true
        pinnedThemeName = currentPinnedThemeName()
        driver.activate(makeStream) { [weak self] name in
            self?.pinnedThemeName = name
        }
    }
}
