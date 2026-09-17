import Foundation
import Testing
@testable import CmuxRestartCommands

@Suite("Restart command schema")
struct RestartCommandSchemaTests {
    @Test func materializedSchemaMatchesParserRules() throws {
        let data = try #require(RestartCommandSchema.materializedData())
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try dictionary(root["properties"])
        let definitions = try dictionary(properties["definitions"])
        let items = try dictionary(definitions["items"])
        let definitionProperties = try dictionary(items["properties"])
        let match = try dictionary(definitionProperties["match"])
        let matchProperties = try dictionary(match["properties"])

        let executable = try dictionary(matchProperties["executable"])
        #expect(executable["pattern"] as? String == RestartCommandDefinitionSet.pathComponentPattern)

        let environment = try dictionary(matchProperties["environment"])
        let propertyNames = try dictionary(environment["propertyNames"])
        #expect(propertyNames["pattern"] as? String == RestartCommandDefinitionSet.environmentNamePattern)
        #expect(environment["minProperties"] as? Int == 1)
        #expect(environment["maxProperties"] as? Int == RestartCommandDefinitionSet.maximumEnvironmentPredicateCount)

        let predicate = try dictionary(environment["additionalProperties"])
        let predicateProperties = try dictionary(predicate["properties"])
        let component = try dictionary(predicateProperties["normalizedFinalComponent"])
        #expect(component["pattern"] as? String == RestartCommandDefinitionSet.pathComponentPattern)
        let alternatives = try #require(predicate["oneOf"] as? [Any])
        #expect(alternatives.count == 2)
        let branches = try alternatives.map { try dictionary($0) }
        let present = try #require(branches.first { branch in
            guard let properties = branch["properties"] as? [String: Any],
                  let state = properties["state"] as? [String: Any] else { return false }
            return state["const"] as? String == "present"
        })
        #expect((present["required"] as? [String]) == ["normalizedFinalComponent"])

        let absent = try #require(branches.first { branch in
            guard let properties = branch["properties"] as? [String: Any],
                  let state = properties["state"] as? [String: Any] else { return false }
            return state["const"] as? String == "absent"
        })
        let absentNot = try dictionary(absent["not"])
        #expect((absentNot["required"] as? [String]) == ["normalizedFinalComponent"])

        let command = try dictionary(definitionProperties["command"])
        let description = try #require(command["description"] as? String)
        for forbidden in ["$", "`", "!", "*", "?", "[", "{", "}", ";", "|", "&", "<", ">", "(", ")", "~", "="] {
            #expect(description.contains(forbidden))
        }
    }

    private func dictionary(
        _ value: Any?,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> [String: Any] {
        try #require(value as? [String: Any], sourceLocation: sourceLocation)
    }
}
