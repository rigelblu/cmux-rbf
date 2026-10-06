import AppKit
import CmuxFoundation
import CmuxSettings
@testable import CmuxSettingsUI
import Foundation
import SwiftUI
import Testing

@MainActor
@Suite(.serialized)
struct WorkspaceColorRowAlignmentTests {

    @Test func builtInAndCustomPaletteRowsAlignTrailingControlColumns() throws {
        let suiteName = "workspace-color-alignment-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        // Set up one custom color alongside built-in colors, with distinct labels
        defaults.set(
            ["Blue": "#007AFF", "Orange": "#FF9500", "Custom 1": "#FF80FF"],
            forKey: "workspaceTabColor.colors"
        )
        defaults.set(
            ["Custom 1": "Ocean"],
            forKey: "workspaceTabColor.displayNames"
        )
        defaults.set(
            ["Blue": "Work Label", "Orange": "Ops Label", "Custom 1": "Personal Label"],
            forKey: "workspaceTabColor.labels"
        )

        let catalog = SettingCatalog()
        let view = WorkspaceColorsSection(
            defaultsStore: UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suiteName)!),
            jsonStore: JSONConfigStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(suiteName).json")
            ),
            catalog: catalog,
            errorLog: SettingsErrorLog(),
            hostActions: AlignmentTestHostActions()
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
            let fields = Self.editableTextFields(in: window.contentView)
            return fields.contains { $0.stringValue == "Work Label" }
                && fields.contains { $0.stringValue == "Ops Label" }
                && fields.contains { $0.stringValue == "Personal Label" }
                && fields.contains { $0.stringValue == "#FF80FF" }
        }

        let fields = Self.editableTextFields(in: window.contentView)
        let blueLabel = try #require(
            fields.first { $0.stringValue == "Work Label" },
            "Rendered fields: \(fields.map(\.stringValue))"
        )
        let orangeLabel = try #require(
            fields.first { $0.stringValue == "Ops Label" },
            "Rendered fields: \(fields.map(\.stringValue))"
        )
        let customLabel = try #require(
            fields.first { $0.stringValue == "Personal Label" },
            "Rendered fields: \(fields.map(\.stringValue))"
        )
        let customHexField = try #require(
            fields.first { $0.stringValue == "#FF80FF" },
            "Rendered fields: \(fields.map(\.stringValue))"
        )

        let blueLabelFrame = blueLabel.convert(blueLabel.bounds, to: window.contentView)
        let orangeLabelFrame = orangeLabel.convert(orangeLabel.bounds, to: window.contentView)
        let customLabelFrame = customLabel.convert(customLabel.bounds, to: window.contentView)
        let customHexFrame = customHexField.convert(customHexField.bounds, to: window.contentView)

        // Column 1 (Label field): width must be 190 across all rows
        #expect(
            abs(blueLabelFrame.width - 190) <= 2.0,
            "Blue label width (\(blueLabelFrame.width)) should be ~190pt"
        )
        #expect(
            abs(orangeLabelFrame.width - 190) <= 2.0,
            "Orange label width (\(orangeLabelFrame.width)) should be ~190pt"
        )
        #expect(
            abs(customLabelFrame.width - 190) <= 2.0,
            "Custom label width (\(customLabelFrame.width)) should be ~190pt"
        )

        // Column 1 (Label field): minX must align within 1pt across built-in and custom rows
        #expect(
            abs(blueLabelFrame.minX - customLabelFrame.minX) <= 1.0,
            "Built-in Blue label minX (\(blueLabelFrame.minX)) must match custom label minX (\(customLabelFrame.minX))"
        )
        #expect(
            abs(orangeLabelFrame.minX - customLabelFrame.minX) <= 1.0,
            "Built-in Orange label minX (\(orangeLabelFrame.minX)) must match custom label minX (\(customLabelFrame.minX))"
        )
        #expect(
            abs(blueLabelFrame.minX - orangeLabelFrame.minX) <= 1.0,
            "Built-in Blue minX (\(blueLabelFrame.minX)) must match built-in Orange minX (\(orangeLabelFrame.minX))"
        )

        // Column 3 (Hex field): custom row hex field width must be 92pt
        #expect(
            abs(customHexFrame.width - 92) <= 2.0,
            "Custom hex field width (\(customHexFrame.width)) should be ~92pt"
        )

        let customNameField = try #require(
            fields.first { $0.stringValue == "Ocean" },
            "Rendered fields: \(fields.map(\.stringValue))"
        )
        let customNameFrame = customNameField.convert(customNameField.bounds, to: window.contentView)
        // Check vertical alignment of custom name field vs custom label field
        #expect(
            abs(customNameFrame.minY - customLabelFrame.minY) <= 1.0,
            "Custom name minY (\(customNameFrame.minY), maxY: \(customNameFrame.maxY)) must match custom label minY (\(customLabelFrame.minY), maxY: \(customLabelFrame.maxY))"
        )
    }

    private static func editableTextFields(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        return (view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []
            + view.subviews.flatMap { editableTextFields(in: $0) }
    }

    private func pump(until condition: () -> Bool) {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }
}

@MainActor
private final class AlignmentTestHostActions: SettingsHostActions {
    func previewWorkspacePaletteColorEdit(
        paletteName: String,
        expectedOldHex: String,
        proposedHex: String
    ) -> Result<WorkspacePaletteColorEditPreview, WorkspacePaletteColorEditRejection> {
        .success(
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
        .applied(palette: [:])
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
