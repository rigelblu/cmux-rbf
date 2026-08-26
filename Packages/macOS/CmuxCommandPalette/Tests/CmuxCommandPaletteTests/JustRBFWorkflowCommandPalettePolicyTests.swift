import Foundation
import Testing

@testable import CmuxCommandPalette

@Suite("JustRBFWorkflowCommandPalettePolicy")
struct JustRBFWorkflowCommandPalettePolicyTests {
    @Test func recognizesCanonicalWorkflowCommandIdentifiers() throws {
        let workflow = try #require(
            JustRBFWorkflowListParser().parse("claude-ssu\tStart session usage\n").first
        )

        #expect(JustRBFWorkflowCommandPalettePolicy.recognizes(commandID: workflow.commandPaletteID))
        #expect(workflow.commandPaletteID == "palette.workflow.claude-ssu")
        #expect(!JustRBFWorkflowCommandPalettePolicy.recognizes(commandID: "palette.renameWorkspace"))
    }

    @Test func acceptsOnlyTheExactCapturedLocalTerminalWithoutAddingNewline() {
        let workspaceId = UUID()
        let panelId = UUID()
        let otherWorkspaceId = UUID()
        let otherPanelId = UUID()

        #expect(
            JustRBFWorkflowCommandPalettePolicy.activation(
                named: "claude-ssu",
                targetWorkspaceId: workspaceId,
                targetPanelId: panelId,
                resolvedWorkspaceId: workspaceId,
                resolvedPanelId: panelId,
                resolvedPanelIsTerminal: true,
                resolvedPanelIsRemote: false
            ) == JustRBFWorkflowActivation(
                workspaceId: workspaceId,
                panelId: panelId,
                input: "claude-ssu"
            )
        )

        let invalidTargets: [(UUID?, UUID?, Bool, Bool)] = [
            (nil, nil, false, false),
            (otherWorkspaceId, panelId, true, false),
            (workspaceId, otherPanelId, true, false),
            (workspaceId, panelId, false, false),
            (workspaceId, panelId, true, true),
        ]
        for (resolvedWorkspaceId, resolvedPanelId, isTerminal, isRemote) in invalidTargets {
            #expect(
                JustRBFWorkflowCommandPalettePolicy.activation(
                    named: "claude-ssu",
                    targetWorkspaceId: workspaceId,
                    targetPanelId: panelId,
                    resolvedWorkspaceId: resolvedWorkspaceId,
                    resolvedPanelId: resolvedPanelId,
                    resolvedPanelIsTerminal: isTerminal,
                    resolvedPanelIsRemote: isRemote
                ) == nil
            )
        }
    }
}
