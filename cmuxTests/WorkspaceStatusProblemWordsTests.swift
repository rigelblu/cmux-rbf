import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// The sentences the footer pill shows for a problem in his status list (#cm-109.3, `unknown_icon`). Each sentence
/// names a value from his file, so a test pins that the place, the id and the value reach it, and that the line is the
/// catalog's sentence and not its key.
@Suite("Workspace status problem words")
struct WorkspaceStatusProblemWordsTests {
    @Test func anUnknownIconNamesThePlaceTheIdTheValueAndBothKindsOfIcon() {
        let line = WorkspaceStatusProblemWords.line(.unknownIcon(entry: 7, id: "parked", value: " Half "))
        #expect(line.contains("7"), "\(line)")
        #expect(line.contains("“parked”"), "\(line)")
        #expect(line.contains("“ Half ”"), "\(line)")
        // The id comes before the value, as the three arguments are in the format: a swap keeps both in the line.
        if let idAt = line.range(of: "“parked”"), let valueAt = line.range(of: "“ Half ”") {
            #expect(idAt.lowerBound < valueAt.lowerBound, "\(line)")
        }
        for name in WorkspaceStatusIcon.allCases.map(\.rawValue) {
            #expect(line.contains(name), "\(name) is missing from \(line)")
        }
        #expect(line.contains("neither one of cmux's shapes nor an SF Symbol on this Mac"), "\(line)")
        #expect(line.contains("or an SF Symbol's name in lowercase, such as moon.zzz.fill."), "\(line)")
        #expect(!line.contains("sidebar.statusFile.problem.unknownIcon"), "\(line)")
    }

    @Test func anUnknownIconHasItsOwnSentence() {
        let icon = WorkspaceStatusProblemWords.line(.unknownIcon(entry: 2, id: "a", value: "x"))
        let extends = WorkspaceStatusProblemWords.line(.unknownExtends(entry: 2, id: "a", value: "x"))
        #expect(icon != extends)
    }

    @Test func workspaceStatusesSchemaAcceptsShapesAndSymbolPatternAndNull() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let schemaURL = repositoryRoot.appendingPathComponent("web/data/cmux.schema.json")
        let data = try Data(contentsOf: schemaURL)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try #require(root["properties"] as? [String: Any])
        let workspaceStatuses = try #require(properties["workspaceStatuses"] as? [String: Any])
        let items = try #require(workspaceStatuses["items"] as? [String: Any])
        let itemProps = try #require(items["properties"] as? [String: Any])
        let icon = try #require(itemProps["icon"] as? [String: Any])
        let desc = try #require(icon["description"] as? String)
        #expect(desc.contains("moon.zzz.fill"), "description does not name moon.zzz.fill: \(desc)")
        #expect(desc.contains("Zzz"), "description does not name Zzz: \(desc)")
        #expect(desc.contains("💤"), "description does not name 💤: \(desc)")
        let anyOf = try #require(icon["anyOf"] as? [[String: Any]])
        let patternFound = anyOf.compactMap { $0["pattern"] as? String }.first
        #expect(patternFound == "^[a-z0-9]+(\\.[a-z0-9]+)*$", "pattern mismatch: \(String(describing: patternFound))")
    }
}
