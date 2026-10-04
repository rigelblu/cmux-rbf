import AppKit
import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct WorkspaceColorMenuTests {
    @Test func sharedPaletteWriterAppendsNewEntriesAndDropsOnlyRemovedSlots() throws {
        let suite = "WorkspaceColorMenuTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let colors = SettingCatalog().workspaceColors
        colors.palette.set(["Custom 11": "#445566"], in: defaults)
        WorkspaceTabColorSettings.setColor(named: "Custom 2", hex: "#778899", defaults: defaults)
        #expect(colors.menuPreferences.value(in: defaults).orderedNames == ["Custom 11", "Custom 2"])
        WorkspaceTabColorSettings.removeColor(named: "Custom 11", defaults: defaults)
        #expect(colors.menuPreferences.value(in: defaults).orderedNames == ["Custom 2"])
        WorkspaceTabColorSettings.setColor(named: "Custom 11", hex: "#445566", defaults: defaults)
        #expect(colors.menuPreferences.value(in: defaults).orderedNames == ["Custom 2", "Custom 11"])
        #expect(WorkspaceTabColorSettings.palette(defaults: defaults).map(\.name) == ["Custom 2", "Custom 11"])
    }

    @Test func legacyPaletteSeedsTheSameTypedSettingsRowsBeforePreferencesChange() throws {
        let suite = "WorkspaceColorMenuTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["Teal": "006b6b"], forKey: "workspaceTabColor.defaultOverrides")
        defaults.set(["445566"], forKey: "workspaceTabColor.customColors")
        let before = WorkspaceTabColorSettings.colorSettingsSnapshot(defaults: defaults)
        WorkspaceTabColorSettings.migrateLegacyPaletteForSettings(defaults: defaults)
        let colors = SettingCatalog().workspaceColors
        #expect(colors.palette.value(in: defaults) == before.palette)
        #expect(WorkspaceTabColorSettings.colorSettingsSnapshot(defaults: defaults) == before)
        #expect(colors.customNameHighWaterMark.value(in: defaults) == 1)
        let saved = try WorkspaceTabColorSettings.applyColorPreferences(
            .visibility(name: "Custom 1", visible: false), expected: before, defaults: defaults
        )
        #expect(saved.palette == before.palette)
        #expect(!WorkspaceTabColorSettings.colorMenuCandidates(targetHexes: ["#445566"], defaults: defaults).contains { $0.hex == "#445566" })
    }

    @Test func preferencesPersistAcrossReadersWithoutChangingCanonicalPalette() throws {
        let suite = "WorkspaceColorMenuTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let before = WorkspaceTabColorSettings.colorSettingsSnapshot(defaults: defaults)
        #expect(SettingCatalog().workspaceColors.palette.value(in: defaults) == before.palette)
        let after = try WorkspaceTabColorSettings.applyColorPreferences(
            .move(name: "Teal", before: "Red"), expected: before, defaults: defaults
        )
        let saved = try WorkspaceTabColorSettings.applyColorPreferences(
            .visibility(name: "Red", visible: false), expected: after, defaults: defaults
        )
        let rows = WorkspaceTabColorSettings.colorMenuCandidates(targetHexes: ["#C0392B"], defaults: defaults)
        #expect(rows[1].hex == "#006B6B")
        #expect(!rows.contains { $0.hex == "#C0392B" })
        #expect(WorkspaceTabColorSettings.palette(defaults: defaults).first?.name == "Red")
        #expect(WorkspaceTabColorSettings.resolvedColorHex("Red", defaults: defaults) == "#C0392B")
        #expect(WorkspaceTabColorSettings.colorSettingsSnapshot(defaults: defaults) == saved)
    }

    @Test func successfulRecoveriesKeepTheirDistinctPersistenceBoundaries() throws {
        let suite = "WorkspaceColorMenuTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let colors = SettingCatalog().workspaceColors
        colors.palette.set(["Teal": "#123456", "Custom 11": "#445566"], in: defaults)
        colors.displayNames.set(["Custom 11": "Ocean"], in: defaults)
        colors.labels.set(["Teal": "Focused", "Custom 11": "Research"], in: defaults)
        colors.menuPreferences.set(.init(orderedNames: ["Custom 11", "Teal"], hiddenNames: ["Teal"]), in: defaults)
        colors.customNameHighWaterMark.set(11, in: defaults)
        let before = WorkspaceTabColorSettings.colorSettingsSnapshot(defaults: defaults)
        let restored = try WorkspaceTabColorSettings.applyColorPreferences(.restoreOrder, expected: before, defaults: defaults)
        #expect(restored.palette == before.palette)
        #expect(restored.displayNames == before.displayNames)
        #expect(restored.labels == before.labels)
        #expect(restored.preferences.hiddenNames == ["Teal"])
        let reset = try WorkspaceTabColorSettings.applyColorPreferences(.resetPalette, expected: restored, defaults: defaults)
        #expect(reset.palette.count == 16)
        #expect(reset.palette["Teal"] == "#006B6B")
        #expect(reset.displayNames.isEmpty)
        #expect(reset.labels == ["Teal": "Focused"])
        #expect(reset.preferences == WorkspaceColorMenuPreferences())
        #expect(colors.customNameHighWaterMark.value(in: defaults) == 11)
    }

    @Test func unsuccessfulReadbackRestoresThePriorPreferenceRecord() throws {
        let suite = "WorkspaceColorMenuTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let colors = SettingCatalog().workspaceColors
        let before = WorkspaceTabColorSettings.colorSettingsSnapshot(defaults: defaults)
        #expect(throws: WorkspaceColorSettingsSnapshot.SaveError.failed) {
            try WorkspaceTabColorSettings.applyColorPreferences(.visibility(name: "Teal", visible: false), expected: before, defaults: defaults, persist: { _, _ in
                colors.menuPreferences.set(.init(hiddenNames: ["Red"]), in: defaults)
            })
        }
        #expect(WorkspaceTabColorSettings.colorSettingsSnapshot(defaults: defaults) == before)
        #expect(defaults.object(forKey: colors.menuPreferences.userDefaultsKey) == nil)
    }

    @Test(arguments: Array(1...6))
    func partialResetFailureRestoresEveryPaletteKey(failedAfter: Int) throws {
        let suite = "WorkspaceColorMenuTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let colors = SettingCatalog().workspaceColors
        colors.palette.set(["Teal": "#123456", "Custom 11": "#445566"], in: defaults)
        colors.displayNames.set(["Custom 11": "Ocean"], in: defaults)
        colors.labels.set(["Teal": "Focused", "Custom 11": "Research"], in: defaults)
        colors.menuPreferences.set(.init(orderedNames: ["Custom 11", "Teal"], hiddenNames: ["Teal"]), in: defaults)
        colors.customNameHighWaterMark.set(11, in: defaults)
        defaults.set(["Teal": "#123456"], forKey: "workspaceTabColor.defaultOverrides")
        defaults.set(["#445566"], forKey: "workspaceTabColor.customColors")
        let before = WorkspaceTabColorSettings.colorSettingsSnapshot(defaults: defaults)
        let keys = [colors.palette.userDefaultsKey, "workspaceTabColor.defaultOverrides", "workspaceTabColor.customColors", colors.displayNames.userDefaultsKey, colors.labels.userDefaultsKey, colors.menuPreferences.userDefaultsKey]
        #expect(throws: WorkspaceColorSettingsSnapshot.SaveError.failed) {
            try WorkspaceTabColorSettings.applyColorPreferences(.resetPalette, expected: before, defaults: defaults, persist: { _, _ in
                for key in keys.prefix(failedAfter) { defaults.removeObject(forKey: key) }
                throw WorkspaceColorSettingsSnapshot.SaveError.failed
            })
        }
        #expect(WorkspaceTabColorSettings.colorSettingsSnapshot(defaults: defaults) == before)
        #expect(colors.customNameHighWaterMark.value(in: defaults) == 11)
        #expect(defaults.dictionary(forKey: "workspaceTabColor.defaultOverrides") as? [String: String] == ["Teal": "#123456"])
        #expect(defaults.array(forKey: "workspaceTabColor.customColors") as? [String] == ["#445566"])
    }

    @Test func externalRefreshRejectsStalePreferenceWithoutRecreatingRemovedColor() throws {
        let suite = "WorkspaceColorMenuTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let before = WorkspaceTabColorSettings.colorSettingsSnapshot(defaults: defaults)
        SettingCatalog().workspaceColors.palette.set(["Red": "#C0392B"], in: defaults)
        #expect(throws: WorkspaceColorSettingsSnapshot.SaveError.stale) {
            try WorkspaceTabColorSettings.applyColorPreferences(.move(name: "Teal", before: "Red"), expected: before, defaults: defaults)
        }
        #expect(WorkspaceTabColorSettings.currentColorHex(named: "Teal", defaults: defaults) == nil)
        #expect(SettingCatalog().workspaceColors.menuPreferences.value(in: defaults) == WorkspaceColorMenuPreferences())
    }

    @Test func externalMetadataRefreshRejectsStaleActionOnAnExistingColor() throws {
        let suite = "WorkspaceColorMenuTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let colors = SettingCatalog().workspaceColors
        let before = WorkspaceTabColorSettings.colorSettingsSnapshot(defaults: defaults)
        colors.labels.set(["Teal": "Refreshed"], in: defaults)
        let refreshed = WorkspaceTabColorSettings.colorSettingsSnapshot(defaults: defaults)
        #expect(throws: WorkspaceColorSettingsSnapshot.SaveError.stale) {
            try WorkspaceTabColorSettings.applyColorPreferences(
                .visibility(name: "Teal", visible: false), expected: before, defaults: defaults
            )
        }
        #expect(WorkspaceTabColorSettings.colorSettingsSnapshot(defaults: defaults) == refreshed)
        #expect(defaults.object(forKey: colors.menuPreferences.userDefaultsKey) == nil)
    }

    @Test
    func namedPaletteColorMarksTheMatchingMenuItem() throws {
        let palette = WorkspaceTabColorSettings.labeledPaletteEntries()
        let selected = try #require(palette.first)
        let menu = SidebarColorSubmenu.make(
            targetHexes: ["  \(selected.hex.lowercased()) "],
            apply: { _ in },
            promptCustomColor: {}
        )
        let visiblePalette = WorkspaceTabColorSettings.colorMenuCandidates(targetHexes: [selected.hex]).compactMap {
            if case let .paletteEntry(entry) = $0.kind { return entry }; return nil
        }
        #expect(menu.items.count >= visiblePalette.count + 5)
        for (entry, item) in zip(visiblePalette, menu.items.dropFirst(3)) {
            #expect(item.title == entry.displayName)
            #expect(item.state == (entry.hex == selected.hex ? .on : .off))
            #expect(item.image != nil)
        }
    }

    @Test
    func unmatchedCustomColorLeavesNamedPaletteItemsUnmarked() throws {
        let palette = WorkspaceTabColorSettings.labeledPaletteEntries()
        #expect(!palette.isEmpty)
        let usedHexes = Set(palette.map { $0.hex.uppercased() })
        let customHex = try #require((0..<0x1000000).lazy.map {
            String(format: "#%06X", $0)
        }.first { !usedHexes.contains($0) })
        let menu = SidebarColorSubmenu.make(
            targetHexes: [customHex],
            apply: { _ in },
            promptCustomColor: {}
        )
        let visiblePalette = WorkspaceTabColorSettings.colorMenuCandidates(targetHexes: [customHex]).compactMap {
            if case let .paletteEntry(entry) = $0.kind { return entry }; return nil
        }
        #expect(menu.items.count >= visiblePalette.count + 5)
        for (entry, item) in zip(visiblePalette, menu.items.dropFirst(3)) {
            #expect(item.title == entry.displayName)
            #expect(item.state == .off)
        }
    }
}
