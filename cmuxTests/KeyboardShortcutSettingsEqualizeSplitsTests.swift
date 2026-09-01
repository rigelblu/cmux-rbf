import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class KeyboardShortcutSettingsEqualizeSplitsTests: XCTestCase {
    func testSettingsFileStoreParsesEqualizeSplitsShortcut() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "equalizeSplits": "cmd+ctrl+e"
              }
            }
            """,
            to: settingsFileURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            store.override(for: .equalizeSplits),
            StoredShortcut(key: "e", command: true, shift: false, option: false, control: true)
        )
    }

    func testSettingsFileStoreParsesOrientationFilteredEqualizeShortcuts() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "equalizeSplitWidths": "cmd+ctrl+h",
                "equalizeSplitHeights": "cmd+ctrl+j"
              }
            }
            """,
            to: settingsFileURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            store.override(for: .equalizeSplitWidths),
            StoredShortcut(key: "h", command: true, shift: false, option: false, control: true)
        )
        XCTAssertEqual(
            store.override(for: .equalizeSplitHeights),
            StoredShortcut(key: "j", command: true, shift: false, option: false, control: true)
        )
    }

    func testOrientationFilteredEqualizeShortcutsAreUnboundByDefault() {
        XCTAssertTrue(KeyboardShortcutSettings.Action.equalizeSplitWidths.defaultShortcut.isUnbound)
        XCTAssertTrue(KeyboardShortcutSettings.Action.equalizeSplitHeights.defaultShortcut.isUnbound)
        XCTAssertFalse(KeyboardShortcutSettings.Action.equalizeSplits.defaultShortcut.isUnbound)
    }

    func testSettingsFileStoreParsesSystemWideHotkeyWithoutSharedStoreRecursion() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "showHideAllWindows": "cmd+ctrl+."
              }
            }
            """,
            to: settingsFileURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            store.override(for: .showHideAllWindows),
            StoredShortcut(key: ".", command: true, shift: false, option: false, control: true)
        )
    }

    /// `#cm-67.1`: `panes.arrangePatterns` has to travel from `cmux.json` into
    /// UserDefaults before `SplitArrangementPattern.custom` can see it.
    ///
    /// This covers the half a reader-only test cannot: `cmux.json` sections are
    /// dispatched by hand in `parseSettingsRoot`, not by walking the catalog, so
    /// registering a `DefaultsKey` is necessary and **not sufficient**. Without
    /// `parsePanesSection` the key never lands and every custom pattern is
    /// silently absent from the menu — which is exactly how this shipped-looking
    /// slice behaved until dogfood caught it.
    func testPanesArrangePatternsTravelFromSettingsFileIntoDefaults() throws {
        let key = SplitArrangementPattern.customPatternsDefaultsKey
        let previous = UserDefaults.standard.dictionary(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.removeObject(forKey: key)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "panes": {
                "arrangePatterns": {
                  "Triptych": "1:1:0.5",
                  "Reading": "2:1",
                  "  ": "1:1",
                  "NotAString": 5,
                  "Reading ": "9:9"
                }
              }
            }
            """,
            to: settingsFileURL
        )

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )

        let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: String]
        // Shape validation only: the blank name and the non-string value are
        // dropped here; weight validation belongs to `SplitRatioSpec` so the
        // parser and the menu cannot disagree about what is valid.
        // `"Reading "` trims onto `"Reading"`. Iteration is sorted by raw key, so
        // `"Reading"` wins every reload rather than whichever the dictionary
        // yielded first — cold review 2026-09-01 flagged the nondeterminism.
        XCTAssertEqual(stored, ["Triptych": "1:1:0.5", "Reading": "2:1"])

        // And the app-side reader turns exactly that into two menu patterns.
        XCTAssertEqual(SplitArrangementPattern.custom().map(\.id), ["custom.Reading", "custom.Triptych"])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let baseURL = FileManager.default.temporaryDirectory
        let directoryURL = baseURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func writeSettingsFile(_ contents: String, to url: URL) throws {
        try contents.data(using: .utf8)?.write(to: url)
    }
}
