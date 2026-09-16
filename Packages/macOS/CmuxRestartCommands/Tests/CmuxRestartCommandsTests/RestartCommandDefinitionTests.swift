import Foundation
import Testing
@testable import CmuxRestartCommands

@Suite("Restart command definitions")
struct RestartCommandDefinitionTests {
    @Test func defaultDefinitionsFileUsesRegularJSON() {
        let homeDirectory = URL(fileURLWithPath: "/tmp/cmux-restart-command-home", isDirectory: true)

        #expect(
            RestartCommandDefinitionsRepository.defaultDefinitionsFileURL(homeDirectory: homeDirectory)
                .path == "/tmp/cmux-restart-command-home/.config/cmux/restart-commands.json"
        )
    }

    @Test func defaultsMatchOnlyTheThreeApprovedForms() throws {
        let definitions = RestartCommandDefinitionSet.appDefaults
        let matcher = RestartCommandMatcher(definitions: definitions)

        #expect(matcher.match(evidence(argv: ["jjui"], configDirectory: .absent))?.definitionID == .jjui)
        #expect(matcher.match(evidence(argv: ["/opt/bin/jjui"], configDirectory: .present("/tmp/jjui-brief/")))?.definitionID == .jjuiBrief)
        #expect(matcher.match(evidence(argv: ["/opt/bin/hunk", "diff", "--stat"], configDirectory: .absent))?.definitionID == .hunk)
        #expect(definitions.definition(id: .hunk)?.command == "hunk")

        #expect(matcher.match(evidence(argv: ["jjui"], configDirectory: .unavailable)) == nil)
        #expect(matcher.match(evidence(argv: ["jjui"], configDirectory: .present("/tmp/other"))) == nil)
        #expect(matcher.match(evidence(argv: ["hunk"], configDirectory: .absent)) == nil)
        #expect(matcher.match(evidence(argv: ["hunk", "show"], configDirectory: .absent)) == nil)
        #expect(matcher.match(evidence(argv: ["not-jjui"], configDirectory: .absent)) == nil)
    }

    @Test func semanticJSONEditsKeepApprovalDigest() throws {
        let source = """
        {
          "definitions": [
            { "cwd": "saved", "command": "hunk", "match": { "argumentTailPrefix": ["diff"], "executable": "hunk" }, "id": "hunk" },
            { "id": "jjui-brief", "match": { "environment": { "JJUI_CONFIG_DIR": { "normalizedFinalComponent": "jjui-brief", "state": "present" } }, "executable": "jjui" }, "command": "jjui-brief", "cwd": "saved" },
            { "id": "jjui", "match": { "environment": { "JJUI_CONFIG_DIR": { "state": "absent" } }, "executable": "jjui" }, "command": "jjui", "cwd": "saved" }
          ],
          "$schema": "anything-editor-only.json",
          "version": 1
        }
        """
        let decoded = try RestartCommandDefinitionSet.decodeJSON(Data(source.utf8))
        #expect(decoded == .appDefaults)
        #expect(decoded.approvalDigest == RestartCommandDefinitionSet.appDefaults.approvalDigest)
    }

    @Test func commandOnlyEditPreservesDetectorFingerprint() throws {
        let defaults = RestartCommandDefinitionSet.appDefaults
        let edited = try RestartCommandDefinitionSet(definitions: defaults.definitions.map { definition in
            guard definition.id == .hunk else { return definition }
            return RestartCommandDefinition(
                id: definition.id,
                match: definition.match,
                command: "hunk --staged",
                cwd: definition.cwd
            )
        })
        #expect(edited.approvalDigest != defaults.approvalDigest)
        #expect(edited.detectorFingerprint(for: .hunk) == defaults.detectorFingerprint(for: .hunk))
    }

    @Test func unknownFieldsAndByteOverflowFailClosed() throws {
        let unknown = RestartCommandDefinitionSet.appDefaults.editableDefaultsData()
            .replacingUTF8("\"version\": 1", with: "\"version\": 1, \"enabled\": true")
        #expect(throws: RestartCommandDefinitionError.unknownField) {
            try RestartCommandDefinitionSet.decodeJSON(unknown)
        }

        let oneThousand = String(repeating: "é", count: 500)
        let valid = try replacingCommand(.jjui, with: oneThousand)
        #expect(valid.definition(id: .jjui)?.command.utf8.count == 1_000)
        #expect(throws: RestartCommandDefinitionError.commandTooLong) {
            try replacingCommand(.jjui, with: oneThousand + "x")
        }
    }

    @Test func commentsAreRejectedAsInvalidRegularJSON() {
        let commented = Data(
            #"""
            { "version": 1, // comments are not regular JSON
              "definitions": [] }
            """#.utf8
        )

        #expect(throws: RestartCommandDefinitionError.invalidJSON) {
            try RestartCommandDefinitionSet.decodeJSON(commented)
        }
    }

    @Test func commandGrammarAllowsArgumentsButRejectsPromptInjection() throws {
        #expect(try replacingCommand(.hunk, with: "hunk diff --stat").definition(id: .hunk)?.command == "hunk diff --stat")
        #expect(try replacingCommand(.hunk, with: "hunk 'a file'").definition(id: .hunk)?.command == "hunk 'a file'")
        #expect(try replacingCommand(.hunk, with: "hunk a\\ file").definition(id: .hunk)?.command == "hunk a\\ file")

        for unsafe in [
            " hunk", "hunk ", "hunk\tdiff", "hunk\ndiff", "hunk\rdiff",
            "hunk; whoami", "hunk | cat", "hunk && whoami", "hunk $(whoami)",
            "hunk `whoami`", "hunk *", "hunk > out", "hunk 'unterminated",
        ] {
            #expect(throws: RestartCommandDefinitionError.unsafeCommand) {
                try replacingCommand(.hunk, with: unsafe)
            }
        }
    }

    @Test func bundledResourceLoadsShippedDefaults() throws {
        let bundled = try BundledRestartCommandDefinitions.load()
        #expect(bundled.definitions.count == 3)
        #expect(bundled.definitions.map(\.id) == [.hunk, .jjui, .jjuiBrief])
        #expect(bundled.definition(id: .hunk)?.command == "hunk")
        #expect(bundled.definition(id: .jjui)?.command == "jjui")
        #expect(bundled.definition(id: .jjuiBrief)?.command == "jjui-brief")
    }

    @Test func genericIdentifiersValidateSlugsAndAllowCustomEntries() throws {
        #expect(RestartCommandDefinitionID(rawValue: "nvim") != nil)
        #expect(RestartCommandDefinitionID(rawValue: "hx") != nil)
        #expect(RestartCommandDefinitionID(rawValue: "custom-tui-1") != nil)
        #expect(RestartCommandDefinitionID(rawValue: "0") != nil)

        #expect(RestartCommandDefinitionID(rawValue: "") == nil)
        #expect(RestartCommandDefinitionID(rawValue: "NVIM") == nil)
        #expect(RestartCommandDefinitionID(rawValue: "a_b") == nil)
        #expect(RestartCommandDefinitionID(rawValue: "a b") == nil)
        #expect(RestartCommandDefinitionID(rawValue: "-start") == nil)
        #expect(RestartCommandDefinitionID(rawValue: String(repeating: "a", count: 33)) == nil)

        let customJSON = """
        {
          "version": 1,
          "definitions": [
            {
              "id": "nvim",
              "match": { "executable": "nvim" },
              "command": "nvim",
              "cwd": "saved"
            }
          ]
        }
        """
        let decoded = try RestartCommandDefinitionSet.decodeJSON(Data(customJSON.utf8))
        #expect(decoded.definitions.count == 1)
        #expect(decoded.definitions.first?.id.rawValue == "nvim")
        #expect(decoded.definition(id: RestartCommandDefinitionID(rawValue: "nvim")!)?.command == "nvim")
    }

    @Test func strictJSONRejectsTrailingCommas() {
        let trailingComma = Data(
            #"""
            {
              "version": 1,
              "definitions": [
                {
                  "id": "nvim",
                  "match": { "executable": "nvim" },
                  "command": "nvim",
                  "cwd": "saved",
                }
              ]
            }
            """#.utf8
        )
        #expect(throws: RestartCommandDefinitionError.invalidJSON) {
            try RestartCommandDefinitionSet.decodeJSON(trailingComma)
        }
    }

    @Test func definitionCountBoundsEnforced() throws {
        #expect(throws: RestartCommandDefinitionError.incompleteDefinitionSet) {
            try RestartCommandDefinitionSet(definitions: [])
        }

        let one = try RestartCommandDefinitionSet(definitions: [
            RestartCommandDefinition(
                id: .hunk,
                match: RestartCommandMatchDefinition(executable: "hunk"),
                command: "hunk",
                cwd: .saved
            )
        ])
        #expect(one.definitions.count == 1)

        let thirtyTwoDefinitions = (1...32).map { index in
            RestartCommandDefinition(
                id: RestartCommandDefinitionID(rawValue: "app-\(index)")!,
                match: RestartCommandMatchDefinition(executable: "app-\(index)"),
                command: "app-\(index)",
                cwd: .saved
            )
        }
        let thirtyTwo = try RestartCommandDefinitionSet(definitions: thirtyTwoDefinitions)
        #expect(thirtyTwo.definitions.count == 32)

        let thirtyThreeDefinitions = (1...33).map { index in
            RestartCommandDefinition(
                id: RestartCommandDefinitionID(rawValue: "app-\(index)")!,
                match: RestartCommandMatchDefinition(executable: "app-\(index)"),
                command: "app-\(index)",
                cwd: .saved
            )
        }
        #expect(throws: RestartCommandDefinitionError.incompleteDefinitionSet) {
            try RestartCommandDefinitionSet(definitions: thirtyThreeDefinitions)
        }

        let duplicateDefinitions = [
            RestartCommandDefinition(
                id: .hunk,
                match: RestartCommandMatchDefinition(executable: "hunk"),
                command: "hunk",
                cwd: .saved
            ),
            RestartCommandDefinition(
                id: .hunk,
                match: RestartCommandMatchDefinition(executable: "hunk"),
                command: "hunk-two",
                cwd: .saved
            ),
        ]
        #expect(throws: RestartCommandDefinitionError.duplicateDefinition) {
            try RestartCommandDefinitionSet(definitions: duplicateDefinitions)
        }
    }

    private func evidence(
        argv: [String],
        configDirectory: RestartCommandEnvironmentEvidence
    ) -> RestartCommandProcessEvidence {
        RestartCommandProcessEvidence(
            arguments: argv,
            environment: ["JJUI_CONFIG_DIR": configDirectory]
        )
    }

    private func replacingCommand(
        _ id: RestartCommandDefinitionID,
        with command: String
    ) throws -> RestartCommandDefinitionSet {
        try RestartCommandDefinitionSet(definitions: RestartCommandDefinitionSet.appDefaults.definitions.map {
            guard $0.id == id else { return $0 }
            return RestartCommandDefinition(id: $0.id, match: $0.match, command: command, cwd: $0.cwd)
        })
    }
}

private extension Data {
    func replacingUTF8(_ source: String, with replacement: String) -> Data {
        let text = String(decoding: self, as: UTF8.self)
        return Data(text.replacingOccurrences(of: source, with: replacement).utf8)
    }
}
