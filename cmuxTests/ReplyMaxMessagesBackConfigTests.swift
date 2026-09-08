import CmuxSettings
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `cm-69.6` Scenario E — `reply.maxMessagesBack` parsed from `cmux.json`.
///
/// The only check in this slice that `ReplyPanelModel` cannot answer: the cap
/// is a pure value there, and everything about *reading* it lives in the
/// settings layer.
///
/// **Named before the build rather than after, because `-only-testing:`
/// matches a class.** An unmatched filter runs nothing and still prints
/// `TEST SUCCEEDED`, so "name the class later" ships the settings layer
/// unverified behind a green-looking run.
///
/// **The assertion that earns its place is the fallback one.** `cmux.json`
/// sections dispatch by hand in `parseSettingsRoot`, so the key can exist in
/// the catalog, the schema, the template and all 20 locales while being
/// wholly inert — `#cm-67`'s v0.25.1 shipped exactly that, under 149 passing
/// assertions. A test that only checks the happy path passes on a section
/// nobody dispatches, because an absent key and an ignored key both leave the
/// default in place.
final class ReplyMaxMessagesBackConfigTests: XCTestCase {
    private let defaultsKey = SettingCatalog().reply.maxMessagesBack.userDefaultsKey

    private var directoryURL: URL!
    private var previousValue: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let defaults = UserDefaults.standard
        previousValue = defaults.object(forKey: defaultsKey)
        defaults.removeObject(forKey: defaultsKey)
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-reply-cap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: defaultsKey)
        if let previousValue {
            defaults.set(previousValue, forKey: defaultsKey)
        }
        try? FileManager.default.removeItem(at: directoryURL)
        try super.tearDownWithError()
    }

    private func loadSettings(_ json: String) throws {
        let url = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try json.write(to: url, atomically: true, encoding: .utf8)
        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: url.path,
            fallbackPath: nil,
            startWatching: false
        )
    }

    /// The value the panel would read, or `nil` when nothing was stored.
    private var storedCap: Int? {
        UserDefaults.standard.object(forKey: defaultsKey) as? Int
    }

    func testConfiguredValueIsRead() throws {
        try loadSettings(#"{ "reply": { "maxMessagesBack": 10 } }"#)
        XCTAssertEqual(storedCap, 10)
    }

    func testAbsentKeyLeavesTheDefault() throws {
        try loadSettings(#"{ "reply": {} }"#)
        XCTAssertNil(storedCap, "nothing stored means the catalog default applies")
        XCTAssertEqual(SettingCatalog().reply.maxMessagesBack.defaultValue, 5)
    }

    func testAbsentSectionLeavesTheDefault() throws {
        try loadSettings(#"{ "sidebar": { "hideAllDetails": true } }"#)
        XCTAssertNil(storedCap)
    }

    /// Zero, negative and non-integer all fall back rather than being clamped.
    ///
    /// Clamping `0` up to `1` would give the user a cap they did not ask for
    /// and no way to tell it apart from one they did. The catalog default is
    /// the honest answer to an unusable value.
    func testUnusableValuesFallBackToTheDefault() throws {
        for bad in ["0", "-3", #""five""#, "true", "2.5"] {
            try loadSettings("{ \"reply\": { \"maxMessagesBack\": \(bad) } }")
            XCTAssertNil(storedCap, "\(bad) should not be stored")
        }
    }

    /// The range's ceiling is what makes the manual scenarios runnable.
    ///
    /// `cm-69.1` Scenario 7 and `cm-69.2b` Scenario 1 both exercise paging,
    /// which the cap otherwise makes rare — they set this key very high as
    /// their fixture. A ceiling below that would make both untestable.
    func testTheRaisedCapFixtureIsAccepted() throws {
        try loadSettings(#"{ "reply": { "maxMessagesBack": 100000 } }"#)
        XCTAssertEqual(storedCap, 100_000)
    }
}
