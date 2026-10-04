import Foundation
import Testing
@testable import CmuxSettings

@Suite("Workspace color chooser preferences")
struct WorkspaceColorMenuPreferencesTests {
    private let canonical = ["Red", "Teal", "Custom 2", "Custom 11"]
    private let palette = ["Red": "#C0392B", "Teal": "#006B6B", "Custom 2": "#445566", "Custom 11": "#778899"]

    @Test func incompleteAndMalformedRecordsUseTheDefault() {
        #expect(WorkspaceColorMenuPreferences.decodeFromUserDefaults(["order": ["Teal"]]) == nil)
        #expect(WorkspaceColorMenuPreferences.decodeFromUserDefaults(["order": ["Teal", 1], "hidden": []]) == nil)
        let preferences = WorkspaceColorMenuPreferences(orderedNames: ["missing", "Teal", "Teal", "Red"], hiddenNames: ["missing"])
        #expect(preferences.order(canonicalNames: canonical) == ["Teal", "Red", "Custom 2", "Custom 11"])
        #expect(WorkspaceColorMenuPreferences.decodeFromUserDefaults(preferences.encodeForUserDefaults()) == preferences)
    }

    @Test func newlyAddedColorsAppendAndRemovedSlotsDoNotPermuteSurvivors() {
        let preferences = WorkspaceColorMenuPreferences(orderedNames: ["Custom 11", "Teal", "Red", "Custom 2"])
        #expect(preferences.order(canonicalNames: ["Red", "Teal", "Custom 11", "Aqua"]) == ["Custom 11", "Teal", "Red", "Aqua"])
    }

    @Test func paletteReconciliationAppendsEvenWhenCanonicalInsertionWouldMoveSurvivors() {
        let before = WorkspaceColorMenuPreferences(hiddenNames: ["Custom 11", "Aqua", "missing"])
        let added = before.reconciled(
            previousCanonicalNames: ["Red", "Custom 11"],
            canonicalNames: ["Red", "Aqua", "Custom 2", "Custom 11"]
        )
        #expect(added.orderedNames == ["Red", "Custom 11", "Aqua", "Custom 2"])
        #expect(added.hiddenNames == ["Custom 11"])
        let removed = added.reconciled(
            previousCanonicalNames: ["Red", "Aqua", "Custom 2", "Custom 11"],
            canonicalNames: ["Red", "Aqua", "Custom 2"]
        )
        #expect(removed.orderedNames == ["Red", "Aqua", "Custom 2"])
        #expect(removed.hiddenNames.isEmpty)
    }

    @Test func movesPreserveHiddenAndEditedMetadata() throws {
        let before = WorkspaceColorSettingsSnapshot(palette: palette, displayNames: ["Custom 11": "Ocean"], labels: ["Teal": "Focused"], preferences: .init(hiddenNames: ["Teal"]))
        let top = try before.applying(.move(name: "Custom 11", before: "Red"), canonicalNames: canonical, defaultPalette: [:])
        #expect(top.preferences.order(canonicalNames: canonical) == ["Custom 11", "Red", "Teal", "Custom 2"])
        let bottom = try top.applying(.move(name: "Custom 11", before: nil), canonicalNames: canonical, defaultPalette: [:])
        #expect(bottom.preferences.order(canonicalNames: canonical) == canonical)
        #expect(top.palette == before.palette)
        #expect(top.displayNames == before.displayNames)
        #expect(top.labels == before.labels)
        #expect(top.preferences.hiddenNames == before.preferences.hiddenNames)
    }

    @Test func twoRecoveryActionsHaveDifferentBoundaries() throws {
        let before = WorkspaceColorSettingsSnapshot(palette: palette, displayNames: ["Custom 11": "Ocean"], labels: ["Red": "Urgent", "Custom 11": "Research"], preferences: .init(orderedNames: Array(canonical.reversed()), hiddenNames: ["Red"]))
        let restored = try before.applying(.restoreOrder, canonicalNames: canonical, defaultPalette: ["Red": "#C0392B"])
        #expect(restored.palette == palette)
        #expect(restored.preferences.hiddenNames == ["Red"])
        #expect(restored.labels == before.labels)
        #expect(restored.displayNames == before.displayNames)
        #expect(restored.preferences.order(canonicalNames: canonical) == canonical)
        let reset = try before.applying(.resetPalette, canonicalNames: canonical, defaultPalette: ["Red": "#C0392B"])
        #expect(reset.palette == ["Red": "#C0392B"])
        #expect(reset.labels == ["Red": "Urgent"])
        #expect(reset.displayNames.isEmpty)
        #expect(reset.preferences == WorkspaceColorMenuPreferences())
    }

    @Test func staleRowAndDestinationAreRejected() {
        let before = WorkspaceColorSettingsSnapshot(palette: palette)
        #expect(throws: WorkspaceColorSettingsSnapshot.SaveError.stale) {
            try before.applying(.move(name: "missing", before: "Red"), canonicalNames: canonical, defaultPalette: [:])
        }
        #expect(throws: WorkspaceColorSettingsSnapshot.SaveError.stale) {
            try before.applying(.move(name: "Red", before: "missing"), canonicalNames: canonical, defaultPalette: [:])
        }
        #expect(throws: WorkspaceColorSettingsSnapshot.SaveError.stale) {
            try before.applying(.visibility(name: "missing", visible: false), canonicalNames: canonical, defaultPalette: [:])
        }
    }

    @Test func hiddenAssignedHexIsNotAnUnlistedRecoveryChoice() {
        let rows = WorkspaceColorMenuModel.candidates(orderedNames: canonical, palette: palette, labels: [:], preferences: .init(hiddenNames: ["Red"]), targetHexes: ["#C0392B"])
        #expect(rows.first?.state == .off)
        #expect(!rows.contains { $0.hex == "#C0392B" })
        #expect(rows.last?.kind == .editLabels)
    }

    @Test func visibleAliasesKeepMixedStateAndAbsentHexIsDeduplicated() {
        let aliases = ["Red": "#006B6B", "Teal": "#006B6B", "Ocean": "#123456"]
        let rows = WorkspaceColorMenuModel.candidates(orderedNames: ["Red", "Teal", "Ocean"], palette: aliases, labels: ["Teal": "Focused"], preferences: .init(orderedNames: ["Ocean", "Teal", "Red"], hiddenNames: ["Red"]), targetHexes: ["#006B6B", "#ABCDEF", "abcdef"])
        let choices = rows.compactMap { if case .paletteEntry(let entry) = $0.kind { return entry.displayName }; return nil }
        #expect(choices == ["Ocean", "Focused (Teal)"])
        #expect(rows.first { $0.hex == "#006B6B" }?.state == .mixed)
        #expect(rows.filter { if case .unlisted = $0.kind { return true }; return false }.count == 1)
    }

    @Test func allHiddenKeepsNoColorAndManagementWithoutInventingAssignment() {
        let rows = WorkspaceColorMenuModel.candidates(orderedNames: canonical, palette: palette, labels: [:], preferences: .init(hiddenNames: canonical), targetHexes: ["#006B6B"])
        #expect(rows.map(\.kind) == [.noColor, .editLabels])
        #expect(rows.first?.state == .off)
    }

    @Test func missingPaletteAndExplicitEmptyPaletteRemainDistinct() throws {
        let suite = "WorkspaceColorMenuPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = SettingCatalog().workspaceColors.palette
        #expect(key.value(in: defaults).count == 16)
        key.set([:], in: defaults)
        #expect(key.value(in: defaults).isEmpty)
    }
}
