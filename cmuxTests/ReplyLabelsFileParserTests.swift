import CmuxSettings
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `cm-69.3` Scenario A, the file layer — `reply.labels` parsed from
/// `cmux.json`.
///
/// The other two layers (the normaliser, and the catalog default) are pure and
/// tested in `CmuxSettings`'s `ReplyLabelsCatalogTests`. This one exists for
/// the rule only the file store can break: **the parser never writes the
/// defaults.** The store layers user choice over the file over the built-in
/// default, so a parser that filled in the defaults for an absent key
/// would overwrite whatever the Settings screen stored.
///
/// Named before the parser branch was written, because `-only-testing:`
/// matches a class and an unmatched filter still prints `TEST SUCCEEDED`.
final class ReplyLabelsFileParserTests: XCTestCase {
    private let defaultsKey = SettingCatalog().reply.labels.userDefaultsKey

    /// The file store's own bookkeeping, persisted in the same defaults. The
    /// test host shares its bundle id — and so its defaults — with the dev
    /// app, so a real `cmux.json` that sets `reply.labels` leaves a backup
    /// here, and an absent key in a fixture then "restores" it (observed
    /// 2026-09-11: `["ship it", "why?"]`). Cleared and put back, as
    /// `WindowTitleTemplateTests` does.
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
            .appendingPathComponent("cmux-reply-labels-\(UUID().uuidString)", isDirectory: true)
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

    private func loadSettings(_ json: String) throws {
        let url = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try json.write(to: url, atomically: true, encoding: .utf8)
        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: url.path,
            fallbackPath: nil,
            startWatching: false
        )
    }

    /// What the store holds, or `nil` when the file wrote nothing.
    private var storedLabels: [String]? {
        UserDefaults.standard.array(forKey: defaultsKey) as? [String]
    }

    /// A bad entry is skipped and the rest kept — the case the file store's
    /// shared `jsonStringArray` would fail, rejecting the whole list.
    func testAListIsStoredNormalised() throws {
        try loadSettings(#"{ "reply": { "labels": ["ship it", 7, "  why? ", ""] } }"#)
        XCTAssertEqual(storedLabels, ["ship it", "why?"])
    }

    /// `[]` means no labels. Stored as an empty list, it reads back empty
    /// rather than as the defaults.
    func testAnEmptyListIsStoredAsEmpty() throws {
        try loadSettings(#"{ "reply": { "labels": [] } }"#)
        XCTAssertEqual(storedLabels, [])
    }

    func testAnAbsentKeyStoresNothing() throws {
        try loadSettings(#"{ "reply": { "maxMessagesBack": 5 } }"#)
        XCTAssertNil(storedLabels, "the parser must not write the defaults")
        XCTAssertEqual(SettingCatalog().reply.labels.defaultValue, ["lgtm", "why?", "redline"])
    }

    func testAnAbsentSectionStoresNothing() throws {
        try loadSettings(#"{ "sidebar": { "hideAllDetails": true } }"#)
        XCTAssertNil(storedLabels)
    }

    /// A value that is not a list at all is logged and ignored — it neither
    /// becomes a one-label list nor falls back to writing the defaults.
    func testANonListValueStoresNothing() throws {
        for bad in [#""redline""#, "3", "true", "{}", "null"] {
            try loadSettings("{ \"reply\": { \"labels\": \(bad) } }")
            XCTAssertNil(storedLabels, "\(bad) should not be stored")
        }
    }
}
