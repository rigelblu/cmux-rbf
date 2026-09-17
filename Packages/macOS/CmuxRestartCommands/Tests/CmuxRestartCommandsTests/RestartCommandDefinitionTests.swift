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
        let definitions = try BundledRestartCommandDefinitions.load()
        let matcher = RestartCommandMatcher(definitions: definitions)

        #expect(matcher.match(evidence(argv: ["jjui"], configDirectory: .absent))?.definitionID == "jjui")
        #expect(matcher.match(evidence(argv: ["/opt/bin/jjui"], configDirectory: .present("/tmp/jjui-brief/")))?.definitionID == "jjui-brief")
        #expect(matcher.match(evidence(argv: ["/opt/bin/hunk", "diff", "--stat"], configDirectory: .absent))?.definitionID == "hunk")
        #expect(definitions.definition(id: "hunk")?.command == "hunk diff")

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
            { "cwd": "saved", "command": "hunk diff", "match": { "argumentTailPrefix": ["diff"], "executable": "hunk" }, "id": "hunk" },
            { "id": "jjui-brief", "match": { "environment": { "JJUI_CONFIG_DIR": { "normalizedFinalComponent": "jjui-brief", "state": "present" } }, "executable": "jjui" }, "command": "jjui-brief", "cwd": "saved" },
            { "id": "jjui", "match": { "environment": { "JJUI_CONFIG_DIR": { "state": "absent" } }, "executable": "jjui" }, "command": "jjui", "cwd": "saved" }
          ],
          "$schema": "anything-editor-only.json",
          "version": 1
        }
        """
        let decoded = try RestartCommandDefinitionSet.decodeJSON(Data(source.utf8))
        let shipped = try BundledRestartCommandDefinitions.load()
        #expect(decoded == shipped)
        #expect(decoded.approvalDigest == shipped.approvalDigest)
    }

    @Test func commandOnlyEditPreservesDetectorFingerprint() throws {
        let defaults = try BundledRestartCommandDefinitions.load()
        let edited = try RestartCommandDefinitionSet(definitions: defaults.definitions.map { definition in
            guard definition.id == "hunk" else { return definition }
            return RestartCommandDefinition(
                id: definition.id,
                match: definition.match,
                command: "hunk --staged",
                cwd: definition.cwd
            )
        })
        #expect(edited.approvalDigest != defaults.approvalDigest)
        #expect(edited.detectorFingerprint(for: "hunk") == defaults.detectorFingerprint(for: "hunk"))
    }

    @Test func unknownFieldsAndByteOverflowFailClosed() throws {
        let unknown = try BundledRestartCommandDefinitions.load().editableDefaultsData()
            .replacingUTF8("\"version\": 1", with: "\"version\": 1, \"enabled\": true")
        #expect(throws: RestartCommandDefinitionError.invalidDefinition(problem(.unknownField, 3, "enabled"))) {
            try RestartCommandDefinitionSet.decodeJSON(unknown)
        }

        let oneThousand = String(repeating: "é", count: 500)
        let valid = try replacingCommand("jjui", with: oneThousand)
        #expect(valid.definition(id: "jjui")?.command.utf8.count == 1_000)
        #expect(throws: RestartCommandDefinitionError.commandTooLong) {
            try replacingCommand("jjui", with: oneThousand + "x")
        }
    }

    @Test func commentsAreRejectedAsInvalidRegularJSON() {
        let commented = Data(
            #"""
            { "version": 1, // comments are not regular JSON
              "definitions": [] }
            """#.utf8
        )

        #expect(throws: RestartCommandDefinitionError.invalidJSONAtLine(1)) {
            try RestartCommandDefinitionSet.decodeJSON(commented)
        }
    }

    @Test func commandGrammarAllowsArgumentsButRejectsPromptInjection() throws {
        #expect(try replacingCommand("hunk", with: "hunk diff --stat").definition(id: "hunk")?.command == "hunk diff --stat")
        #expect(try replacingCommand("hunk", with: "hunk 'a file'").definition(id: "hunk")?.command == "hunk 'a file'")
        #expect(try replacingCommand("hunk", with: "hunk a\\ file").definition(id: "hunk")?.command == "hunk a\\ file")

        for unsafe in [
            " hunk", "hunk ", "hunk\tdiff", "hunk\ndiff", "hunk\rdiff",
            "hunk; whoami", "hunk | cat", "hunk && whoami", "hunk $(whoami)",
            "hunk `whoami`", "hunk *", "hunk > out", "hunk 'unterminated",
        ] {
            #expect(throws: RestartCommandDefinitionError.unsafeCommand) {
                try replacingCommand("hunk", with: unsafe)
            }
        }
    }

    @Test func bundledResourceLoadsShippedDefaults() throws {
        let bundled = try BundledRestartCommandDefinitions.load()
        #expect(bundled.definitions.count == 3)
        #expect(bundled.definitions.map(\.id.rawValue) == ["hunk", "jjui", "jjui-brief"])
        #expect(bundled.definition(id: "hunk")?.command == "hunk diff")
        #expect(bundled.definition(id: "jjui")?.command == "jjui")
        #expect(bundled.definition(id: "jjui-brief")?.command == "jjui-brief")
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
        #expect(throws: RestartCommandDefinitionError.invalidJSONAtLine(8)) {
            try RestartCommandDefinitionSet.decodeJSON(trailingComma)
        }
    }

    @Test func leadingUTF8BOMStillDecodesValidCatalog() throws {
        var source = Data([0xEF, 0xBB, 0xBF])
        source.append(try BundledRestartCommandDefinitions.load().editableDefaultsData())

        let decoded = try RestartCommandDefinitionSet.decodeJSON(source)
        #expect(decoded == (try BundledRestartCommandDefinitions.load()))
    }

    @Test func leadingUTF8BOMPreservesLocatedRuleFailure() {
        let source = Data(
            """
            {
              "version": 1,
              "definitions": [{
                "id": "NVIM",
                "match": { "executable": "nvim" },
                "command": "nvim",
                "cwd": "saved"
              }]
            }
            """.utf8
        )
        let expected = RestartCommandDefinitionError.invalidDefinition(problem(.invalidValue, 4, "id"))
        #expect(throws: expected) {
            try RestartCommandDefinitionSet.decodeJSON(source)
        }

        var withBOM = Data([0xEF, 0xBB, 0xBF])
        withBOM.append(source)
        #expect(throws: expected) {
            try RestartCommandDefinitionSet.decodeJSON(withBOM)
        }
    }

    @Test func locatedRuleFailuresNameExactLineKindAndField() throws {
        let validDefinition = #"{"id":"nvim","match":{"executable":"nvim"},"command":"nvim","cwd":"saved"}"#
        let cases: [(String, RestartCommandDefinitionProblem)] = [
            (
                """
                {
                  "mystery": true,
                  "version": 1,
                  "definitions": [\(validDefinition)]
                }
                """,
                problem(.unknownField, 2, "mystery")
            ),
            (
                """
                {
                  "version": 1,
                  "definitions": [{"id":"nvim","match":{"executable":"nvim"},"command":"nvim","cwd":"saved","mystery":true}]
                }
                """,
                problem(.unknownField, 3, "mystery")
            ),
            (
                """
                {
                  "version": 1,
                  "definitions": [{"id":"nvim","match":{
                    "mystery": true,
                    "executable": "nvim"
                  },"command":"nvim","cwd":"saved"}]
                }
                """,
                problem(.unknownField, 4, "mystery")
            ),
            (
                """
                {
                  "version": 1,
                  "definitions": [{"id":"nvim","match":{"executable":"nvim","environment":{
                    "NAME": {
                      "state": "absent", "mystery": true
                    }
                  }},"command":"nvim","cwd":"saved"}]
                }
                """,
                problem(.unknownField, 5, "mystery")
            ),
            (#"{"definitions":["# + validDefinition + #"]}"#, problem(.missingField, 1, "version")),
            (#"{"version":1}"#, problem(.missingField, 1, "definitions")),
            (
                """
                {
                  "$schema": "schema.json",
                  "version": 1,
                  "definitions":
                  [
                    {"match":{"executable":"nvim"},"command":"nvim","cwd":"saved"}
                  ]
                }
                """,
                problem(.missingField, 6, "id")
            ),
            (#"{"version":1,"definitions":[{"id":"nvim","command":"nvim","cwd":"saved"}]}"#, problem(.missingField, 1, "match")),
            (#"{"version":1,"definitions":[{"id":"nvim","match":{"executable":"nvim"},"cwd":"saved"}]}"#, problem(.missingField, 1, "command")),
            (#"{"version":1,"definitions":[{"id":"nvim","match":{"executable":"nvim"},"command":"nvim"}]}"#, problem(.missingField, 1, "cwd")),
            (
                """
                {
                  "$schema": "schema.json",
                  "version": 1,
                  "definitions":
                  [{
                    "id": "nvim",
                    "match": {},
                    "command":"nvim","cwd":"saved"}]
                }
                """,
                problem(.missingField, 7, "executable")
            ),
            (#"{"version":1,"definitions":[{"id":"nvim","match":{"executable":"nvim","environment":{"NAME":{}}},"command":"nvim","cwd":"saved"}]}"#, problem(.missingField, 1, "state")),
            (#"{"version":1,"definitions":[{"id":"nvim","match":{"executable":"nvim","environment":{"NAME":{"state":"present"}}},"command":"nvim","cwd":"saved"}]}"#, problem(.missingField, 1, "normalizedFinalComponent")),
            (
                """
                {
                  "$schema": "schema.json",
                  "version": 1,
                  "definitions":
                  [{
                    "id": "nvim",
                    "command": "nvim",
                    "match": 3,
                    "cwd": "saved"
                  }]
                }
                """,
                problem(.invalidValue, 8, "match")
            ),
            (#"{"version":1,"definitions":[{"id":"nvim","match":{"executable":"nvim"},"command":"nvim","cwd":3}]}"#, problem(.invalidValue, 1, "cwd")),
            (#"{"version":1,"definitions":[{"id":"nvim","match":{"executable":"nvim"},"command":"nvim","cwd":"home"}]}"#, problem(.invalidValue, 1, "cwd")),
            (#"{"version":true,"definitions":["# + validDefinition + #"]}"#, problem(.invalidValue, 1, "version")),
            (#"{"version":1.5,"definitions":["# + validDefinition + #"]}"#, problem(.invalidValue, 1, "version")),
            (#"{"version":1,"definitions":[]}"#, problem(.invalidValue, 1, "definitions")),
            (
                """
                {
                  "$schema": "schema.json",
                  "version": 1,
                  "definitions":
                  [
                  {
                    "command": "nvim",
                    "cwd": "saved",
                    "id": "NVIM",
                    "match": {"executable":"nvim"}
                  }]
                }
                """,
                problem(.invalidValue, 9, "id")
            ),
            (#"{"version":1,"definitions":[{"id":"nvim","match":{"executable":""},"command":"nvim","cwd":"saved"}]}"#, problem(.invalidValue, 1, "executable")),
            (#"{"version":1,"definitions":[{"id":"nvim","match":{"executable":"bin/nvim"},"command":"nvim","cwd":"saved"}]}"#, problem(.invalidValue, 1, "executable")),
            (#"{"version":1,"definitions":[{"id":"nvim","match":{"executable":"nvim","argumentTailPrefix":[]},"command":"nvim","cwd":"saved"}]}"#, problem(.invalidValue, 1, "argumentTailPrefix")),
            (#"{"version":1,"definitions":[{"id":"nvim","match":{"executable":"nvim","argumentTailPrefix":[""]},"command":"nvim","cwd":"saved"}]}"#, problem(.invalidValue, 1, "argumentTailPrefix")),
            (#"{"version":1,"definitions":[{"id":"nvim","match":{"executable":"nvim","environment":{"BAD-NAME":{"state":"absent"}}},"command":"nvim","cwd":"saved"}]}"#, problem(.invalidValue, 1, "environment")),
            (#"{"version":1,"definitions":[{"id":"nvim","match":{"executable":"nvim","environment":{}},"command":"nvim","cwd":"saved"}]}"#, problem(.invalidValue, 1, "environment")),
            (#"{"version":1,"definitions":[{"id":"nvim","match":{"executable":"nvim","environment":{"A":{"state":"absent"},"B":{"state":"absent"},"C":{"state":"absent"},"D":{"state":"absent"},"E":{"state":"absent"}}},"command":"nvim","cwd":"saved"}]}"#, problem(.invalidValue, 1, "environment")),
            (#"{"version":1,"definitions":[{"id":"nvim","match":{"executable":"nvim","environment":{"NAME":{"state":"absent","normalizedFinalComponent":"x"}}},"command":"nvim","cwd":"saved"}]}"#, problem(.invalidValue, 1, "normalizedFinalComponent")),
            (#"{"version":1,"definitions":[{"id":"nvim","match":{"executable":"nvim","environment":{"NAME":{"state":"present","normalizedFinalComponent":""}}},"command":"nvim","cwd":"saved"}]}"#, problem(.invalidValue, 1, "normalizedFinalComponent")),
            (#"{"version":1,"definitions":[{"id":"nvim","match":{"executable":"nvim","environment":{"NAME":{"state":"present","normalizedFinalComponent":"a/b"}}},"command":"nvim","cwd":"saved"}]}"#, problem(.invalidValue, 1, "normalizedFinalComponent")),
            (#"{"version":1,"definitions":[{"id":"nvim","match":{"executable":"nvim"},"command":"","cwd":"saved"}]}"#, problem(.invalidValue, 1, "command")),
            (#"{"version":1,"definitions":[{"id":"nvim","match":{"executable":"nvim"},"command":"nvim; whoami","cwd":"saved"}]}"#, problem(.invalidValue, 1, "command")),
            (#"{"version":1,"definitions":[{"id":"nvim","match":{"executable":"nvim"},"command":""# + String(repeating: "x", count: 1_001) + #"","cwd":"saved"}]}"#, problem(.invalidValue, 1, "command")),
        ]

        for (source, expected) in cases {
            expectLocatedProblem(source, expected)
        }

        let thirtyThree = (1...33).map {
            #"{"id":"app-\#($0)","match":{"executable":"app-\#($0)"},"command":"app-\#($0)","cwd":"saved"}"#
        }.joined(separator: ",")
        expectLocatedProblem(
            #"{"version":1,"definitions":["# + thirtyThree + "]}",
            problem(.invalidValue, 1, "definitions")
        )
    }

    @Test func explicitNullValuesAreInvalidAtTheirKey() {
        let cases: [(String, RestartCommandDefinitionProblem)] = [
            (
                """
                {
                  "version": 1,
                  "definitions": [{
                    "id": "nvim",
                    "match": {
                      "executable": "nvim",
                      "argumentTailPrefix": null
                    },
                    "command": "nvim",
                    "cwd": "saved"
                  }]
                }
                """,
                problem(.invalidValue, 7, "argumentTailPrefix")
            ),
            (
                """
                {
                  "version": 1,
                  "definitions": [{
                    "id": "nvim",
                    "match": {
                      "executable": "nvim",
                      "environment": null
                    },
                    "command": "nvim",
                    "cwd": "saved"
                  }]
                }
                """,
                problem(.invalidValue, 7, "environment")
            ),
            (
                """
                {
                  "version": 1,
                  "definitions": [{
                    "id": "nvim",
                    "match": {
                      "executable": "nvim",
                      "environment": {
                        "NAME": {
                          "state": "present",
                          "normalizedFinalComponent": null
                        }
                      }
                    },
                    "command": "nvim",
                    "cwd": "saved"
                  }]
                }
                """,
                problem(.invalidValue, 10, "normalizedFinalComponent")
            ),
            (
                """
                {
                  "version": 1,
                  "definitions": [{
                    "id": "nvim",
                    "match": { "executable": "nvim" },
                    "command": "nvim",
                    "cwd": null
                  }]
                }
                """,
                problem(.invalidValue, 7, "cwd")
            ),
        ]

        for (source, expected) in cases {
            expectLocatedProblem(source, expected)
        }
    }

    @Test func locatedFailuresUseStructuralPositionsAndEarliestSourcePosition() {
        expectLocatedProblem(
            """
            {
              "version": 1,
              "definitions": [
                {
                  "id": "first",
                  "match": { "executable": "first" },
                  "command": "first",
                  "cwd": "saved"
                },
                {
                  "id": "second",
                  "match": { "executable": "second" },
                  "command": "second",
                  "cwd": "home"
                }
              ]
            }
            """,
            problem(.invalidValue, 14, "cwd")
        )

        expectLocatedProblem(
            """
            {
              "version": 1,
              "definitions": [{
                "id": "nvim",
                "match":
                {},
                "command": "nvim",
                "cwd": "saved"
              }]
            }
            """,
            problem(.missingField, 5, "executable")
        )

        expectLocatedProblem(
            """
            {
              "version": 1,
              "definitions": [
                {
                  "match": { "executable": "nvim" },
                  "command": "nvim",
                  "cwd": "saved"
                }
              ]
            }
            """,
            problem(.missingField, 4, "id")
        )

        expectLocatedProblem(
            #"{"definitions":[],"version":true}"#,
            problem(.invalidValue, 1, "definitions")
        )
        expectLocatedProblem(
            #"{"version":true,"definitions":[]}"#,
            problem(.invalidValue, 1, "version")
        )

        let crlf = """
        {
          "version": 1,
          "definitions": []
        }
        """.replacingOccurrences(of: "\n", with: "\r\n")
        expectLocatedProblem(crlf, problem(.invalidValue, 3, "definitions"))
    }

    @Test func repeatedObjectKeyIsInvalidJSONAtRepeatLine() {
        let repeated = Data(
            """
            {
              "version": 1,
              "version": 1,
              "definitions": []
            }
            """.utf8
        )
        #expect(throws: RestartCommandDefinitionError.invalidJSONAtLine(3)) {
            try RestartCommandDefinitionSet.decodeJSON(repeated)
        }
    }

    @Test func structuralScannerReportsMissingColonLine() {
        let missingColon = Data(
            """
            {
              "version" 1,
              "definitions": []
            }
            """.utf8
        )
        #expect(throws: RestartCommandDefinitionError.invalidJSONAtLine(2)) {
            try RestartCommandDefinitionSet.decodeJSON(missingColon)
        }
    }

    @Test func structuralScannerRejectsNestingBombWithoutCrashing() {
        let bomb = Data(String(repeating: "[", count: 60_000).utf8)
        #expect(throws: RestartCommandDefinitionError.invalidJSONAtLine(1)) {
            try RestartCommandDefinitionSet.decodeJSON(bomb)
        }
    }

    @Test func structuralScannerAllows64Containers() {
        let source = String(repeating: "[", count: 64) + "0" + String(repeating: "]", count: 64)
        #expect(throws: RestartCommandDefinitionError.invalidTopLevelObject) {
            try RestartCommandDefinitionSet.decodeJSON(Data(source.utf8))
        }
    }

    @Test func structuralScannerRejects65thContainerAtItsLine() {
        let source = String(repeating: "[", count: 64) + "\n[0" + String(repeating: "]", count: 65)
        #expect(throws: RestartCommandDefinitionError.invalidJSONAtLine(2)) {
            try RestartCommandDefinitionSet.decodeJSON(Data(source.utf8))
        }
    }

    @Test func duplicateIDsPointAtLaterID() {
        expectLocatedProblem(
            """
            {
              "version": 1,
              "definitions": [
                { "id": "nvim", "match": { "executable": "nvim" }, "command": "nvim", "cwd": "saved" },
                { "id": "nvim", "match": { "executable": "nvim" }, "command": "nvim", "cwd": "saved" }
              ]
            }
            """,
            problem(.repeatedID, 5)
        )
    }

    @Test func topLevelArrayRemainsUnlocated() {
        #expect(throws: RestartCommandDefinitionError.invalidTopLevelObject) {
            try RestartCommandDefinitionSet.decodeJSON(Data(#"[]"#.utf8))
        }
    }

    @Test func programmaticValidationKeepsPlainReasons() {
        let definition = RestartCommandDefinition(
            id: "nvim",
            match: RestartCommandMatchDefinition(executable: "bin/nvim"),
            command: "nvim",
            cwd: .saved
        )
        #expect(throws: RestartCommandDefinitionError.emptyExecutable) {
            try RestartCommandDefinitionSet(definitions: [definition])
        }
    }

    @Test func approvedRBFFileAndBundledResourceStillDecode() throws {
        let source = """
        {
          "$schema": "./restart-commands.schema.json",
          "version": 1,
          "definitions": [
            {
              "id": "jjui",
              "match": {
                "executable": "jjui",
                "environment": {
                  "JJUI_CONFIG_DIR": { "state": "absent" }
                }
              },
              "command": "jjui",
              "cwd": "saved"
            },
            {
              "id": "jjui-brief",
              "match": {
                "executable": "jjui",
                "environment": {
                  "JJUI_CONFIG_DIR": {
                    "state": "present",
                    "normalizedFinalComponent": "jjui-brief"
                  }
                }
              },
              "command": "jjui-brief",
              "cwd": "saved"
            },
            {
              "id": "hunk",
              "match": { "executable": "hunk", "argumentTailPrefix": ["diff"] },
              "command": "hunk diff",
              "cwd": "saved"
            },
            {
              "id": "nvim",
              "match": { "executable": "nvim" },
              "command": "nvim",
              "cwd": "saved"
            },
            {
              "id": "herdr-agent-attach",
              "match": { "executable": "herdr-agent-attach", "argumentTailPrefix": ["--session"] },
              "command": "herdr-agent attach --restore",
              "cwd": "saved"
            }
          ]
        }
        """
        let decoded = try RestartCommandDefinitionSet.decodeJSON(Data(source.utf8))
        #expect(decoded.approvalDigest == "5b0632e82e2b2d7240847661c96103f5c28d080a169d16dbde0700b517080127")
        #expect(try BundledRestartCommandDefinitions.load().definitions.count == 3)
    }

    @Test func environmentNamesAreOpenAndBounded() throws {
        let valid = #"{"version":1,"definitions":[{"id":"herdr","match":{"executable":"herdr","environment":{"HERDR_AGENT_RESTORE":{"state":"present","normalizedFinalComponent":"agent"}}},"command":"herdr","cwd":"saved"}]}"#
        let decoded = try RestartCommandDefinitionSet.decodeJSON(Data(valid.utf8))
        #expect(decoded.definition(id: "herdr")?.match.environment?["HERDR_AGENT_RESTORE"]?.state == .present)

        for name in ["", "BAD=NAME", "BAD-NAME", "1BAD"] {
            let source = #"{"version":1,"definitions":[{"id":"herdr","match":{"executable":"herdr","environment":{""# + name + #"":{"state":"absent"}}},"command":"herdr","cwd":"saved"}]}"#
            expectLocatedProblem(source, problem(.invalidValue, 1, "environment"))
        }
    }

    @Test func definitionCountBoundsEnforced() throws {
        #expect(throws: RestartCommandDefinitionError.incompleteDefinitionSet) {
            try RestartCommandDefinitionSet(definitions: [])
        }

        let one = try RestartCommandDefinitionSet(definitions: [
            RestartCommandDefinition(
                id: "hunk",
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
                id: "hunk",
                match: RestartCommandMatchDefinition(executable: "hunk"),
                command: "hunk",
                cwd: .saved
            ),
            RestartCommandDefinition(
                id: "hunk",
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
        let shipped = try BundledRestartCommandDefinitions.load()
        return try RestartCommandDefinitionSet(definitions: shipped.definitions.map {
            guard $0.id == id else { return $0 }
            return RestartCommandDefinition(id: $0.id, match: $0.match, command: command, cwd: $0.cwd)
        })
    }

    private static func problem(
        _ kind: RestartCommandDefinitionProblem.Kind,
        _ line: Int,
        _ field: String? = nil
    ) -> RestartCommandDefinitionProblem {
        RestartCommandDefinitionProblem(kind: kind, line: line, field: field)
    }

    private func problem(
        _ kind: RestartCommandDefinitionProblem.Kind,
        _ line: Int,
        _ field: String? = nil
    ) -> RestartCommandDefinitionProblem {
        Self.problem(kind, line, field)
    }

    private func expectLocatedProblem(
        _ source: String,
        _ expected: RestartCommandDefinitionProblem,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            _ = try RestartCommandDefinitionSet.decodeJSON(Data(source.utf8))
            Issue.record("Expected located definition failure", sourceLocation: sourceLocation)
        } catch let error as RestartCommandDefinitionError {
            #expect(error == .invalidDefinition(expected), sourceLocation: sourceLocation)
        } catch {
            Issue.record("Unexpected error: \(error)", sourceLocation: sourceLocation)
        }
    }
}

private extension Data {
    func replacingUTF8(_ source: String, with replacement: String) -> Data {
        let text = String(decoding: self, as: UTF8.self)
        return Data(text.replacingOccurrences(of: source, with: replacement).utf8)
    }
}
