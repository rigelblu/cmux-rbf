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
