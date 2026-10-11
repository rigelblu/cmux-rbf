import CmuxSettings
import Foundation
import Testing

@testable import CmuxSettingsUI

// cm-119.1: a save the store refuses because cmux.json cannot be read reaches
// the Settings error log. The switch test checks the log and that the file's
// bytes are unchanged. The shortcut test checks the same, and also that the row
// goes back to the stored shortcut. What a switch shows after the alert is not
// checked here: the model's value is written only by its change stream, which
// these tests do not start.
// Every test uses its own temp directory, never the user's real cmux.json.

/// An object that is never closed.
private let brokenConfig = #"{ "sidebar": { "width": 240 }, "figma": "#

/// The longest a test waits for the model's save task to finish. A bound only:
/// a passing run returns as soon as the entry is recorded.
private let saveBound: Duration = .seconds(15)

@MainActor
@Suite struct SettingsRefusedSaveTests {

    private struct Fixture {
        let dir: URL
        let fileURL: URL
        let store: JSONConfigStore

        func remove() { try? FileManager.default.removeItem(at: dir) }
    }

    private func makeBrokenFixture() throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-refused-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("cmux.json", isDirectory: false)
        try Data(brokenConfig.utf8).write(to: fileURL)
        return Fixture(dir: dir, fileURL: fileURL, store: JSONConfigStore(fileURL: fileURL))
    }

    /// What the system says for a file in the wrong format at this path.
    private func fileSentence(for url: URL) -> String {
        CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path]).localizedDescription
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + saveBound
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// Scenario 15.
    @Test func refusedSwitchRecordsOneAlertEntry() async throws {
        let fixture = try makeBrokenFixture()
        defer { fixture.remove() }
        let key = SettingCatalog().computerUse.showInMenuBar
        let errorLog = SettingsErrorLog()

        // The store has read the file before the save, whatever the model's
        // stream has done.
        _ = await fixture.store.value(for: key)
        let model = JSONValueModel(store: fixture.store, key: key, errorLog: errorLog)
        model.set(false)

        let recorded = await waitUntil { errorLog.entries.count == 1 }
        #expect(recorded, "the refused save recorded no alert entry")
        #expect(errorLog.entries.count == 1)
        #expect(errorLog.entries.first?.keyID == "computerUse.showInMenuBar")
        #expect(errorLog.entries.first?.message == fileSentence(for: fixture.fileURL))
        #expect(model.lastWriteError != nil)
        #expect(try Data(contentsOf: fixture.fileURL) == Data(brokenConfig.utf8))
    }

    /// Scenario 26.
    @Test func refusedShortcutAssignRollsBackAndRecords() async throws {
        let fixture = try makeBrokenFixture()
        defer { fixture.remove() }
        let catalog = SettingCatalog()
        let errorLog = SettingsErrorLog()
        let action = ShortcutAction.openSettings

        _ = await fixture.store.value(for: catalog.shortcuts.bindings)
        let model = ShortcutListModel(jsonStore: fixture.store, catalog: catalog, errorLog: errorLog)
        await model.assign(
            stroke: ShortcutStroke(key: "j", command: true, shift: true, option: true, control: true),
            to: action
        )

        #expect(errorLog.entries.count == 1)
        #expect(errorLog.entries.first?.keyID == "shortcuts.bindings")
        #expect(errorLog.entries.first?.message == fileSentence(for: fixture.fileURL))
        #expect(model.bindings[action.rawValue] == nil)
        #expect(model.effective(for: action) == action.defaultShortcut)
        #expect(try Data(contentsOf: fixture.fileURL) == Data(brokenConfig.utf8))
    }
}
