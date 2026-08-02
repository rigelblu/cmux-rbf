import Testing

@testable import CmuxSettingsUI

/// Lifecycle regression tests for ``TerminalThemePinModel``, mirroring
/// ``MobilePairingStatusModelLifecycleTests``.
///
/// The guard matters more here than for the model this one is cloned from.
/// `AppSection.init` runs on every evaluation of the settings section stack and
/// constructs a throwaway model each time — only the first `State(initialValue:)`
/// survives (see the note in `DefaultsValueModel`). If the host read ever migrates
/// into `init`, the mobile model loses an in-memory snapshot read, while this one
/// would pay a **ghostty config read per settings re-render**.
///
/// Added by cold review 2026-08-02: the first implementation kept the injectable
/// seam from the template and dropped its test, which is the inversion worth
/// naming — the clone with the higher cost of regression shipped with less proof.
@MainActor
@Suite struct TerminalThemePinModelLifecycleTests {
    /// Counts host reads and stream creations so construction can be proven inert.
    private final class CountingThemePinHost {
        private(set) var pinnedThemeNameReads = 0
        private(set) var streamCreations = 0
        var currentPinnedThemeName: String?

        private let stream: AsyncStream<String?>

        init(stream: AsyncStream<String?>) {
            self.stream = stream
        }

        func readPinnedThemeName() -> String? {
            pinnedThemeNameReads += 1
            return currentPinnedThemeName
        }

        func makeStream() -> AsyncStream<String?> {
            streamCreations += 1
            return stream
        }
    }

    @Test func initializationDoesNotReadTheHostOrStartObservationStream() {
        let (stream, _) = AsyncStream<String?>.makeStream()
        let host = CountingThemePinHost(stream: stream)

        _ = TerminalThemePinModel(
            currentPinnedThemeName: { host.readPinnedThemeName() },
            makeStream: { host.makeStream() }
        )

        #expect(host.pinnedThemeNameReads == 0)
        #expect(host.streamCreations == 0)
    }

    @Test func startObservingSeedsExactlyOnceNoMatterHowOftenItIsCalled() {
        // `AppSection`'s `.task` can run again on re-appear, and the settings
        // section stack re-evaluates freely — so a second call must not pay for a
        // second host read.
        let (stream, _) = AsyncStream<String?>.makeStream()
        let host = CountingThemePinHost(stream: stream)
        host.currentPinnedThemeName = "rose-pine-pink-city-dawn"

        let model = TerminalThemePinModel(
            currentPinnedThemeName: { host.readPinnedThemeName() },
            makeStream: { host.makeStream() }
        )
        model.startObserving()
        model.startObserving()
        model.startObserving()

        #expect(host.pinnedThemeNameReads == 1)
        #expect(host.streamCreations == 1)
        #expect(model.pinnedThemeName == "rose-pine-pink-city-dawn")
    }

    @Test func aNilSeedIsAValueNotAnAbsence() {
        // `nil` means "the theme follows the appearance" — the common case. It
        // must not be mistaken for "the host has not answered yet" and re-read.
        let (stream, _) = AsyncStream<String?>.makeStream()
        let host = CountingThemePinHost(stream: stream)
        host.currentPinnedThemeName = nil

        let model = TerminalThemePinModel(
            currentPinnedThemeName: { host.readPinnedThemeName() },
            makeStream: { host.makeStream() }
        )
        model.startObserving()
        model.startObserving()

        #expect(host.pinnedThemeNameReads == 1)
        #expect(model.pinnedThemeName == nil)
    }
}
