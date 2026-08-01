import CmuxSettings
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `cm-11.1` — `workspaceColors.labels` parsed from `cmux.json`.
///
/// The ordering assertion here is the load-bearing one. `parseWorkspaceColorsSection` has
/// four unconditional returns before its `colors` block ends, so a `labels` block appended
/// after them would silently never execute for anyone who also sets `colors` — which is
/// every user who has customised a palette.
final class WorkspaceColorLabelsConfigTests: XCTestCase {
    private let labelsDefaultsKey = SettingCatalog().workspaceColors.labels.userDefaultsKey

    private var directoryURL: URL!
    private var previousPalette: [String: String]?
    private var previousLabels: [String: String]?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let defaults = UserDefaults.standard
        previousPalette = defaults.dictionary(forKey: WorkspaceTabColorSettings.paletteKey) as? [String: String]
        previousLabels = defaults.dictionary(forKey: labelsDefaultsKey) as? [String: String]
        WorkspaceTabColorSettings.reset(defaults: defaults)
        defaults.removeObject(forKey: labelsDefaultsKey)
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-labels-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        let defaults = UserDefaults.standard
        WorkspaceTabColorSettings.reset(defaults: defaults)
        defaults.removeObject(forKey: labelsDefaultsKey)
        if let previousPalette {
            defaults.set(previousPalette, forKey: WorkspaceTabColorSettings.paletteKey)
        }
        if let previousLabels {
            defaults.set(previousLabels, forKey: labelsDefaultsKey)
        }
        try? FileManager.default.removeItem(at: directoryURL)
        try super.tearDownWithError()
    }

    /// Writes a `cmux.json` and lets the file store apply it to managed defaults.
    private func loadSettings(_ json: String) throws {
        let url = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try json.write(to: url, atomically: true, encoding: .utf8)
        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: url.path,
            fallbackPath: nil,
            startWatching: false
        )
    }

    private var storedLabels: [String: String] {
        UserDefaults.standard.dictionary(forKey: labelsDefaultsKey) as? [String: String] ?? [:]
    }

    func testLabelsAreParsedFromConfig() throws {
        try loadSettings(
            """
            {
              "workspaceColors": {
                "labels": { "Teal": "GOAL: Primary" }
              }
            }
            """
        )
        XCTAssertEqual(storedLabels["Teal"], "GOAL: Primary")
    }

    func testLabelsSurviveAlongsideAColorsBlock() throws {
        // The regression this suite exists for: `colors` ends its block with an
        // unconditional return, so a labels parse placed below it never runs.
        try loadSettings(
            """
            {
              "workspaceColors": {
                "colors": { "Teal": "#006b6b", "Neon Mint": "#00f5d4" },
                "labels": { "Teal": "GOAL: Primary", "Neon Mint": "SPIKE: Scratch" }
              }
            }
            """
        )
        XCTAssertEqual(
            storedLabels["Teal"],
            "GOAL: Primary",
            "labels must be parsed above the `colors` early return"
        )
        XCTAssertEqual(storedLabels["Neon Mint"], "SPIKE: Scratch")
        // And the palette itself must still be applied.
        let palette = WorkspaceTabColorSettings.palette(defaults: .standard)
        XCTAssertEqual(palette.map(\.name).sorted(), ["Neon Mint", "Teal"])
    }

    func testLabelsSurviveAnInvalidIndicatorStyle() throws {
        // `indicatorStyle` returns unconditionally when it cannot be decoded.
        try loadSettings(
            """
            {
              "workspaceColors": {
                "indicatorStyle": "not-a-real-style",
                "labels": { "Teal": "GOAL: Primary" }
              }
            }
            """
        )
        XCTAssertEqual(
            storedLabels["Teal"],
            "GOAL: Primary",
            "an unrelated invalid key must not swallow the labels block"
        )
    }

    func testLabelsSurviveAnInvalidSelectionColor() throws {
        try loadSettings(
            """
            {
              "workspaceColors": {
                "selectionColor": "not-a-hex",
                "labels": { "Teal": "GOAL: Primary" }
              }
            }
            """
        )
        XCTAssertEqual(storedLabels["Teal"], "GOAL: Primary")
    }

    func testInvalidLabelValuesAreIgnoredRatherThanPoisoningTheMap() throws {
        try loadSettings(
            """
            {
              "workspaceColors": {
                "labels": { "Teal": "GOAL: Primary", "Red": 42, "": "orphan" }
              }
            }
            """
        )
        XCTAssertEqual(storedLabels["Teal"], "GOAL: Primary", "a valid sibling must still load")
        XCTAssertNil(storedLabels["Red"], "a non-string label is not a label")
        XCTAssertNil(storedLabels[""], "an empty palette name cannot key a label")
    }

    func testLabelsAreTrimmedAndEmptyOnesDropped() throws {
        try loadSettings(
            """
            {
              "workspaceColors": {
                "labels": { "Teal": "  GOAL: Primary  ", "Blue": "   " }
              }
            }
            """
        )
        XCTAssertEqual(storedLabels["Teal"], "GOAL: Primary")
        XCTAssertNil(storedLabels["Blue"], "a whitespace-only label clears rather than stores")
    }
}
