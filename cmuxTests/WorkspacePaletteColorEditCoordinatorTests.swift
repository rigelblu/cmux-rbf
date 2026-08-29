import CmuxSettingsUI
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("WorkspacePaletteColorEditCoordinator", .serialized)
struct WorkspacePaletteColorEditCoordinatorTests {
    @Test("Preview rejects a duplicate palette value")
    func previewRejectsDuplicateHex() throws {
        try withIsolatedPalette([
            "Custom 11": "#FF8300",
            "Custom 12": "#0080FF",
        ]) {
            let result = WorkspacePaletteColorEditCoordinator().preview(
                appDelegate: nil,
                paletteName: "Custom 11",
                expectedOldHex: "#FF8300",
                proposedHex: "#0080ff"
            )

            #expect(result == .failure(.duplicatePaletteValue(paletteName: "Custom 12")))
        }
    }

    @Test("Imported duplicate values remain editable without propagation")
    func importedDuplicateIsRepairable() throws {
        try withIsolatedPalette([
            "Custom 11": "#FF8300",
            "Custom 12": "#FF8300",
        ]) {
            let preview = try WorkspacePaletteColorEditCoordinator().preview(
                appDelegate: nil,
                paletteName: "Custom 11",
                expectedOldHex: "#FF8300",
                proposedHex: "#00C65E"
            ).get()

            #expect(!preview.propagationAllowed)
            #expect(!preview.requiresConfirmation)
        }
    }

    @Test("Palette-only apply commits one normalized custom value")
    func paletteOnlyApplyCommits() throws {
        try withIsolatedPalette(["Custom 11": "#FF8300"]) {
            let coordinator = WorkspacePaletteColorEditCoordinator()
            let preview = try coordinator.preview(
                appDelegate: nil,
                paletteName: "Custom 11",
                expectedOldHex: "#ff8300",
                proposedHex: "00c65e"
            ).get()

            #expect(coordinator.apply(preview, decision: .paletteOnly, appDelegate: nil)
                == .applied(palette: ["Custom 11": "#00C65E"]))
            #expect(WorkspaceTabColorSettings.resolvedPaletteMap() == ["Custom 11": "#00C65E"])
        }
    }

    @Test("Apply fails stale when the palette changes after preview")
    func applyRejectsStalePreview() throws {
        try withIsolatedPalette(["Custom 11": "#FF8300"]) {
            let coordinator = WorkspacePaletteColorEditCoordinator()
            let preview = try coordinator.preview(
                appDelegate: nil,
                paletteName: "Custom 11",
                expectedOldHex: "#FF8300",
                proposedHex: "#00C65E"
            ).get()
            WorkspaceTabColorSettings.persistPaletteMap(["Custom 11": "#112233"])

            #expect(coordinator.apply(preview, decision: .paletteOnly, appDelegate: nil)
                == .rejected(.unavailablePaletteEntry))
            #expect(WorkspaceTabColorSettings.resolvedPaletteMap() == ["Custom 11": "#112233"])
        }
    }

    private func withIsolatedPalette(
        _ palette: [String: String],
        body: () throws -> Void
    ) throws {
        let defaults = UserDefaults.standard
        let oldPalette = defaults.dictionary(forKey: WorkspaceTabColorSettings.paletteKey)
        WorkspaceTabColorSettings.persistPaletteMap(palette, defaults: defaults)
        defer {
            WorkspaceTabColorSettings.reset(defaults: defaults)
            if let oldPalette { defaults.set(oldPalette, forKey: WorkspaceTabColorSettings.paletteKey) }
        }
        try body()
    }
}
