import Testing

@testable import CmuxCommandPalette

@Suite("JustRBFWorkflowListParser")
struct JustRBFWorkflowListParserTests {
    private let parser = JustRBFWorkflowListParser()

    @Test func parsesEmptyAndCompleteSnapshotsWithoutNormalizingDescriptions() throws {
        #expect(try parser.parse("") == [])

        let workflows = try parser.parse(
            "claude-ssu\n"
                + "codex-vcs-change-describe\t\n"
                + "gcr-migrate-to-blue\tMigrate \\t safely\n"
        )

        #expect(workflows.map(\.name) == [
            "claude-ssu",
            "codex-vcs-change-describe",
            "gcr-migrate-to-blue",
        ])
        #expect(workflows.map(\.escapedDescription) == [nil, "", "Migrate \\t safely"])
        #expect(workflows[0].commandPaletteID == "palette.workflow.claude-ssu")
        #expect(
            workflows[1].commandPaletteID
                == "palette.workflow.codex-vcs-change-describe"
        )
        #expect(workflows[0].commandPaletteKeywords == [
            "claude-ssu",
            "workflow",
            "just-rbf",
            "rbf",
        ])
        #expect(workflows[1].commandPaletteKeywords == [
            "codex-vcs-change-describe",
            "workflow",
            "just-rbf",
            "rbf",
        ])
        #expect(workflows[2].commandPaletteKeywords == [
            "gcr-migrate-to-blue",
            "workflow",
            "just-rbf",
            "rbf",
            "Migrate \\t safely",
        ])
        #expect(workflows[0].commandPaletteTitle(category: "Workflow") == "Workflow: claude-ssu")
        #expect(
            workflows[1].commandPaletteTitle(category: "Workflow")
                == "Workflow: codex-vcs-change-describe"
        )
        #expect(
            workflows[2].commandPaletteTitle(category: "Workflow")
                == "Workflow: gcr-migrate-to-blue Migrate \\t safely"
        )
    }

    @Test func acceptsOnlyCanonicalNames() throws {
        let workflows = try parser.parse("a\na0-b2\n0\n")
        #expect(workflows.map(\.name) == ["a", "a0-b2", "0"])

        for invalidName in ["A", "with_underscore", "-leading", "trailing-", "double--dash", "café"] {
            #expect(throws: JustRBFWorkflowListParser.ParseError.invalidName(invalidName)) {
                try parser.parse("\(invalidName)\n")
            }
        }
    }

    @Test func rejectsIncompleteOrAmbiguousSnapshots() {
        #expect(throws: JustRBFWorkflowListParser.ParseError.missingFinalNewline) {
            try parser.parse("claude-ssu")
        }
        #expect(throws: JustRBFWorkflowListParser.ParseError.blankRow) {
            try parser.parse("claude-ssu\n\n")
        }
        #expect(throws: JustRBFWorkflowListParser.ParseError.multipleDescriptionSeparators) {
            try parser.parse("claude-ssu\tone\ttwo\n")
        }
        #expect(throws: JustRBFWorkflowListParser.ParseError.duplicateName("claude-ssu")) {
            try parser.parse("claude-ssu\nclaude-ssu\tdescription\n")
        }
    }
}
