import Foundation
import Testing
@testable import CmuxWorkspaces

/// The checking table of `WorkspaceStatusListParser`, one fixture per rule. Values are built the way
/// `JSONSerialization` gives them.
@Suite struct WorkspaceStatusListParserTests {
    private let parser = WorkspaceStatusListParser()

    private func good(_ id: String, _ name: String = "Name", extends: String? = "todo") -> [String: Any] {
        var entry: [String: Any] = ["id": id, "name": name]
        if let extends { entry["extends"] = extends }
        return entry
    }

    private func json(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    @Test func noKeyIsNoListAndNoProblem() {
        let result = parser.parse(nil)
        #expect(result.list == nil)
        #expect(result.problems.isEmpty)
    }

    @Test func aKeyThatIsNotAnArrayIsNotAList() throws {
        let notArrays: [Any] = [try json("{}"), try json("\"statuses\""), try json("5"), try json("true"), try json("null")]
        for value in notArrays {
            let result = parser.parse(value)
            #expect(result.list == nil, "\(value)")
            #expect(result.problems == [.notAList], "\(value)")
        }
    }

    @Test func anEmptyArrayIsAnEmptyListFromTheFile() throws {
        let result = parser.parse(try json("[]"))
        #expect(result.list == WorkspaceStatusList(entries: [], source: .file))
        #expect(result.problems.isEmpty)
    }

    @Test func anEntryThatIsNotAnObjectIsSkippedAtItsPlaceInTheFile() {
        let result = parser.parse([good("a"), "b", 5, good("c")] as [Any])
        #expect(result.list?.entries.map(\.id) == ["a", "c"])
        #expect(result.problems == [.entryNotAnObject(entry: 2), .entryNotAnObject(entry: 3)])
    }

    @Test func anEntryWithNoUsableIDIsSkipped() {
        let missing: [String: Any] = ["name": "A", "extends": "todo"]
        let notText: [String: Any] = ["id": 5, "name": "B", "extends": "todo"]
        let blank: [String: Any] = ["id": "  \n ", "name": "C", "extends": "todo"]
        let result = parser.parse([missing, notText, blank, good("kept")] as [Any])
        #expect(result.list?.entries.map(\.id) == ["kept"])
        #expect(result.problems == [.noID(entry: 1), .noID(entry: 2), .noID(entry: 3)])
    }

    @Test func autoAndNoneAreReservedInAnyCase() {
        let result = parser.parse([good("auto"), good("None"), good("NONE"), good("Auto"), good("ok")] as [Any])
        #expect(result.list?.entries.map(\.id) == ["ok"])
        #expect(result.problems == [
            .reservedID(entry: 1, id: "auto"),
            .reservedID(entry: 2, id: "None"),
            .reservedID(entry: 3, id: "NONE"),
            .reservedID(entry: 4, id: "Auto"),
        ])
    }

    @Test func aRepeatedIDKeepsTheFirst() {
        let result = parser.parse([good("a", "First"), good("b"), good("a", "Second")] as [Any])
        #expect(result.list?.entries.map(\.name) == ["First", "Name"])
        #expect(result.problems == [.repeatedID(entry: 3, id: "a")])
    }

    @Test func idsDifferingOnlyInCaseAreTwoStatuses() {
        let result = parser.parse([good("parked"), good("Parked")] as [Any])
        #expect(result.list?.entries.map(\.id) == ["parked", "Parked"])
        #expect(result.problems.isEmpty)
    }

    @Test func aSkippedEntryDoesNotTakeItsID() {
        let noName: [String: Any] = ["id": "a", "extends": "todo"]
        let result = parser.parse([noName, good("a", "Second")] as [Any])
        #expect(result.list?.entries.map(\.name) == ["Second"])
        #expect(result.problems == [.noName(entry: 1, id: "a")])
    }

    @Test func anEntryWithNoUsableNameIsSkipped() {
        let missing: [String: Any] = ["id": "a", "extends": "todo"]
        let notText: [String: Any] = ["id": "b", "name": 7, "extends": "todo"]
        let blank: [String: Any] = ["id": "c", "name": "   ", "extends": "todo"]
        let result = parser.parse([missing, notText, blank] as [Any])
        #expect(result.list?.entries.isEmpty == true)
        #expect(result.problems == [.noName(entry: 1, id: "a"), .noName(entry: 2, id: "b"), .noName(entry: 3, id: "c")])
    }

    @Test func anEntryOfHisOwnWithNoExtendsIsSkippedAndAMisspeltKeyIsAMissingKey() {
        let missing: [String: Any] = ["id": "a", "name": "A"]
        let misspelt: [String: Any] = ["id": "b", "name": "B", "extend": "todo"]
        let result = parser.parse([missing, misspelt] as [Any])
        #expect(result.list?.entries.isEmpty == true)
        #expect(result.problems == [.noExtends(entry: 1, id: "a"), .noExtends(entry: 2, id: "b")])
    }

    @Test func anExtendsThatIsBlankIsNotGiven() {
        let empty: [String: Any] = ["id": "a", "name": "A", "extends": ""]
        let spaces: [String: Any] = ["id": "b", "name": "B", "extends": "  \n "]
        let result = parser.parse([empty, spaces] as [Any])
        #expect(result.list?.entries.isEmpty == true)
        #expect(result.problems == [.noExtends(entry: 1, id: "a"), .noExtends(entry: 2, id: "b")])
    }

    @Test func anExtendsThatIsNotOneOfCmuxsFiveIsSkipped() {
        let word = good("a", extends: "paused")
        let result = parser.parse([word] as [Any])
        #expect(result.list?.entries.isEmpty == true)
        #expect(result.problems == [.unknownExtends(entry: 1, id: "a", value: "paused")])
    }

    /// A value that is not text is shown as he typed it. Parsed from file text, so booleans are the numbers
    /// `JSONSerialization` gives them and must still read `true`, not `1`.
    @Test func anExtendsThatIsNotTextIsShownAsTyped() throws {
        let typed: [(String, String)] = [
            ("true", "true"), ("false", "false"), ("5", "5"), ("null", "null"), ("1", "1"), ("0", "0"),
            ("2.5", "2.5"), ("[1, \"a\", true]", "[1,\"a\",true]"),
            ("{ \"b\": 1, \"a\": \"x/y\" }", "{\"a\":\"x/y\",\"b\":1}"),
        ]
        for (index, (written, shown)) in typed.enumerated() {
            let text = "[{ \"id\": \"e\(index)\", \"name\": \"E\", \"extends\": \(written) }]"
            let result = parser.parse(try json(text))
            #expect(result.problems == [.unknownExtends(entry: 1, id: "e\(index)", value: shown)], "\(written)")
        }
    }

    /// An unknown `extends` keeps the spaces he typed round it, in the problem's value.
    @Test func anUnknownExtendsKeepsTheSpacesHeTyped() {
        let result = parser.parse([good("a", extends: " Paused ")] as [Any])
        #expect(result.list?.entries.isEmpty == true)
        #expect(result.problems == [.unknownExtends(entry: 1, id: "a", value: " Paused ")])
    }

    /// `held` is not reserved: it is a valid id. It reaches the picker beside the greyed row, whose id begins with a
    /// space, so no two rows share an id.
    @Test func aStatusNamedHeldIsKeptAndHasItsOwnRow() {
        let result = parser.parse([good("held", "Held"), good("paused")] as [Any])
        #expect(result.problems.isEmpty)
        #expect(result.list?.entries.map(\.id) == ["held", "paused"])
        guard let list = result.list else { Issue.record("no list"); return }
        let resolution = WorkspaceStatusResolution.resolve(
            override: WorkspaceStatusFixtures.override(.working, at: .todo),
            own: nil, inferred: .todo, list: list
        )
        let rows = WorkspaceStatusPicker().rows(resolution: resolution, inferred: .todo, isHidden: false, list: list).rows
        #expect(rows.map(\.id) == ["auto", "held", "paused", " held", "none"])
        let own = WorkspaceStatusResolution.resolve(
            override: nil, own: WorkspaceOwnStatus(id: "held"), inferred: .todo, list: list
        )
        let ownRows = WorkspaceStatusPicker().rows(resolution: own, inferred: .todo, isHidden: false, list: list).rows
        #expect(ownRows.filter(\.isChecked).map(\.id) == ["held"])
        #expect(Set(ownRows.map(\.id)).count == ownRows.count)
    }

    /// The parser is public and takes `Any?`, so a caller can hand it a value no JSON file can give. Writing such a
    /// value as JSON raises an Objective-C exception that kills the process; it is shown with `String(describing:)`.
    @Test func anExtendsNoJSONFileCouldGiveIsShownWithoutCrashing() {
        let epoch = Date(timeIntervalSince1970: 0)
        let values: [(Any, String)] = [
            (epoch, "1970-01-01 00:00:00 +0000"),
            ([epoch], "[1970-01-01 00:00:00 +0000]"),
            (Double.nan, "nan"),
        ]
        for (index, (value, shown)) in values.enumerated() {
            let entry: [String: Any] = ["id": "e\(index)", "name": "E", "extends": value]
            let result = parser.parse([entry] as [Any])
            #expect(result.list?.entries.isEmpty == true)
            #expect(result.problems == [.unknownExtends(entry: 1, id: "e\(index)", value: shown)], "\(shown)")
        }
    }

    /// Ids and `extends` are matched exactly: a cmux id or an `extends` typed in another case is not cmux's.
    @Test func aCmuxIDOrAnExtendsTypedInAnotherCaseIsNotCmuxs() {
        let upperDone: [String: Any] = ["id": "Done", "name": "Done"]
        let upperExtends = good("a", extends: "Todo")
        let upperReview = good("Review", extends: "review")
        let result = parser.parse([upperDone, upperExtends, upperReview] as [Any])
        #expect(result.problems == [
            .noExtends(entry: 1, id: "Done"),
            .unknownExtends(entry: 2, id: "a", value: "Todo"),
        ])
        #expect(result.list?.entries.map(\.id) == ["Review"])
        #expect(result.list?.entries.map(\.isCmuxOwn) == [false])
    }

    @Test func everyOneOfCmuxsFiveIsAcceptedAsExtends() {
        let entries = WorkspaceTaskStatus.allCases.map { good("from-\($0.rawValue)", extends: $0.rawValue) }
        let result = parser.parse(entries as [Any])
        #expect(result.problems.isEmpty)
        #expect(result.list?.entries.map(\.extends) == WorkspaceTaskStatus.allCases.map { Optional($0) })
    }

    @Test func oneOfCmuxsFiveKeepsItselfAndIgnoresAnyExtends() {
        let withValid: [String: Any] = ["id": "review", "name": "Review", "extends": "todo"]
        let withNonsense: [String: Any] = ["id": "done", "name": "Done", "extends": "nonsense"]
        let withNone: [String: Any] = ["id": "working", "name": "Working"]
        let result = parser.parse([withValid, withNonsense, withNone] as [Any])
        #expect(result.problems.isEmpty)
        #expect(result.list?.entries.map(\.extends) == [nil, nil, nil])
        #expect(result.list?.entries.map(\.isCmuxOwn) == [true, true, true])
        #expect(result.list?.entries.map(\.behavesAs) == [.review, .done, .working])
    }

    @Test func aColorIsKeptAsTypedAndAnythingElseKeepsTheEntryWithNoColor() {
        var typed = good("a"); typed["color"] = "2: REVIEW"
        var hex = good("b"); hex["color"] = "#ff8800"
        let missing = good("c")
        var notText = good("d"); notText["color"] = 12
        var blank = good("e"); blank["color"] = "  "
        var empty = good("f"); empty["color"] = ""
        var spaced = good("g"); spaced["color"] = "  2: REVIEW \n"
        let result = parser.parse([typed, hex, missing, notText, blank, empty, spaced] as [Any])
        #expect(result.problems.isEmpty)
        #expect(result.list?.entries.map(\.color) == ["2: REVIEW", "#ff8800", nil, nil, nil, nil, "  2: REVIEW \n"])
    }

    @Test func aFieldTheParserDoesNotKnowIsIgnored() {
        var entry = good("a"); entry["hidden"] = true; entry["whatever"] = ["x": 1]
        let result = parser.parse([entry] as [Any])
        #expect(result.problems.isEmpty)
        #expect(result.list?.entries == [WorkspaceStatusEntry(id: "a", name: "Name", extends: .todo, color: nil)])
    }

    @Test func idAndNameAreKeptTrimmed() {
        let entry: [String: Any] = ["id": "  parked ", "name": " Parked\n", "extends": " todo "]
        let result = parser.parse([entry] as [Any])
        #expect(result.problems.isEmpty)
        #expect(result.list?.entries == [WorkspaceStatusEntry(id: "parked", name: "Parked", extends: .todo, color: nil)])
    }

    /// An entry that breaks two rules gets one problem: the first rule of the table, top to bottom.
    @Test func anEntryThatBreaksTwoRulesGetsTheFirstProblemOnly() {
        let reservedAndNoName: [String: Any] = ["id": "auto"]
        let repeatedAndNoName: [String: Any] = ["id": "a"]
        let noNameAndNoExtends: [String: Any] = ["id": "b"]
        let noIDAndNoName: [String: Any] = [:]
        let result = parser.parse([good("a"), reservedAndNoName, repeatedAndNoName, noNameAndNoExtends, noIDAndNoName] as [Any])
        #expect(result.problems == [
            .reservedID(entry: 2, id: "auto"),
            .repeatedID(entry: 3, id: "a"),
            .noName(entry: 4, id: "b"),
            .noID(entry: 5),
        ])
    }

    /// His real block, parsed whole: eleven entries in the file's order, no problem.
    @Test func hisBlockParsesWholeInTheFilesOrder() throws {
        let text = """
        [
          { "id": "dogfood",         "name": "Dogfood",           "extends": "review",  "color": "2: DOGFOOD" },
          { "id": "done",            "name": "Done",                                    "color": "1: DONE" },
          { "id": "review",          "name": "Review",                                  "color": "2: REVIEW" },
          { "id": "paused",          "name": "Paused",            "extends": "todo",    "color": "3: PAUSED" },
          { "id": "blocked",         "name": "Blocked",           "extends": "todo",    "color": "3: BLOCKED" },
          { "id": "doing-primary",   "name": "Doing (Primary)",   "extends": "working", "color": "3: DOING (Primary)" },
          { "id": "doing-secondary", "name": "Doing (Secondary)", "extends": "working", "color": "3: DOING (Secondary)" },
          { "id": "next",            "name": "Next",              "extends": "todo",    "color": "4: NEXT" },
          { "id": "upcoming",        "name": "Upcoming",          "extends": "todo",    "color": "5: UPCOMING" },
          { "id": "parked",          "name": "Parked",            "extends": "todo",    "color": "5: PARKED" },
          { "id": "future",          "name": "Future",            "extends": "todo",    "color": "6: FUTURE" }
        ]
        """
        let result = parser.parse(try json(text))
        #expect(result.problems.isEmpty)
        #expect(result.list == WorkspaceStatusFixtures.toms)
    }
}
