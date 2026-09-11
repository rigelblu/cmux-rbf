import CmuxSettings
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// What happens to a setting when its key is taken **out** of `cmux.json`.
///
/// The store keeps the value a key overwrote when the file first set it, and
/// puts it back when the key goes away — **unless the setting was changed
/// since**, in which case the change stays (Tom, dogfood 2026-09-11: *"I just
/// reset it, which means you should not do anything and let the reset stay
/// in effect"*). One rule for every `cmux.json`-managed setting, so it is
/// tested across the value kinds that compare differently: a list, and a
/// colour the file can set to `null`.
///
/// The test host shares the dev app's bundle id and so its defaults; the
/// store's two bookkeeping keys are cleared and put back around each test, as
/// `WindowTitleTemplateTests` does.
final class SettingsFileKeyRemovalTests: XCTestCase {
    private let labelsKey = SettingCatalog().reply.labels.userDefaultsKey
    private let selectionColorKey = "sidebarSelectionColorHex"
    private let storeBookkeepingKeys = [
        "cmux.settingsFile.backups.v1",
        "cmux.settingsFile.importedManagedDefaults.v1",
    ]

    private var directoryURL: URL!
    private var previousValues: [String: Any] = [:]

    private var isolatedKeys: [String] { [labelsKey, selectionColorKey] + storeBookkeepingKeys }

    override func setUpWithError() throws {
        try super.setUpWithError()
        let defaults = UserDefaults.standard
        previousValues = [:]
        for key in isolatedKeys {
            previousValues[key] = defaults.object(forKey: key)
            defaults.removeObject(forKey: key)
        }
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-key-removal-\(UUID().uuidString)", isDirectory: true)
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

    private var storedLabels: [String]? {
        UserDefaults.standard.array(forKey: labelsKey) as? [String]
    }

    private var storedSelectionColor: String? {
        UserDefaults.standard.string(forKey: selectionColorKey)
    }

    /// Removing the key after a Settings edit keeps the edit. The store saved
    /// the pre-file list when the file set the key; restoring it would undo
    /// the user's choice with a value they had replaced twice over.
    func testRemovingTheKeyKeepsASettingsEditMadeSince() throws {
        UserDefaults.standard.set(["before", "the file"], forKey: labelsKey)
        try loadSettings(#"{ "reply": { "labels": ["from file"] } }"#)
        XCTAssertEqual(storedLabels, ["from file"])

        UserDefaults.standard.set(["lgtm", "why?", "redline"], forKey: labelsKey)
        try loadSettings(#"{ "reply": { "maxMessagesBack": 5 } }"#)
        XCTAssertEqual(storedLabels, ["lgtm", "why?", "redline"])
    }

    /// The control: with no edit since, removing the key still brings back
    /// what was there before the file set it.
    func testRemovingTheKeyRestoresThePreFileListWhenUntouched() throws {
        UserDefaults.standard.set(["before", "the file"], forKey: labelsKey)
        try loadSettings(#"{ "reply": { "labels": ["from file"] } }"#)
        XCTAssertEqual(storedLabels, ["from file"])

        try loadSettings(#"{ "reply": { "maxMessagesBack": 5 } }"#)
        XCTAssertEqual(storedLabels, ["before", "the file"])
    }

    /// A file `null` stores *nothing*, so "absent" is what the file put
    /// there — not a change made since. Treating it as one dropped the
    /// user's colour for good (cold code review, 2026-09-11). The template
    /// ships `"selectionColor": null`, so uncommenting it is enough.
    func testRemovingANullKeyRestoresThePreFileValue() throws {
        UserDefaults.standard.set("#112233", forKey: selectionColorKey)
        try loadSettings(#"{ "workspaceColors": { "selectionColor": null } }"#)
        XCTAssertNil(storedSelectionColor)

        try loadSettings(#"{ "reply": { "maxMessagesBack": 5 } }"#)
        XCTAssertEqual(storedSelectionColor, "#112233")
    }
}
