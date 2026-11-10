import CmuxSettings
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `cm-136.2` Scenario 7, the file layer — `reply.inline.enabled` parsed from
/// `cmux.json`.
///
/// Shaped like `ReplyLabelsFileParserTests`. The rule it guards is the one the
/// file store can break: **the parser never writes the default.** The store
/// ranks a Settings toggle over the file, so a parser that stored `true` for
/// an absent key would overwrite whatever the user switched off.
///
/// Named before the parser branch was written, because `-only-testing:`
/// matches a class and an unmatched filter still prints `TEST SUCCEEDED`.
final class ReplyInlineEnabledFileParserTests: XCTestCase {
    private let defaultsKey = SettingCatalog().reply.inlineEnabled.userDefaultsKey

    /// The file store's own bookkeeping, persisted in the same defaults. The
    /// test host shares its bundle id with the dev app, so a real `cmux.json`
    /// leaves a backup here; cleared and put back, as the labels tests do.
    private let storeBookkeepingKeys = [
        "cmux.settingsFile.backups.v1",
        "cmux.settingsFile.importedManagedDefaults.v1",
    ]

    private var directoryURL: URL!
    private var previousValues: [String: Any] = [:]

    private var isolatedKeys: [String] { [defaultsKey] + storeBookkeepingKeys }

    override func setUpWithError() throws {
        try super.setUpWithError()
        let defaults = UserDefaults.standard
        previousValues = [:]
        for key in isolatedKeys {
            previousValues[key] = defaults.object(forKey: key)
            defaults.removeObject(forKey: key)
        }
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-reply-inline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        let defaults = UserDefaults.standard
        for key in isolatedKeys {
            defaults.removeObject(forKey: key)
            if let previous = previousValues[key] { defaults.set(previous, forKey: key) }
        }
        try? FileManager.default.removeItem(at: directoryURL)
        try super.tearDownWithError()
    }

    /// Loads the fixture and returns the store, so a test can read which
    /// paths the file marked invalid.
    @discardableResult
    private func loadSettings(_ json: String) throws -> KeyboardShortcutSettingsFileStore {
        let url = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try json.write(to: url, atomically: true, encoding: .utf8)
        return KeyboardShortcutSettingsFileStore(
            primaryPath: url.path,
            fallbackPath: nil,
            startWatching: false
        )
    }

    /// What the store holds, or `nil` when the file wrote nothing.
    private var storedInlineEnabled: Bool? {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool
    }

    func testFalseIsStored() throws {
        try loadSettings(#"{ "reply": { "inline": { "enabled": false } } }"#)
        XCTAssertEqual(storedInlineEnabled, false)
    }

    func testTrueIsStored() throws {
        try loadSettings(#"{ "reply": { "inline": { "enabled": true } } }"#)
        XCTAssertEqual(storedInlineEnabled, true)
    }

    func testAnAbsentKeyStoresNothing() throws {
        try loadSettings(#"{ "reply": { "maxMessagesBack": 5 } }"#)
        XCTAssertNil(storedInlineEnabled, "the parser must not write the default")
        XCTAssertTrue(SettingCatalog().reply.inlineEnabled.defaultValue)
    }

    func testAnAbsentInlineObjectStoresNothing() throws {
        try loadSettings(#"{ "reply": { "labels": ["lgtm"] } }"#)
        XCTAssertNil(storedInlineEnabled)
    }

    /// A string is not a boolean. It is logged as invalid and stores nothing,
    /// so the toolbar stays on, as the default says.
    func testAStringIsLoggedInvalidAndStoresNothing() throws {
        let store = try loadSettings(#"{ "reply": { "inline": { "enabled": "no" } } }"#)
        XCTAssertNil(storedInlineEnabled, "a non-boolean must not be stored")
        XCTAssertEqual(store.invalidSettingPaths, ["reply.inline.enabled"])
    }

    /// `"inline": false` is a switch written at the wrong level. Silently
    /// ignoring it leaves the toolbar on with no warning, so it is logged as
    /// invalid, as `panes.arrangePatterns` does for a non-object.
    func testANonObjectInlineIsLoggedInvalid() throws {
        let store = try loadSettings(#"{ "reply": { "inline": false } }"#)
        XCTAssertNil(storedInlineEnabled, "a non-object must not be stored")
        XCTAssertEqual(store.invalidSettingPaths, ["reply.inline"])
    }
}
