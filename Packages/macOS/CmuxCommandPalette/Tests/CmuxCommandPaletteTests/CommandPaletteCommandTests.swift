import Testing

@testable import CmuxCommandPalette

@Suite("CommandPaletteCommand")
struct CommandPaletteCommandTests {
    @Test func titleCodeTokenIsOptionalPresentationMetadata() {
        let ordinaryCommand = command()
        let workflowCommand = command(titleCodeToken: "claude-ssu")

        #expect(ordinaryCommand.titleCodeToken == nil)
        #expect(workflowCommand.titleCodeToken == "claude-ssu")
        #expect(workflowCommand.searchableTexts == ordinaryCommand.searchableTexts)
    }

    private func command(titleCodeToken: String? = nil) -> CommandPaletteCommand {
        CommandPaletteCommand(
            id: "test.command",
            rank: 0,
            title: "Workflow: claude-ssu Start session usage",
            titleCodeToken: titleCodeToken,
            subtitle: "",
            shortcutHint: nil,
            kindLabel: nil,
            keywords: ["workflow"],
            dismissOnRun: true,
            action: {}
        )
    }
}
