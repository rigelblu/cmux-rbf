import CmuxSettings
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `cm-11.1` — auto-minted `Custom N` palette names must never be reused.
///
/// A raw palette name is the label key, the config dictionary key, and the FNV-1a input
/// to the command-palette command ID. Recycling a freed index therefore retargets any
/// `cmux.json` `actions` override keyed by that ID — its title, subtitle, keywords, and
/// palette visibility — onto a different color. That defect ships in cmux today,
/// independent of labels; `cm-11` repairs it because labels key off the same name.
final class WorkspaceColorMonotonicMintingTests: XCTestCase {
    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUp() {
        super.setUp()
        suiteName = "cmux-monotonic-minting-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// Custom palette entry names, in `palette()` order.
    private func customNames(_ defaults: UserDefaults) -> [String] {
        WorkspaceTabColorSettings.customPaletteEntries(defaults: defaults).map(\.name)
    }

    // MARK: - The core defect

    func testFreedCustomNameIsNeverReused() {
        _ = WorkspaceTabColorSettings.addCustomColor("#111111", defaults: defaults)
        let firstName = try? XCTUnwrap(customNames(defaults).first)
        XCTAssertEqual(firstName, "Custom 1", "first mint should start at index 1")

        WorkspaceTabColorSettings.removeColor(named: "Custom 1", defaults: defaults)
        XCTAssertTrue(customNames(defaults).isEmpty, "the entry should be gone")

        _ = WorkspaceTabColorSettings.addCustomColor("#222222", defaults: defaults)
        let secondName = customNames(defaults).first

        XCTAssertNotEqual(
            secondName,
            "Custom 1",
            """
            A freed custom name was reused. Any cmux.json `actions` override keyed by \
            Custom 1's command ID now silently retargets onto #222222.
            """
        )
    }

    func testReusedNameWouldCarryTheRemovedEntrysCommandIdentity() {
        _ = WorkspaceTabColorSettings.addCustomColor("#111111", defaults: defaults)
        let removedName = customNames(defaults).first ?? ""
        let removedCommandID = WorkspaceColorCommandIdentity.commandID(forPaletteName: removedName)

        WorkspaceTabColorSettings.removeColor(named: removedName, defaults: defaults)
        _ = WorkspaceTabColorSettings.addCustomColor("#222222", defaults: defaults)
        let mintedName = customNames(defaults).first ?? ""

        XCTAssertNotEqual(
            WorkspaceColorCommandIdentity.commandID(forPaletteName: mintedName),
            removedCommandID,
            "the new color must not inherit the removed color's command-palette identity"
        )
    }

    func testALabelKeyedToARemovedEntryDoesNotTransferToItsSuccessor() {
        _ = WorkspaceTabColorSettings.addCustomColor("#111111", defaults: defaults)
        let removedName = customNames(defaults).first ?? ""
        let labels = [removedName: "GOAL: Primary"]

        WorkspaceTabColorSettings.removeColor(named: removedName, defaults: defaults)
        _ = WorkspaceTabColorSettings.addCustomColor("#222222", defaults: defaults)

        let palette = WorkspaceTabColorSettings.resolvedPaletteMap(defaults: defaults)
        let entries = WorkspaceColorSemanticLabelResolver.effectiveEntries(
            orderedNames: customNames(defaults),
            palette: palette,
            labels: labels
        )
        XCTAssertEqual(
            entries.first?.label,
            nil,
            "meaning attached to a removed color must not reappear on an unrelated one"
        )
    }

    // MARK: - Durability of the high-water mark

    func testResetPaletteDoesNotReEnableRecycling() {
        _ = WorkspaceTabColorSettings.addCustomColor("#111111", defaults: defaults)
        XCTAssertEqual(customNames(defaults), ["Custom 1"])

        // Settings' Reset Palette restores default colors. It must not restore the
        // ability to recycle a name that already carried meaning.
        WorkspaceTabColorSettings.reset(defaults: defaults)
        _ = WorkspaceTabColorSettings.addCustomColor("#222222", defaults: defaults)

        XCTAssertNotEqual(customNames(defaults).first, "Custom 1", "reset re-enabled recycling")
    }

    func testHighWaterMarkSurvivesRelaunch() {
        _ = WorkspaceTabColorSettings.addCustomColor("#111111", defaults: defaults)
        WorkspaceTabColorSettings.removeColor(named: "Custom 1", defaults: defaults)

        // A fresh UserDefaults instance over the same suite stands in for a relaunch:
        // the mark must be persisted, not held in memory.
        let relaunched = UserDefaults(suiteName: suiteName)!
        _ = WorkspaceTabColorSettings.addCustomColor("#222222", defaults: relaunched)

        XCTAssertNotEqual(
            customNames(relaunched).first,
            "Custom 1",
            "the mark did not survive the process boundary"
        )
    }

    // MARK: - Every path that persists a palette

    func testConfigWrittenPaletteThenRemovalDoesNotReuse() {
        // The brief's concrete case: mark at 0, cmux.json defines Custom 1..3, the user
        // removes Custom 3 in Settings, then Choose Custom Color… mints max(0, 2) + 1.
        WorkspaceTabColorSettings.persistPaletteMap(
            ["Custom 1": "#111111", "Custom 2": "#222222", "Custom 3": "#333333"],
            defaults: defaults
        )
        WorkspaceTabColorSettings.removeColor(named: "Custom 3", defaults: defaults)
        _ = WorkspaceTabColorSettings.addCustomColor("#444444", defaults: defaults)

        let palette = WorkspaceTabColorSettings.resolvedPaletteMap(defaults: defaults)
        XCTAssertNotEqual(
            palette["Custom 3"],
            "#444444",
            "a name that entered through cmux.json was recycled after removal"
        )
    }

    func testMintingSkipsPastTheHighestNameEvenWhenLowerIndexesAreFree() {
        WorkspaceTabColorSettings.persistPaletteMap(
            ["Custom 7": "#777777"],
            defaults: defaults
        )
        _ = WorkspaceTabColorSettings.addCustomColor("#888888", defaults: defaults)

        let minted = customNames(defaults).first { $0 != "Custom 7" }
        XCTAssertEqual(minted, "Custom 8", "minting must count up from the highest name in use")
    }
}
