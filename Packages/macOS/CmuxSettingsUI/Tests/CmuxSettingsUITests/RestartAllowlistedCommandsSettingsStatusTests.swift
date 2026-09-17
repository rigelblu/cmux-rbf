import Foundation
import Testing
@testable import CmuxSettingsUI

@Suite("Restart allowlisted commands Settings status")
struct RestartAllowlistedCommandsSettingsStatusTests {
    @Test func syntaxErrorLineAppearsOnlyWhenKnown() throws {
        let located = RestartAllowlistedCommandsSettingsStatus.enabledFallback(
            warning: .unusableUserFile(problem: .invalidJSON(line: 42))
        )
        let generic = RestartAllowlistedCommandsSettingsStatus.enabledFallback(
            warning: .unusableUserFile(problem: nil)
        )

        #expect(try #require(located.warningText).contains("42"))
        #expect(!(try #require(generic.warningText)).contains("42"))
    }

    @Test func locatedProblemsUseExactWarningCopy() {
        let cases: [(RestartCommandsFileProblem, String)] = [
            (
                .invalidJSON(line: 2),
                "Line 2 contains invalid JSON. Shipped definitions are running; custom definitions aren’t."
            ),
            (
                .unknownField(line: 3, field: "mystery"),
                "Line 3 has a field cmux doesn’t know: “mystery”. Shipped definitions are running; custom definitions aren’t."
            ),
            (
                .missingField(line: 4, field: "command"),
                "Line 4 is missing “command”. Shipped definitions are running; custom definitions aren’t."
            ),
            (
                .invalidValue(line: 5, field: "cwd"),
                "Line 5 has an invalid “cwd” value. Shipped definitions are running; custom definitions aren’t."
            ),
            (
                .repeatedID(line: 6),
                "Line 6 repeats an id used above. Shipped definitions are running; custom definitions aren’t."
            ),
        ]

        for (problem, expected) in cases {
            let status = RestartAllowlistedCommandsSettingsStatus.enabledFallback(
                warning: .unusableUserFile(problem: problem)
            )
            #expect(status.warningText == expected)
        }
    }

    @Test func warningFieldIsEscapedAndCutToThirtyTwoCharacters() {
        let field = "1234567890123456789012345678901\n\u{202E}tail"
        let status = RestartAllowlistedCommandsSettingsStatus.enabledFallback(
            warning: .unusableUserFile(problem: .unknownField(line: 9, field: field))
        )
        #expect(
            status.warningText ==
                "Line 9 has a field cmux doesn’t know: “1234567890123456789012345678901\\n…”. Shipped definitions are running; custom definitions aren’t."
        )

        let bidi = RestartAllowlistedCommandsSettingsStatus.enabledFallback(
            warning: .unusableUserFile(problem: .missingField(line: 10, field: "ab\u{202E}cd"))
        )
        #expect(
            bidi.warningText ==
                "Line 10 is missing “ab\\u{202E}cd”. Shipped definitions are running; custom definitions aren’t."
        )
    }

    @Test func newFallbackKeysMatchNeighborLocalizationCoverage() throws {
        var repositoryRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { repositoryRoot.deleteLastPathComponent() }
        let catalogURL = repositoryRoot.appendingPathComponent("Resources/Localizable.xcstrings")
        let root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        )
        let strings = try #require(root["strings"] as? [String: Any])
        let neighbor = try #require(
            strings["settings.terminal.restartCommands.fallbackWarning.atLine"] as? [String: Any]
        )
        let neighborLocalizations = try #require(neighbor["localizations"] as? [String: Any])
        let keys = [
            "settings.terminal.restartCommands.fallbackWarning.unknownField",
            "settings.terminal.restartCommands.fallbackWarning.missingField",
            "settings.terminal.restartCommands.fallbackWarning.invalidValue",
            "settings.terminal.restartCommands.fallbackWarning.repeatedID",
        ]

        for key in keys {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            #expect(Set(localizations.keys) == Set(neighborLocalizations.keys))
            for value in localizations.values {
                let localization = try #require(value as? [String: Any])
                let stringUnit = try #require(localization["stringUnit"] as? [String: Any])
                let text = try #require(stringUnit["value"] as? String)
                #expect(text.contains("%lld"))
                if key != "settings.terminal.restartCommands.fallbackWarning.repeatedID" {
                    #expect(text.contains("%@"))
                }
            }
        }
    }
}
