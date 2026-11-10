import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `cm-136.2` round 2, the production read: the Reply toolbar's gate reads
/// `reply.inline.enabled` from the app's own defaults, not a constant.
///
/// The gate itself is `ReplyInlineTriggerTests.settingOffIgnores`. This file
/// proves the production environment feeds it the stored value, which is the
/// part a `{ true }` closure would silently get wrong.
@MainActor
@Suite("Reply inline setting read", .serialized)
struct ReplyInlineSettingTests {
    private let defaultsKey = SettingCatalog().reply.inlineEnabled.userDefaultsKey

    @Test("The production environment reads the stored switch, and defaults to on")
    func productionReadsTheSetting() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: defaultsKey)
        defer {
            if let saved { defaults.set(saved, forKey: defaultsKey) } else { defaults.removeObject(forKey: defaultsKey) }
        }

        defaults.set(false, forKey: defaultsKey)
        #expect(ReplyInlineEnvironment.production.settingEnabled() == false)

        defaults.set(true, forKey: defaultsKey)
        #expect(ReplyInlineEnvironment.production.settingEnabled() == true)

        defaults.removeObject(forKey: defaultsKey)
        #expect(ReplyInlineEnvironment.production.settingEnabled() == true, "an absent key is the default, on")
    }

    /// Counts the production observer's calls. A class, so the escaping closure
    /// and the test read the same count.
    @MainActor
    final class FireCount {
        var value = 0
    }

    /// The production observer is `UserDefaults.didChangeNotification` through a
    /// main-queue hop. The controller's `?? AnyCancellable {}` would hide a sink
    /// that never fired, so this test proves it fires, and stops once cancelled.
    @Test("The production observer fires on a defaults write, and stops when cancelled")
    func productionObserverFiresOnADefaultsWrite() async {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: defaultsKey)
        defer {
            if let saved { defaults.set(saved, forKey: defaultsKey) } else { defaults.removeObject(forKey: defaultsKey) }
        }

        let fired = FireCount()
        let token = ReplyInlineEnvironment.production.observeSetting { fired.value += 1 }
        defaults.set(false, forKey: defaultsKey)
        // A bounded poll: the sink hops to the main queue, which this await lets run.
        for _ in 0..<40 where fired.value == 0 { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(fired.value >= 1, "the production observer must fire on a defaults write")

        token?.cancel()
        fired.value = 0
        defaults.set(true, forKey: defaultsKey)
        for _ in 0..<40 where fired.value == 0 { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(fired.value == 0, "a cancelled observer must not fire")
        withExtendedLifetime(token) {}
    }
}
