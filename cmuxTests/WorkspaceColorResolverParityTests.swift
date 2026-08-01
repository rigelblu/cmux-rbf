import CmuxSettings
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `cm-11.1` — one resolver behind every entrypoint that accepts a color value.
///
/// Five sites turn a color value into a hex and four of them behave differently today:
/// the config workspace definition is hex-first then case-insensitive name; the socket
/// `set_color` handler is name-first then hex; `TabManager.applyWorkspacePaletteColor` is
/// an exact case-sensitive dictionary lookup with no hex support at all.
///
/// This suite exists to stop the one-surface-only outcome — labels working in the menu
/// while the CLI silently rejects them. Each behaviour is asserted through all three
/// callers against the same fixture.
@MainActor
final class WorkspaceColorResolverParityTests: XCTestCase {
    private let labelsKey = SettingCatalog().workspaceColors.labels.userDefaultsKey

    private var previousPalette: [String: String]?
    private var previousLabels: [String: String]?
    private var previousManager: TabManager?

    private static let teal = "#006B6B"
    private static let red = "#C0392B"

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        previousPalette = defaults.dictionary(forKey: WorkspaceTabColorSettings.paletteKey) as? [String: String]
        previousLabels = defaults.dictionary(forKey: labelsKey) as? [String: String]

        WorkspaceTabColorSettings.persistPaletteMap(
            ["Teal": Self.teal, "Red": Self.red],
            defaults: defaults
        )
        defaults.set(["Teal": "GOAL: Primary"], forKey: labelsKey)
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        WorkspaceTabColorSettings.reset(defaults: defaults)
        if let previousPalette {
            defaults.set(previousPalette, forKey: WorkspaceTabColorSettings.paletteKey)
        }
        if let previousLabels {
            defaults.set(previousLabels, forKey: labelsKey)
        } else {
            defaults.removeObject(forKey: labelsKey)
        }
        if let previousManager {
            TerminalController.shared.setActiveTabManager(previousManager)
        }
        super.tearDown()
    }

    // MARK: - Caller 1: config workspace definition

    private func configResolved(_ input: String) -> String? {
        WorkspaceTabColorSettings.resolvedColorHex(input)
    }

    // MARK: - Caller 2: TabManager palette action (command palette)

    private func tabManagerResolved(_ input: String) throws -> String? {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        manager.applyWorkspacePaletteColor(named: input, toWorkspaceIds: [workspace.id])
        return workspace.customColor
    }

    // MARK: - Caller 3: socket / CLI set_color

    private func socketResolved(_ input: String) throws -> String? {
        let manager = TabManager()
        if previousManager == nil {
            previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        }
        TerminalController.shared.setActiveTabManager(manager)
        let workspace = try XCTUnwrap(manager.selectedWorkspace)

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "workspace.action",
            "params": [
                "action": "set_color",
                "workspace_id": workspace.id.uuidString,
                "color": input,
            ],
        ]
        let line = try XCTUnwrap(String(
            data: try JSONSerialization.data(withJSONObject: payload),
            encoding: .utf8
        ))
        _ = TerminalController.shared.handleSocketLine(line)
        TerminalMutationBus.shared.drainForTesting()
        return workspace.customColor
    }

    /// Asserts all three callers agree, so a behaviour can never land on one surface only.
    private func assertAllCallersResolve(
        _ input: String,
        to expected: String?,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(configResolved(input), expected, "config definition: \(message)", file: file, line: line)
        XCTAssertEqual(try tabManagerResolved(input), expected, "TabManager palette action: \(message)", file: file, line: line)
        XCTAssertEqual(try socketResolved(input), expected, "socket set_color: \(message)", file: file, line: line)
    }

    // MARK: - Compatibility that must never break

    func testHexResolvesEverywhere() throws {
        try assertAllCallersResolve("#006b6b", to: Self.teal, "a hex value is permanently valid input")
    }

    func testRawPaletteNameResolvesEverywhere() throws {
        try assertAllCallersResolve("Teal", to: Self.teal, "a raw palette name is permanently valid input")
    }

    func testRawNameResolvesCaseInsensitivelyEverywhere() throws {
        // The command-palette path is exact case-sensitive today; unifying is strictly
        // more permissive, so nothing that works now stops working.
        try assertAllCallersResolve("TEAL", to: Self.teal, "raw names fold case once unified")
    }

    // MARK: - The new capability

    func testExactLabelResolvesEverywhere() throws {
        try assertAllCallersResolve(
            "GOAL: Primary",
            to: Self.teal,
            "a semantic label must resolve at every entrypoint, not just in the menu"
        )
    }

    func testLabelResolvesCaseFoldedAndTrimmedEverywhere() throws {
        try assertAllCallersResolve(
            "  goal: primary  ",
            to: Self.teal,
            "labels fold case after trimming"
        )
    }

    // MARK: - Failing closed

    func testUnknownValueIsRejectedEverywhere() throws {
        try assertAllCallersResolve(
            "Chartreuse",
            to: nil,
            "an unknown color must not silently apply some other color"
        )
    }

    func testLabelForAnotherEntryDoesNotResolveToTheWrongColor() throws {
        // "GOAL: Primary" labels Teal. Red must stay reachable only by its own identity.
        XCTAssertEqual(configResolved("Red"), Self.red)
        try assertAllCallersResolve("GOAL: Primary", to: Self.teal, "label points at its own entry")
    }

    // MARK: - No inline matching left behind

    func testSocketNoLongerPrefersNameOverHex() throws {
        // The socket handler matched names before hex. A palette entry named like a hex
        // is the only observable case, and hex-first is the unified order.
        WorkspaceTabColorSettings.persistPaletteMap(
            ["Teal": Self.teal, "#FFFFFF": Self.red],
            defaults: .standard
        )
        XCTAssertEqual(
            try socketResolved("#FFFFFF"),
            "#FFFFFF",
            "hex is resolved as a hex value, not as a palette entry that happens to be named like one"
        )
    }
}
