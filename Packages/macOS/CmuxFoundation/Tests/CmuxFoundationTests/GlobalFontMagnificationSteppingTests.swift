import Foundation
import Testing

@testable import CmuxFoundation

/// Behavior tests for ``GlobalFontMagnification/step(by:)``, the increment the
/// global zoom shortcuts drive.
///
/// Each test gets its own `UserDefaults` suite and `NotificationCenter` so
/// stepping never touches the running app's stored magnification and change
/// notifications can be counted in isolation.
@Suite struct GlobalFontMagnificationSteppingTests {
    private func makeSubject(
        startingAt percent: Int? = nil
    ) -> (GlobalFontMagnification, UserDefaults, NotificationCenter) {
        let suiteName = "cmux.tests.globalFontMagnification.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        if let percent {
            defaults.set(percent, forKey: GlobalFontMagnification.percentKey)
        }
        let center = NotificationCenter()
        let subject = GlobalFontMagnification(userDefaults: defaults, notificationCenter: center)
        return (subject, defaults, center)
    }

    @Test func stepUpAdvancesOneIncrement() {
        let (subject, _, _) = makeSubject(startingAt: 100)
        #expect(subject.step(by: 1) == 110)
        #expect(subject.storedPercent == 110)
    }

    @Test func stepDownRetreatsOneIncrement() {
        let (subject, _, _) = makeSubject(startingAt: 100)
        #expect(subject.step(by: -1) == 90)
        #expect(subject.storedPercent == 90)
    }

    @Test func multipleIncrementsApplyTogether() {
        let (subject, _, _) = makeSubject(startingAt: 100)
        #expect(subject.step(by: 3) == 130)
    }

    @Test func steppingUpClampsAtMaximum() {
        let (subject, _, _) = makeSubject(startingAt: GlobalFontMagnification.maximumPercent)
        #expect(subject.step(by: 1) == GlobalFontMagnification.maximumPercent)
    }

    @Test func steppingDownClampsAtMinimum() {
        let (subject, _, _) = makeSubject(startingAt: GlobalFontMagnification.minimumPercent)
        #expect(subject.step(by: -1) == GlobalFontMagnification.minimumPercent)
    }

    @Test func overshootingLandsExactlyOnTheBound() {
        let (subject, _, _) = makeSubject(startingAt: 100)
        #expect(subject.step(by: 500) == GlobalFontMagnification.maximumPercent)
        #expect(subject.step(by: -500) == GlobalFontMagnification.minimumPercent)
    }

    /// The guard that keeps key-repeat at a bound from reloading every
    /// terminal's Ghostty config once per repeat.
    ///
    /// ``GlobalFontMagnification/setPercent(_:)`` posts unconditionally, and
    /// `AppDelegate` answers that notification by invalidating the config cache
    /// and reloading every surface. A step that changes nothing must therefore
    /// stay silent.
    @Test func steppingAtABoundPostsNoNotification() {
        let (subject, _, center) = makeSubject(startingAt: GlobalFontMagnification.maximumPercent)
        var posts = 0
        let token = center.addObserver(
            forName: GlobalFontMagnification.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in posts += 1 }
        defer { center.removeObserver(token) }

        for _ in 0..<20 {
            _ = subject.step(by: 1)
        }

        #expect(posts == 0)
    }

    @Test func aStepThatChangesTheValuePostsExactlyOnce() {
        let (subject, _, center) = makeSubject(startingAt: 100)
        var posts = 0
        let token = center.addObserver(
            forName: GlobalFontMagnification.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in posts += 1 }
        defer { center.removeObserver(token) }

        _ = subject.step(by: 1)

        #expect(posts == 1)
    }

    @Test func steppingBackAndForthReturnsToTheStartingPercent() {
        let (subject, _, _) = makeSubject(startingAt: 120)
        _ = subject.step(by: 2)
        _ = subject.step(by: -2)
        #expect(subject.storedPercent == 120)
    }

    /// Stepping from an unset key treats the stored value as the default rather
    /// than as zero.
    @Test func steppingFromUnsetStorageStartsAtTheDefault() {
        let (subject, _, _) = makeSubject()
        #expect(subject.step(by: 1) == GlobalFontMagnification.defaultPercent + GlobalFontMagnification.stepPercent)
    }

    @Test func zeroIncrementsChangeNothingAndStaySilent() {
        let (subject, _, center) = makeSubject(startingAt: 130)
        var posts = 0
        let token = center.addObserver(
            forName: GlobalFontMagnification.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in posts += 1 }
        defer { center.removeObserver(token) }

        #expect(subject.step(by: 0) == 130)
        #expect(posts == 0)
    }
}
