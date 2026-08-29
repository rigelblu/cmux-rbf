import Testing

@testable import CmuxSettingsUI

@MainActor
@Suite
struct WorkspacePaletteColorEditHostDispatchTests {
    @Test func paletteEditMethodsDispatchToTheInjectedHostThroughTheProtocol() {
        let preview = WorkspacePaletteColorEditPreview(
            paletteName: "Custom 1",
            oldHex: "#0080FF",
            newHex: "#123456",
            workspaceCount: 0,
            groupCount: 0,
            propagationAllowed: true,
            revisionToken: "revision"
        )
        let host = RecordingWorkspacePaletteColorEditHostActions(preview: preview)
        let injectedHost: any SettingsHostActions = host

        #expect(
            injectedHost.previewWorkspacePaletteColorEdit(
                paletteName: preview.paletteName,
                expectedOldHex: preview.oldHex,
                proposedHex: preview.newHex
            ) == .success(preview)
        )
        #expect(host.previewCalls == 1)

        #expect(
            injectedHost.applyWorkspacePaletteColorEdit(preview, decision: .paletteOnly)
                == .applied(palette: [preview.paletteName: preview.newHex])
        )
        #expect(host.applyCalls == 1)
    }
}

@MainActor
private final class RecordingWorkspacePaletteColorEditHostActions: SettingsHostActions {
    let preview: WorkspacePaletteColorEditPreview
    private(set) var previewCalls = 0
    private(set) var applyCalls = 0

    init(preview: WorkspacePaletteColorEditPreview) {
        self.preview = preview
    }

    func previewWorkspacePaletteColorEdit(
        paletteName: String,
        expectedOldHex: String,
        proposedHex: String
    ) -> Result<WorkspacePaletteColorEditPreview, WorkspacePaletteColorEditRejection> {
        previewCalls += 1
        return .success(preview)
    }

    func applyWorkspacePaletteColorEdit(
        _ preview: WorkspacePaletteColorEditPreview,
        decision: WorkspacePaletteColorEditDecision
    ) -> WorkspacePaletteColorEditResult {
        applyCalls += 1
        return .applied(palette: [preview.paletteName: preview.newHex])
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
