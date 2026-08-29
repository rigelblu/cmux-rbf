import AppKit
import CmuxSettings
import SwiftUI
import Testing

@testable import CmuxSettingsUI

@MainActor
@Suite(.serialized)
struct WorkspaceColorDisplayNameEditingTests {
    @Test func rejectedDirectHexStaysBesideTheDraftThatProducedItsError() throws {
        let suiteName = "workspace-color-rejected-hex-draft-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(
            ["Custom 1": "#FF80FF", "Custom 2": "#FF10FF"],
            forKey: "workspaceTabColor.colors"
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let host = DuplicateRejectingPaletteEditHost()
        let view = WorkspaceColorsSection(
            defaultsStore: UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suiteName)!),
            jsonStore: JSONConfigStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(suiteName).json")
            ),
            catalog: SettingCatalog(),
            errorLog: SettingsErrorLog(),
            hostActions: host
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 1_000, height: 1_600)
        let window = NSWindow(
            contentRect: NSRect(x: -4_000, y: -4_000, width: 1_000, height: 1_600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        defer { window.orderOut(nil) }

        pump {
            Self.editableTextFields(in: window.contentView)
                .contains { $0.stringValue == "#FF10FF" }
        }
        let field = try #require(
            Self.editableTextFields(in: window.contentView)
                .first { $0.stringValue == "#FF10FF" }
        )
        #expect(window.makeFirstResponder(field))
        field.selectText(nil)
        type("#FF80FF", into: window)
        sendReturn(to: window)

        pump { host.proposals == ["#FF80FF"] }
        #expect(
            defaults.dictionary(forKey: "workspaceTabColor.colors")?["Custom 2"] as? String
                == "#FF10FF"
        )
        #expect(field.stringValue == "#FF80FF")

        field.selectText(nil)
        type("#FF70FF", into: window)
        sendReturn(to: window)
        pump { host.proposals == ["#FF80FF", "#FF70FF"] }
        #expect(field.stringValue == "#FF70FF")
        #expect(host.proposals == ["#FF80FF", "#FF70FF"])
    }

    @Test func replacingAnExistingDisplayNameDoesNotCollideWithItsOwnPaletteEntry() async throws {
        let suiteName = "workspace-color-display-name-self-collision-\(UUID().uuidString)"
        do {
            let setup = try #require(UserDefaults(suiteName: suiteName))
            setup.removePersistentDomain(forName: suiteName)
            setup.set(
                ["Custom 1": "#FF80FF", "Custom 2": "#FF10FF"],
                forKey: "workspaceTabColor.colors"
            )
            setup.set(
                ["Custom 1": "rigelblu", "Custom 2": "sdf"],
                forKey: "workspaceTabColor.displayNames"
            )
            setup.set(
                ["Custom 1": "Goal: CONTINUOUS", "Custom 2": "fsf"],
                forKey: "workspaceTabColor.labels"
            )
        }
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        let catalog = SettingCatalog()
        let view = WorkspaceColorsSection(
            defaultsStore: UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suiteName)!),
            jsonStore: JSONConfigStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(suiteName).json")
            ),
            catalog: catalog,
            errorLog: SettingsErrorLog(),
            hostActions: NoopSettingsHostActions()
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 1_000, height: 1_600)
        let window = NSWindow(
            contentRect: NSRect(x: -4_000, y: -4_000, width: 1_000, height: 1_600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        defer { window.orderOut(nil) }

        pump {
            Self.editableTextFields(in: window.contentView)
                .contains { $0.stringValue == "rigelblu" }
        }
        let fields = Self.editableTextFields(in: window.contentView)
        let field = try #require(
            fields.first { $0.stringValue == "rigelblu" },
            "Expected the Custom 1 field; rendered values: \(fields.map(\.stringValue))"
        )
        #expect(window.makeFirstResponder(field))
        field.selectText(nil)
        type("Goal: CONTINUOUS", into: window)
        sendReturn(to: window)
        #expect(
            UserDefaults(suiteName: suiteName)?
                .dictionary(forKey: catalog.workspaceColors.displayNames.userDefaultsKey)?["Custom 1"] as? String
                == "rigelblu"
        )

        field.selectText(nil)
        type("Tangerine", into: window)
        sendReturn(to: window)

        await spin {
            UserDefaults(suiteName: suiteName)?
                .dictionary(forKey: catalog.workspaceColors.displayNames.userDefaultsKey)?["Custom 1"] as? String
                == "Tangerine"
        }
        #expect(
            UserDefaults(suiteName: suiteName)?
                .dictionary(forKey: catalog.workspaceColors.displayNames.userDefaultsKey)?["Custom 1"] as? String
                == "Tangerine"
        )
    }

    @Test func localErrorBelongsOnlyToTheDraftThatProducedIt() {
        var state = WorkspaceColorAliasErrorState()
        state.record("collision", for: "Goal: CONTINUOUS")

        #expect(
            state.message(
                for: "Goal: CONTINUOUS",
                storedValue: "rigelblu",
                importedMessage: nil
            ) == "collision"
        )
        #expect(
            state.message(
                for: "Tangerine",
                storedValue: "rigelblu",
                importedMessage: nil
            ) == nil
        )
    }

    @Test func importedErrorIsHiddenWhileRepairingTheStoredValue() {
        let state = WorkspaceColorAliasErrorState()

        #expect(
            state.message(
                for: "rigelblu",
                storedValue: "rigelblu",
                importedMessage: "imported collision"
            ) == "imported collision"
        )
        #expect(
            state.message(
                for: "Tangerine",
                storedValue: "rigelblu",
                importedMessage: "imported collision"
            ) == nil
        )
    }

    private func pump(until condition: () -> Bool) {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func spin(until condition: () -> Bool) async {
        var spins = 0
        while !condition(), spins < 100_000 {
            await Task.yield()
            spins += 1
        }
    }

    private func type(_ text: String, into window: NSWindow) {
        for character in text {
            sendKey(String(character), keyCode: 0, to: window)
        }
    }

    private func sendReturn(to window: NSWindow) {
        sendKey("\r", keyCode: 36, to: window)
    }

    private func sendKey(_ characters: String, keyCode: UInt16, to window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )
            if let event { window.sendEvent(event) }
        }
    }

    private static func editableTextFields(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        return (view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []
            + view.subviews.flatMap { editableTextFields(in: $0) }
    }

}

@MainActor
private final class DuplicateRejectingPaletteEditHost: SettingsHostActions {
    private(set) var proposals: [String] = []

    func previewWorkspacePaletteColorEdit(
        paletteName: String,
        expectedOldHex: String,
        proposedHex: String
    ) -> Result<WorkspacePaletteColorEditPreview, WorkspacePaletteColorEditRejection> {
        proposals.append(proposedHex)
        if proposedHex == "#FF80FF" {
            return .failure(.duplicatePaletteValue(paletteName: "Custom 1"))
        }
        return .success(
            WorkspacePaletteColorEditPreview(
                paletteName: paletteName,
                oldHex: expectedOldHex,
                newHex: proposedHex,
                workspaceCount: 0,
                groupCount: 0,
                propagationAllowed: true,
                revisionToken: "revision"
            )
        )
    }

    func applyWorkspacePaletteColorEdit(
        _ preview: WorkspacePaletteColorEditPreview,
        decision: WorkspacePaletteColorEditDecision
    ) -> WorkspacePaletteColorEditResult {
        .applied(
            palette: [
                "Custom 1": "#FF80FF",
                "Custom 2": preview.newHex,
            ]
        )
    }

    func clearBrowserHistory() {}
    func openConfigInExternalEditor() {}
    func sendFeedback() {}
    func sendTestNotification() {}
    func openSystemNotificationSettings() {}
    func restartApp() {}
    func openBrowserImportFlow() {}
    func requestNotificationAuthorization() {}
    func openTerminalConfigWindow() {}
    func openMobilePairingWindow() {}
    func previewNotificationSound(value: String, customFilePath: String) {}
    func browserHistoryEntryCount() -> Int? { nil }
}
