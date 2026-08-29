import CmuxSettings
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class WorkspaceColorDisplayNamesConfigTests: XCTestCase {
    private let catalog = SettingCatalog()

    func testDisplayNamesLoadBeforeColorsEarlyReturns() throws {
        try withIsolatedDefaults { directoryURL in
            try loadSettings(
                """
                {
                  "workspaceColors": {
                    "colors": { "Custom 11": "#ff8300", "Custom 12": "#0080ff" },
                    "displayNames": {
                      "Custom 11": "  Tangerine  ",
                      "Custom 12": "tangerine"
                    }
                  }
                }
                """,
                directoryURL: directoryURL
            )

            let stored = UserDefaults.standard.dictionary(
                forKey: catalog.workspaceColors.displayNames.userDefaultsKey
            ) as? [String: String]
            XCTAssertEqual(stored, ["Custom 11": "Tangerine", "Custom 12": "tangerine"])
            XCTAssertEqual(
                WorkspaceTabColorSettings.palette(defaults: .standard).map(\.name).sorted(),
                ["Custom 11", "Custom 12"]
            )
        }
    }

    func testMalformedDisplayNamesAreDropped() throws {
        try withIsolatedDefaults { directoryURL in
            try loadSettings(
                """
                {
                  "workspaceColors": {
                    "displayNames": {
                      "Custom 11": "Tangerine",
                      "Custom 12": "   ",
                      "Custom 13": 42,
                      "": "Orphan"
                    }
                  }
                }
                """,
                directoryURL: directoryURL
            )

            let stored = UserDefaults.standard.dictionary(
                forKey: catalog.workspaceColors.displayNames.userDefaultsKey
            ) as? [String: String]
            XCTAssertEqual(stored, ["Custom 11": "Tangerine"])
        }
    }

    private func withIsolatedDefaults(_ body: (URL) throws -> Void) throws {
        let defaults = UserDefaults.standard
        let paletteKey = WorkspaceTabColorSettings.paletteKey
        let displayNamesKey = catalog.workspaceColors.displayNames.userDefaultsKey
        let oldPalette = defaults.dictionary(forKey: paletteKey)
        let oldDisplayNames = defaults.dictionary(forKey: displayNamesKey)
        WorkspaceTabColorSettings.reset(defaults: defaults)
        defaults.removeObject(forKey: displayNamesKey)
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-display-names-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer {
            WorkspaceTabColorSettings.reset(defaults: defaults)
            defaults.removeObject(forKey: displayNamesKey)
            if let oldPalette { defaults.set(oldPalette, forKey: paletteKey) }
            if let oldDisplayNames { defaults.set(oldDisplayNames, forKey: displayNamesKey) }
            try? FileManager.default.removeItem(at: directoryURL)
        }
        try body(directoryURL)
    }

    private func loadSettings(_ json: String, directoryURL: URL) throws {
        let url = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try json.write(to: url, atomically: true, encoding: .utf8)
        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: url.path,
            fallbackPath: nil,
            startWatching: false
        )
    }
}
