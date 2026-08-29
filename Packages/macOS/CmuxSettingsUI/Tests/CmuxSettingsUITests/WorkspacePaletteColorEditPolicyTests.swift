import Testing

@testable import CmuxSettingsUI

@MainActor
@Suite
struct WorkspacePaletteColorEditPolicyTests {
    @Test func uniqueOldValueAutomaticallyUpdatesExistingAssignments() {
        let preview = WorkspacePaletteColorEditPreview(
            paletteName: "Custom 1",
            oldHex: "#0080FF",
            newHex: "#FF80FF",
            workspaceCount: 1,
            groupCount: 0,
            propagationAllowed: true,
            revisionToken: "revision"
        )

        #expect(preview.automaticDecision == .paletteAndAssignments)
    }

    @Test func ambiguousImportedOldValueChangesOnlyTheTargetedPaletteEntry() {
        let preview = WorkspacePaletteColorEditPreview(
            paletteName: "Custom 1",
            oldHex: "#0080FF",
            newHex: "#FF80FF",
            workspaceCount: 1,
            groupCount: 0,
            propagationAllowed: false,
            revisionToken: "revision"
        )

        #expect(preview.automaticDecision == .paletteOnly)
    }
}
